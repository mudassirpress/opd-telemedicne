import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/home_widget/chat_call/chat/voice/voice_manager/voice_message_manager.dart';

/// Polished WhatsApp-style voice message player bubble supporting:
/// - Real-time waveform scrubbing
/// - Dynamic played/unplayed color distinctions
/// - Accurate duration & timestamp display
/// - WhatsApp-style microphone icon indicating receiver listen status (Grey -> Blue)
/// - WhatsApp-style outgoing message delivery receipts (Clock -> Single Grey -> Double Grey -> Double Blue)
/// - Full multi-player mutual exclusion & graceful error handling
class VoiceMessageBubble extends StatefulWidget {
  final String messageId;
  final String audioUrl;
  final int duration; // in seconds
  final bool isMe;
  final DateTime timestamp;
  final bool isRead;
  final bool isDelivered;
  final MessageDeliveryState deliveryStatus;
  final bool isListened;
  final String? senderAvatarUrl;
  final VoidCallback? onListened;

  const VoiceMessageBubble({
    super.key,
    required this.messageId,
    required this.audioUrl,
    required this.duration,
    required this.isMe,
    required this.timestamp,
    this.isRead = false,
    this.isDelivered = false,
    this.deliveryStatus = MessageDeliveryState.sent,
    this.isListened = false,
    this.senderAvatarUrl,
    this.onListened,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  AudioPlayer? _audioPlayer;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  late bool _isListened;
  late List<double> _waveformAmplitudes;

  // Actual playback tracking to ensure honest listening detection (preventing false positives from seeks)
  int _actualPlayedMs = 0;
  DateTime? _lastPlayStartTime;

  @override
  void initState() {
    super.initState();
    _isListened = widget.isListened;
    _waveformAmplitudes = _generateWaveform(widget.messageId, widget.audioUrl, 38);
    _initPlayer();
    _listenToGlobalState();
  }

  @override
  void didUpdateWidget(VoiceMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isListened && !_isListened) {
      setState(() {
        _isListened = true;
      });
    }
  }

  void _listenToGlobalState() {
    VoiceMessageManager.addPlayingStateListener(_onGlobalPlayingStateChanged);
  }

  void _onGlobalPlayingStateChanged(String? playingId) {
    if (mounted && playingId != widget.messageId && _isPlaying) {
      _pausePlayback();
    }
  }

  Future<void> _initPlayer() async {
    try {
      _audioPlayer = AudioPlayer();

      if (widget.audioUrl.startsWith('http://') ||
          widget.audioUrl.startsWith('https://')) {
        await _audioPlayer!.setUrl(widget.audioUrl);
      } else {
        final file = File(widget.audioUrl);
        if (await file.exists()) {
          await _audioPlayer!.setFilePath(widget.audioUrl);
        } else {
          throw Exception('Local voice file not found');
        }
      }

      _totalDuration = _audioPlayer!.duration ?? Duration(seconds: widget.duration);

      _positionSubscription = _audioPlayer!.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() {
          _currentPosition = pos;
        });

        // Track active listening
        _checkListeningProgress(pos);
      });

      _playerStateSubscription = _audioPlayer!.playerStateStream.listen((state) {
        if (!mounted) return;

        if (state.processingState == ProcessingState.completed) {
          // Playback completed naturally
          if (_isPlaying) {
            _accumulatePlayedTime();
          }
          setState(() {
            _isPlaying = false;
            _currentPosition = Duration.zero;
          });
          _audioPlayer?.seek(Duration.zero);
          VoiceMessageManager.unregisterPlayer(_audioPlayer);

          // Natural completion triggers listen status
          _triggerListened();
        }
      });

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[VoiceMessageBubble] Error initializing audio: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  void _accumulatePlayedTime() {
    if (_lastPlayStartTime != null) {
      _actualPlayedMs += DateTime.now().difference(_lastPlayStartTime!).inMilliseconds;
      _lastPlayStartTime = null;
    }
  }

  void _checkListeningProgress(Duration position) {
    if (widget.isMe || _isListened) return;

    final totalMs = _totalDuration.inMilliseconds > 0
        ? _totalDuration.inMilliseconds
        : widget.duration * 1000;

    if (totalMs <= 0) return;

    int currentSessionMs = 0;
    if (_lastPlayStartTime != null) {
      currentSessionMs = DateTime.now().difference(_lastPlayStartTime!).inMilliseconds;
    }
    final totalPlayedMs = _actualPlayedMs + currentSessionMs;
    final progress = position.inMilliseconds / totalMs;

    // Requirement:
    // Mark as listened when playback reaches at least 90% of audio duration while playing,
    // or when playback reaches completion naturally.
    // Seeking alone without playing does not trigger it.
    final hasMeaningfulPlayback = totalPlayedMs >= (totalMs * 0.40).clamp(500, 10000);
    if (_isPlaying && (progress >= 0.90 || position.inMilliseconds >= totalMs - 250) && hasMeaningfulPlayback) {
      _triggerListened();
    }
  }

