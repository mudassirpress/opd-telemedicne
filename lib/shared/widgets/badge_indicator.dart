import 'package:flutter/material.dart';

/// Reusable badge indicator component displaying numerical counts (e.g. 1, 5, 99+).
/// Automatically hides when `count <= 0`.
///
/// Can be used standalone (e.g. inside a row or card) or as an overlay wrapping
/// a `child` widget (such as an icon in a navigation bar or header).
class BadgeIndicator extends StatelessWidget {
  final int count;
  final int maxCount;
  final Widget? child;
  final Color? badgeColor;
  final Color? textColor;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final Offset offset;
  final bool showZero;

  const BadgeIndicator({
    super.key,
    required this.count,
    this.maxCount = 99,
    this.child,
    this.badgeColor,
    this.textColor,
    this.fontSize = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    this.offset = const Offset(-6, -4),
    this.showZero = false,
  });

  String get _formattedCount {
    if (count > maxCount) return '$maxCount+';
    return count.toString();
  }

  @override
  Widget build(BuildContext context) {
    if (count <= 0 && !showZero) {
      return child ?? const SizedBox.shrink();
    }

    final effectiveBadgeColor = badgeColor ?? const Color(0xFFE53935);
    final effectiveTextColor = textColor ?? Colors.white;

    final badgeWidget = AnimatedScale(
      scale: count > 0 || showZero ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      child: Container(
        constraints: BoxConstraints(
          minWidth: fontSize * 1.6,
          minHeight: fontSize * 1.6,
        ),
        padding: padding,
        decoration: BoxDecoration(
          color: effectiveBadgeColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: effectiveBadgeColor.withValues(alpha: 0.35),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          widthFactor: 1.0,
          heightFactor: 1.0,
          child: Text(
            _formattedCount,
            style: TextStyle(
              color: effectiveTextColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );

    if (child == null) {
      return badgeWidget;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child!,
        Positioned(
          top: offset.dy,
          right: offset.dx,
          child: badgeWidget,
        ),
      ],
    );
  }
}
