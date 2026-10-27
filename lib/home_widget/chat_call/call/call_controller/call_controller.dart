import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:zego_express_engine/zego_express_engine.dart';
import 'package:telemedicine/data/models/call_model.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_controller/chat_controller.dart';
import 'package:telemedicine/offline_db/offline_call_service.dart';
import 'package:telemedicine/offline_db/offline_converters.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';

class CallController {
  static final CallController _instance = CallController._internal();
  factory CallController() => _instance;
  CallController._internal();

  static const int zegoAppId = ZegoConfig.appId;
  static const String zegoAppSign = ZegoConfig.appSign;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ChatController _chatController = ChatController();

  // ── State ──────────────────────────────────────────────────
  String? _remoteStreamId;
  bool get hasRemoteStream => _remoteStreamId != null;
  bool _isJoined = false;
  bool _isInitialized = false;
  bool _isEngineAlive = false;
  bool _isFrontCamera = true;
  String? _currentRoomId;
  String? _currentStreamId;

  // Pre-warm state
  bool _isPreWarmed = false;
  bool _preWarmingInProgress = false;

  Completer<bool>? _joinRoomCompleter;
  Completer<bool>? _publishStreamCompleter;
  StreamSubscription? _callSubscription;

  final Map<String, Stream<List<CallModel>>> _callHistoryCache = {};

  // Recording
  bool _isRecording = false;
  String? _currentRecordingPath;
  DateTime? _recordingStartTime;
  final Map<String, String> _ongoingCalls = {};

  // ── Call state machine ─────────────────────────────────────
  String? _activeCallId;
  String? _activeCallStatus;
  Timer? _ringTimeoutTimer;
  static const int _ringTimeoutSeconds = 45;

  // Stream controllers
  final StreamController<bool> _isUserBusyController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _microphoneStateController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _speakerStateController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _cameraStateController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _networkQualityController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<bool> _recordingStateController =
      StreamController<bool>.broadcast();
  final StreamController<String> _remoteStreamController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  final StreamController<String> _localStreamController =
      StreamController<String>.broadcast();
  final StreamController<String> _callStatusController =
      StreamController<String>.broadcast();

  // Online status
  final Map<String, StreamSubscription<DocumentSnapshot>>
  _onlineStatusSubscriptions = {};
  final Map<String, StreamController<bool>> _userOnlineStatusControllers = {};
  final Map<String, StreamSubscription> _userOnlineStatusSubscriptions = {};

  // Getters
  bool get isJoined => _isJoined;
  bool get isInitialized => _isInitialized;
  bool get isFrontCamera => _isFrontCamera;
  bool get isRecording => _isRecording;
  bool get isPreWarmed => _isPreWarmed;
  String? get activeCallId => _activeCallId;
  String? get activeCallStatus => _activeCallStatus;
  Stream<bool> get isUserBusy => _isUserBusyController.stream;
  Stream<bool> get microphoneState => _microphoneStateController.stream;
  Stream<bool> get speakerState => _speakerStateController.stream;
  Stream<bool> get cameraState => _cameraStateController.stream;
  Stream<String> get errors => _errorController.stream;
  Stream<Map<String, dynamic>> get networkQuality =>
      _networkQualityController.stream;
  Stream<bool> get recordingState => _recordingStateController.stream;
  Stream<String> get onRemoteStreamAdded => _remoteStreamController.stream;
  Stream<bool> get onConnectionState => _connectionStateController.stream;
  Stream<String> get onLocalStreamPublished => _localStreamController.stream;
  Stream<String> get callStatus => _callStatusController.stream;
  bool get isZegoConfigured => zegoAppId != 0 && zegoAppSign.isNotEmpty;