  void _triggerListened() {
    if (widget.isMe || _isListened) return;
    setState(() {
      _isListened = true;
    });
    widget.onListened?.call();
  }

  Future<void> _togglePlayPause() async {
    if (_audioPlayer == null || _hasError) return;

    try {
      if (_isPlaying) {
        await _pausePlayback();
      } else {
        await _startPlayback();
      }
    } catch (e) {
      debugPrint('[VoiceMessageBubble] Error toggling playback: $e');
    }
  }

  Future<void> _startPlayback() async {
    if (_audioPlayer == null) return;

    // Stop any currently playing audio in the app
    await VoiceMessageManager.stopAllAudio();

    VoiceMessageManager.registerPlayer(_audioPlayer!, widget.messageId);

    _lastPlayStartTime = DateTime.now();
    await _audioPlayer!.play();

    if (mounted) {
      setState(() {
        _isPlaying = true;
      });
    }
  }

  Future<void> _pausePlayback() async {
    _accumulatePlayedTime();
    await _audioPlayer?.pause();

    if (mounted) {
      setState(() {
        _isPlaying = false;
      });
    }
  }

  void _seekToProgress(double progressRatio) {
    if (_audioPlayer == null || _hasError) return;

    final totalMs = _totalDuration.inMilliseconds > 0
        ? _totalDuration.inMilliseconds
        : widget.duration * 1000;

    if (totalMs <= 0) return;

    final targetMs = (progressRatio * totalMs).round().clamp(0, totalMs);
    final targetDuration = Duration(milliseconds: targetMs);

    _audioPlayer?.seek(targetDuration);
    setState(() {
      _currentPosition = targetDuration;
    });
  }

