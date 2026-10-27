import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';

/// A single row inside an [showAnchoredMenu] popup.
class AnchoredMenuItem {
  final String label;
  final VoidCallback onTap;

  /// When false the popup is removed instantly instead of playing the close
  /// animation. Use this for items that push a new screen, so the popup's
  /// scrim never flashes over the incoming route.
  final bool animateClose;

  const AnchoredMenuItem({
    required this.label,
    required this.onTap,
    this.animateClose = true,
  });
}

/// Opens a floating popup card anchored **directly underneath** the widget
/// identified by [link]. It is rendered in the app's [Overlay], so it floats
/// above the chat screen instead of pushing or covering it, and it is never a
/// bottom sheet or a full-screen dialog.
///
/// Behaviour:
///  * opens/closes with a short scale + fade animation
///  * dismisses on an outside tap
///  * flips above the anchor and clamps its width/height so it can never
///    leave the viewport on small devices
///
/// [anchorKey] must be the `GlobalKey` of the anchoring widget (the same widget
/// that hosts [link]) so the popup can measure the space available around it.
///
/// The returned future completes once the popup has finished closing, so the
/// caller can safely navigate straight after an item is picked.
Future<void> showAnchoredMenu({
  required BuildContext context,
  required GlobalKey anchorKey,
  required LayerLink link,
  required List<AnchoredMenuItem> items,
  double maxWidth = 240,
  double gap = 6,
  double horizontalInset = 6,
}) {
  if (items.isEmpty) return Future<void>.value();

  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<void>();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _AnchoredMenu(
      anchorKey: anchorKey,
      link: link,
      items: items,
      maxWidth: maxWidth,
      gap: gap,
      horizontalInset: horizontalInset,
      onClosed: () {
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );

  overlay.insert(entry);
  return completer.future;
}

class _AnchoredMenu extends StatefulWidget {
  final GlobalKey anchorKey;
  final LayerLink link;
  final List<AnchoredMenuItem> items;
  final double maxWidth;
  final double gap;
  final double horizontalInset;
  final VoidCallback onClosed;

  const _AnchoredMenu({
    required this.anchorKey,
    required this.link,
    required this.items,
    required this.maxWidth,
    required this.gap,
    required this.horizontalInset,
    required this.onClosed,
  });

  @override
  State<_AnchoredMenu> createState() => _AnchoredMenuState();
}

class _AnchoredMenuState extends State<_AnchoredMenu>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    reverseDuration: const Duration(milliseconds: 130),
  );

  final GlobalKey _menuKey = GlobalKey();

  bool _flipAbove = false;
  bool _needsClamp = false;
  double _maxHeight = double.infinity;
  bool _needsMeasure = true;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) widget.onClosed();
    });
    _controller.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The first frame renders the popup at its natural size (a shrink-wrapped
  /// `Column`). Once measured, this decides whether the popup has to flip above
  /// the anchor and/or become scrollable so it can never leave the viewport.
  void _measure() {
    if (!mounted || !_needsMeasure) return;
    final anchorBox =
        widget.anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final menuBox = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchorBox == null || menuBox == null) return;

    final screenSize = MediaQuery.sizeOf(context);
    final anchorTopLeft = anchorBox.localToGlobal(Offset.zero);
    final availableBelow = screenSize.height -
        (anchorTopLeft.dy + anchorBox.size.height) -
        widget.gap;
    final availableAbove = anchorTopLeft.dy - widget.gap;
    final needed = menuBox.size.height;

    final shouldFlip = needed > availableBelow && availableAbove > availableBelow;
    final available = shouldFlip ? availableAbove : availableBelow;

    setState(() {
      _flipAbove = shouldFlip;
      // Only clamp when the natural height genuinely does not fit, so the popup
      // stays exactly as large as its content in the normal case.
      _needsClamp = needed > available;
      _maxHeight = _needsClamp ? math.max(120.0, available) : double.infinity;
      _needsMeasure = false;
    });
  }

  void _dismiss() {
    if (_controller.isDismissed) return;
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = math.min(
      widget.maxWidth,
      math.min(context.sw * 0.9, MediaQuery.sizeOf(context).width - 24),
    );

    return Stack(
      children: [
        // Scrim: tapping anywhere outside closes the popup.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: AnimatedOpacity(
              opacity: _controller.value,
              duration: const Duration(milliseconds: 170),
              child: Container(
                color: const Color(0xFF0B2041).withValues(alpha: 0.12),
              ),
            ),
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          targetAnchor: _flipAbove
              ? Alignment.topRight
              : Alignment.bottomRight,
          followerAnchor:
              _flipAbove ? Alignment.bottomRight : Alignment.topRight,
          offset: Offset(
            -widget.horizontalInset,
            _flipAbove ? -widget.gap : widget.gap,
          ),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = _controller.value;
              return Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.90 + 0.10 * t,
                  alignment: _flipAbove
                      ? Alignment.bottomRight
                      : Alignment.topRight,
                  child: child,
                ),
              );
            },
            child: _buildCard(maxWidth),
          ),
        ),
      ],
    );
  }

  /// Shrink-wrapped popup card: only as wide as the widest row needs (capped at
  /// [maxWidth]) and only as tall as the number of rows requires.
  Widget _buildCard(double maxWidth) {
    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in widget.items) _buildRow(item),
      ],
    );

    // A plain `Column` is greedy under a `SingleChildScrollView`, so the
    // scroll view is only added when the measured height actually overflows.
    final body = _needsClamp
        ? SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: rows,
          )
        : rows;

    return Container(
      key: _menuKey,
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: _maxHeight,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF12263F).withValues(alpha: 0.16),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: body,
          ),
        ),
      ),
    );
  }

  /// One compact, WhatsApp-like row: a small plain icon, then the label.
  /// No tile background and no dividers, so the card stays small and calm.
  Widget _buildRow(AnchoredMenuItem item) {
    return InkWell(
      onTap: () {
        if (item.animateClose) {
          _dismiss();
        } else {
          widget.onClosed();
        }
        item.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
