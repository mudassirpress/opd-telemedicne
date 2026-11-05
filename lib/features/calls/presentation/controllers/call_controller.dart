// lib/features/calls/presentation/controllers/call_controller.dart
//
// High-performance voice call controller bridging legacy references to the new
// clean calling module architecture in `lib/features/calling/`.

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/local/offline_call_service.dart';
import 'package:telemedicine/data/models/call_model.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart' as new_calling;
import 'package:telemedicine/features/calling/domain/call_status.dart';

class CallController {
  static final CallController _instance = CallController._internal();
  factory CallController() => _instance;
  CallController._internal();

  final new_calling.CallController _callingController =
      new_calling.CallController.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final Map<String, StreamSubscription<DocumentSnapshot>> _onlineStatusSubscriptions = {};
  final Map<String, StreamController<bool>> _userOnlineStatusControllers = {};

  // Stream forwarders
  Stream<bool> get isUserBusy => const Stream.empty();
  Stream<bool> get microphoneState =>
      _callingController.microphoneMutedStream.map((muted) => !muted);
  Stream<bool> get speakerState => _callingController.speakerPhoneStream;
  Stream<bool> get cameraState => const Stream.empty();
  Stream<String> get errors => const Stream.empty();
  Stream<Map<String, dynamic>> get networkQuality => const Stream.empty();
  Stream<bool> get recordingState => const Stream.empty();
  Stream<String> get onRemoteStreamAdded => const Stream.empty();
  Stream<bool> get onConnectionState =>
      _callingController.activeCallStream.map((c) => c != null);
  Stream<String> get onLocalStreamPublished => const Stream.empty();
  Stream<String> get callStatus =>
      _callingController.activeCallStream.map((c) => c?.status ?? 'ended');

  bool get isJoined => _callingController.isCallActive;
  bool get isInitialized => true;
  bool get isRecording => false;
  bool get isPreWarmed => true;
  String? get activeCallId => _callingController.activeCallId;
  String? get activeCallStatus => _callingController.activeCallStatus;
  bool get isCallActive => _callingController.isCallActive;

  Future<void> preWarmEngine() => _callingController.preWarmEngine();

  Future<void> initializeZego({bool enableVideo = false}) async {
    await _callingController.preWarmEngine();
  }

  void resetForScreen() {
    stopAllOnlineStatusMonitoring();
  }

  void dispose() {
    stopAllOnlineStatusMonitoring();
  }

  Future<void> softReset() async {
    final activeId = _callingController.activeCallId;
    if (activeId != null && activeId.isNotEmpty) {
      await _callingController.endCall(activeId, endReason: 'soft_reset');
    }
  }

  Future<void> destroyEngine() async {
    await softReset();
  }

  Future<bool> requestPermissions({required bool isVideoCall}) async {
    final perms = [Permission.microphone];
    if (isVideoCall) perms.add(Permission.camera);
    final results = await perms.request();
    return results.values.every((s) => s == PermissionStatus.granted);
  }

