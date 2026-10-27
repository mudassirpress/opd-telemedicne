import 'package:just_audio/just_audio.dart';

class VoiceMessageManager {
  static AudioPlayer? _currentPlayer;
  static String? _currentPlayingId;

  // Listeners for UI updates
  static final List<Function(String?)> _playingStateListeners = [];
  static final List<Function(Duration, Duration, String?)> _progressListeners =
      [];

  static void registerPlayer(AudioPlayer player, String messageId) {
    // Stop any existing player first (without disposing it so its widget remains functional)
    if (_currentPlayer != null && _currentPlayer != player) {
      _currentPlayer?.stop();
    }

    _currentPlayer = player;
    _currentPlayingId = messageId;

    // Notify listeners
    _notifyPlayingStateChanged(messageId);
  }

  static Future<void> stopAllAudio() async {
    if (_currentPlayer != null) {
      await _currentPlayer?.stop();
      _currentPlayer = null;
    }
    _currentPlayingId = null;
    _notifyPlayingStateChanged(null);
    _notifyProgressChanged(Duration.zero, Duration.zero, null);
  }

  static void unregisterPlayer([AudioPlayer? player]) {
    if (player == null || _currentPlayer == player) {
      _currentPlayer = null;
      _currentPlayingId = null;
    }
  }

  static String? getCurrentPlayingId() => _currentPlayingId;
  static AudioPlayer? getCurrentPlayer() => _currentPlayer;

  static void addPlayingStateListener(Function(String?) listener) {
    _playingStateListeners.add(listener);
  }

  static void removePlayingStateListener(Function(String?) listener) {
    _playingStateListeners.remove(listener);
  }

  static void addProgressListener(
    Function(Duration, Duration, String?) listener,
  ) {
    _progressListeners.add(listener);
  }

  static void removeProgressListener(
    Function(Duration, Duration, String?) listener,
  ) {
    _progressListeners.remove(listener);
  }

  static void _notifyPlayingStateChanged(String? messageId) {
    for (var listener in _playingStateListeners) {
      listener(messageId);
    }
  }

  static void _notifyProgressChanged(
    Duration position,
    Duration duration,
    String? messageId,
  ) {
    for (var listener in _progressListeners) {
      listener(position, duration, messageId);
    }
  }

  static void updateProgress(Duration position, Duration duration) {
    _notifyProgressChanged(position, duration, _currentPlayingId);
  }

  static void dispose() {
    if (_currentPlayer != null) {
      _currentPlayer?.dispose();
      _currentPlayer = null;
    }
    _currentPlayingId = null;
    _playingStateListeners.clear();
    _progressListeners.clear();
  }
}
