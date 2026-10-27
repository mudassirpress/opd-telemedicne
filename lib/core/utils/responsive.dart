import 'package:flutter/material.dart';

/// Responsive sizing helpers shared by every screen in the app.
///
/// The design baseline is a **360 logical-pixel wide** phone (the common
/// Android baseline). Everything derived from it:
///
///  * [fs]  – font sizes that gently shrink on narrow phones and never grow
///            past the baseline on wide phones/tablets, so text stays compact
///            and WhatsApp-like on every device.
///  * [rsp] – spacing (padding/margins/gaps) that shrinks on small phones and
///            grows only slightly on large ones.
///  * [contentMaxWidth] – caps content width so tablets and large phones do
///            not stretch cards/forms across the whole display.
///
/// System font scaling is handled once at the app root (see `main.dart`),
/// which clamps the platform text scale to a safe range; these helpers only
/// adapt to the physical screen size.
extension ResponsiveContext on BuildContext {
  /// Full logical screen size.
  Size get screenSize => MediaQuery.sizeOf(this);

  /// Screen width in logical pixels.
  double get sw => screenSize.width;

  /// Screen height in logical pixels.
  double get sh => screenSize.height;

  /// The smaller of the two screen dimensions — the usual way to tell phones
  /// apart from tablets.
  double get shortestSide => screenSize.shortestSide;

  /// Effective text scale after the app-root clamp (1.0 … 1.25).
  double get textScale => MediaQuery.textScalerOf(this).scale(1.0);

  /// Narrow phones such as iPhone SE / 320dp Androids.
  bool get isSmallPhone => shortestSide < 340;

  /// Regular phone (everything below the tablet threshold).
  bool get isPhone => shortestSide < 600;

  /// Tablet / large unfoldables.
  bool get isTablet => shortestSide >= 600;

  /// Wide phones (Pixel XL class, most modern flagships).
  bool get isLargePhone => sw >= 412;

  /// Responsive font size: `context.fs(14)`.
  ///
  /// Returns the same value on a 360dp+ phone and slightly smaller text on
  /// narrower devices, keeping the compact look consistent everywhere.
  double fs(double size) => size * (sw / 360).clamp(0.9, 1.0);

  /// Responsive spacing: `context.rsp(16)`.
  ///
  /// Padding/margins/gaps shrink on narrow phones and may grow up to 12% on
  /// wide phones, capped so tablets keep the same rhythm.
  double rsp(double spacing) => spacing * (sw / 360).clamp(0.85, 1.12);

  /// Maximum content width for centered columns (forms, detail panes).
  /// Full width on phones, capped on tablets/large phones so cards and
  /// buttons do not stretch unnecessarily.
  double get contentMaxWidth {
    if (isTablet) return 600;
    if (sw >= 480) return 520;
    return sw;
  }

  /// Convenience: a fraction of the screen width, e.g. `context.swFrac(.9)`.
  double swFrac(double fraction) => sw * fraction;
}

/// Wraps [child] in a [ConstrainedBox] limited to [ResponsiveContext.contentMaxWidth]
/// and centers it — the standard way to stop UIs stretching on large phones
/// and tablets.
class CenteredContent extends StatelessWidget {
  const CenteredContent({super.key, required this.child, this.maxWidth});

  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? context.contentMaxWidth,
        ),
        child: child,
      ),
    );
  }
}
