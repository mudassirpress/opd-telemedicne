import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/features/chat/presentation/chat_status/message_status_indicator.dart';
import 'package:telemedicine/features/chat/presentation/voice/voice_manager/voice_playback_controller.dart';

/// WhatsApp-grade voice note bubble.
///
/// Playback is delegated to the app-wide [VoicePlaybackController]. This widget
/// owns no [AudioPlayer], which is what guarantees single-active concurrency and
/// prevents the historical "every rebuilt bubble starts itself" bug.
///
/// Rebuild scope:
///  * the play button listens to the shared snapshot independently;
///  * the waveform + timer listen independently;
///  * the avatar, reply header and bubble chrome never rebuild on progress.
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

  /// Quoted reply preview, anchored above the player controls, inside the same
  /// bubble. Used when a voice note replies to text/media/audio.
  final Widget? replyHeader;

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
    this.replyHeader,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  final VoicePlaybackController _playback = VoicePlaybackController.instance;

  late bool _isListened;
  late List<double> _waveformAmplitudes;
  double? _dragProgress;

  @override
  void initState() {
    super.initState();
    _isListened = widget.isListened || _playback.isPlayed(widget.messageId);
    _waveformAmplitudes = _generateWaveform(
      widget.messageId,
      widget.audioUrl,
      38,
    );
    _playback.state.addListener(_onPlaybackStateChanged);
  }

  @override
  void didUpdateWidget(VoiceMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isListened && !_isListened) {
      setState(() => _isListened = true);
    }
  }

  void _onPlaybackStateChanged() {
    if (!mounted) return;
    final snapshot = _playback.state.value;
    final justPlayed = snapshot.playedIds.contains(widget.messageId);
    if (justPlayed && !_isListened && !widget.isMe) {
      setState(() => _isListened = true);
      widget.onListened?.call();
    }
  }

  @override
  void dispose() {
    _playback.state.removeListener(_onPlaybackStateChanged);
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTimestamp(DateTime time) {
    final hour = time.hour > 12
        ? time.hour - 12
        : (time.hour == 0 ? 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    final amPm = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $amPm';
  }

  static List<double> _generateWaveform(String id, String url, int count) {
    final seed = (id.isNotEmpty ? id : url).hashCode;
    final rand = math.Random(seed.abs());
    final result = <double>[];
    double current = 0.35;
    for (var i = 0; i < count; i++) {
      final rawTarget = 0.20 + rand.nextDouble() * 0.75;
      current = current * 0.4 + rawTarget * 0.6;
      result.add(current.clamp(0.18, 1.0));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final maxBubbleWidth = math.min(290.0, context.sw - 50);
    final bubbleColor = widget.isMe ? const Color(0xFFE7FFDB) : Colors.white;
    final borderColor = widget.isMe
        ? const Color(0xFFC7EBB8)
        : const Color(0xFFE2E8F0);

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.replyHeader != null) ...[
            widget.replyHeader!,
            const SizedBox(height: 6),
          ],
          if (widget.isMe) _buildOutgoingContent() else _buildIncomingContent(),
        ],
      ),
    );
  }

  Widget _buildOutgoingContent() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildAvatarWithMic(isLeft: true),
        const SizedBox(width: 8),
        _buildPlayPauseButton(),
        const SizedBox(width: 8),
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

  Widget _buildIncomingContent() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildPlayPauseButton(),
        const SizedBox(width: 8),
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
        _buildAvatarWithMic(isLeft: false),
      ],
    );
  }

  Widget _buildPlayPauseButton() {
    return ValueListenableBuilder<VoicePlaybackSnapshot>(
      valueListenable: _playback.state,
      builder: (context, snapshot, _) {
        final isLoading = snapshot.isLoadingId(widget.messageId);
        final hasError =
            snapshot.activeId == widget.messageId && snapshot.error != null;
        final isPlaying = snapshot.isPlayingId(widget.messageId);

        if (isLoading) {
          return _circleButton(
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

        if (hasError) {
          return GestureDetector(
            onTap: () => _playback.play(widget.messageId),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red.shade100,
              ),
              child: const Icon(
                Icons.refresh_rounded,
                color: Colors.red,
                size: 20,
              ),
            ),
          );
        }

        return GestureDetector(
          onTap: () => _playback.toggle(widget.messageId),
          child: _circleButton(
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        );
      },
    );
  }

  Widget _circleButton({required Widget child}) {
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF54656F),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _buildAvatarWithMic({required bool isLeft}) {
    final micColor = _isListened
        ? const Color(0xFF34B7F1)
        : const Color(0xFF94A3B8);
    final avatarImage = widget.senderAvatarUrl;
    final hasImage = avatarImage != null && avatarImage.isNotEmpty;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFCBD5E1),
            border: Border.all(
              color: widget.isMe
                  ? const Color(0xFFC7EBB8)
                  : const Color(0xFFE2E8F0),
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
                : const Icon(Icons.person, size: 24, color: Color(0xFF64748B)),
          ),
        ),
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
            child: const Icon(Icons.mic, size: 10, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildWaveformInteractive() {
    return ValueListenableBuilder<VoicePlaybackSnapshot>(
      valueListenable: _playback.state,
      builder: (context, snapshot, _) {
        final isActive = snapshot.isActive(widget.messageId);
        final total = _totalDuration(snapshot);
        final position = isActive
            ? snapshot.position
            : _playback.positionFor(widget.messageId);
        var progress = 0.0;
        if (total.inMilliseconds > 0) {
          progress = (position.inMilliseconds / total.inMilliseconds).clamp(
            0.0,
            1.0,
          );
        }
        if (_dragProgress != null) progress = _dragProgress!;

        const playedColor = Color(0xFF34B7F1);
        const unplayedColor = Color(0xFFB0BEC5);

        return LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            final barCount = (totalWidth / 4.0).floor().clamp(20, 48);
            final bars = _waveformAmplitudes.length == barCount
                ? _waveformAmplitudes
                : _resampleBars(_waveformAmplitudes, barCount);

            void updateDrag(Offset localPosition) {
              final ratio = (localPosition.dx / totalWidth).clamp(0.0, 1.0);
              setState(() => _dragProgress = ratio);
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                final ratio = (details.localPosition.dx / totalWidth).clamp(
                  0.0,
                  1.0,
                );
                _playback.seekToRatio(widget.messageId, ratio);
              },
              onHorizontalDragStart: (details) {
                updateDrag(details.localPosition);
              },
              onHorizontalDragUpdate: (details) {
                updateDrag(details.localPosition);
              },
              onHorizontalDragEnd: (_) {
                final ratio = _dragProgress;
                setState(() => _dragProgress = null);
                if (ratio != null) {
                  _playback.seekToRatio(widget.messageId, ratio);
                }
              },
              onHorizontalDragCancel: () {
                setState(() => _dragProgress = null);
              },
              child: SizedBox(
                height: 28,
                width: totalWidth,
                child: RepaintBoundary(
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
              ),
            );
          },
        );
      },
    );
  }

  List<double> _resampleBars(List<double> source, int targetCount) {
    if (source.isEmpty) return List.filled(targetCount, 0.4);
    final res = <double>[];
    for (var i = 0; i < targetCount; i++) {
      final index = ((i / targetCount) * source.length).floor().clamp(
        0,
        source.length - 1,
      );
      res.add(source[index]);
    }
    return res;
  }

  Duration _totalDuration(VoicePlaybackSnapshot snapshot) {
    if (snapshot.activeId == widget.messageId &&
        snapshot.duration > Duration.zero) {
      return snapshot.duration;
    }
    if (widget.duration > 0) return Duration(seconds: widget.duration);
    return _playback.durationFor(widget.messageId);
  }

  Widget _buildMetaRow({required bool isOutgoing}) {
    return ValueListenableBuilder<VoicePlaybackSnapshot>(
      valueListenable: _playback.state,
      builder: (context, snapshot, _) {
        final isActive = snapshot.isActive(widget.messageId);
        final total = _totalDuration(snapshot);
        final completed = snapshot.completedId == widget.messageId;
        final showPosition =
            isActive &&
            !completed &&
            (snapshot.isPlaying || snapshot.position > Duration.zero);
        final displayDuration = showPosition ? snapshot.position : total;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatDuration(displayDuration),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Color(0xFF667781),
                letterSpacing: -0.2,
              ),
            ),
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
                  MessageStatusIndicator(
                    state: widget.deliveryStatus,
                    color: const Color(0xFF667781),
                    size: 14,
                    readColor: const Color(0xFF34B7F1),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Custom painter for WhatsApp voice message waveform bars with smooth progress
/// playhead. Repaints are clipped to the waveform's own RepaintBoundary.
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

    for (var i = 0; i < totalBars; i++) {
      final x = (i * spacing) + (spacing / 2);
      final halfHeight = (maxHalfHeight * amplitudes[i]).clamp(
        2.5,
        maxHalfHeight,
      );
      final paint = x <= playedWidth ? playedPaint : unplayedPaint;
      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        paint,
      );
    }

    final thumbX = playedWidth.clamp(0.0, size.width);
    final thumbPaint = Paint()..color = thumbColor;
    final thumbBorderPaint = Paint()..color = Colors.white;

    canvas.drawCircle(Offset(thumbX, centerY), 4.5, thumbBorderPaint);
    canvas.drawCircle(Offset(thumbX, centerY), 3.5, thumbPaint);
  }

  @override
  bool shouldRepaint(covariant _WhatsAppWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor ||
        !listEquals(oldDelegate.amplitudes, amplitudes);
  }
}
