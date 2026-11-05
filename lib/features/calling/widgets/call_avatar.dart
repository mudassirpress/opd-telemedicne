// lib/features/calling/widgets/call_avatar.dart

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class CallAvatar extends StatefulWidget {
  final String? imageUrl;
  final String name;
  final double radius;
  final bool isRinging;

  const CallAvatar({
    super.key,
    this.imageUrl,
    required this.name,
    this.radius = 64,
    this.isRinging = false,
  });

  @override
  State<CallAvatar> createState() => _CallAvatarState();
}

class _CallAvatarState extends State<CallAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isRinging) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(CallAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRinging && !oldWidget.isRinging) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isRinging && oldWidget.isRinging) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initials = widget.name.trim().isNotEmpty
        ? widget.name.trim()[0].toUpperCase()
        : '?';

    Widget avatar = CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF15386A),
      backgroundImage: (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
          ? CachedNetworkImageProvider(widget.imageUrl!)
          : null,
      child: (widget.imageUrl == null || widget.imageUrl!.isEmpty)
          ? Text(
              initials,
              style: TextStyle(
                fontSize: widget.radius * 0.7,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            )
          : null,
    );

    if (!widget.isRinging) return avatar;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: (widget.radius * 2 + 28) * _pulseAnimation.value,
              height: (widget.radius * 2 + 28) * _pulseAnimation.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF11B7A8).withValues(alpha: 0.18),
              ),
            ),
            Container(
              width: (widget.radius * 2 + 14) * _pulseAnimation.value,
              height: (widget.radius * 2 + 14) * _pulseAnimation.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF11B7A8).withValues(alpha: 0.28),
              ),
            ),
            avatar,
          ],
        );
      },
    );
  }
}

