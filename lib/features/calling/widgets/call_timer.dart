// lib/features/calling/widgets/call_timer.dart

import 'package:flutter/material.dart';

class CallTimerWidget extends StatelessWidget {
  final int durationSeconds;
  final TextStyle? style;

  const CallTimerWidget({
    super.key,
    required this.durationSeconds,
    this.style,
  });

  static String formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    final m = minutes.toString().padLeft(2, '0');
    final s = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      final h = hours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      formatDuration(durationSeconds),
      style: style ??
          const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: Color(0xFFE8F1FC),
          ),
    );
  }
}

