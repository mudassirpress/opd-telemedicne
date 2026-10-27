import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Looping in-app ringtone for an incoming call.
///
/// Idempotent per isolate: [playDefaultRingtone] while already ringing is a
/// no-op, so the notification presenter (which rings the moment the call
/// notification goes up) and the Incoming Call screen (which rings when it
/// opens) can both call it without stacking a second MediaPlayer on top of
/// the first.
///
/// [stopDefaultRingtone] is always forwarded to the platform side even when
/// this isolate believes nothing is playing — the native player is a no-op
/// when it is already stopped, and a different isolate may have started it.
class SystemRingtonePlayer {
  static const MethodChannel _channel = MethodChannel(
    'telemedicine/system_ringtone',
  );

  static bool _isRinging = false;

  /// Whether this isolate most recently started the ringtone and has not
  /// stopped it since.
  static bool get isRinging => _isRinging;

  static Future<void> playDefaultRingtone() async {
    if (_isRinging) return;
    _isRinging = true;
    try {
      await _channel.invokeMethod<void>('playDefaultRingtone');
    } on MissingPluginException catch (e) {
      _isRinging = false;
      debugPrint('Default ringtone plugin is not available: $e');
    } on PlatformException catch (e) {
      _isRinging = false;
      debugPrint('Failed to play default ringtone: ${e.message}');
    }
  }

  static Future<void> stopDefaultRingtone() async {
    _isRinging = false;
    try {
      await _channel.invokeMethod<void>('stopDefaultRingtone');
    } on MissingPluginException catch (e) {
      debugPrint('Default ringtone plugin is not available: $e');
    } on PlatformException catch (e) {
      debugPrint('Failed to stop default ringtone: ${e.message}');
    }
  }
}