  String _formatDuration(Duration duration) {
    int totalSeconds = duration.inSeconds;
    int minutes = totalSeconds ~/ 60;
    int seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTimestamp(DateTime time) {
    final hour = time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    final amPm = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $amPm';
  }

  /// Generates a realistic voice message waveform amplitude pattern
  static List<double> _generateWaveform(String id, String url, int count) {
    final seed = (id.isNotEmpty ? id : url).hashCode;
    final rand = math.Random(seed.abs());
    final result = <double>[];

    double current = 0.35;
    for (int i = 0; i < count; i++) {
      // Create speech-like peaks and troughs
      final rawTarget = 0.20 + rand.nextDouble() * 0.75;
      current = current * 0.4 + rawTarget * 0.6;
      result.add(current.clamp(0.18, 1.0));
    }
    return result;
  }

  @override
  void dispose() {
    VoiceMessageManager.removePlayingStateListener(_onGlobalPlayingStateChanged);
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();

    if (VoiceMessageManager.getCurrentPlayingId() == widget.messageId) {
      VoiceMessageManager.unregisterPlayer(_audioPlayer);
    }
    _audioPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxBubbleWidth = math.min(290.0, context.sw - 50);

    // WhatsApp authentic theme styling
    // Outgoing: soft light green (#E7FFDB / #D9FDD3)
    // Incoming: pure white (#FFFFFF)
    final bubbleColor = widget.isMe ? const Color(0xFFE7FFDB) : Colors.white;
    final borderColor = widget.isMe ? const Color(0xFFC7EBB8) : const Color(0xFFE2E8F0);

    return Container(
      constraints: BoxConstraints(
        maxWidth: maxBubbleWidth,
        minWidth: math.min(230.0, maxBubbleWidth),
      ),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(widget.isMe ? 16 : 4),
          bottomRight: Radius.circular(widget.isMe ? 4 : 16),
        ),
        border: Border.all(color: borderColor, width: 0.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: widget.isMe ? _buildOutgoingContent() : _buildIncomingContent(),
    );
  }

  /// Outgoing voice message (Current user sent):
  /// - Sender profile picture on the LEFT with microphone status icon
  /// - Play/pause button
  /// - Waveform with played progress
  /// - Duration below waveform on left
  /// - Timestamp and WhatsApp delivery ticks on right
  Widget _buildOutgoingContent() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. Sender profile picture with microphone status badge
        _buildAvatarWithMic(isLeft: true),
        const SizedBox(width: 8),

        // 2. Play / Pause Button
        _buildPlayPauseButton(),
        const SizedBox(width: 8),

        // 3. Waveform + Duration & Delivery Ticks
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildWaveformInteractive(),
              const SizedBox(height: 4),
              _buildMetaRow(isOutgoing: true),
            ],
          ),
        ),
      ],
    );
  }

  /// Incoming voice message (Received from doctor or patient):
  /// - Play button on the LEFT
  /// - Waveform in center
  /// - Duration below waveform
  /// - Sender profile image on the RIGHT with microphone status icon
  Widget _buildIncomingContent() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. Play / Pause Button on the left
        _buildPlayPauseButton(),
        const SizedBox(width: 8),

        // 2. Waveform + Duration & Timestamp in center
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildWaveformInteractive(),
              const SizedBox(height: 4),
              _buildMetaRow(isOutgoing: false),
            ],
          ),
        ),
        const SizedBox(width: 8),

        // 3. Sender profile image with microphone status badge on the right
        _buildAvatarWithMic(isLeft: false),
      ],
    );
  }

  /// Circular play/pause button matching WhatsApp's iconic voice note style
  Widget _buildPlayPauseButton() {
    if (_isLoading) {
      return Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF54656F),
        ),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      );
    }

    if (_hasError) {
      return GestureDetector(
        onTap: () {
          setState(() {
            _isLoading = true;
            _hasError = false;
          });
          _initPlayer();
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.shade100,
          ),
          child: const Icon(Icons.refresh_rounded, color: Colors.red, size: 20),
        ),
      );
    }

    return GestureDetector(
      onTap: _togglePlayPause,
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF54656F),
        ),
        child: Icon(
          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }

  /// Avatar with the circular microphone status badge:
  /// - GREY: Voice message has NOT been listened to by the receiver
  /// - BLUE: Voice message HAS been listened to (threshold reached)
  Widget _buildAvatarWithMic({required bool isLeft}) {
    // WhatsApp Listen Status:
    // Grey when unlistened, Blue when listened.
    final Color micColor = _isListened ? const Color(0xFF34B7F1) : const Color(0xFF94A3B8);

    final avatarImage = widget.senderAvatarUrl;
    final hasImage = avatarImage != null && avatarImage.isNotEmpty;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Profile picture
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFCBD5E1),
            border: Border.all(
              color: widget.isMe ? const Color(0xFFC7EBB8) : const Color(0xFFE2E8F0),
              width: 1.0,
            ),
          ),
          child: ClipOval(
            child: hasImage
                ? CachedNetworkImage(
                    imageUrl: avatarImage,
                    fit: BoxFit.cover,
                    width: 42,
                    height: 42,
                    placeholder: (context, url) => const Icon(
                      Icons.person,
                      size: 24,
                      color: Color(0xFF64748B),
                    ),
                    errorWidget: (context, url, error) => const Icon(
                      Icons.person,
                      size: 24,
                      color: Color(0xFF64748B),
                    ),
                  )
                : const Icon(
                    Icons.person,
                    size: 24,
                    color: Color(0xFF64748B),
                  ),
          ),
        ),

        // Small microphone icon badge
        Positioned(
          bottom: -2,
          left: isLeft ? null : -3,
          right: isLeft ? -3 : null,
          child: Container(
            width: 17,
            height: 17,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: micColor,
              border: Border.all(
                color: widget.isMe ? const Color(0xFFE7FFDB) : Colors.white,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: const Icon(
              Icons.mic,
              size: 10,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  /// Interactive waveform scrubber with played/unplayed distinguishing and drag support
  Widget _buildWaveformInteractive() {
    double progress = 0.0;
    if (_totalDuration.inMilliseconds > 0) {
      progress = (_currentPosition.inMilliseconds / _totalDuration.inMilliseconds).clamp(0.0, 1.0);
    }

    // Colors:
    // Played portion: Blue (#34B7F1)
    // Unplayed portion: Grey (#B0BEC5)
    const playedColor = Color(0xFF34B7F1);
    const unplayedColor = Color(0xFFB0BEC5);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        // 2.5px bar + 1.5px space = 4.0px per bar
        final barCount = (totalWidth / 4.0).floor().clamp(20, 48);

        // Subsample or interpolate waveform
        final bars = _waveformAmplitudes.length == barCount
            ? _waveformAmplitudes
            : _resampleBars(_waveformAmplitudes, barCount);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final ratio = (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
            _seekToProgress(ratio);
          },
          onHorizontalDragUpdate: (details) {
            final ratio = (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
            _seekToProgress(ratio);
          },
          child: SizedBox(
            height: 28,
            width: totalWidth,
            child: CustomPaint(
              size: Size(totalWidth, 28),
              painter: _WhatsAppWaveformPainter(
                amplitudes: bars,
                progress: progress,
                playedColor: playedColor,
                unplayedColor: unplayedColor,
                thumbColor: playedColor,
              ),
            ),
          ),
        );
      },
    );
  }

  List<double> _resampleBars(List<double> source, int targetCount) {
    if (source.isEmpty) return List.filled(targetCount, 0.4);
    final res = <double>[];
    for (int i = 0; i < targetCount; i++) {
      final index = ((i / targetCount) * source.length).floor().clamp(0, source.length - 1);
      res.add(source[index]);
    }
    return res;
  }

  /// Duration and Status row below the waveform
  Widget _buildMetaRow({required bool isOutgoing}) {
    final displayDuration = (_isPlaying || _currentPosition.inSeconds > 0)
        ? _formatDuration(_currentPosition)
        : _formatDuration(
            _totalDuration.inSeconds > 0
                ? _totalDuration
                : Duration(seconds: widget.duration),
          );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Voice message duration
        Text(
          displayDuration,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Color(0xFF667781),
            letterSpacing: -0.2,
          ),
        ),

        // Message timestamp & Outgoing Delivery Ticks
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatTimestamp(widget.timestamp),
              style: const TextStyle(
                fontSize: 10.5,
                color: Color(0xFF667781),
                letterSpacing: -0.2,
              ),
            ),
            if (isOutgoing) ...[
              const SizedBox(width: 3),
              _buildDeliveryStatusTick(),
            ],
          ],
        ),
      ],
    );
  }

  /// WhatsApp-style outgoing ticks:
  /// - Pending: Clock icon
  /// - Sent: Single grey tick
  /// - Delivered: Double grey tick
  /// - Listened to: Double blue tick
  Widget _buildDeliveryStatusTick() {
    if (widget.deliveryStatus == MessageDeliveryState.pending) {
      return const Icon(
        Icons.access_time_rounded,
        size: 11,
        color: Color(0xFF667781),
      );
    }

    if (_isListened) {
      // Listened: double blue ticks
      return const Icon(
        Icons.done_all_rounded,
        size: 15,
        color: Color(0xFF34B7F1),
      );
    }

    if (widget.isDelivered ||
        widget.deliveryStatus == MessageDeliveryState.delivered ||
        widget.isRead) {
      // Delivered: double grey ticks
      return const Icon(
        Icons.done_all_rounded,
        size: 15,
        color: Color(0xFF667781),
      );
    }

    // Sent: single grey tick
    return const Icon(
      Icons.done_rounded,
      size: 14,
      color: Color(0xFF667781),
    );
  }
}

