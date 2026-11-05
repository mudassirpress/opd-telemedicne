// lib/features/calling/controllers/call_controller.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/call_session_manager.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/features/calling/data/repositories/call_repository.dart';
import 'package:telemedicine/features/calling/domain/call_model.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';
import 'package:telemedicine/features/calling/services/call_audio_service.dart';
import 'package:telemedicine/features/calling/services/call_notification_service.dart';
import 'package:telemedicine/features/calling/services/call_permission_service.dart';
import 'package:telemedicine/features/calling/services/zego_call_service.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';

class CallController {
  static final CallController instance = CallController._internal();
  factory CallController() => instance;
  CallController._internal();

  final CallRepository _repository = CallRepository();
  final ZegoCallService _zegoService = ZegoCallService.instance;
  final CallAudioService _audioService = CallAudioService.instance;
  final CallNotificationService _notificationService =
      CallNotificationService.instance;
  final CallPermissionService _permissionService =
      CallPermissionService.instance;
  final ChatController _chatController = ChatController();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Active call state
  VoiceCallModel? _activeCall;
  Timer? _ringTimeoutTimer;
  Timer? _durationTimer;
  int _callDuration = 0;
  bool _isConnecting = false;

  // Streams
  final StreamController<VoiceCallModel?> _activeCallController =
      StreamController<VoiceCallModel?>.broadcast();
  final StreamController<int> _callDurationController =
      StreamController<int>.broadcast();
  final StreamController<bool> _microphoneMutedController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _speakerPhoneController =
      StreamController<bool>.broadcast();

  Stream<VoiceCallModel?> get activeCallStream => _activeCallController.stream;
  Stream<int> get durationStream => _callDurationController.stream;
  Stream<bool> get microphoneMutedStream => _microphoneMutedController.stream;
  Stream<bool> get speakerPhoneStream => _speakerPhoneController.stream;

  VoiceCallModel? get activeCall => _activeCall;
  String? get activeCallId => _activeCall?.callId;
  String? get activeCallStatus => _activeCall?.status;
  int get callDuration => _callDuration;
  bool get isDurationTimerRunning =>
      _durationTimer != null && _durationTimer!.isActive;
  bool get isCallActive =>
      _activeCall != null && !CallingStatus.isTerminal(_activeCall!.status);

