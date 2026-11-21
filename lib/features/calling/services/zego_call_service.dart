// lib/features/calling/services/zego_call_service.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

enum ZegoCallConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Scalable, Low-Latency RTC Calling Service powered by ZegoExpressEngine.
/// Designed for high-concurrency production load with robust room lifecycle
/// management, race-condition prevention, and clean teardown.
class ZegoCallService {
  static final ZegoCallService instance = ZegoCallService._internal();
  factory ZegoCallService() => instance;
  ZegoCallService._internal();

  static const int _appId = ZegoConfig.appId;
  static const String _appSign = ZegoConfig.appSign;

  bool _isEngineCreated = false;
  bool _isInRoom = false;
  String? _currentRoomId;
  String? _currentStreamId;
  String? _remoteStreamId;
  final Set<String> _subscribedStreams = <String>{};

  // Completer to ensure local audio stream is ONLY published AFTER verified Logined state
  Completer<bool>? _roomLoginCompleter;

  // Broadcast Streams
  final StreamController<ZegoCallConnectionStatus> _connectionStatusController =
      StreamController<ZegoCallConnectionStatus>.broadcast();
  final StreamController<String> _remoteStreamController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _networkQualityController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<ZegoCallConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;
  Stream<String> get remoteStreamStream => _remoteStreamController.stream;
  Stream<Map<String, dynamic>> get networkQualityStream =>
      _networkQualityController.stream;

  bool get isEngineCreated => _isEngineCreated;
  bool get isInRoom => _isInRoom;
  String? get currentRoomId => _currentRoomId;
  String? get currentStreamId => _currentStreamId;
  String? get remoteStreamId => _remoteStreamId;
  bool get hasRemoteAudio => _remoteStreamId != null;

  /// Sanitizes user ID to conform with Zego specifications (alphanumeric & underscore only, max 64 chars).
  static String formatZegoUserId(String rawId) {
    final clean = rawId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    if (clean.isEmpty) return 'user_default';
    return clean.length > 64 ? clean.substring(0, 64) : clean;
  }

  /// Sanitizes room ID to conform with Zego specifications (collision-free & deterministic).
  static String formatRoomId(String rawId) {
    final clean = rawId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    if (clean.isEmpty) return 'room_call_default';
    return clean.length > 64 ? clean.substring(0, 64) : clean;
  }

  /// Initializes the Zego Express Engine with audio-optimized scenario & echo cancellation.
  Future<bool> initializeEngine() async {
    if (_isEngineCreated) return true;

    try {
      debugPrint('🎙️ [RTC Stage 1: Engine Init] Initializing Zego Express Engine (AppID: $_appId)...');
      await ZegoExpressEngine.createEngineWithProfile(
        ZegoEngineProfile(
          _appId,
          ZegoScenario.StandardVoiceCall,
          appSign: _appSign,
        ),
      );

      _isEngineCreated = true;
      _registerEventHandlers();

      // Optimize engine specifically for voice calls
      await ZegoExpressEngine.instance.enableCamera(false);

      // Hardware acoustic processing
      try {
        await ZegoExpressEngine.instance.enableAEC(true);
        await ZegoExpressEngine.instance.enableAGC(true);
        await ZegoExpressEngine.instance.enableANS(true);
      } catch (e) {
        debugPrint('⚠️ [RTC Audio Enhancements] Notice: $e');
      }

      debugPrint('✅ [RTC Stage 1: Engine Init] Engine initialized successfully.');
      return true;
    } catch (e) {
      debugPrint('❌ [RTC Stage 1: Engine Init Failed] $e');
      _isEngineCreated = false;
      return false;
    }
  }

