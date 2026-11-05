// lib/features/calling/services/call_audio_service.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/services/audio_call_proximity_service.dart';
import 'package:telemedicine/core/services/audio_service.dart';
import 'package:telemedicine/core/services/call_ringtone_service.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

class CallAudioService {
  CallAudioService._();
  static final CallAudioService instance = CallAudioService._();

  bool _isSpeakerOn = false;
  bool _isMuted = false;

  bool get isSpeakerOn => _isSpeakerOn;
  bool get isMuted => _isMuted;

  /// Initializes audio settings for active voice call.
  /// Pure audio calls default to earpiece (loudspeaker = false) and activate proximity blanking.
  Future<void> onCallConnected() async {
    _isSpeakerOn = false;
    _isMuted = false;

    // Route to earpiece by default for voice calls
    try {
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(false);
      await ZegoExpressEngine.instance.muteMicrophone(false);
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] Zego audio route setup failed: $e');
    }

    // Activate proximity blanking and earpiece routing
    try {
      await AudioCallProximityService.instance.onCallStarted(isVideoCall: false);
      await AudioCallProximityService.instance.onCallConnected();
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] Proximity sensor setup failed: $e');
    }
  }

  /// Toggles Speakerphone (Loudspeaker vs Earpiece).
  Future<bool> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    try {
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(_isSpeakerOn);
      await AudioCallProximityService.instance.onSpeakerToggled(_isSpeakerOn);
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] toggleSpeaker error: $e');
    }
    return _isSpeakerOn;
  }

  /// Sets speakerphone to a specific state.
  Future<void> setSpeaker(bool enable) async {
    _isSpeakerOn = enable;
    try {
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(enable);
      await AudioCallProximityService.instance.onSpeakerToggled(enable);
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] setSpeaker error: $e');
    }
  }

  /// Toggles Microphone Mute.
  Future<bool> toggleMute() async {
    _isMuted = !_isMuted;
    try {
      await ZegoExpressEngine.instance.muteMicrophone(_isMuted);
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] toggleMute error: $e');
    }
    return _isMuted;
  }

  Future<void> setMuted(bool mute) async {
    _isMuted = mute;
    try {
      await ZegoExpressEngine.instance.muteMicrophone(mute);
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] setMuted error: $e');
    }
  }

  /// Starts ringtone playback for incoming call.
  /// Uses the bundled call ringtone as single source of truth, with system fallback.
  Future<void> startRingtone({Duration? timeout, VoidCallback? onTimeout}) async {
    try {
      await CallRingtoneService.instance.startRingtone(
        timeout: timeout ?? const Duration(seconds: 45),
        onTimeout: onTimeout,
      );
      // Fallback only if the in-app player failed to start
      if (!CallRingtoneService.instance.isPlaying) {
        await SystemRingtonePlayer.playDefaultRingtone();
      }
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] In-app ringtone failed: $e, trying fallback.');
      try {
        await SystemRingtonePlayer.playDefaultRingtone();
      } catch (e2) {
        debugPrint('⚠️ [CallAudioService] Fallback ringtone failed: $e2');
      }
    }
  }

  /// Stops ringtone playback immediately across all engines.
  Future<void> stopRingtone() async {
    try {
      await CallRingtoneService.instance.stopRingtone();
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] stop in-app ringtone error: $e');
    }
    try {
      await SystemRingtonePlayer.stopDefaultRingtone();
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] stop system ringtone error: $e');
    }
  }

  /// Cleans up audio and releases proximity wake locks on call end.
  Future<void> cleanup() async {
    await stopRingtone();
    try {
      await AudioCallProximityService.instance.releaseAll();
    } catch (e) {
      debugPrint('⚠️ [CallAudioService] proximity cleanup error: $e');
    }
    _isSpeakerOn = false;
    _isMuted = false;
  }
}
