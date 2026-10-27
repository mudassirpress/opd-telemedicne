import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Audio service responsible for managing the incoming call ringtone lifecycle.
///
/// Ensures clean loop playback on incoming calls and immediate teardown
/// on Accept, Reject, or Timeout.
class CallRingtoneService {
  CallRingtoneService._();
  static final CallRingtoneService instance = CallRingtoneService._();

  AudioPlayer? _audioPlayer;
  bool _isPlaying = false;
  Timer? _timeoutTimer;

  /// Default timeout for unanswered incoming calls (e.g. 45 seconds).
  static const Duration defaultCallTimeout = Duration(seconds: 45);

  /// Path to the in-app ringtone asset
  static const String ringtoneAssetPath = 'sound/call_ringtoun.mp3';

  /// Whether the ringtone is currently playing
  bool get isPlaying => _isPlaying;

  /// Starts looping the custom calling ringtone for an incoming call.
  ///
  /// [timeout]: Optional custom timeout duration before automatically stopping.
  /// [onTimeout]: Optional callback invoked if the incoming call times out without answer.
  Future<void> startRingtone({
    Duration timeout = defaultCallTimeout,
    VoidCallback? onTimeout,
  }) async {
    if (_isPlaying) {
      debugPrint('📞 [CallRingtone] Ringtone already playing — ignoring duplicate start.');
      return;
    }

    try {
      _audioPlayer ??= AudioPlayer();

      // Configure audio context for an incoming call
      await _audioPlayer!.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: true,
            stayAwake: true,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.notificationRingtone,
            audioFocus: AndroidAudioFocus.gainTransientExclusive,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {
              AVAudioSessionOptions.duckOthers,
              AVAudioSessionOptions.defaultToSpeaker,
            },
          ),
        ),
      );

      // Set to infinite loop mode and max volume
      await _audioPlayer!.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer!.setVolume(1.0);

      // Play bundled ringtone asset
      await _audioPlayer!.play(AssetSource(ringtoneAssetPath));
      _isPlaying = true;
      debugPrint('🔔 [CallRingtone] Started in-app ringtone loop.');

      // Start safety timeout timer
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(timeout, () {
        debugPrint('⏰ [CallRingtone] Incoming call timed out after ${timeout.inSeconds}s.');
        stopRingtone();
        onTimeout?.call();
      });
    } catch (e, stackTrace) {
      _isPlaying = false;
      debugPrint('❌ [CallRingtone] Error starting ringtone: $e\n$stackTrace');
    }
  }

  /// Immediately stops ringtone playback and cancels the timeout timer.
  ///
  /// Call this when:
  /// - User taps Accept
  /// - User taps Decline / Reject
  /// - Caller cancels or terminates the call
  /// - The call screen is disposed
  Future<void> stopRingtone() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    if (!_isPlaying && _audioPlayer == null) return;

    try {
      if (_audioPlayer != null) {
        await _audioPlayer!.stop();
        await _audioPlayer!.seek(Duration.zero);
      }
      debugPrint('🔇 [CallRingtone] Stopped in-app ringtone.');
    } catch (e) {
      debugPrint('⚠️ [CallRingtone] Error stopping ringtone: $e');
    } finally {
      _isPlaying = false;
    }
  }

  /// Releases audio resources when completely done.
  Future<void> dispose() async {
    await stopRingtone();
    await _audioPlayer?.dispose();
    _audioPlayer = null;
  }
}