  void _registerEventHandlers() {
    ZegoExpressEngine.onRoomStateChanged = (
      String roomId,
      ZegoRoomStateChangedReason reason,
      int errorCode,
      Map<String, dynamic> extendedData,
    ) {
      debugPrint(
        '📞 [RTC Room State Callback] room=$roomId reason=$reason code=$errorCode ext=$extendedData',
      );

      switch (reason) {
        case ZegoRoomStateChangedReason.Logined:
          debugPrint('✅ [RTC Stage 4: Room Connected] Room $roomId verified CONNECTED (Logined).');
          _isInRoom = true;
          _currentRoomId = roomId;
          if (_roomLoginCompleter != null && !_roomLoginCompleter!.isCompleted) {
            _roomLoginCompleter!.complete(true);
          }
          _connectionStatusController.add(ZegoCallConnectionStatus.connected);
          break;

        case ZegoRoomStateChangedReason.Reconnected:
          debugPrint('🔄 [RTC Reconnected] Room $roomId re-established connection.');
          _connectionStatusController.add(ZegoCallConnectionStatus.connected);
          break;

        case ZegoRoomStateChangedReason.Logining:
          debugPrint('⏳ [RTC Stage 3: Room Connecting] Logging into room $roomId...');
          _connectionStatusController.add(ZegoCallConnectionStatus.connecting);
          break;

        case ZegoRoomStateChangedReason.Reconnecting:
          debugPrint('⚠️ [RTC Reconnecting] Connection lost. Attempting auto-reconnect to $roomId...');
          _connectionStatusController.add(ZegoCallConnectionStatus.reconnecting);
          break;

        case ZegoRoomStateChangedReason.Logout:
        case ZegoRoomStateChangedReason.LogoutFailed:
          debugPrint('🚪 [RTC Disconnected] Room $roomId logged out or session ended.');
          _isInRoom = false;
          if (_roomLoginCompleter != null && !_roomLoginCompleter!.isCompleted) {
            _roomLoginCompleter!.complete(false);
          }
          _connectionStatusController.add(ZegoCallConnectionStatus.disconnected);
          break;

        default:
          if (errorCode != 0) {
            debugPrint('❌ [RTC Room Error] Room $roomId encountered SDK error code: $errorCode');
            if (_roomLoginCompleter != null && !_roomLoginCompleter!.isCompleted) {
              _roomLoginCompleter!.complete(false);
            }
            _connectionStatusController.add(ZegoCallConnectionStatus.failed);
          }
          break;
      }
    };

    ZegoExpressEngine.onRoomStreamUpdate = (
      String roomId,
      ZegoUpdateType updateType,
      List<ZegoStream> streamList,
      Map<String, dynamic> extendedData,
    ) {
      debugPrint(
        '📡 [RTC Stream Update Callback] room=$roomId type=$updateType streams=${streamList.length}',
      );

      if (updateType == ZegoUpdateType.Add) {
        for (final stream in streamList) {
          final sId = stream.streamID;
          if (!_subscribedStreams.contains(sId)) {
            _subscribedStreams.add(sId);
            _remoteStreamId = sId;
            debugPrint('🎧 [RTC Stage 6: Remote Stream Added & Playing] Subscribing to: $sId in room $roomId');
            ZegoExpressEngine.instance.startPlayingStream(
              sId,
              canvas: null, // Pure voice call
            );
            _remoteStreamController.add(sId);
          }
        }
      } else if (updateType == ZegoUpdateType.Delete) {
        for (final stream in streamList) {
          final sId = stream.streamID;
          debugPrint('🛑 [RTC Remote Stream Removed] Stopping playback for: $sId');
          _subscribedStreams.remove(sId);
          ZegoExpressEngine.instance.stopPlayingStream(sId);
          if (_remoteStreamId == sId) {
            _remoteStreamId = _subscribedStreams.isNotEmpty ? _subscribedStreams.first : null;
          }
        }
      }
    };

    ZegoExpressEngine.onNetworkQuality = (
      String userID,
      ZegoStreamQualityLevel upstreamQuality,
      ZegoStreamQualityLevel downstreamQuality,
    ) {
      _networkQualityController.add({
        'userId': userID,
        'upstream': upstreamQuality.index,
        'downstream': downstreamQuality.index,
      });
    };
  }

