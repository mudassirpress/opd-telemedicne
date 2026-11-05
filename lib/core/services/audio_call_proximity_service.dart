import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

/// AudioCallProximityService manages hardware-level proximity sensor screen
/// blanking and audio routing (earpiece vs loudspeaker) for pure audio calls.
///
/// Features:
/// 1. Hardware Screen Blanking & Touch Lock:
///    - On Android: uses native PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK (0x00000020).
///    - On iOS: uses UIDevice.current.isProximityMonitoringEnabled = true.
///    - Automatically turns the screen completely OFF and locks touches when the
///      device is held to the ear; instantly restores display & touch when moved away.
/// 2. Audio Routing:
///    - Pure audio calls route to Earpiece by default (not loudspeaker).
///    - Proximity screen blanking is active strictly while routed to Earpiece.
///    - When toggled to Loudspeaker, proximity blanking is disabled so the screen
///      stays ON for touch and UI interaction.
///    - When toggled back to Earpiece, proximity blanking is re-enabled immediately.
/// 3. Call Lifecycle & Cleanup:
///    - Wake lock and proximity monitoring are acquired upon call connection.
///    - In dispose() / call termination, all wake locks are safely released and
///      the user's standard screen timeout is restored.
class AudioCallProximityService {
  AudioCallProximityService._();
  static final AudioCallProximityService instance = AudioCallProximityService._();

  static const MethodChannel _channel = MethodChannel('telemedicine/proximity');

  bool _isProximityEnabled = false;
  bool _isSpeakerOn = false;
  bool _isCallConnected = false;
  bool _isVideoCall = false;

  /// Whether proximity screen blanking is currently active.
  bool get isProximityEnabled => _isProximityEnabled;

  /// Current speakerphone routing status (false = earpiece, true = loudspeaker).
  bool get isSpeakerOn => _isSpeakerOn;

  /// Checks if the device hardware supports proximity screen-off wake lock.
  Future<bool> isProximitySupported() async {
    try {
      final supported = await _channel.invokeMethod<bool>('isProximitySensorSupported');
      return supported ?? false;
    } on PlatformException catch (e) {
      debugPrint('[AudioCallProximityService] isProximitySupported error: $e');
      return false;
    }
  }

  /// Initializes proximity and audio routing for an incoming/outgoing call session.
  /// Pure audio calls default to earpiece routing.
  Future<void> onCallStarted({required bool isVideoCall}) async {
    _isVideoCall = isVideoCall;
    _isCallConnected = false;

    if (_isVideoCall) {
      // Video calls always route to speaker and do not use proximity blanking.
      _isSpeakerOn = true;
      await _setEngineAudioRoute(toSpeaker: true);
      await disableProximityScreenOff();
    } else {
      // Pure audio calls default to earpiece!
      _isSpeakerOn = false;
      await _setEngineAudioRoute(toSpeaker: false);
    }
  }

  /// Called as soon as the media session is established (CallState.connected).
  /// For pure audio calls with earpiece routing, activates the hardware proximity lock.
  Future<void> onCallConnected() async {
    _isCallConnected = true;
    if (!_isVideoCall && !_isSpeakerOn) {
      // Route audio to earpiece by default
      await _setEngineAudioRoute(toSpeaker: false);
      await enableProximityScreenOff();
    }
  }

  /// Enables the native proximity sensor to blank the screen on ear proximity.
  Future<bool> enableProximityScreenOff() async {
    if (_isProximityEnabled) return true;
    try {
      final success = await _channel.invokeMethod<bool>('enableProximitySensor');
      _isProximityEnabled = success ?? false;
      debugPrint('[AudioCallProximityService] Proximity screen blanking enabled: $_isProximityEnabled');
      return _isProximityEnabled;
    } on PlatformException catch (e) {
      debugPrint('[AudioCallProximityService] enableProximitySensor error: $e');
      _isProximityEnabled = false;
      return false;
    }
  }

  /// Disables the native proximity sensor and releases the proximity wake lock.
  Future<bool> disableProximityScreenOff() async {
    if (!_isProximityEnabled) return true;
    try {
      final success = await _channel.invokeMethod<bool>('disableProximitySensor');
      _isProximityEnabled = false;
      debugPrint('[AudioCallProximityService] Proximity screen blanking disabled');
      return success ?? true;
    } on PlatformException catch (e) {
      debugPrint('[AudioCallProximityService] disableProximitySensor error: $e');
      return false;
    }
  }

  /// Explicitly routes audio to the Earpiece (receiver).
  /// If call is connected in pure audio mode, enables proximity blanking.
  Future<void> routeAudioToEarpiece() async {
    _isSpeakerOn = false;
    await _setEngineAudioRoute(toSpeaker: false);
    if (_isCallConnected && !_isVideoCall) {
      await enableProximityScreenOff();
    }
  }

  /// Explicitly routes audio to the Loudspeaker.
  /// Disables proximity blanking so screen stays ON for UI interaction.
  Future<void> routeAudioToSpeaker() async {
    _isSpeakerOn = true;
    await disableProximityScreenOff();
    await _setEngineAudioRoute(toSpeaker: true);
  }

  /// Handles user tapping the Speakerphone toggle button.
  /// - When switching to Loudspeaker: routes audio to speaker and disables proximity.
  /// - When switching to Earpiece: routes audio to earpiece and enables proximity.
  Future<void> onSpeakerToggled(bool isSpeakerOn) async {
    if (isSpeakerOn) {
      await routeAudioToSpeaker();
    } else {
      await routeAudioToEarpiece();
    }
  }

  /// Safely updates Zego's audio route.
  Future<void> _setEngineAudioRoute({required bool toSpeaker}) async {
    try {
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(toSpeaker);
    } catch (e) {
      debugPrint('[AudioCallProximityService] Zego setAudioRouteToSpeaker error: $e');
    }
  }

  /// Releases all locks and resets proximity monitoring when the call ends or
  /// the widget is disposed. Restores default system screen management.
  Future<void> releaseAll() async {
    _isCallConnected = false;
    _isVideoCall = false;
    _isSpeakerOn = false;
    await disableProximityScreenOff();
  }
}