/// Custom painter for WhatsApp voice message waveform bars with smooth progress playhead
class _WhatsAppWaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;
  final Color thumbColor;

  _WhatsAppWaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
    required this.thumbColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;

    final playedPaint = Paint()
      ..color = playedColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4;

    final unplayedPaint = Paint()
      ..color = unplayedColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4;

    final totalBars = amplitudes.length;
    final spacing = size.width / totalBars;
    final centerY = size.height / 2;
    final maxHalfHeight = size.height * 0.44;

    final playedWidth = size.width * progress;

    for (int i = 0; i < totalBars; i++) {
      final x = (i * spacing) + (spacing / 2);
      final heightFactor = amplitudes[i];
      final halfHeight = (maxHalfHeight * heightFactor).clamp(2.5, maxHalfHeight);

      final isBarPlayed = x <= playedWidth;
      final paint = isBarPlayed ? playedPaint : unplayedPaint;

      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        paint,
      );
    }

    // Draw the scrubber playhead thumb circle at progress position
    final thumbX = playedWidth.clamp(0.0, size.width);
    final thumbPaint = Paint()..color = thumbColor;
    final thumbBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Small white border ring with solid thumb
    canvas.drawCircle(Offset(thumbX, centerY), 4.5, thumbBorderPaint);
    canvas.drawCircle(Offset(thumbX, centerY), 3.5, thumbPaint);
  }

  @override
  bool shouldRepaint(covariant _WhatsAppWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor ||
        oldDelegate.amplitudes != amplitudes;
  }
}
