import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One voice note as seen by the centralized playback pipeline.
@immutable
class VoiceQueueItem {
  final String messageId;
  final String audioUrl;
  final int durationSeconds;
  final bool isMe;

  /// True when the server (or the sender's device) already considers the note
  /// listened to. It is never used to auto-play anything; it only prevents an
  /// old note from being treated as "new" when computing the next track.
  final bool alreadyListened;

  const VoiceQueueItem({
    required this.messageId,
    required this.audioUrl,
    required this.durationSeconds,
    required this.isMe,
    this.alreadyListened = false,
  });

  Duration get declaredDuration => Duration(seconds: durationSeconds);
}

@immutable
class VoicePlaybackSnapshot {
  final String? activeId;
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration duration;
  final Set<String> playedIds;
  final String? completedId;
  final Object? error;

  const VoicePlaybackSnapshot({
    this.activeId,
    this.isPlaying = false,
    this.isLoading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playedIds = const <String>{},
    this.completedId,
    this.error,
  });

  static const VoicePlaybackSnapshot initial = VoicePlaybackSnapshot();

  bool isActive(String messageId) => activeId == messageId;

  bool isPlayingId(String messageId) => activeId == messageId && isPlaying;

  bool isLoadingId(String messageId) => activeId == messageId && isLoading;

  bool isPlayed(String messageId) => playedIds.contains(messageId);

  Duration positionFor(String messageId, Duration fallback) =>
      activeId == messageId ? position : fallback;

