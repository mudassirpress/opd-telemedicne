import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// WhatsApp-style swipe-to-reply gesture wrapper.
///
/// A horizontal drag of at least [threshold] pixels (in either direction)
/// fires [onReply] on release and animates the bubble back. Below the
/// threshold the bubble springs back silently, and a drag that never starts
/// leaves the child's own tap / long-press recognisers to handle the gesture.
///
/// The reply affordance fades in on the side the bubble is being pulled away
/// from: dragging right shows it on the left, dragging left on the right.
class SwipeToReplyWrapper extends StatefulWidget {
  const SwipeToReplyWrapper({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
    this.maxShift = 88,
    this.threshold = 56,
  });

  final Widget child;
  final VoidCallback onReply;

  /// When false the wrapper becomes a pass-through (used while the message
  /// list is in multi-select mode, where a horizontal drag must not steal the
  /// tap that toggles a selection).
  final bool enabled;

  /// How far the bubble can travel at all.
  final double maxShift;

  /// How far it must travel for the reply to fire.
  final double threshold;

  @override
  State<SwipeToReplyWrapper> createState() => _SwipeToReplyWrapperState();
}

class _SwipeToReplyWrapperState extends State<SwipeToReplyWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // AnimationController parks at lowerBound when no value is given, which
      // would render every bubble maxShift pixels to the left until the first
      // drag. Always rest at 0 (centred).
      value: 0,
      lowerBound: -widget.maxShift,
      upperBound: widget.maxShift,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    if (!_dragging) _dragging = true;
    _controller.value = _controller.value + details.delta.dx;
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    final offset = _controller.value;
    _dragging = false;
    if (offset.abs() >= widget.threshold) {
      widget.onReply();
    }
    _controller.animateTo(
      0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final replyColor = Theme.of(context).colorScheme.secondary;

    return GestureDetector(
      // Opaque, not deferToChild: the wrapper must own the horizontal drag
      // even when the bubble itself does not absorb pointer hits (an icon-only
      // or padded bubble), otherwise the swipe never reaches the recogniser.
      behavior: HitTestBehavior.opaque,
      // Measure the travel from pointer-down: the threshold is about how far
      // the finger actually moved, not about how far it moved after the arena
      // accepted the drag (which would swallow the first ~18px of every swipe).
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () {
        _dragging = false;
        _controller.animateTo(0, curve: Curves.easeOutCubic);
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final dx = _controller.value;
          final progress = (dx.abs() / widget.threshold).clamp(0.0, 1.0);
          // The icon only shows while it is meaningful: a real drag, never a
          // resting bubble that happens to sit at offset 0.
          final showIcon = _dragging && progress > 0.01;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Transform.translate(offset: Offset(dx, 0), child: child),
              if (showIcon)
                Positioned(
                  left: dx >= 0 ? 4 : null,
                  right: dx >= 0 ? null : 4,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Opacity(
                      opacity: progress,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: replyColor.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.reply_rounded,
                          size: 20,
                          color: replyColor,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}