  Future<Map<String, dynamic>> startCallWithBusyCheck({
    required String channelId,
    required String callerId,
    required String receiverId,
    required String callerName,
    required String receiverName,
    required String receiverType,
    String? callerImage,
    String? receiverImage,
    required String callType,
    String? callerType,
  }) =>
      startCallWithCheck(
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

  Future<Map<String, dynamic>> startCallWithCheck({
    required String channelId,
    required String callerId,
    required String receiverId,
    required String callerName,
    required String receiverName,
    required String receiverType,
    String? callerImage,
    String? receiverImage,
    required String callType,
    String? callerType,
  }) async {
    return await _callingController.initiateVoiceCall(
      callerId: callerId,
      callerName: callerName,
      callerRole: callerType ?? 'patient',
      callerImage: callerImage,
      receiverId: receiverId,
      receiverName: receiverName,
      receiverRole: receiverType,
      receiverImage: receiverImage,
    );
  }

  Future<bool> acceptCall(String callId, {String? userId, String? userName}) =>
      _callingController.acceptCall(callId, userId: userId, userName: userName);

  Future<bool> rejectCall(String callId, {String? rejectedBy}) =>
      _callingController.rejectCall(callId, rejectedBy: rejectedBy);

  Future<bool> cancelCall(String callId) =>
      _callingController.cancelCall(callId);

  Future<void> endCall(String callId, {String? endReason}) =>
      _callingController.endCall(callId, endReason: endReason);

  Future<void> missCall(String callId) => _callingController.missCall(callId);

  Future<void> terminateAndCleanupCall({
    required String callId,
    required String reason,
  }) =>
      _callingController.endCall(callId, endReason: reason);

  Future<void> muteMicrophone(bool mute) => _callingController.toggleMute();

  Future<void> handleAppKilledDuringCall() async {
    final activeId = _callingController.activeCallId;
    if (activeId != null && activeId.isNotEmpty) {
      await _callingController.endCall(activeId, endReason: 'app_killed');
    }
  }

  Future<bool> isUserOnCall(String userId) async {
    return await _callingController.checkPatientAvailability(userId).then(
      (m) => m['busy'] == true,
    );
  }

  Future<Map<String, dynamic>> checkDoctorReachability(String doctorId) =>
      _callingController.checkDoctorAvailability(doctorId).then((m) => {
            'isReachable': m['available'] == true,
            'reason': m['reason'],
          });

  Future<Map<String, dynamic>> checkPatientReachability(String patientId) =>
      _callingController.checkPatientAvailability(patientId).then((m) => {
            'isReachable': m['available'] == true,
            'reason': m['reason'],
          });

  Stream<CallModel?> incomingCallStream(String userId) {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return const Stream.empty();

    return _firestore
        .collection(FirestoreCollections.calls)
        .where('receiverId', isEqualTo: cleanId)
        .limit(10)
        .snapshots()
        .map((snap) {
      for (final doc in snap.docs) {
        final data = doc.data();
        final status = (data['callStatus'] ?? data['status'])?.toString();
        if (CallingStatus.isRinging(status)) {
          return CallModel.fromMap(data, doc.id);
        }
      }
      return null;
    });
  }

  Stream<CallModel?> watchCall(String callId) {
    return _firestore
        .collection(FirestoreCollections.calls)
        .doc(callId)
        .snapshots()
        .map((s) {
      if (!s.exists || s.data() == null) return null;
      try {
        return CallModel.fromMap(s.data()!, s.id);
      } catch (e) {
        debugPrint('watchCall parse error for $callId: $e');
        return null;
      }
    });
  }

  Future<CallModel?> getCall(String callId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      return doc.exists && doc.data() != null
          ? CallModel.fromMap(doc.data()!, doc.id)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteCallHistory(String callId) async {
    await OfflineCallService.instance.deleteCall(callId);
    try {
      await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .delete();
    } catch (e) {
      debugPrint('deleteCallHistory error: $e');
    }
  }

  Stream<List<CallModel>> getCallHistory(String userId) {
    return _callingController.getCallHistoryStream(userId).map((list) {
      return list.map((c) {
        return CallModel(
          id: c.callId,
          callerId: c.callerId,
          receiverId: c.receiverId,
          callerName: c.callerName,
          receiverName: c.receiverName,
          callerImage: c.callerImage,
          receiverImage: c.receiverImage,
          callerType: c.callerRole,
          receiverRole: c.receiverRole,
          channelId: c.roomId,
          callType: c.callType,
          callStatus: c.status,
          startTime: c.createdAt,
          acceptedAt: c.acceptedAt,
          endedAt: c.endedAt,
          duration: c.duration,
          endReason: c.endReason,
          missedCall: c.missedCall,
          rejectedBy: c.rejectedBy,
          callerDeviceId: c.callerDeviceId,
          receiverDeviceId: c.receiverDeviceId,
        );
      }).toList();
    });
  }

  // ─────────────────────────────────────────────────────────────
  // PRESENCE & ONLINE STATUS STREAM
  // ─────────────────────────────────────────────────────────────

  bool _isDoctorPresenceOnline(Map<String, dynamic> data) {
    final manualAvailability =
        data['manualAvailability'] as bool? ??
        data['isOnline'] as bool? ??
        false;
    final isActive = data['isActive'] as bool? ?? true;
    final isDeleted = data['isDeleted'] as bool? ?? false;
    final isSuspended = data['isSuspended'] as bool? ?? false;
    final accountStatus = data['accountStatus'] as String? ?? 'Active';
    return manualAvailability &&
        isActive &&
        !isDeleted &&
        !isSuspended &&
        accountStatus == 'Active';
  }

  Future<bool> checkUserOnlineStatus({
    required String userId,
    required String userType,
  }) async {
    try {
      final col = userType == 'doctor'
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;
      final doc = await _firestore.collection(col).doc(userId).get();
      if (!doc.exists || doc.data() == null) return false;
      final data = doc.data()!;
      if (userType == 'doctor') {
        return _isDoctorPresenceOnline(data);
      } else {
        final isOnline = data['isOnline'] as bool? ?? false;
        final lastSeen = data['lastSeen'] as Timestamp?;
        if (!isOnline && lastSeen != null) {
          final diff = DateTime.now().difference(lastSeen.toDate());
          if (diff.inSeconds < 60) return true;
        }
        return isOnline;
      }
    } catch (e) {
      debugPrint('checkUserOnlineStatus error: $e');
      return false;
    }
  }

  Stream<dynamic> checkUserOnlineStatusStream({
    required String userId,
    required String userType,
  }) {
    final col = userType == 'doctor'
        ? FirestoreCollections.doctors
        : FirestoreCollections.patients;
    return _firestore.collection(col).doc(userId).snapshots().map((doc) {
      if (!doc.exists || doc.data() == null) return false;
      final data = doc.data()!;
      if (userType == 'doctor') {
        return _isDoctorPresenceOnline(data);
      } else {
        final isOnline = data['isOnline'] as bool? ?? false;
        final lastSeen = data['lastSeen'] as Timestamp?;
        if (!isOnline && lastSeen != null) {
          final diff = DateTime.now().difference(lastSeen.toDate());
          if (diff.inSeconds < 60) return true;
        }
        return isOnline;
      }
    }).distinct();
  }

  void startMonitoringUserOnlineStatus({
    required String userId,
    required String userType,
    required Function(bool) onStatusChange,
  }) {
    _onlineStatusSubscriptions[userId]?.cancel();
    final col = userType == 'doctor'
        ? FirestoreCollections.doctors
        : FirestoreCollections.patients;
    _onlineStatusSubscriptions[userId] =
        _firestore.collection(col).doc(userId).snapshots().listen((doc) {
      if (!doc.exists || doc.data() == null) {
        onStatusChange(false);
        return;
      }
      final data = doc.data()!;
      if (userType == 'doctor') {
        onStatusChange(_isDoctorPresenceOnline(data));
        return;
      }
      final isOnline = data['isOnline'] as bool? ?? false;
      final lastSeen = data['lastSeen'] as Timestamp?;
      if (!isOnline && lastSeen != null) {
        final diff = DateTime.now().difference(lastSeen.toDate());
        if (diff.inMinutes < 2) {
          onStatusChange(true);
          return;
        }
      }
      onStatusChange(isOnline);
    });
  }

  void stopMonitoringUserOnlineStatus(String userId) {
    _onlineStatusSubscriptions[userId]?.cancel();
    _onlineStatusSubscriptions.remove(userId);
  }

  void stopAllOnlineStatusMonitoring() {
    for (final sub in _onlineStatusSubscriptions.values) {
      sub.cancel();
    }
    _onlineStatusSubscriptions.clear();
    for (final ctrl in _userOnlineStatusControllers.values) {
      ctrl.close();
    }
    _userOnlineStatusControllers.clear();
  }

  Stream<bool> getUserOnlineStatusController({
    required String userId,
    required String userType,
  }) {
    if (_userOnlineStatusControllers.containsKey(userId)) {
      return _userOnlineStatusControllers[userId]!.stream;
    }

    final controller = StreamController<bool>.broadcast();
    _userOnlineStatusControllers[userId] = controller;

    final col = userType == 'doctor'
        ? FirestoreCollections.doctors
        : FirestoreCollections.patients;

    _onlineStatusSubscriptions[userId] =
        _firestore.collection(col).doc(userId).snapshots().listen((doc) {
      if (!doc.exists || doc.data() == null) {
        controller.add(false);
        return;
      }
      final data = doc.data()!;
      if (userType == 'doctor') {
        controller.add(_isDoctorPresenceOnline(data));
        return;
      }
      final isOnline = data['isOnline'] as bool? ?? false;
      final lastSeen = data['lastSeen'] as Timestamp?;
      if (!isOnline && lastSeen != null) {
        final diff = DateTime.now().difference(lastSeen.toDate());
        if (diff.inMinutes < 2) {
          controller.add(true);
          return;
        }
      }
      controller.add(isOnline);
    });

    return controller.stream.distinct();
  }
}
