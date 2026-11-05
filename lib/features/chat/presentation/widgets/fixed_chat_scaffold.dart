import 'package:flutter/material.dart';

/// A conversation scaffold whose wallpaper never moves.
///
/// The default [Scaffold] resizes its body when the keyboard appears, which
/// drags a `BoxDecoration` background (and any `BoxFit.contain` image) upward
/// with the layout. This scaffold instead:
///  * disables automatic resize;
///  * pins the wallpaper with `Positioned.fill` in a [Stack];
///  * lets only the composer be pushed by `MediaQuery.viewInsets.bottom`.
///
/// The header therefore stays fixed, the wallpaper stays fixed, and the
/// message viewport shrinks exactly by the keyboard height.
class FixedChatScaffold extends StatelessWidget {
  final Widget header;
  final Widget body;
  final Widget composer;
  final Widget? overlay;
  final Color backgroundColor;
  final String backgroundAsset;
  final double backgroundOpacity;
  final Duration keyboardAnimationDuration;

  const FixedChatScaffold({
    super.key,
    required this.header,
    required this.body,
    required this.composer,
    this.overlay,
    this.backgroundColor = const Color(0xFFEDF2F8),
    this.backgroundAsset = 'assets/images/download.jpeg',
    this.backgroundOpacity = 0.1,
    this.keyboardAnimationDuration = const Duration(milliseconds: 180),
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: backgroundColor,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: backgroundOpacity,
                child: Image.asset(
                  backgroundAsset,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      const ColoredBox(color: Color(0xFFEDF2F8)),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                header,
                Expanded(child: body),
                AnimatedPadding(
                  duration: keyboardAnimationDuration,
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(bottom: bottomInset),
                  child: composer,
                ),
              ],
            ),
          ),
          if (overlay != null) overlay!,
        ],
      ),
    );
  }
}