  VoicePlaybackSnapshot copyWith({
    String? activeId,
    bool? isPlaying,
    bool? isLoading,
    Duration? position,
    Duration? duration,
    Set<String>? playedIds,
    String? completedId,
    Object? error,
    bool clearError = false,
  }) {
    return VoicePlaybackSnapshot(
      activeId: activeId ?? this.activeId,
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playedIds: playedIds ?? this.playedIds,
      completedId: completedId ?? this.completedId,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Single audio session for every voice note in the app.
///
/// Responsibilities:
///  * exactly one [AudioPlayer] instance (audio focus is therefore singular);
///  * sequential auto-advance to the *immediately following unplayed incoming*
///    voice note only;
///  * durable played-state so list rebuilds/re-entry can never auto-play a
///    finished note;
///  * a fine-grained [state] notifier so only the waveform/controls rebuild
///    while the 60/120 FPS message list remains untouched;
///  * position memory per note so pause/resume and manual replay are
///    deterministic.
class VoicePlaybackController {
  VoicePlaybackController._();

  static final VoicePlaybackController instance = VoicePlaybackController._();

  static const String _playedStateKey = 'voice_notes_played_v1';
  static const Duration _autoAdvanceGap = Duration(milliseconds: 120);

  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: true,
    handleAudioSessionActivation: true,
    androidApplyAudioAttributes: true,
    useLazyPreparation: true,
  );

  final ValueNotifier<VoicePlaybackSnapshot> state =
      ValueNotifier<VoicePlaybackSnapshot>(VoicePlaybackSnapshot.initial);

  final Map<String, VoiceQueueItem> _items = <String, VoiceQueueItem>{};
  final List<String> _order = <String>[];
  final Map<String, Duration> _rememberedPositions = <String, Duration>{};
  final Set<String> _playedIds = <String>{};

  Future<void>? _initialization;
  bool _loadedPlayedState = false;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  String? _queueSignature;
  String? _activeId;
  String? _loadedSourceId;
  String? _completedId;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _completionHandled = false;
  int _completionEpoch = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Object? _error;

  String? get activeId => _activeId;

  bool isPlayed(String messageId) {
    if (_playedIds.contains(messageId)) return true;
    return _items[messageId]?.alreadyListened ?? false;
  }

  /// Replaces the queue without ever starting playback.
  ///
  /// This is the method a list build/re-entry calls. It is deliberately
  /// side-effect-free with respect to the transport: rebuilding a conversation
  /// or receiving a new socket message can never make an old note play.
  void updateQueue(Iterable<VoiceQueueItem> items) {
    final nextItems = <String, VoiceQueueItem>{};
    final nextOrder = <String>[];
    final signature = StringBuffer();

    for (final item in items) {
      if (item.messageId.isEmpty || item.audioUrl.isEmpty) continue;
      nextItems[item.messageId] = item;
      nextOrder.add(item.messageId);
      signature
        ..write(item.messageId)
        ..write('|')
        ..write(item.audioUrl)
        ..write('|')
        ..write(item.durationSeconds)
        ..write('|')
        ..write(item.isMe)
        ..write('|')
        ..write(item.alreadyListened)
        ..write(';');
    }

    final nextSignature = signature.toString();
    if (nextSignature == _queueSignature) return;
    _queueSignature = nextSignature;

    _items
      ..clear()
      ..addAll(nextItems);
    _order
      ..clear()
      ..addAll(nextOrder);

    for (final id in _rememberedPositions.keys.toList()) {
      if (!_items.containsKey(id)) _rememberedPositions.remove(id);
    }

    if (_activeId != null && !_items.containsKey(_activeId!)) {
      unawaited(stop(clearQueue: false));
      return;
    }

    _emit();
  }

  /// True when the currently loaded source is this note. Used by the bubble to
  /// distinguish "paused at remembered position" from "not active".
  bool isActive(String messageId) => _activeId == messageId;

  Duration positionFor(String messageId) {
    if (_activeId == messageId) return _position;
    return _rememberedPositions[messageId] ?? Duration.zero;
  }

  Duration durationFor(String messageId) {
    if (_activeId == messageId && _duration > Duration.zero) return _duration;
    return _items[messageId]?.declaredDuration ?? Duration.zero;
  }

  /// Deterministic single-tap toggle.
  Future<void> toggle(String messageId) async {
    if (_activeId == messageId && _isPlaying) {
      await pause();
      return;
    }
    await play(messageId);
  }

  /// Starts/resumes [messageId] from its current scrubber position.
  Future<void> play(String messageId) async {
    await _ensureInitialized();
    final item = _items[messageId];
    if (item == null) return;
    // Any explicit tap cancels a pending auto-advance from the previous note.
    _completionEpoch++;

    if (_activeId == messageId && _loadedSourceId == messageId) {
      // A completed note stays idle until the user taps it. If the last
      // position is at the end, replay from zero; a scrub to the middle is
      // honoured exactly as-is.
      if (_duration > Duration.zero &&
          _position >= _duration - const Duration(milliseconds: 200)) {
        await _player.seek(Duration.zero);
        _position = Duration.zero;
      }
      _completedId = null;
      _completionHandled = false;
      _error = null;
      _isPlaying = true;
      _isLoading = false;
      _emit();
      try {
        await _player.play();
      } catch (e) {
        _handlePlaybackError(messageId, e);
      }
      return;
    }

    await _switchTo(item);
  }

  Future<void> _switchTo(VoiceQueueItem item) async {
    final previousId = _activeId;
    if (previousId != null) {
      _rememberedPositions[previousId] = _position;
    }

    // The shared player is the concurrency guarantee: changing source stops
    // any other voice note immediately.
    try {
      await _player.stop();
    } catch (_) {}

    final startAt = _rememberedPositions[item.messageId] ?? Duration.zero;
    _activeId = item.messageId;
    _loadedSourceId = null;
    _completedId = null;
    _completionHandled = false;
    _error = null;
    _position = startAt;
    _duration = item.declaredDuration;
    _isLoading = true;
    _isPlaying = true;
    _emit();

    try {
      await _loadSource(item.audioUrl);
      _loadedSourceId = item.messageId;

      final loadedDuration = _player.duration;
      if (loadedDuration != null && loadedDuration > Duration.zero) {
        _duration = loadedDuration;
      }
      if (startAt > Duration.zero) {
        final safeStart = startAt < _duration ? startAt : Duration.zero;
        await _player.seek(safeStart);
        _position = safeStart;
      }
      _isLoading = false;
      _emit();
      await _player.play();
    } catch (e) {
      _handlePlaybackError(item.messageId, e);
    }
  }

  Future<void> _loadSource(String audioUrl) async {
    if (audioUrl.startsWith('http://') || audioUrl.startsWith('https://')) {
      await _player.setUrl(audioUrl);
      return;
    }
    if (audioUrl.startsWith('assets/')) {
      await _player.setAsset(audioUrl);
      return;
    }
    final file = File(audioUrl);
    if (await file.exists()) {
      await _player.setFilePath(audioUrl);
      return;
    }
    throw StateError('Voice file not found: $audioUrl');
  }

  Future<void> pause() async {
    if (_activeId == null) return;
    _isPlaying = false;
    _emit();
    try {
      await _player.pause();
    } catch (_) {}
  }

  /// Pauses and forgets the active track. If [clearQueue] is true the queue is
  /// emptied, which is what leaving a conversation does.
  Future<void> stop({bool clearQueue = true}) async {
    if (_activeId != null) {
      _rememberedPositions[_activeId!] = _position;
    }
    _activeId = null;
    _loadedSourceId = null;
    _completedId = null;
    _completionHandled = false;
    _isPlaying = false;
    _isLoading = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _error = null;
    if (clearQueue) {
      _items.clear();
      _order.clear();
      _queueSignature = null;
      _rememberedPositions.clear();
    }
    _emit();
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// Moves the scrubber. If the note is not active the target is remembered and
  /// applied on the next explicit play (it still never starts playback).
  Future<void> seekToRatio(String messageId, double ratio) async {
    final item = _items[messageId];
    if (item == null) return;
    _completionEpoch++;
    final total = durationFor(messageId);
    final totalMs = total.inMilliseconds > 0
        ? total.inMilliseconds
        : item.durationSeconds * 1000;
    if (totalMs <= 0) return;

    final clamped = ratio.clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (clamped * totalMs).round().clamp(0, totalMs),
    );

    if (_activeId == messageId && _loadedSourceId == messageId) {
      await _player.seek(target);
      _position = target;
      _completedId = null;
      _completionHandled = false;
      _emit();
      return;
    }

    _rememberedPositions[messageId] = target;
    _emit();
  }

  Future<void> _ensureInitialized() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    if (!_loadedPlayedState) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _playedIds.addAll(prefs.getStringList(_playedStateKey) ?? const []);
      } catch (e) {
        debugPrint('[VoicePlayback] played-state load failed: $e');
      }
      _loadedPlayedState = true;
    }