  /// Joins a voice call room and begins publishing audio ONLY after room connection is verified.
  /// Prevents race condition bugs where publishing begins before room handshake finishes.
  Future<bool> joinCallRoom({
    required String roomId,
    required String userId,
    required String userName,
  }) async {
    final engineReady = await initializeEngine();
    if (!engineReady) {
      debugPrint('❌ [RTC Stage 2: Abort] Engine initialization failed.');
      return false;
    }

    final cleanRoomId = formatRoomId(roomId);
    final zegoUserId = formatZegoUserId(userId);
    final zegoUserName = userName.trim().isEmpty ? zegoUserId : userName.trim();
    final zegoUser = ZegoUser(zegoUserId, zegoUserName);

    // Dynamic collision-free configuration
    final roomConfig = ZegoRoomConfig(0, true, '');

    debugPrint(
      '🚪 [RTC Stage 2: Token / Room Config] room=$cleanRoomId, user=$zegoUserId ($zegoUserName)',
    );

    try {
      _roomLoginCompleter = Completer<bool>();

      debugPrint('🚪 [RTC Stage 3: Join Room] Initiating loginRoom for $cleanRoomId...');
      final loginResult = await ZegoExpressEngine.instance.loginRoom(
        cleanRoomId,
        zegoUser,
        config: roomConfig,
      );

      if (loginResult.errorCode != 0) {
        debugPrint(
          '❌ [RTC Stage 3: Join Room Failed] loginRoom returned errorCode: ${loginResult.errorCode}',
        );
        _roomLoginCompleter = null;
        return false;
      }

      // Race condition safeguard: Wait until onRoomStateChanged confirms Logined
      bool isConnected = false;
      try {
        isConnected = await _roomLoginCompleter!.future.timeout(
          const Duration(seconds: 12),
          onTimeout: () {
            debugPrint('⏰ [RTC Stage 3: Timeout] Waiting for room Logined callback timed out after 12s.');
            return false;
          },
        );
      } catch (e) {
        debugPrint('⚠️ [RTC Login Completer Error]: $e');
        isConnected = false;
      } finally {
        _roomLoginCompleter = null;
      }

      if (!isConnected) {
        debugPrint('❌ [RTC Stage 4: Aborted] Room not connected. Terminating room session.');
        await leaveCallRoom();
        return false;
      }

      _isInRoom = true;
      _currentRoomId = cleanRoomId;

      // Stage 5: Publish local audio stream only after room is verified connected
      final streamId = 'stream_${cleanRoomId}_$zegoUserId';
      _currentStreamId = streamId;

      debugPrint('🎙️ [RTC Stage 5: Local Stream Published] Starting audio publication: $streamId');
      await ZegoExpressEngine.instance.startPublishingStream(streamId);
      await ZegoExpressEngine.instance.enableCamera(false);
      await ZegoExpressEngine.instance.muteMicrophone(false);

      return true;
    } catch (e) {
      debugPrint('❌ [RTC Stage 3: Exception joining room] $e');
      _roomLoginCompleter = null;
      await leaveCallRoom();
      return false;
    }
  }

  /// Leaves the current voice call room and stops all streams with strict teardown sequence:
  /// 1. stopPublishingStream()
  /// 2. stopPlayingStream() for all active remote streams
  /// 3. logoutRoom()
  Future<void> leaveCallRoom() async {
    if (!_isInRoom && _currentRoomId == null && _currentStreamId == null) return;

    final roomId = _currentRoomId;
    debugPrint('🚪 [RTC Stage 7: Teardown Initiated] room: $roomId');

    try {
      // 1. Stop local publishing
      if (_currentStreamId != null) {
        debugPrint('⏹️ [RTC Teardown] Stopping local publishing stream: $_currentStreamId');
        await ZegoExpressEngine.instance.stopPublishingStream();
        _currentStreamId = null;
      }

      // 2. Stop all remote playing streams
      for (final sId in _subscribedStreams) {
        debugPrint('⏹️ [RTC Teardown] Stopping remote stream playback: $sId');
        try {
          await ZegoExpressEngine.instance.stopPlayingStream(sId);
        } catch (_) {}
      }
      _subscribedStreams.clear();
      _remoteStreamId = null;

      // 3. Logout from room
      if (roomId != null) {
        debugPrint('🚪 [RTC Teardown] Logging out of room: $roomId');
        await ZegoExpressEngine.instance.logoutRoom(roomId);
      }
    } catch (e) {
      debugPrint('⚠️ [RTC Teardown Exception]: $e');
    } finally {
      _isInRoom = false;
      _currentRoomId = null;
      _roomLoginCompleter = null;
      _connectionStatusController.add(ZegoCallConnectionStatus.disconnected);
      debugPrint('✅ [RTC Stage 8: Teardown Complete]');
    }
  }

  /// Destroys the engine on complete app teardown / logout.
  Future<void> destroy() async {
    await leaveCallRoom();
    if (_isEngineCreated) {
      try {
        await ZegoExpressEngine.destroyEngine();
      } catch (e) {
        debugPrint('⚠️ [ZegoCallService] Error destroying engine: $e');
      }
      _isEngineCreated = false;
    }
  }
}
