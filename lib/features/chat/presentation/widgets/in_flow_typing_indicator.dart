import 'dart:async';

import 'package:flutter/material.dart';

/// Receiver-side typing indicator with a hard local expiry.
///
/// A `typing: true` document can become stale (app killed, network lost, a
/// missed `typing: false`). Relying only on the remote flag leaves the dots
/// pulsing forever. This widget owns a TTL timer: every new [signal] refresh
/// extends it, and when the timer fires the bubble removes itself even though
/// the last remote value is still `true`.
class RemoteTypingIndicator extends StatefulWidget {
  final bool active;

  /// Changes whenever a new typing heartbeat arrives (for example
  /// `lastTypingUpdate`). A changed value restarts the TTL.
  final Object? signal;

  /// How long the indicator may stay visible after the last heartbeat.
  final Duration ttl;

  /// Optional label, e.g. "Dr. Meera is typing".
  final String? label;

  const RemoteTypingIndicator({
    super.key,
    required this.active,
    this.signal,
    this.ttl = const Duration(seconds: 3),
    this.label,
  });

  @override
  State<RemoteTypingIndicator> createState() => _RemoteTypingIndicatorState();
}

class _RemoteTypingIndicatorState extends State<RemoteTypingIndicator> {
  Timer? _expiryTimer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _show();
  }

  @override
  void didUpdateWidget(RemoteTypingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _hide();
      return;
    }
    if (!oldWidget.active || oldWidget.signal != widget.signal) {
      _show();
    }
  }

  void _show() {
    _expiryTimer?.cancel();
    if (!_visible) {
      setState(() => _visible = true);
    }
    _expiryTimer = Timer(widget.ttl, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _hide() {
    _expiryTimer?.cancel();
    if (_visible) setState(() => _visible = false);
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: _visible
            ? Align(
                key: const ValueKey<String>('typing-visible'),
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(left: 16, bottom: 6, top: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0F233C).withValues(alpha: 0.06),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const RepaintBoundary(child: _BouncingTypingDots()),
                      if (widget.label != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.label!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink(key: ValueKey<String>('typing-hidden')),
      ),
    );
  }
}

class _BouncingTypingDots extends StatefulWidget {
  const _BouncingTypingDots();

  @override
  State<_BouncingTypingDots> createState() => _BouncingTypingDotsState();
}

class _BouncingTypingDotsState extends State<_BouncingTypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final delay = index * 0.2;
            final progress = (_controller.value - delay).clamp(0.0, 0.6);
            final offset = -3.0 * (progress / 0.6) * (1 - (progress / 0.6));
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Transform.translate(
                offset: Offset(0, offset),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF94A3B8),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