    _playerStateSub ??= _player.playerStateStream.listen(_onPlayerState);
    _positionSub ??= _player.positionStream.listen(_onPosition);
    _durationSub ??= _player.durationStream.listen(_onDuration);
    _emit();
  }

  void _onPosition(Duration position) {
    if (_activeId == null) return;
    if (_player.processingState == ProcessingState.completed) return;
    _position = position;
    _emit();

    final total = _duration;
    if (total > Duration.zero &&
        position.inMilliseconds >= (total.inMilliseconds * 0.9).round()) {
      unawaited(_markPlayed(_activeId!));
    }
  }

  void _onDuration(Duration? duration) {
    if (_activeId == null || duration == null || duration <= Duration.zero) {
      return;
    }
    _duration = duration;
    _emit();
  }

  void _onPlayerState(PlayerState playerState) {
    if (_activeId == null) return;

    final completed = playerState.processingState == ProcessingState.completed;

    if (completed && !_completionHandled) {
      _completionHandled = true;
      _isPlaying = false;
      unawaited(_handleNaturalCompletion(_activeId!));
      return;
    }

    _isPlaying = playerState.playing && !completed;
    if (!completed) _completionHandled = false;
    _emit();
  }

  Future<void> _handleNaturalCompletion(String finishedId) async {
    if (_activeId != finishedId) return;
    final epoch = ++_completionEpoch;

    _rememberedPositions[finishedId] = Duration.zero;
    _position = Duration.zero;
    _completedId = finishedId;
    _isPlaying = false;
    _isLoading = false;
    await _markPlayed(finishedId);

    try {
      await _player.seek(Duration.zero);
    } catch (_) {}
    _emit();

    final next = _nextAutoPlayable(finishedId);
    if (next == null) return;

    // A tiny gap lets the completed bubble paint its final state before the
    // next note's loading state replaces it.
    await Future<void>.delayed(_autoAdvanceGap);
    if (epoch != _completionEpoch) return;
    if (_activeId != finishedId || !_items.containsKey(next.messageId)) return;
    await _switchTo(next);
  }

  VoiceQueueItem? _nextAutoPlayable(String finishedId) {
    final index = _order.indexOf(finishedId);
    if (index < 0 || index + 1 >= _order.length) return null;

    // Strictly adjacent: an outgoing note between two audio messages must stop
    // the chain instead of skipping ahead to a later incoming note.
    final next = _items[_order[index + 1]];
    if (next == null) return null;
    if (next.isMe) return null;
    if (isPlayed(next.messageId)) return null;
    return next;
  }

  Future<void> _markPlayed(String messageId) async {
    if (!_playedIds.add(messageId)) return;
    _emit();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_playedStateKey, _playedIds.toList());
    } catch (e) {
      debugPrint('[VoicePlayback] played-state save failed: $e');
    }
  }

  void _handlePlaybackError(String messageId, Object error) {
    if (_activeId != messageId) return;
    _isLoading = false;
    _isPlaying = false;
    _error = error;
    debugPrint('[VoicePlayback] playback failed for $messageId: $error');
    _emit();
  }

  void _emit() {
    state.value = VoicePlaybackSnapshot(
      activeId: _activeId,
      isPlaying: _isPlaying,
      isLoading: _isLoading,
      position: _position,
      duration: _duration,
      playedIds: Set<String>.unmodifiable(_playedIds),
      completedId: _completedId,
      error: _error,
    );
  }

  /// Called by the app lifecycle when returning to the foreground. Audio focus
  /// is owned by just_audio; we deliberately do NOT auto-resume, because a
  /// voice note must only ever start on an explicit user action.
  void onAppForegrounded() {
    if (kDebugMode) {
      debugPrint('[VoicePlayback] foregrounded; transport left untouched');
    }
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    await stop();
    _playedIds.clear();
    _loadedPlayedState = false;
    _queueSignature = null;
    await _playerStateSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    _playerStateSub = null;
    _positionSub = null;
    _durationSub = null;
    _initialization = null;
    _emit();
  }

  Future<void> dispose() async {
    await _playerStateSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _player.dispose();
    state.dispose();
  }
}
