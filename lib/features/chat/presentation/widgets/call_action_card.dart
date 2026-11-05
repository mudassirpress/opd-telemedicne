import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:telemedicine/data/models/chat_call_event.dart';

/// WhatsApp-grade call timeline card.
///
/// The card is driven by a normalized [ChatCallEvent] plus the *live* call
/// state supplied by the caller. That is the transformation guarantee: a chat
/// message whose legacy body still says "in progress" renders as an ended card
/// as soon as no live call exists, and flips to "In progress" with a running
/// timer when the call is actually live.
class ChatCallActionCard extends StatelessWidget {
  final ChatCallEvent event;
  final bool isMe;
  final bool isLiveCall;
  final int? liveDurationSeconds;
  final DateTime timestamp;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Optional trailing receipt widget (outgoing calls only).
  final Widget? trailing;

  const ChatCallActionCard({
    super.key,
    required this.event,
    required this.isMe,
    required this.timestamp,
    this.isLiveCall = false,
    this.liveDurationSeconds,
    this.onTap,
    this.onLongPress,
    this.trailing,
  });

  ChatCallStatus get _effectiveStatus {
    if (event.isRecording) return ChatCallStatus.recorded;
    if (event.status.isLive && !isLiveCall) return ChatCallStatus.completed;
    return event.status;
  }

  bool get _isLive => isLiveCall && event.status.isLive;