  /// Pre-warms the Zego engine and microphone permission on app startup.
  Future<void> preWarmEngine() async {
    try {
      await _permissionService.checkAndRequestMicrophonePermission();
      await _zegoService.initializeEngine();
    } catch (e) {
      debugPrint('⚠️ [CallController] Engine pre-warm notice: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRE-CALL AVAILABILITY & ELIGIBILITY VALIDATION
  // ─────────────────────────────────────────────────────────────

  /// Validates whether a Doctor is reachable and ready to receive calls.
  Future<Map<String, dynamic>> checkDoctorAvailability(String doctorId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.doctors)
          .doc(doctorId.trim())
          .get();

      if (!doc.exists || doc.data() == null) {
        return {'available': false, 'reason': 'Doctor profile not found.'};
      }

      final data = doc.data()!;
      if (data['isDeleted'] == true || data['isSuspended'] == true) {
        return {
          'available': false,
          'reason': 'Doctor account is currently inactive.',
        };
      }

      final manualAvailability =
          data['manualAvailability'] as bool? ?? data['isOnline'] as bool? ?? false;
      final isOnline = (data['isOnline'] == true) && manualAvailability;

      if (!isOnline) {
        return {
          'available': false,
          'reason': 'Doctor is currently offline / unavailable.',
        };
      }

      // Check if doctor is on another call
      final isBusy = await _repository.isUserBusy(doctorId);
      if (isBusy) {
        return {
          'available': false,
          'busy': true,
          'reason': 'Doctor is currently attending another patient.',
        };
      }

      return {'available': true};
    } catch (e) {
      debugPrint('⚠️ [CallController] checkDoctorAvailability error: $e');
      return {'available': true}; // Fail open if error
    }
  }

  /// Validates whether a Patient is reachable and ready to receive calls.
  Future<Map<String, dynamic>> checkPatientAvailability(String patientId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.patients)
          .doc(patientId.trim())
          .get();

      if (!doc.exists || doc.data() == null) {
        return {'available': false, 'reason': 'Patient profile not found.'};
      }

      final isBusy = await _repository.isUserBusy(patientId);
      if (isBusy) {
        return {
          'available': false,
          'busy': true,
          'reason': 'Patient is currently on another call.',
        };
      }

      return {'available': true};
    } catch (e) {
      debugPrint('⚠️ [CallController] checkPatientAvailability error: $e');
      return {'available': true};
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CALL INITIATION (PATIENT <-> DOCTOR)
  // ─────────────────────────────────────────────────────────────

  /// Initiates an outgoing voice call with full validation and signaling.
  Future<Map<String, dynamic>> initiateVoiceCall({
    required String callerId,
    required String callerName,
    required String callerRole,
    String? callerImage,
    required String receiverId,
    required String receiverName,
    required String receiverRole,
    String? receiverImage,
  }) async {
    // 1. Microphone permission
    final hasMic =
        await _permissionService.checkAndRequestMicrophonePermission();
    if (!hasMic) {
      return {
        'success': false,
        'error': 'Microphone permission is required to place a voice call.',
      };
    }

    // 2. Self busy check
    if (isCallActive) {
      return {
        'success': false,
        'error': 'You are already in an active call session.',
      };
    }

    // 3. Receiver availability & busy check
    if (receiverRole == 'doctor') {
      final availability = await checkDoctorAvailability(receiverId);
      if (availability['available'] != true) {
        return {
          'success': false,
          'error': availability['reason'] ?? 'Doctor is unavailable.',
          'busy': availability['busy'] == true,
        };
      }
    } else {
      final availability = await checkPatientAvailability(receiverId);
      if (availability['available'] != true) {
        return {
          'success': false,
          'error': availability['reason'] ?? 'Patient is unavailable.',
          'busy': availability['busy'] == true,
        };
      }
    }

    // 4. Generate IDs
    final callDoc = _firestore.collection(FirestoreCollections.calls).doc();
    final callId = callDoc.id;
    final roomId = 'room_call_$callId';

    final call = VoiceCallModel(
      callId: callId,
      callerId: callerId,
      callerName: callerName,
      callerRole: callerRole,
      callerImage: callerImage,
      receiverId: receiverId,
      receiverName: receiverName,
      receiverRole: receiverRole,
      receiverImage: receiverImage,
      roomId: roomId,
      status: CallingStatus.calling,
      createdAt: DateTime.now().toUtc(),
    );

    _activeCall = call;
    _activeCallController.add(call);

    // 5. Write Firestore record
    try {
      await _repository.createCall(call);
    } catch (e) {
      _activeCall = null;
      _activeCallController.add(null);
      return {'success': false, 'error': 'Failed to initiate call: $e'};
    }

    // 6. Record in chat history without breaking chat
    unawaited(
      _chatController.saveCallMessage(
        senderId: callerId,
        receiverId: receiverId,
        callType: 'audio',
        callStatus: CallingStatus.calling,
        receiverRole: receiverRole,
        callId: callId,
      ),
    );

    // 7. Send FCM high-priority notification to receiver
    unawaited(
      _dispatchCallPush(call),
    );

    // 8. Start ring timeout timer (45 seconds)
    _startRingTimeout(callId);

    // 9. Pre-join media room as caller
    unawaited(
      _zegoService.joinCallRoom(
        roomId: roomId,
        userId: callerId,
        userName: callerName,
      ),
    );

    return {
      'success': true,
      'callId': callId,
      'roomId': roomId,
      'call': call,
    };
  }

  Future<void> _dispatchCallPush(VoiceCallModel call) async {
    final token = await _notificationService.resolveReceiverToken(
      call.receiverId,
      preferredRole: call.receiverRole,
    );
    if (token != null && token.isNotEmpty) {
      await _notificationService.sendIncomingCallPush(
        receiverToken: token,
        callId: call.callId,
        roomId: call.roomId,
        callerId: call.callerId,
        callerName: call.callerName,
        callerRole: call.callerRole,
        callerImage: call.callerImage,
        receiverId: call.receiverId,
        receiverRole: call.receiverRole,
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CALL ACCEPTANCE & ROOM JOIN
  // ─────────────────────────────────────────────────────────────

  /// Accepts an incoming voice call, joins the Zego audio room, and connects audio.
  Future<bool> acceptCall(String callId, {String? userId, String? userName}) async {
    if (_activeCall?.callId == callId &&
        (_activeCall?.status == CallingStatus.connected ||
            _activeCall?.status == CallingStatus.accepted)) {
      debugPrint('ℹ️ [CallController] Call $callId is already active/connected.');
      return true;
    }

    _cancelRingTimeout();
    await _audioService.stopRingtone();

    // Request mic
    final hasMic = await _permissionService.checkAndRequestMicrophonePermission();
    if (!hasMic) {
      debugPrint('❌ [CallController] Cannot accept call without microphone permission.');
      return false;
    }

    final success = await _repository.acceptCall(callId);
    if (!success) return false;

    final call = await _repository.getCall(callId);
    if (call == null) return false;

    _activeCall = call.copyWith(status: CallingStatus.accepted);
    _activeCallController.add(_activeCall);

    // Join Zego room
    final joinSuccess = await _zegoService.joinCallRoom(
      roomId: call.roomId,
      userId: userId ?? call.receiverId,
      userName: userName ?? call.receiverName,
    );

    if (joinSuccess) {
      await _repository.updateCallStatus(
        callId: callId,
        status: CallingStatus.connected,
        connectedAt: DateTime.now().toUtc(),
      );
      _activeCall = _activeCall?.copyWith(status: CallingStatus.connected);
      _activeCallController.add(_activeCall);

      await _audioService.onCallConnected();
      startCallDurationTimer(reset: true);
      return true;
    } else {
      await endCall(callId, endReason: 'room_join_failed');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CALL REJECTION / CANCELLATION / TIMEOUT
  // ─────────────────────────────────────────────────────────────

  /// Rejects an incoming call.
  Future<bool> rejectCall(String callId, {String? rejectedBy}) async {
    _cancelRingTimeout();
    await _audioService.stopRingtone();
    await IncomingCallCoordinator.instance.dismissNotification(callId);

    final success = await _repository.rejectCall(callId, rejectedBy: rejectedBy);
    await _cleanupActiveCall();
    return success;
  }

  /// Cancels an outgoing call before the receiver answers.
  Future<bool> cancelCall(String callId) async {
    _cancelRingTimeout();

    final call = _activeCall ?? await _repository.getCall(callId);
    final success = await _repository.cancelCall(callId);

    // Send cancel push to dismiss ringing on recipient's phone
    if (call != null) {
      final token = await _notificationService.resolveReceiverToken(
        call.receiverId,
        preferredRole: call.receiverRole,
      );
      if (token != null) {
        unawaited(_notificationService.sendCallCancelPush(
          receiverToken: token,
          callId: callId,
        ));
      }
    }

    await _cleanupActiveCall();
    return success;
  }

  /// Auto-marks call as missed on ring timeout.
  Future<void> missCall(String callId) async {
    _cancelRingTimeout();
    await _audioService.stopRingtone();
    await IncomingCallCoordinator.instance.dismissNotification(callId);

    final call = _activeCall ?? await _repository.getCall(callId);
    await _repository.updateCallStatus(
      callId: callId,
      status: CallingStatus.missed,
      endedAt: DateTime.now().toUtc(),
      missedCall: true,
      endReason: 'ring_timeout',
    );

    // Send missed call push notification
    if (call != null) {
      final token = await _notificationService.resolveReceiverToken(
        call.receiverId,
        preferredRole: call.receiverRole,
      );
      if (token != null) {
        unawaited(_notificationService.sendMissedCallPush(
          receiverToken: token,
          callId: callId,
          callerName: call.callerName,
          callerImage: call.callerImage,
          callerId: call.callerId,
        ));
      }
    }

    await _cleanupActiveCall();
  }

  /// Terminates and ends an ongoing active call.
  Future<void> endCall(String callId, {String? endReason}) async {
    _cancelRingTimeout();
    stopCallDurationTimer();

    await _repository.endCall(
      callId: callId,
      duration: _callDuration,
      endReason: endReason ?? 'user_hangup',
    );

    await _cleanupActiveCall();
  }

  Future<void> _cleanupActiveCall() async {
    _cancelRingTimeout();
    stopCallDurationTimer();
    await _audioService.cleanup();
    await _zegoService.leaveCallRoom();
    CallSessionManager.instance.endSession();
    _activeCall = null;
    _callDuration = 0;
    _activeCallController.add(null);
  }

  // ─────────────────────────────────────────────────────────────
  // IN-CALL CONTROLS
  // ─────────────────────────────────────────────────────────────

  Future<bool> toggleMute() async {
    final muted = await _audioService.toggleMute();
    _microphoneMutedController.add(muted);
    return muted;
  }

  Future<bool> toggleSpeaker() async {
    final speaker = await _audioService.toggleSpeaker();
    _speakerPhoneController.add(speaker);
    return speaker;
  }

  // ─────────────────────────────────────────────────────────────
  // TIMERS & WATCHERS
  // ─────────────────────────────────────────────────────────────

  void _startRingTimeout(String callId) {
    _cancelRingTimeout();
    _ringTimeoutTimer = Timer(const Duration(seconds: 45), () async {
      if (_activeCall?.callId == callId &&
          CallingStatus.isRinging(_activeCall?.status)) {
        debugPrint('⏰ [CallController] Call $callId timed out after 45s.');
        await missCall(callId);
      }
    });
  }

  void _cancelRingTimeout() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
  }

  /// Starts the call duration ticker starting from 00:00 when a call is connected.
  /// If [reset] is true, resets to 0. If already running, preserves current elapsed time.
  void startCallDurationTimer({bool reset = false}) {
    if (reset) {
      stopCallDurationTimer();
      _callDuration = 0;
    } else if (isDurationTimerRunning) {
      _callDurationController.add(_callDuration);
      return;
    }
    stopCallDurationTimer();
    _callDurationController.add(_callDuration);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _callDuration++;
      _callDurationController.add(_callDuration);
    });
  }

  void stopCallDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  // ─────────────────────────────────────────────────────────────
  // CALL HISTORY
  // ─────────────────────────────────────────────────────────────

  Stream<List<VoiceCallModel>> getCallHistoryStream(String userId) {
    return _repository.watchUserCallHistory(userId);
  }

  List<VoiceCallModel> getOfflineCallHistory(String userId) {
    return _repository.getOfflineCallHistory(userId);
  }

  // Backward compatibility forwarders for legacy CallService / ChatScreen
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
    return await initiateVoiceCall(
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

  Future<void> terminateAndCleanupCall({
    required String callId,
    required String reason,
  }) async {
    await endCall(callId, endReason: reason);
  }
}

