import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/fcm_token_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';

/// Single entry point for placing calls and for the callee-side Firestore
/// listener.
///
/// Call documents keep their legacy field names (`callStatus`, `startTime`) and
/// also carry the newer aliases (`status`, `createdAt`) so either contract can
/// be consumed. The listener intentionally filters the status client-side: a
/// `where(callStatus == 'ringing')` query misses the `calling` state that the
/// caller writes first, which was the reason foreground calls never surfaced.
class CallService {
  CallService._();

  static final CallService instance = CallService._();

  static const int _ringTimeoutMs = 45000;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FCMServiceV2 _fcm = FCMServiceV2();
  final CallController _callController = CallController();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _incomingSub;
  String? _watchedUserId;

  /// Places a call, writes the call document and pushes the invitation to the
  /// receiver's device.
  Future<Map<String, dynamic>> startCall({
    required String callerId,
    required String callerName,
    required String receiverId,
    required String receiverName,
    required String channelId,
    required String callType,
    String? callerImage,
    String? receiverImage,
    String? callerType,
    String receiverType = 'patient',
  }) async {
    final result = await _callController.startCallWithCheck(
      channelId: channelId,
      callerId: callerId,
      receiverId: receiverId,
      callerName: callerName,
      receiverName: receiverName,
      receiverType: receiverType,
      callerImage: callerImage,
      receiverImage: receiverImage,
      callType: callType,
      callerType: callerType,
    );

    if (result['success'] != true) return result;

    final callId = (result['callId'] ?? '').toString();
    if (callId.isEmpty) return result;

    final receiverToken = await _resolveFcmToken(
      receiverId,
      preferredRole: receiverType,
    );
    if (receiverToken == null || receiverToken.isEmpty) {
      debugPrint(
        '[CallService] no FCM token for receiver=$receiverId '
        '(callId=$callId); the Firestore listener is the fallback',
      );
      return result;
    }

    unawaited(
      _fcm.sendCallNotification(
        receiverToken: receiverToken,
        callerName: callerName,
        callType: callType,
        callId: callId,
        channelId: channelId,
        callerImage: callerImage,
        callerId: callerId,
        callerType: callerType,
        receiverId: receiverId,
        receiverType: receiverType,
        targetModule: 'opd_telemedicine',
        expiresAtMillis: DateTime.now().millisecondsSinceEpoch + _ringTimeoutMs,
      ),
    );

    return result;
  }

  /// Watches every call addressed to [userId] and funnels still-ringing ones
  /// through [IncomingCallCoordinator] (dedup, screen, notification).
  ///
  /// Only the `receiverId` equality filter is used, so no composite index is
  /// required and documents in the pre-delivery `calling` state are included.
  Future<void> watchIncomingCalls(String userId) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return;
    if (_watchedUserId == cleanId && _incomingSub != null) return;

    await stopWatchingIncomingCalls();
    _watchedUserId = cleanId;

    _incomingSub = _firestore
        .collection(FirestoreCollections.calls)
        .where(CallPayloadKeys.receiverId, isEqualTo: cleanId)
        .limit(20)
        .snapshots()
        .listen(
          (snapshot) {
            if (!_isAppForeground) return;

            final now = DateTime.now();
            for (final doc in snapshot.docs) {
              final data = Map<String, dynamic>.from(doc.data());
              final status = _statusOf(data);
              if (!CallStatus.isRinging(status)) continue;

              final started = _parseTime(
                data['startTime'] ?? data['createdAt'] ?? data['startTimeIso'],
              );
              if (started != null && now.difference(started).inSeconds > 90) {
                continue;
              }

              unawaited(_handleIncomingDocument(doc.id, data));
            }
          },
          onError: (Object e, StackTrace s) {
            debugPrint('[CallService] incoming call watcher error: $e\n$s');
          },
        );
  }

  Future<void> stopWatchingIncomingCalls() async {
    await _incomingSub?.cancel();
    _incomingSub = null;
    _watchedUserId = null;
  }

  Future<void> _handleIncomingDocument(
    String callId,
    Map<String, dynamic> data,
  ) async {
    final status = _statusOf(data);
    if (!CallStatus.isRinging(status)) return;

    final channelId = _str(
      data[CallPayloadKeys.channelId] ?? data[CallPayloadKeys.roomId],
    );
    final callerType = _str(
      data[CallPayloadKeys.callerType] ?? data['callerRole'],
    );

    final payload = <String, dynamic>{
      ...data,
      CallPayloadKeys.callId: callId,
      CallPayloadKeys.callerId: _str(
        data[CallPayloadKeys.callerId] ?? data['callerUid'],
      ),
      CallPayloadKeys.callerName: _str(
        data[CallPayloadKeys.callerName] ?? data['caller'],
      ),
      CallPayloadKeys.callerImage: _str(
        data[CallPayloadKeys.callerImage] ?? data['callerAvatar'],
      ),
      CallPayloadKeys.receiverId: _str(data[CallPayloadKeys.receiverId]),
      CallPayloadKeys.callerType: callerType.isEmpty ? 'doctor' : callerType,
      CallPayloadKeys.callType:
          _str(data[CallPayloadKeys.callType]).toLowerCase() == 'video'
          ? 'video'
          : 'audio',
      CallPayloadKeys.channelId: channelId,
      CallPayloadKeys.roomId: channelId,
      CallPayloadKeys.timestamp: _str(
        data[CallPayloadKeys.timestamp] ?? data['startTimeIso'],
      ),
      CallPayloadKeys.callStatus: status,
    };

    final parsed = IncomingCallPayload.tryParse(payload);
    if (parsed == null) return;

    // A CallKit surface from the background isolate cannot be observed in the
    // static set above in every process configuration; ask the plugin directly
    // so the same call never rings twice.
    try {
      final active = await FlutterCallkitIncoming.activeCalls();
      if (active.any((c) => c.id == callId)) return;
    } catch (_) {
      // Plugin unavailable (tests/desktop): fall through to the coordinator.
    }

    await IncomingCallCoordinator.instance.registerIncomingCall(
      payload,
      origin: IncomingCallOrigin.firestoreWatcher,
    );
  }

  Future<bool> acceptCall(String callId) => _callController.acceptCall(callId);

  Future<bool> declineCall(String callId) => _callController.rejectCall(callId);

  Future<void> endCall(String callId) => _callController.endCall(callId);

  Future<void> terminateAndCleanupCall({
    required String callId,
    required String reason,
  }) =>
      _callController.terminateAndCleanupCall(callId: callId, reason: reason);

  Future<void> cancelCall(String callId) => _callController.cancelCall(callId);

  Future<String?> _resolveFcmToken(
    String userId, {
    String? preferredRole,
  }) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return null;

    final collections = <String>[
      if (preferredRole == 'doctor') FirestoreCollections.doctors,
      if (preferredRole == 'patient') FirestoreCollections.patients,
      if (preferredRole != 'doctor') FirestoreCollections.doctors,
      if (preferredRole != 'patient') FirestoreCollections.patients,
    ];

    for (final collection in collections) {
      try {
        final doc = await _firestore.collection(collection).doc(cleanId).get();
        final token = _str(doc.data()?['fcmToken']);
        if (token.isNotEmpty) return token;
      } catch (e) {
        debugPrint('[CallService] token lookup failed in $collection: $e');
      }
    }
    return null;
  }

  static bool get _isAppForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  static String _statusOf(Map<String, dynamic> data) =>
      _str(data[CallPayloadKeys.callStatus] ?? data['status']);

  static String _str(dynamic value) => value?.toString().trim() ?? '';

  static DateTime? _parseTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