  // ─────────────────────────────────────────────────────────────
  // PRE-WARM ENGINE (call this at app startup / home screen)
  // Warms up Zego + requests permissions ahead of time so the
  // actual call setup is nearly instantaneous.
  // ─────────────────────────────────────────────────────────────
  Future<void> preWarmEngine() async {
    if (_isPreWarmed || _preWarmingInProgress || !isZegoConfigured) return;
    _preWarmingInProgress = true;
    debugPrint('🔥 Pre-warming Zego engine...');
    try {
      // Request permissions silently in background
      await Future.wait([
        Permission.microphone.request(),
        Permission.camera.request(),
      ]);

      // Create engine if not alive
      if (!_isEngineAlive) {
        await ZegoExpressEngine.createEngineWithProfile(
          ZegoEngineProfile(
            zegoAppId,
            ZegoScenario.General,
            appSign: zegoAppSign,
          ),
        );
        _isEngineAlive = true;
      }

      // Light setup — camera OFF, mic OFF to save resources until needed
      await ZegoExpressEngine.instance.enableCamera(false);
      await ZegoExpressEngine.instance.muteMicrophone(true);

      _setupEventHandlers();
      _isInitialized = true;
      _isPreWarmed = true;
      debugPrint('✅ Zego engine pre-warmed');
    } catch (e) {
      debugPrint('Pre-warm error (non-fatal): $e');
    } finally {
      _preWarmingInProgress = false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // ZEGO INIT
  // Fast path if already pre-warmed; full path otherwise.
  // ─────────────────────────────────────────────────────────────
  Future<bool> initializeZego({bool enableVideo = false}) async {
    if (!isZegoConfigured) {
      _addError('Zego App ID is not properly configured');
      return false;
    }

    // Already fully ready
    if (_isInitialized && _isEngineAlive) {
      // Just update camera state for this call type
      await ZegoExpressEngine.instance.enableCamera(enableVideo);
      await ZegoExpressEngine.instance.muteMicrophone(false);
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(enableVideo);
      debugPrint('⚡ Zego reused (pre-warmed)');
      return true;
    }

    try {
      // Permissions — run in parallel
      final results = await Future.wait([
        Permission.microphone.request(),
        if (enableVideo) Permission.camera.request(),
      ]);
      if (results[0] != PermissionStatus.granted) {
        _addError('Microphone permission denied');
        return false;
      }
      if (enableVideo &&
          results.length > 1 &&
          results[1] != PermissionStatus.granted) {
        _addError('Camera permission denied');
        return false;
      }

      // Create engine only if not alive
      if (!_isEngineAlive) {
        await ZegoExpressEngine.createEngineWithProfile(
          ZegoEngineProfile(
            zegoAppId,
            ZegoScenario.General,
            appSign: zegoAppSign,
          ),
        );
        _isEngineAlive = true;
      }

      await Future.wait([
        ZegoExpressEngine.instance.enableCamera(enableVideo),
        ZegoExpressEngine.instance.muteMicrophone(false),
        ZegoExpressEngine.instance.setAudioRouteToSpeaker(enableVideo),
      ]);

      _setupEventHandlers();
      _isInitialized = true;
      debugPrint('✅ Zego initialized');
      return true;
    } catch (e) {
      _addError('Error initializing Zego: $e');
      _isInitialized = false;
      return false;
    }
  }

  void _setupEventHandlers() {
    ZegoExpressEngine.onRoomStateUpdate =
        (
          String roomID,
          ZegoRoomState state,
          int errorCode,
          Map<String, dynamic> extendedData,
        ) {
          debugPrint('📡 Room $roomID → $state (err=$errorCode)');
          switch (state) {
            case ZegoRoomState.Connected:
              _isJoined = true;
              _currentRoomId = roomID;
              _connectionStateController.add(true);
              if (_joinRoomCompleter != null &&
                  !_joinRoomCompleter!.isCompleted) {
                _joinRoomCompleter!.complete(true);
              }
              break;
            case ZegoRoomState.Connecting:
              _connectionStateController.add(false);
              break;
            case ZegoRoomState.Disconnected:
              _isJoined = false;
              _connectionStateController.add(false);
              if (errorCode != 0 &&
                  _joinRoomCompleter != null &&
                  !_joinRoomCompleter!.isCompleted) {
                _joinRoomCompleter!.complete(false);
              }
              break;
          }
        };

    ZegoExpressEngine.onRoomStreamUpdate =
        (
          String roomID,
          ZegoUpdateType updateType,
          List<ZegoStream> streamList,
          Map<String, dynamic> extendedData,
        ) {
          for (final stream in streamList) {
            if (updateType == ZegoUpdateType.Add) {
              final isLocal = _currentStreamId == stream.streamID;
              if (!isLocal) {
                debugPrint('✅ Remote stream added: ${stream.streamID}');
                _remoteStreamId = stream.streamID;
                // Start playing immediately — don't wait
                ZegoExpressEngine.instance.startPlayingStream(
                  stream.streamID,
                  canvas: null,
                );
                _remoteStreamController.add(stream.streamID);
              }
            } else if (updateType == ZegoUpdateType.Delete) {
              if (_remoteStreamId == stream.streamID) {
                debugPrint('⚠️ Remote stream removed: ${stream.streamID}');
                _remoteStreamId = null;
              }
            }
          }
        };

    ZegoExpressEngine.onPublisherStateUpdate =
        (
          String streamID,
          ZegoPublisherState state,
          int errorCode,
          Map<String, dynamic> extendedData,
        ) {
          debugPrint('📤 Publisher $streamID → $state (err=$errorCode)');
          if (state == ZegoPublisherState.Publishing) {
            _localStreamController.add(streamID);
            if (_publishStreamCompleter != null &&
                !_publishStreamCompleter!.isCompleted) {
              _publishStreamCompleter!.complete(true);
            }
          } else if (state == ZegoPublisherState.NoPublish &&
              _publishStreamCompleter != null &&
              !_publishStreamCompleter!.isCompleted) {
            _publishStreamCompleter!.complete(false);
          }
        };

    // Network quality monitoring
    ZegoExpressEngine.onNetworkQuality =
        (
          String userID,
          ZegoStreamQualityLevel upstreamQuality,
          ZegoStreamQualityLevel downstreamQuality,
        ) {
          _networkQualityController.add({
            'userId': userID,
            'upload': upstreamQuality.index,
            'download': downstreamQuality.index,
          });
        };
  }

  // ─────────────────────────────────────────────────────────────
  // SOFT RESET — does NOT destroy the engine (fast path)
  // ─────────────────────────────────────────────────────────────
  Future<void> softReset() async {
    debugPrint('🔄 softReset (engine stays alive)');
    try {
      if (_isJoined) {
        if (_remoteStreamId != null) {
          await ZegoExpressEngine.instance.stopPlayingStream(_remoteStreamId!);
        }
        await ZegoExpressEngine.instance.stopPreview();
        await ZegoExpressEngine.instance.stopPublishingStream();
        await ZegoExpressEngine.instance.enableCamera(false);
        await ZegoExpressEngine.instance.muteMicrophone(true);
        await ZegoExpressEngine.instance.logoutRoom();
      }
    } catch (e) {
      debugPrint('softReset error (non-fatal): $e');
    }
    _isJoined = false;
    _currentRoomId = null;
    _currentStreamId = null;
    _remoteStreamId = null;
    _activeCallId = null;
    _activeCallStatus = null;
    _cancelRingTimeout();
  }

  /// Full reset: leave room + destroy engine (only when truly needed).
  Future<void> resetAndReinitialize() async {
    debugPrint('🔄 resetAndReinitialize');
    try {
      await softReset();
      if (_isEngineAlive) {
        try {
          await ZegoExpressEngine.destroyEngine();
        } catch (_) {}
        _isEngineAlive = false;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } catch (e) {
      debugPrint('Error during reset: $e');
    }
    _isInitialized = false;
    _isPreWarmed = false;
    _isJoined = false;
    _currentRoomId = null;
    _currentStreamId = null;
    _remoteStreamId = null;
  }

  // ─────────────────────────────────────────────────────────────
  // ROOM JOIN — optimized with parallel operations
  // ─────────────────────────────────────────────────────────────
  Future<bool> joinRoom({
    required String roomId,
    required String uid,
    required String userName,
    bool isVideo = false,
  }) async {
    try {
      if (_isJoined) {
        debugPrint('Already in room, doing soft reset');
        await softReset();
        await Future.delayed(const Duration(milliseconds: 150));
      }

      _joinRoomCompleter = Completer<bool>();
      _publishStreamCompleter = Completer<bool>();

      final user = ZegoUser(uid, userName);
      final config = ZegoRoomConfig.defaultConfig()
        ..isUserStatusNotify = true
        ..token = '';

      _currentStreamId = '${roomId}_$uid';
      _currentRoomId = roomId;

      // Login to room
      try {
        await ZegoExpressEngine.instance.loginRoom(
          roomId,
          user,
          config: config,
        );
      } catch (e) {
        debugPrint('❌ loginRoom error: $e');
        _joinRoomCompleter!.complete(false);
        return false;
      }

      // Wait for connection with reduced timeout
      final connected = await _joinRoomCompleter!.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => false,
      );

      if (!connected) {
        debugPrint('❌ Room connection timeout/failed');
        await softReset();
        return false;
      }

      // Start publishing + configure media in parallel
      await Future.wait([
        ZegoExpressEngine.instance.startPublishingStream(_currentStreamId!),
        ZegoExpressEngine.instance.enableCamera(isVideo),
        ZegoExpressEngine.instance.setAudioRouteToSpeaker(isVideo),
        ZegoExpressEngine.instance.muteMicrophone(false),
      ]);

      // Wait for publish with short timeout (non-blocking — continue anyway)
      await _publishStreamCompleter!.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => true,
      );

      if (isVideo) {
        await ZegoExpressEngine.instance.startPreview();
      }

      debugPrint('✅ Joined and publishing in room: $roomId');
      return true;
    } catch (e) {
      debugPrint('❌ joinRoom error: $e');
      return false;
    }
  }

  Future<void> leaveRoom() async {
    if (!_isJoined) return;
    try {
      await Future.wait([
        ZegoExpressEngine.instance.stopPreview(),
        ZegoExpressEngine.instance.stopPublishingStream(),
      ]);
      await ZegoExpressEngine.instance.logoutRoom();
    } catch (e) {
      debugPrint('leaveRoom error: $e');
    } finally {
      _isJoined = false;
      _currentRoomId = null;
      _currentStreamId = null;
      _remoteStreamId = null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // ONLINE STATUS
  // ─────────────────────────────────────────────────────────────
  /// Doctor availability is the manual duty switch plus account standing.
  ///
  /// Heartbeat freshness is intentionally not consulted: the heartbeat timer
  /// only runs while the doctor app is in the foreground, so requiring it here
  /// turned an explicitly-online doctor into "offline" as soon as the app was
  /// backgrounded. Reachability is established by the call handshake/FCM path.
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
      if (!doc.exists) return false;
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
      if (!doc.exists) return false;
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
    _onlineStatusSubscriptions[userId] = _firestore
        .collection(col)
        .doc(userId)
        .snapshots()
        .listen((doc) {
          if (!doc.exists) {
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
    for (final sub in _userOnlineStatusSubscriptions.values) {
      sub.cancel();
    }
    _userOnlineStatusSubscriptions.clear();
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
    _userOnlineStatusSubscriptions[userId] = _firestore
        .collection(col)
        .doc(userId)
        .snapshots()
        .listen((doc) {
          if (!doc.exists) {
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

  // ─────────────────────────────────────────────────────────────
  // CALL START — fire-and-forget approach like WhatsApp
  // Signal first, join room simultaneously, don't block on either.
  // ─────────────────────────────────────────────────────────────

  /// Fast call start: writes Firestore + sends FCM concurrently.
  /// Returns as soon as Firestore doc is written (< 500ms typically).
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
  }) async {
    try {
      // Run online + busy checks in parallel
      final results = await Future.wait([
        isUserOnCall(receiverId),
        checkUserOnlineStatus(userId: receiverId, userType: receiverType),
      ]);

      final isOnCall = results[0] as bool;
      final isOnline = results[1] as bool;

      if (isOnCall) {
        unawaited(
          _chatController.saveCallMessage(
            senderId: callerId,
            receiverId: receiverId,
            callType: callType,
            callStatus: 'busy',
            receiverRole: receiverType,
          ),
        );
        return {
          'success': false,
          'error': '$receiverName is on another call.',
          'busy': true,
          'callId': null,
        };
      }

      if (!isOnline) {
        // Doctor is offline — show "Calling..." not "Ringing..."
        return _initiateCall(
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
      }

      return _initiateCall(
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
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'busy': false,
        'callId': null,
      };
    }
  }

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
    try {
      // A receiver who is still in an accepted/ringing call must not receive a
      // second incoming call. Check this before presence so a busy doctor is
      // reported as busy rather than offline. The backend also checks this, but
      // the doctor's active-call fields are not written by every client, so
      // verify the authoritative call documents here as well.
      final receiverBusy = await isUserOnCall(receiverId);
      if (receiverBusy) {
        unawaited(
          _chatController.saveCallMessage(
            senderId: callerId,
            receiverId: receiverId,
            callType: callType,
            callStatus: 'busy',
            receiverRole: receiverType,
          ),
        );
        return {
          'success': false,
          'error': '$receiverName is attending another patient.',
          'callId': null,
          'busy': true,
        };
      }

      final isOnline = await checkUserOnlineStatus(
        userId: receiverId,
        userType: receiverType,
      );
      if (!isOnline) {
        unawaited(
          _chatController.saveCallMessage(
            senderId: callerId,
            receiverId: receiverId,
            callType: callType,
            callStatus: 'missed',
            receiverRole: receiverType,
          ),
        );
        // Persist the missed call locally for offline-first history.
        unawaited(
          _saveCallLocally(
            CallModel(
              id: '${channelId}_missed',
              callerId: callerId,
              receiverId: receiverId,
              callerName: callerName,
              receiverName: receiverName,
              callerImage: callerImage,
              receiverImage: receiverImage,
              channelId: channelId,
              callType: callType,
              callStatus: 'missed',
              startTime: DateTime.now(),
              endedAt: DateTime.now(),
            ),
          ),
        );
        return {
          'success': false,
          'error': '$receiverName is offline.',
          'callId': null,
        };
      }
      // If calling a doctor, perform the Pre-Call Probe Handshake via Cloud Functions
      if (receiverType == 'doctor') {
        try {
          final callable = FirebaseFunctions.instanceFor(
            region: 'asia-south1',
          ).httpsCallable('requestDoctorCall');
          final response = await callable
              .call<Map<String, dynamic>>({
                'callerId': callerId,
                'callerName': callerName,
                'callerImage': callerImage,
                'callerType': callerType ?? 'patient',
                'doctorId': receiverId,
                'callType': callType,
                'channelId': channelId,
              })
              .timeout(const Duration(seconds: 10));

          final resData = response.data;
          if (resData['success'] == true) {
            final String callId = (resData['callId'] ?? '').toString();
            final String effectiveChannel = (resData['channelId'] ?? channelId)
                .toString();

            _activeCallId = callId;
            _activeCallStatus = CallStatus.ringing;
            _callStatusController.add(CallStatus.ringing);
            _ongoingCalls[effectiveChannel] = callerId;

            final call = CallModel(
              id: callId,
              callerId: callerId,
              receiverId: receiverId,
              callerName: callerName,
              receiverName: receiverName,
              callerImage: callerImage,
              receiverImage: receiverImage,
              callerType: callerType,
              channelId: effectiveChannel,
              callType: callType,
              callStatus: CallStatus.ringing,
              startTime: DateTime.now(),
            );
            unawaited(_saveCallLocally(call));
            unawaited(
              _chatController.saveCallMessage(
                senderId: callerId,
                receiverId: receiverId,
                callType: callType,
                callStatus: CallStatus.ringing,
                receiverRole: receiverType,
              ),
            );
            _startRingTimeout(callId);

            return {
              'success': true,
              'error': null,
              'callId': callId,
              'busy': false,
            };
          } else {
            // Handshake failed or doctor unreachable / busy
            final errorMsg =
                (resData['message'] ?? '$receiverName is unreachable.')
                    .toString();
            final isBusy = resData['reason'] == 'DOCTOR_BUSY';

            unawaited(
              _chatController.saveCallMessage(
                senderId: callerId,
                receiverId: receiverId,
                callType: callType,
                callStatus: isBusy ? 'busy' : 'missed',
                receiverRole: receiverType,
              ),
            );

            return {
              'success': false,
              'error': errorMsg,
              'callId': null,
              'busy': isBusy,
            };
          }
        } catch (handshakeErr) {
          debugPrint(
            'Handshake callable unavailable, fallback to _initiateCall: $handshakeErr',
          );
          // Graceful fallback to client-side initiation
        }
      }

      return await _initiateCall(
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
    } catch (e) {
      return {'success': false, 'error': e.toString(), 'callId': null};
    }
  }

  Future<Map<String, dynamic>> _initiateCall({
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
    if (!isZegoConfigured) {
      return {'success': false, 'error': 'Zego not configured', 'callId': null};
    }

    // Duplicate call prevention: if there's already an active call, reject
    if (_activeCallId != null) {
      return {
        'success': false,
        'error': 'You already have an active call.',
        'callId': null,
      };
    }

    // Generate call ID immediately
    final callId = _firestore.collection(FirestoreCollections.calls).doc().id;

    final call = CallModel(
      id: callId,
      callerId: callerId,
      receiverId: receiverId,
      callerName: callerName,
      receiverName: receiverName,
      callerImage: callerImage,
      receiverImage: receiverImage,
      callerType: callerType,
      channelId: channelId,
      callType: callType,
      callStatus: CallStatus.ringing,
      startTime: DateTime.now(),
    );

    // Set active call state
    _activeCallId = callId;
    _activeCallStatus = CallStatus.ringing;
    _callStatusController.add(CallStatus.ringing);

    // FIRE-AND-FORGET: write Firestore + send FCM + save chat message
    debugPrint(
      '📞 STAGE1_CALL_INITIATED callId=$callId from=$callerName($callerId) '
      'to=$receiverId channel=$channelId type=$callType callerType=$callerType',
    );
    try {
      await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .set(call.toMap());
    } catch (e) {
      _activeCallId = null;
      _activeCallStatus = null;
      _callStatusController.add(CallStatus.ended);
      rethrow;
    }
    _ongoingCalls[channelId] = callerId;
    debugPrint(
      '📞 STAGE2_CALL_INVITATION_WRITTEN callId=$callId '
      '(doc committed; receiver sees it via Firestore stream + FCM)',
    );

    // Persist locally (offline-first call history).
    unawaited(_saveCallLocally(call));

    // The incoming-call push is sent by the `sendIncomingCallNotification`
    // Cloud Function, which fires on the creation of this very call document.
    // The client deliberately does NOT push here any more: sending from both
    // sides produced two FCM deliveries per call, which surfaced as two
    // incoming-call notifications and two incoming-call screens. The chat
    // "call ringing" message is still written locally.
    unawaited(
      _chatController.saveCallMessage(
        senderId: callerId,
        receiverId: receiverId,
        callType: callType,
        callStatus: CallStatus.ringing,
        receiverRole: receiverType,
      ),
    );

    // Start 45-second ring timeout
    _startRingTimeout(callId);

    return {'success': true, 'error': null, 'callId': callId, 'busy': false};
  }

  /// Start a 45-second timer. If the call is not answered within this time,
  /// auto-mark it as missed.
  void _startRingTimeout(String callId) {
    _cancelRingTimeout();
    _ringTimeoutTimer = Timer(
      const Duration(seconds: _ringTimeoutSeconds),
      () async {
        // If the call is still ringing after timeout, auto-miss it
        if (_activeCallId == callId &&
            CallStatus.isRinging(_activeCallStatus)) {
          debugPrint('⏰ Call $callId timed out after ${_ringTimeoutSeconds}s');
          await missCall(callId);
        }
      },
    );
  }

  void _cancelRingTimeout() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
  }

  /// Whether [userId] currently has a live call.
  ///
  /// A `ringing` call that nobody answered, nobody cancelled and no client
  /// auto-missed (both apps died during the ring) used to keep both parties
  /// "busy" forever. Ringing docs older than the ring timeout are now ignored
  /// here, so a stale ring can never busy-lock an account.
  Future<bool> isUserOnCall(String userId) async {
    try {
      final cutoff = DateTime.now().subtract(
        const Duration(seconds: _ringTimeoutSeconds + 15),
      );

      bool hasLiveCall(QuerySnapshot<Map<String, dynamic>> snap) {
        return snap.docs.any((doc) {
          final data = doc.data();
          final status = data['callStatus'] as String?;
          if (status == CallStatus.accepted) return true;
          if (status != CallStatus.ringing) return false;
          final started = _safeParseTime(data['startTime']);
          // Unparseable timestamps keep the old (busy) behaviour — safer
          // than silently freeing a genuinely ringing call.
          return !started.isBefore(cutoff);
        });
      }

      // Run both queries in parallel
      final snaps = await Future.wait([
        _firestore
            .collection(FirestoreCollections.calls)
            .where('callStatus', whereIn: ['accepted', 'ringing'])
            .where('callerId', isEqualTo: userId)
            .limit(10)
            .get(),
        _firestore
            .collection(FirestoreCollections.calls)
            .where('callStatus', whereIn: ['accepted', 'ringing'])
            .where('receiverId', isEqualTo: userId)
            .limit(10)
            .get(),
      ]);
      return hasLiveCall(snaps[0]) || hasLiveCall(snaps[1]);
    } catch (e) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CALL LIFECYCLE
  // ─────────────────────────────────────────────────────────────
  /// Answers an incoming call.
  ///
  /// Returns `true` only when this call actually moved `ringing -> accepted`.
  /// A second press, a stale notification action or a call the caller already
  /// cancelled all return `false`, which is what lets
  /// [IncomingCallCoordinator] guarantee a single accept per `callId` instead
  /// of a single button tap.
  Future<bool> acceptCall(String callId) async {
    try {
      debugPrint('📞 STAGE7_ACCEPT_TRIGGERED callId=$callId');
      final doc = await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      if (!doc.exists) return false;
      final data = doc.data()!;

      // Guard against racing a cancelled/ended call: only a call that is
      // still ringing may be accepted.
      if (!CallStatus.canAccept(data['callStatus'] as String?)) {
        debugPrint('acceptCall skipped callId=$callId (${data['callStatus']})');
        return false;
      }

      _cancelRingTimeout();
      _activeCallId = callId;
      _activeCallStatus = CallStatus.accepted;
      _callStatusController.add(CallStatus.accepted);

      // The Firestore status write is the source of truth for the accept.
      // It MUST succeed before this returns true.
      await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .update({
            'callStatus': CallStatus.accepted,
            'acceptedAt': DateTime.now().toIso8601String(),
          });

      // Everything below is bookkeeping: a failure here must never turn a
      // successful accept into a "failed" result, because callers then leave
      // the pending-action record in place and the callee ends up "accepted"
      // on the caller's side but never in the room.
      try {
        await _chatController.saveCallMessage(
          senderId: data['callerId'],
          receiverId: data['receiverId'],
          callType: data['callType'],
          callStatus: CallStatus.accepted,
        );
      } catch (e) {
        debugPrint('acceptCall: chat message save failed (non-fatal): $e');
      }

      // Persist locally (offline-first call history).
      try {
        await OfflineCallService.instance.updateCallStatus(
          callId: callId,
          callStatus: CallStatus.accepted,
          synced: true,
        );
      } catch (e) {
        debugPrint('acceptCall: offline cache update failed (non-fatal): $e');
      }
      return true;
    } catch (e) {
      debugPrint('acceptCall error: $e');
      return false;
    }
  }

  /// Declines an incoming call.
  ///
  /// Returns `true` only when this call actually moved `ringing -> rejected`.
  /// A call that is already accepted (or ended) returns `false`, so a call can
  /// never be both accepted and declined.
  Future<bool> rejectCall(String callId) async {
    try {
      debugPrint('📞 STAGE7_DECLINE_TRIGGERED callId=$callId');
      final doc = await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      if (!doc.exists) return false;
      final data = doc.data()!;
      if (!CallStatus.canDecline(data['callStatus'] as String?)) {
        debugPrint('rejectCall skipped callId=$callId (${data['callStatus']})');
        return false;
      }

      _cancelRingTimeout();
      _activeCallId = null;
      _activeCallStatus = CallStatus.rejected;
      _callStatusController.add(CallStatus.rejected);

      // The Firestore status write is the source of truth for the decline —
      // the same contract as [acceptCall]. It MUST be awaited and MUST
      // succeed before this returns true. It used to be fired with
      // `unawaited(Future.wait([...]))`, so the decline returned `true` —
      // the coordinator then released the callId claim, dismissed the
      // notification and popped the Incoming Call screen — while the call
      // document was still `ringing`, leaving the caller ringing until the
      // 45-second timeout expired.
      await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .update({
            'callStatus': CallStatus.rejected,
            'endedAt': DateTime.now().toIso8601String(),
          });

      // Bookkeeping only: a chat-save failure must never turn a successful
      // decline into a failed one.
      try {
        await _chatController.saveCallMessage(
          senderId: data['callerId'],
          receiverId: data['receiverId'],
          callType: data['callType'],
          callStatus: CallStatus.rejected,
        );
      } catch (e) {
        debugPrint('rejectCall: chat message save failed (non-fatal): $e');
      }
      // Persist locally (offline-first call history).
      await OfflineCallService.instance.updateCallStatus(
        callId: callId,
        callStatus: CallStatus.rejected,
        endTime: DateTime.now(),
      );
    } catch (e) {
      debugPrint('rejectCall error: $e');
      return false;
    }
    await softReset();
    return true;
  }

  Future<void> endCall(String callId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      if (!doc.exists) return;
      final data = doc.data()!;
      final currentStatus = data['callStatus'] as String?;
      if (CallStatus.isTerminal(currentStatus)) {
        _cancelRingTimeout();
        return;
      }
      final startTime = _safeParseTime(data['startTime']);
      final duration = DateTime.now().difference(startTime).inSeconds;

      _cancelRingTimeout();
      _activeCallId = null;
      _activeCallStatus = CallStatus.ended;
      _callStatusController.add(CallStatus.ended);

      unawaited(
        Future.wait([
          _firestore.collection(FirestoreCollections.calls).doc(callId).update({
            'callStatus': CallStatus.ended,
            'endedAt': DateTime.now().toIso8601String(),
            'duration': duration,
          }),
          _chatController.saveCallMessage(
            senderId: data['callerId'],
            receiverId: data['receiverId'],
            callType: data['callType'],
            callStatus: CallStatus.ended,
            duration: duration,
          ),
        ]),
      );
      // Persist locally (offline-first call history).
      await OfflineCallService.instance.updateCallStatus(
        callId: callId,
        callStatus: CallStatus.ended,
        endTime: DateTime.now(),
        duration: duration,
      );
    } catch (e) {
      debugPrint('endCall error: $e');
    }
    await softReset();
  }

  /// Called on BOTH devices when the Firestore call doc reports `accepted`.
  ///
  /// Stops the caller-side ring timeout the instant the receiver accepts,
  /// and keeps the local state machine in sync so the timeout cannot fire
  /// `missCall` on a live call (previously it ran to 45s and killed the call).
  void markCallAcceptedForRemote(String callId) {
    debugPrint('📞 CALL_ACCEPTED markCallAcceptedForRemote callId=$callId');
    _cancelRingTimeout();
    if (_activeCallId == callId &&
        !CallStatus.isTerminal(_activeCallStatus) &&
        _activeCallStatus != CallStatus.accepted) {
      _activeCallStatus = CallStatus.accepted;
      _callStatusController.add(CallStatus.accepted);
    }
  }

  Future<void> missCall(String callId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      if (!doc.exists) return;
      final data = doc.data()!;

      // The ring timeout may still be armed on this device even after the
      // receiver accepted (the accept happens on a different device). A call
      // is only genuinely "missed" while it is still unanswered ('ringing').
      // If it was accepted (or already ended), the timeout must NOT touch it.
      if (!CallStatus.isRinging(data['callStatus'] as String?)) {
        debugPrint(
          '⏰ missCall skipped callId=$callId (current status: '
          '${data['callStatus']}) — call no longer unanswered',
        );
        _cancelRingTimeout();
        return;
      }

      _cancelRingTimeout();
      _activeCallId = null;
      _activeCallStatus = CallStatus.missed;
      _callStatusController.add(CallStatus.missed);

      unawaited(
        Future.wait([
          _firestore.collection(FirestoreCollections.calls).doc(callId).update({
            'callStatus': CallStatus.missed,
            'endedAt': DateTime.now().toIso8601String(),
          }),
          _chatController.saveCallMessage(
            senderId: data['callerId'],
            receiverId: data['receiverId'],
            callType: data['callType'],
            callStatus: CallStatus.missed,
          ),
        ]),
      );
      // Persist locally (offline-first call history).
      await OfflineCallService.instance.updateCallStatus(
        callId: callId,
        callStatus: CallStatus.missed,
        endTime: DateTime.now(),
      );
    } catch (e) {
      debugPrint('missCall error: $e');
    }
  }

  /// Cancel a call that was initiated but not yet answered.
  Future<void> cancelCall(String callId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      if (!doc.exists) return;
      final data = doc.data()!;
      if (!CallStatus.isRinging(data['callStatus'] as String?)) {
        debugPrint('cancelCall skipped callId=$callId (${data['callStatus']})');
        return;
      }

      _cancelRingTimeout();
      _activeCallId = null;
      _activeCallStatus = CallStatus.cancelled;
      _callStatusController.add(CallStatus.cancelled);

      unawaited(
        Future.wait([
          _firestore.collection(FirestoreCollections.calls).doc(callId).update({
            'callStatus': CallStatus.cancelled,
            'endedAt': DateTime.now().toIso8601String(),
          }),
          _chatController.saveCallMessage(
            senderId: data['callerId'],
            receiverId: data['receiverId'],
            callType: data['callType'],
            callStatus: CallStatus.cancelled,
          ),
        ]),
      );
      await OfflineCallService.instance.updateCallStatus(
        callId: callId,
        callStatus: CallStatus.cancelled,
        endTime: DateTime.now(),
      );
    } catch (e) {
      debugPrint('cancelCall error: $e');
    }
    await softReset();
  }

  // ─────────────────────────────────────────────────────────────
  // MEDIA CONTROLS
  // ─────────────────────────────────────────────────────────────
  Future<void> muteMicrophone(bool mute) async {
    try {
      await ZegoExpressEngine.instance.muteMicrophone(mute);
      _microphoneStateController.add(mute);
    } catch (e) {
      _addError('Failed to toggle microphone');
    }
  }

  Future<void> enableSpeaker(bool enable) async {
    try {
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(enable);
      _speakerStateController.add(enable);
    } catch (e) {
      _addError('Failed to toggle speaker');
    }
  }

  Future<void> toggleCameraDirection() async {
    try {
      _isFrontCamera = !_isFrontCamera;
      await ZegoExpressEngine.instance.useFrontCamera(_isFrontCamera);
    } catch (e) {
      _addError('Failed to switch camera');
    }
  }

  Future<void> enableLocalVideo(bool enable) async {
    try {
      await ZegoExpressEngine.instance.enableCamera(enable);
      _cameraStateController.add(!enable);
    } catch (e) {
      _addError('Failed to toggle video');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RECORDING
  // ─────────────────────────────────────────────────────────────
  Future<bool> startCallRecording() async {
    if (!_isJoined || _isRecording) return _isRecording;
    try {
      if (Platform.isAndroid) {
        if (!await Permission.storage.request().isGranted) {
          _addError('Storage permission required for recording');
          return false;
        }
      }
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      _currentRecordingPath =
          '${dir.path}/call_recording_${_currentRoomId}_$ts.m4a';
      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _recordingStateController.add(true);
      return true;
    } catch (e) {
      _addError('Failed to start recording: $e');
      return false;
    }
  }

  Future<String?> stopCallRecording() async {
    if (!_isRecording) return null;
    try {
      final path = _currentRecordingPath;
      _isRecording = false;
      _currentRecordingPath = null;
      _recordingStartTime = null;
      _recordingStateController.add(false);
      if (path != null && await File(path).exists()) {
        final size = await File(path).length();
        if (size > 0) return path;
        await File(path).delete();
      }
      return path;
    } catch (e) {
      _isRecording = false;
      _currentRecordingPath = null;
      _recordingStartTime = null;
      return null;
    }
  }

  Future<Map<String, dynamic>> stopRecordingAndUpload({
    required String callId,
    required String callerId,
    required String receiverId,
  }) async {
    final result = <String, dynamic>{
      'success': false,
      'recordingUrl': null,
      'error': null,
    };
    if (!_isRecording) return result;
    try {
      final path = await stopCallRecording();
      if (path == null) return result;
      final duration = await _getRecordingDuration(path);
      final conversationId = _chatController.getChatId(callerId, receiverId);
      final uploadRes = await FirebaseStorageService.instance.uploadFile(
        storagePath:
            'call_recordings/$conversationId/call_${callId}_${DateTime.now().millisecondsSinceEpoch}.m4a',
        file: File(path),
        contentType: 'audio/mp4',
      );
      final url = uploadRes.downloadUrl;
      unawaited(
        Future.wait([
          _firestore.collection(FirestoreCollections.calls).doc(callId).update({
            'recordingUrl': url,
            'recordingDuration': duration,
            'recordedAt': FieldValue.serverTimestamp(),
          }),
          _chatController.saveCallRecordingMessage(
            senderId: callerId,
            receiverId: receiverId,
            recordingUrl: url,
            callId: callId,
            duration: duration,
          ),
        ]),
      );
      final f = File(path);
      if (await f.exists()) await f.delete();
      result['success'] = true;
    } catch (e) {
      debugPrint('stopRecordingAndUpload error: $e');
    }
    return result;
  }

  Future<int> _getRecordingDuration(String filePath) async {
    try {
      final size = await File(filePath).length();
      return (size / 8000).round().clamp(0, 3600);
    } catch (_) {
      return 0;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // NOTIFICATION
  //
  //  There is intentionally no client-side call push any more. The
  //  `sendIncomingCallNotification` Cloud Function fires on the creation of
  //  the `calls/{callId}` document and is the ONE sender of the incoming-call
  //  FCM. Pushing from the client as well delivered the same `callId` twice,
  //  which surfaced as two incoming-call notifications and two Incoming Call
  //  screens.

  // ─────────────────────────────────────────────────────────────
  // STREAMS / QUERIES
  // ─────────────────────────────────────────────────────────────
  Stream<CallModel?> incomingCallStream(String userId) {
    return _firestore
        .collection(FirestoreCollections.calls)
        .where('receiverId', isEqualTo: userId)
        .where('callStatus', isEqualTo: CallStatus.ringing)
        .orderBy('startTime', descending: true)
        .limit(1)
        .snapshots()
        .map((s) {
          if (s.docs.isEmpty) return null;
          try {
            return CallModel.fromMap(s.docs.first.data());
          } catch (e) {
            debugPrint('incomingCallStream parse error: $e');
            return null;
          }
        });
  }

  Stream<CallModel?> watchCall(String callId) {
    return _firestore
        .collection(FirestoreCollections.calls)
        .doc(callId)
        .snapshots()
        .map((s) {
          if (!s.exists) return null;
          try {
            return CallModel.fromMap(s.data()!);
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
      return doc.exists ? CallModel.fromMap(doc.data()!) : null;
    } catch (_) {
      return null;
    }
  }

  /// Offline-first call history stream:
  ///  1. Emits the Hive cache immediately (works without internet).
  ///  2. Subscribes to Firestore **scoped to this user** (caller OR receiver),
  ///     persists results into Hive (dedup by callId), and emits the merged,
  ///     sorted list.
  ///
  /// The previous implementation listened to the ENTIRE `calls` collection and
  /// filtered client-side — every client downloaded every user's call records.
  Stream<List<CallModel>> getCallHistory(String userId) {
    return _callHistoryCache.putIfAbsent(userId, () {
      final controller = StreamController<List<CallModel>>.broadcast();

      // Offline-first: show cached history immediately.
      Future.microtask(() {
        final cached =
            OfflineCallService.instance
                .getCallHistory(userId)
                .map(OfflineConverters.toDomainCall)
                .toList()
              ..sort((a, b) => b.startTime.compareTo(a.startTime));
        if (!controller.isClosed) {
          controller.add(cached);
        }
      });

      const statuses = ['ended', 'missed', 'rejected', 'accepted', 'cancelled'];
      final callerCalls = <String, CallModel>{};
      final receiverCalls = <String, CallModel>{};

      void emit() {
        if (controller.isClosed) return;
        final server = <CallModel>{
          ...callerCalls.values,
          ...receiverCalls.values,
        }.toList();

        // Persist server call records into Hive (offline-first cache).
        unawaited(
          OfflineCallService.instance.mergeServerCalls(
            server.map(OfflineConverters.toOfflineCall).toList(),
          ),
        );

        final merged = _mergeCallRecords(
          OfflineCallService.instance
              .getCallHistory(userId)
              .map(OfflineConverters.toDomainCall)
              .toList(),
          server,
        )..sort((a, b) => b.startTime.compareTo(a.startTime));

        controller.add(merged);
      }

      CallModel? parseDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
        try {
          return CallModel.fromMap(doc.data());
        } catch (_) {
          return null;
        }
      }

      final callerSub = _firestore
          .collection(FirestoreCollections.calls)
          .where('callerId', isEqualTo: userId)
          .where('callStatus', whereIn: statuses)
          .limit(200)
          .snapshots()
          .listen(
            (snapshot) {
              callerCalls
                ..clear()
                ..addEntries(
                  snapshot.docs
                      .map((d) => parseDoc(d))
                      .whereType<CallModel>()
                      .map((c) => MapEntry(c.id, c)),
                );
              emit();
            },
            onError: (Object error) {
              debugPrint('call history (caller) stream error: $error');
            },
            cancelOnError: false,
          );

      final receiverSub = _firestore
          .collection(FirestoreCollections.calls)
          .where('receiverId', isEqualTo: userId)
          .where('callStatus', whereIn: statuses)
          .limit(200)
          .snapshots()
          .listen(
            (snapshot) {
              receiverCalls
                ..clear()
                ..addEntries(
                  snapshot.docs
                      .map((d) => parseDoc(d))
                      .whereType<CallModel>()
                      .map((c) => MapEntry(c.id, c)),
                );
              emit();
            },
            onError: (Object error) {
              debugPrint('call history (receiver) stream error: $error');
            },
            cancelOnError: false,
          );

      controller.onCancel = () {
        callerSub.cancel();
        receiverSub.cancel();
        _callHistoryCache.remove(userId);
        controller.close();
      };

      return controller.stream;
    });
  }

  List<CallModel> _mergeCallRecords(
    List<CallModel> local,
    List<CallModel> server,
  ) {
    final byId = <String, CallModel>{};
    for (final c in server) {
      byId[c.id] = c;
    }
    for (final c in local) {
      final existing = byId[c.id];
      if (existing == null) {
        byId[c.id] = c;
      }
    }
    return byId.values.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
  }

  Future<void> deleteCallHistory(String callId) async {
    // Delete locally regardless of connectivity.
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

  /// Persist a [CallModel] into the local Hive cache (offline-first).
  Future<void> _saveCallLocally(CallModel call) {
    return OfflineCallService.instance.saveCall(
      OfflineConverters.toOfflineCall(call),
    );
  }

  Future<bool> requestPermissions({required bool isVideoCall}) async {
    try {
      final perms = [Permission.microphone];
      if (isVideoCall) perms.add(Permission.camera);
      final results = await perms.request();
      return results.values.every((s) => s == PermissionStatus.granted);
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // DISPOSE
  // ─────────────────────────────────────────────────────────────
  void cancelSubscription() {
    _callSubscription?.cancel();
    _callSubscription = null;
  }

  /// Screen-scoped cleanup for unrelated screens (chat list, chat screen,
  /// call history, room chat) closing.
  ///
  /// Deliberately does NOT cancel the ring timeout, the active call state or
  /// the call-status subscription: those belong to a live call. The old
  /// `dispose()` was called from four different screens, so closing a chat
  /// while a call was ringing silently killed the 45s auto-miss timer and
  /// left the call (and both users) stuck "ringing" forever.
  void resetForScreen() {
    stopAllOnlineStatusMonitoring();
  }

  void dispose() {
    cancelSubscription();
    stopAllOnlineStatusMonitoring();
    _cancelRingTimeout();
    try {
      if (_isJoined) unawaited(softReset());
    } catch (_) {}
    _isJoined = false;
    _currentRoomId = null;
    _currentStreamId = null;
    _remoteStreamId = null;
    _activeCallId = null;
    _activeCallStatus = null;
    debugPrint('CallController soft-disposed (engine stays alive)');
  }

  /// Call this only when the app is truly closing
  Future<void> destroyEngine() async {
    try {
      await softReset();
      if (_isEngineAlive) {
        await ZegoExpressEngine.destroyEngine();
        _isEngineAlive = false;
      }
    } catch (_) {}
    _isInitialized = false;
    _isPreWarmed = false;
  }

  // ─────────────────────────────────────────────────────────────
  // HELPER
  // ─────────────────────────────────────────────────────────────
  void _addError(String msg) {
    debugPrint('ERROR: $msg');
    if (!_errorController.isClosed) _errorController.add(msg);
  }

  static DateTime _safeParseTime(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }
}

// Convenience extension to avoid lint warnings on fire-and-forget futures
void unawaited(Future<dynamic> future) {
  future.catchError((e) => debugPrint('unawaited error: $e'));
}
