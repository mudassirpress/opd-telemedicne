import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/services/notification_service.dart';

/// Native incoming-call surface (CallKit on iOS, full-screen notification on
/// Android).
///
/// The Firestore watcher and the foreground FCM handler keep using the in-app
/// [IncomingCallScreen]. This service is only used from the background FCM
/// isolate, where Flutter cannot show a screen, and from `configure()` to
/// route accept/decline/timeout events back through [IncomingCallCoordinator].
class CallKitService {
  CallKitService._();

  static final CallKitService instance = CallKitService._();

  static const String _appName = 'Telemedicine';
  static const String _channelName = 'Incoming calls';
  static const String _missedChannelName = 'Missed calls';

  StreamSubscription<CallEvent?>? _eventsSub;
  final Set<String> _activeCallIds = <String>{};

  bool get isConfigured => _eventsSub != null;

  bool isActive(String callId) => _activeCallIds.contains(callId);

  /// Binds the native event stream. Call only from the main isolate, after
  /// `NotificationService.initialize()` has installed the coordinator hooks.
  Future<void> configure() async {
    if (_eventsSub != null) return;

    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        'title': 'Call notifications',
        'rationaleMessagePermission':
            'Notification permission is required to show incoming calls.',
        'postNotificationMessageRequired':
            'Allow notifications in system settings to receive calls.',
      });
      await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (e) {
      debugPrint('[CallKit] permission request failed: $e');
    }

    _eventsSub = FlutterCallkitIncoming.onEvent.listen(
      _handleEvent,
      onError: (Object e) => debugPrint('[CallKit] event stream error: $e'),
    );

    unawaited(_restoreAcceptedCall());
  }

  Future<void> dispose() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    _activeCallIds.clear();
  }

  /// Shows the native ringing UI. Safe to call from the background isolate.
  ///
  /// Returns `true` when the plugin accepted the call. Callers may fall back to
  /// the local notification presenter when it returns `false`.
  Future<bool> showIncomingCall(IncomingCallPayload payload) async {
    if (payload.callId.isEmpty) return false;

    if (payload.isExpired) {
      debugPrint('[CallKit] refusing expired call ${payload.callId}');
      unawaited(
        NotificationService().showMissedCallNotification(
          callId: payload.callId,
          callerName: payload.callerName,
          callType: payload.callType,
          callerImage: payload.callerImage,
        ),
      );
      return false;
    }

    try {
      final params = _toParams(payload);
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      _activeCallIds.add(payload.callId);
      return true;
    } catch (e, s) {
      debugPrint('[CallKit] show failed for ${payload.callId}: $e\n$s');
      return false;
    }
  }

  /// Removes the native ringing UI. Safe to call from either isolate.
  Future<void> hide(String callId) async {
    if (callId.isEmpty) return;
    _activeCallIds.remove(callId);
    try {
      await FlutterCallkitIncoming.hideCallkitIncoming(
        CallKitParams(id: callId),
      );
    } catch (e) {
      debugPrint('[CallKit] hide failed for $callId: $e');
    }
  }

  /// Closes all active CallKit native ringing surfaces.
  Future<void> endAll() async {
    _activeCallIds.clear();
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e) {
      debugPrint('[CallKit] endAll failed: $e');
    }
  }

  /// Delivery acknowledgement written by the background isolate. Moving the
  /// call from `calling` to `ringing` makes the callee visible to the caller
  /// and lets the accept path pass the coordinator's `canAccept` gate.
  Future<void> acknowledgeDelivery(IncomingCallPayload payload) async {
    try {
      final ref = FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(payload.callId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final data = snap.data() ?? <String, dynamic>{};
        final status =
            (data[CallPayloadKeys.callStatus] ?? data['status'] ?? '')
                .toString();
        if (status != CallStatus.calling &&
            status != CallStatus.incoming &&
            status != '') {
          return;
        }
        tx.update(ref, <String, dynamic>{
          CallPayloadKeys.callStatus: CallStatus.ringing,
          'status': CallStatus.ringing,
          'deliveredAt': FieldValue.serverTimestamp(),
          'deliveredTo': payload.receiverId,
        });
      });
      if (payload.receiverId.isEmpty) return;
      final receiverType = (payload.callerType == 'doctor')
          ? 'patient'
          : 'doctor';
      final collection = receiverType == 'doctor'
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(payload.receiverId)
          .set(<String, dynamic>{
            'lastCallAckAt': FieldValue.serverTimestamp(),
            'lastSeen': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[CallKit] delivery ack failed for ${payload.callId}: $e');
    }
  }

  CallKitParams _toParams(IncomingCallPayload payload) {
    final extra = <String, dynamic>{
      ...payload.toMap(),
      CallPayloadKeys.callId: payload.callId,
    };

    return CallKitParams(
      id: payload.callId,
      nameCaller: payload.callerName,
      appName: _appName,
      avatar: payload.callerImage.isEmpty ? null : payload.callerImage,
      handle: payload.callerId,
      type: payload.isVideo ? 1 : 0,
      duration: 45000,
      extra: extra,
      android: const AndroidParams(
        isCustomNotification: false,
        isShowLogo: true,
        isShowCallID: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0B1220',
        actionColor: '#22C55E',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: _channelName,
        missedCallNotificationChannelName: _missedChannelName,
        isShowFullLockedScreen: true,
        isImportant: true,
        isFullScreen: true,
        textAccept: 'Accept',
        textDecline: 'Decline',
      ),
      ios: IOSParams(
        handleType: 'generic',
        supportsVideo: payload.isVideo,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        includesCallsInRecents: true,
        configureAudioSession: true,
        audioSessionMode: 'default',
        audioSessionActive: true,
      ),
    );
  }

  void _handleEvent(CallEvent? event) {
    if (event == null) return;

    if (event is CallEventActionCallAccept) {
      final payload = _payloadFrom(event.callKitParams);
      _activeCallIds.remove(event.callKitParams.id);
      if (payload != null) {
        unawaited(_accept(payload));
      }
      return;
    }

    if (event is CallEventActionCallDecline) {
      final payload = _payloadFrom(event.callKitParams);
      _activeCallIds.remove(event.callKitParams.id);
      if (payload != null) {
        unawaited(
          IncomingCallCoordinator.instance.declineFromNotification(payload),
        );
      }
      return;
    }

    if (event is CallEventActionCallEnded) {
      _activeCallIds.remove(event.callKitParams.id);
      return;
    }

    if (event is CallEventActionCallTimeout) {
      _activeCallIds.remove(event.id);
      unawaited(_markMissed(event.id));
      return;
    }

    if (event is CallEventActionCallConnected) {
      _activeCallIds.remove(event.id);
    }
  }

  Future<void> _accept(IncomingCallPayload payload) async {
    await acknowledgeDelivery(payload);
    await IncomingCallCoordinator.instance.acceptAndOpenCallScreen(payload);
  }

  Future<void> _markMissed(String callId) async {
    if (callId.isEmpty) return;
    try {
      final ref = FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(callId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final data = snap.data() ?? <String, dynamic>{};
        final status =
            (data[CallPayloadKeys.callStatus] ?? data['status'] ?? '')
                .toString();
        if (!CallStatus.isRinging(status)) return;
        tx.update(ref, <String, dynamic>{
          CallPayloadKeys.callStatus: CallStatus.missed,
          'status': CallStatus.missed,
          'endedAt': DateTime.now().toUtc().toIso8601String(),
        });
      });
      final snap = await ref.get();
      if (snap.exists) {
        final data = snap.data() ?? <String, dynamic>{};
        await NotificationService().showMissedCallNotification(
          callId: callId,
          callerName: (data['callerName'] ?? 'Doctor').toString(),
          callType: (data['callType'] ?? 'call').toString(),
          callerImage: data['callerImage']?.toString(),
        );
      }
    } catch (e) {
      debugPrint('[CallKit] missed transition failed for $callId: $e');
    }
  }

  IncomingCallPayload? _payloadFrom(CallKitParams params) {
    final extra = params.extra;
    if (extra != null && extra.isNotEmpty) {
      final parsed = IncomingCallPayload.tryParse(
        extra.map((k, v) => MapEntry(k.toString(), v)),
      );
      if (parsed != null) return parsed;
    }

    return IncomingCallPayload.tryParse(<String, dynamic>{
      CallPayloadKeys.callId: params.id,
      CallPayloadKeys.callerName: params.nameCaller ?? 'Unknown Caller',
      CallPayloadKeys.callerId: params.handle ?? '',
      CallPayloadKeys.callType: params.type == 1 ? 'video' : 'audio',
      CallPayloadKeys.timestamp: DateTime.now().millisecondsSinceEpoch
          .toString(),
    });
  }

  Future<void> _restoreAcceptedCall() async {
    try {
      final active = await FlutterCallkitIncoming.activeCalls();
      for (final params in active) {
        if (!params.isAccepted) continue;
        final payload = _payloadFrom(params);
        if (payload == null) continue;
        await acknowledgeDelivery(payload);
        await IncomingCallCoordinator.instance.acceptAndOpenCallScreen(payload);
      }
    } catch (e) {
      debugPrint('[CallKit] restore active call failed: $e');
    }
  }
}