  @override
  Widget build(BuildContext context) {
    final status = _effectiveStatus;
    final palette = _paletteFor(status);
    final width = math.min(MediaQuery.sizeOf(context).width * 0.72, 270.0);

    return GestureDetector(
      onLongPress: onLongPress,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: width,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0), width: 0.7),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F233C).withValues(alpha: 0.06),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: palette.background,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.iconBackground,
                    ),
                    child: Icon(
                      _iconFor(status),
                      size: 21,
                      color: palette.foreground,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      ),
                      child: Column(
                        key: ValueKey<String>(
                          'call-${status.name}-${_isLive ? 'live' : 'idle'}',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              if (_isLive) ...[
                                const _LiveDot(),
                                const SizedBox(width: 5),
                              ],
                              Expanded(
                                child: Text(
                                  _titleFor(status),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1F2F44),
                                    height: 1.2,
                                  ),
                                ),
                              ),
                              if (_durationLabel != null) ...[
                                const SizedBox(width: 6),
                                _DurationChip(label: _durationLabel!),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _subtitleFor(status),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: _isLive
                                  ? const Color(0xFF0E7C86)
                                  : const Color(0xFF6B7C90),
                              fontWeight: _isLive
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Text(
                                _formatTime(timestamp),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF8A9AAF),
                                ),
                              ),
                              if (isMe && trailing != null) ...[
                                const SizedBox(width: 4),
                                trailing!,
                              ],
                              const Spacer(),
                              if (_isLive)
                                Text(
                                  'Tap to rejoin',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: palette.foreground,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              else if (event.isRecording)
                                Text(
                                  'Tap to play',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: palette.foreground,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              else if (status == ChatCallStatus.missed ||
                                  status == ChatCallStatus.rejected ||
                                  status == ChatCallStatus.cancelled)
                                Text(
                                  'Tap to call back',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: palette.foreground,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? get _durationLabel {
    if (event.isRecording) {
      final seconds = event.durationSeconds ?? 0;
      return seconds > 0 ? _formatDuration(seconds) : null;
    }
    if (_isLive) {
      final seconds = liveDurationSeconds ?? event.durationSeconds ?? 0;
      return _formatDuration(seconds);
    }
    if (event.hasDuration) return _formatDuration(event.durationSeconds!);
    return null;
  }

  String _titleFor(ChatCallStatus status) {
    final kind = event.callType.toLowerCase() == 'video' ? 'Video' : 'Audio';
    switch (status) {
      case ChatCallStatus.missed:
        return 'Missed $kind call';
      case ChatCallStatus.rejected:
        return 'Declined $kind call';
      case ChatCallStatus.cancelled:
        return 'Cancelled $kind call';
      case ChatCallStatus.busy:
        return 'Call declined - line busy';
      case ChatCallStatus.failed:
        return 'Call failed';
      case ChatCallStatus.recorded:
        return 'Call recording';
      case ChatCallStatus.calling:
      case ChatCallStatus.ringing:
      case ChatCallStatus.incoming:
      case ChatCallStatus.connecting:
      case ChatCallStatus.accepted:
      case ChatCallStatus.connected:
      case ChatCallStatus.ongoing:
        return '$kind call in progress';
      case ChatCallStatus.completed:
        return '$kind call ended';
    }
  }

  String _subtitleFor(ChatCallStatus status) {
    if (_isLive) return 'Tap to return to the call';
    switch (status) {
      case ChatCallStatus.missed:
        return 'No answer';
      case ChatCallStatus.rejected:
        return 'Declined by receiver';
      case ChatCallStatus.cancelled:
        return 'Cancelled before answer';
      case ChatCallStatus.busy:
        return 'The other person was on another call';
      case ChatCallStatus.failed:
        return 'Connection could not be established';
      case ChatCallStatus.recorded:
        return 'Call recording available';
      case ChatCallStatus.completed:
        return event.hasDuration ? 'Connected call' : 'Call ended';
      case ChatCallStatus.calling:
      case ChatCallStatus.ringing:
      case ChatCallStatus.incoming:
      case ChatCallStatus.connecting:
      case ChatCallStatus.accepted:
      case ChatCallStatus.connected:
      case ChatCallStatus.ongoing:
        return 'Connecting...';
    }
  }

  IconData _iconFor(ChatCallStatus status) {
    if (event.isRecording) return Icons.graphic_eq_rounded;
    switch (status) {
      case ChatCallStatus.missed:
        return Icons.call_missed_rounded;
      case ChatCallStatus.rejected:
      case ChatCallStatus.cancelled:
        return Icons.call_end_rounded;
      case ChatCallStatus.busy:
        return Icons.phone_disabled_rounded;
      case ChatCallStatus.failed:
        return Icons.error_outline_rounded;
      case ChatCallStatus.recorded:
        return Icons.play_circle_outline_rounded;
      case ChatCallStatus.calling:
      case ChatCallStatus.ringing:
      case ChatCallStatus.incoming:
      case ChatCallStatus.connecting:
      case ChatCallStatus.accepted:
      case ChatCallStatus.connected:
      case ChatCallStatus.ongoing:
        return event.callType.toLowerCase() == 'video'
            ? Icons.videocam_rounded
            : Icons.call_rounded;
      case ChatCallStatus.completed:
        return event.callType.toLowerCase() == 'video'
            ? Icons.videocam_outlined
            : Icons.call_outlined;
    }
  }

  _CallPalette _paletteFor(ChatCallStatus status) {
    switch (status) {
      case ChatCallStatus.missed:
      case ChatCallStatus.rejected:
      case ChatCallStatus.cancelled:
      case ChatCallStatus.failed:
        return const _CallPalette(
          background: Color(0xFFFDECEC),
          iconBackground: Color(0xFFFBD5D5),
          foreground: Color(0xFFB42318),
        );
      case ChatCallStatus.busy:
        return const _CallPalette(
          background: Color(0xFFFFF4E5),
          iconBackground: Color(0xFFFDE7C3),
          foreground: Color(0xFFB54708),
        );
      case ChatCallStatus.recorded:
        return const _CallPalette(
          background: Color(0xFFEAF2FF),
          iconBackground: Color(0xFFD6E4FF),
          foreground: Color(0xFF062B72),
        );
      case ChatCallStatus.calling:
      case ChatCallStatus.ringing:
      case ChatCallStatus.incoming:
      case ChatCallStatus.connecting:
      case ChatCallStatus.accepted:
      case ChatCallStatus.connected:
      case ChatCallStatus.ongoing:
        return const _CallPalette(
          background: Color(0xFFE6F8F5),
          iconBackground: Color(0xFFC9F0E9),
          foreground: Color(0xFF0E7C86),
        );
      case ChatCallStatus.completed:
        return const _CallPalette(
          background: Color(0xFFF1F5F9),
          iconBackground: Color(0xFFE2E8F0),
          foreground: Color(0xFF334155),
        );
    }
  }

  static String _formatDuration(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final minutes = safe ~/ 60;
    final remaining = safe % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final mins = minutes % 60;
      return '$hours:${mins.toString().padLeft(2, '0')}:'
          '${remaining.toString().padLeft(2, '0')}';
    }
    return '$minutes:${remaining.toString().padLeft(2, '0')}';
  }

  static String _formatTime(DateTime time) {
    final hour = time.hour > 12
        ? time.hour - 12
        : (time.hour == 0 ? 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }
}

class _CallPalette {
  final Color background;
  final Color iconBackground;
  final Color foreground;

  const _CallPalette({
    required this.background,
    required this.iconBackground,
    required this.foreground,
  });
}

class _DurationChip extends StatelessWidget {
  final String label;

  const _DurationChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Color(0xFF475569),
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.35, end: 1.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
        ),
        child: Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: Color(0xFF0E7C86),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
