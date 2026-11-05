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

  // Streams
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
  String? get remoteStreamId => _remoteStreamId;
  bool get hasRemoteAudio => _remoteStreamId != null;

  /// Sanitizes user ID to conform with Zego requirements (alphanumeric and underscore).
  static String formatZegoUserId(String rawId) {
    final clean = rawId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    if (clean.isEmpty) return 'user_default';
    return clean.length > 64 ? clean.substring(0, 64) : clean;
  }

  /// Initializes the Zego Express Engine for Standard Voice Calling.
  Future<bool> initializeEngine() async {
    if (_isEngineCreated) return true;

    try {
      debugPrint('🎙️ [ZegoCallService] Initializing Zego Express Engine for voice calling...');
      await ZegoExpressEngine.createEngineWithProfile(
        ZegoEngineProfile(
          _appId,
          ZegoScenario.StandardVoiceCall,
          appSign: _appSign,
        ),
      );

      _isEngineCreated = true;
      _registerEventHandlers();

      // Disable camera explicitly for pure voice call optimization
      await ZegoExpressEngine.instance.enableCamera(false);
      debugPrint('✅ [ZegoCallService] Zego engine initialized successfully.');
      return true;
    } catch (e) {
      debugPrint('❌ [ZegoCallService] Failed to create Zego engine: $e');
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
        '📞 [ZegoCallService] onRoomStateChanged: room=$roomId reason=$reason code=$errorCode',
      );

      if (errorCode != 0) {
        debugPrint('⚠️ [ZegoCallService] Room state error code: $errorCode');
      }

      switch (reason) {
        case ZegoRoomStateChangedReason.Logined:
          _connectionStatusController.add(ZegoCallConnectionStatus.connected);
          break;
        case ZegoRoomStateChangedReason.Logining:
          _connectionStatusController.add(ZegoCallConnectionStatus.connecting);
          break;
        case ZegoRoomStateChangedReason.Reconnecting:
          _connectionStatusController.add(ZegoCallConnectionStatus.reconnecting);
          break;
        case ZegoRoomStateChangedReason.Reconnected:
          _connectionStatusController.add(ZegoCallConnectionStatus.connected);
          break;
        case ZegoRoomStateChangedReason.Logout:
        case ZegoRoomStateChangedReason.LogoutFailed:
          _connectionStatusController.add(ZegoCallConnectionStatus.disconnected);
          break;
        default:
          if (errorCode != 0) {
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
        '📡 [ZegoCallService] onRoomStreamUpdate: type=$updateType streams=${streamList.length}',
      );

      if (updateType == ZegoUpdateType.Add) {
        for (final stream in streamList) {
          debugPrint('🎧 [ZegoCallService] Playing remote audio stream: ${stream.streamID}');
          _remoteStreamId = stream.streamID;
          ZegoExpressEngine.instance.startPlayingStream(
            stream.streamID,
            canvas: null, // Pure voice call (no video canvas)
          );
          _remoteStreamController.add(stream.streamID);
        }
      } else if (updateType == ZegoUpdateType.Delete) {
        for (final stream in streamList) {
          debugPrint('🛑 [ZegoCallService] Stopping remote stream: ${stream.streamID}');
          ZegoExpressEngine.instance.stopPlayingStream(stream.streamID);
          if (_remoteStreamId == stream.streamID) {
            _remoteStreamId = null;
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

  /// Joins a voice call room and begins publishing audio.
  Future<bool> joinCallRoom({
    required String roomId,
    required String userId,
    required String userName,
  }) async {
    await initializeEngine();

    final zegoUserId = formatZegoUserId(userId);
    final zegoUserName = userName.trim().isEmpty ? zegoUserId : userName.trim();
    final zegoUser = ZegoUser(zegoUserId, zegoUserName);

    final roomConfig = ZegoRoomConfig(0, true, '');

    debugPrint(
      '🚪 [ZegoCallService] Logging into room: $roomId as $zegoUserId ($zegoUserName)',
    );

    try {
      final loginResult = await ZegoExpressEngine.instance.loginRoom(
        roomId,
        zegoUser,
        config: roomConfig,
      );

      if (loginResult.errorCode != 0) {
        debugPrint(
          '❌ [ZegoCallService] loginRoom failed with code: ${loginResult.errorCode}',
        );
        return false;
      }

      _isInRoom = true;
      _currentRoomId = roomId;

      // Start publishing local audio stream
      final streamId = 'stream_${roomId}_$zegoUserId';
      _currentStreamId = streamId;

      debugPrint('🎙️ [ZegoCallService] Publishing local audio stream: $streamId');
      await ZegoExpressEngine.instance.startPublishingStream(streamId);
      await ZegoExpressEngine.instance.enableCamera(false);
      await ZegoExpressEngine.instance.muteMicrophone(false);

      return true;
    } catch (e) {
      debugPrint('❌ [ZegoCallService] Error joining room: $e');
      return false;
    }
  }

  /// Leaves the current voice call room and stops all streams.
  Future<void> leaveCallRoom() async {
    if (!_isInRoom && _currentRoomId == null) return;

    final roomId = _currentRoomId;
    debugPrint('🚪 [ZegoCallService] Leaving room: $roomId');

    try {
      if (_currentStreamId != null) {
        await ZegoExpressEngine.instance.stopPublishingStream();
        _currentStreamId = null;
      }
      if (_remoteStreamId != null) {
        await ZegoExpressEngine.instance.stopPlayingStream(_remoteStreamId!);
        _remoteStreamId = null;
      }
      if (roomId != null) {
        await ZegoExpressEngine.instance.logoutRoom(roomId);
      }
    } catch (e) {
      debugPrint('⚠️ [ZegoCallService] Error during room cleanup: $e');
    } finally {
      _isInRoom = false;
      _currentRoomId = null;
      _connectionStatusController.add(ZegoCallConnectionStatus.disconnected);
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

