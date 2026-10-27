import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Shared design primitives that mirror the existing **Sign In** screen so
/// every screen opened from the chat overflow menu looks like part of the same
/// OPD Telemedicine application.
///
/// Everything here reuses the exact tokens of `SignInScreen`:
///  * background `0xFFEDF2F8` + `ECGWatermarkPainter`
///  * `CircularBackButton` (the `LogoCard` is opt-in via `showLogo`, and is
///    off by default so in-chat sub-screens do not repeat the app logo)
///  * title: Quicksand 26 bold `0xFF1F2F44` / letterSpacing -0.5
///  * subtitle: Poppins 13.5 w500 `0xFF657991`, height 1.4
///  * cards: white, radius 18, border `0xFFDCE6F2`, shadow `0xFF0F233C` @ 0.08
///  * info panels: `0xFFF0F4FA`, radius 14 (same as `InfoCard`)
///  * actions: `GradientButton` (52 h, radius 26)
///  * inputs: `MetallicInput`
///  * content is constrained to 440 logical pixels, like Sign In.

/// Page background + ECG watermark + 440px centered column.
///
/// The back button, [OpdTitle] and [OpdSubtitle] are **pinned**: they sit
/// outside the scrollable area and never move, only [child] scrolls. When
/// `scrollable` is false the child is expected to handle its own scrolling
/// (a `ListView`, `GridView`, or an `Expanded` region).
class OpdScreenShell extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final bool showLogo;
  final bool scrollable;
  final Widget? bottom;

  const OpdScreenShell({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.showLogo = false,
    this.scrollable = true,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // ---- Fixed header ----
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: CircularBackButton(
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    context.rsp(24),
                    10,
                    context.rsp(24),
                    0,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: context.contentMaxWidth < 440
                            ? context.contentMaxWidth
                            : 440,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showLogo) ...[
                            const Center(child: LogoCard()),
                            SizedBox(height: context.rsp(24)),
                          ],
                          OpdTitle(title),
                          if (subtitle != null) ...[
                            const SizedBox(height: 6),
                            OpdSubtitle(subtitle!),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: context.rsp(18)),

                // ---- Scrolling / free content area ----
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.rsp(24),
                      0,
                      context.rsp(24),
                      scrollable ? context.rsp(32) : context.rsp(24),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: scrollable
                            ? SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: child,
                              )
                            : child,
                      ),
                    ),
                  ),
                ),

                // ---- Fixed action bar ----
                if (bottom != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.rsp(24),
                      0,
                      context.rsp(24),
                      context.rsp(24),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: bottom,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sign In page title — Quicksand 26 bold.
class OpdTitle extends StatelessWidget {
  final String text;

  const OpdTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: context.fs(20),
        fontWeight: FontWeight.bold,
        color: const Color(0xFF1F2F44),
        letterSpacing: -0.5,
      ),
    );
  }
}

/// Sign In page subtitle — Poppins 13.5 w500.
class OpdSubtitle extends StatelessWidget {
  final String text;

  const OpdSubtitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: context.fs(13.5),
          fontWeight: FontWeight.w500,
          color: const Color(0xFF657991),
          height: 1.4,
        ),
      ),
    );
  }
}

/// Section label — same size/weight `MetallicInput` uses for its label.
class OpdSectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const OpdSectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(14),
                fontWeight: FontWeight.w600,
                color: const Color(0xFF1F2F44),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// White content card with the Sign In border + elevation treatment.
class OpdCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double radius;

  const OpdCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.radius = 18,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0xFFDCE6F2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}

/// A single label/value line, styled like the Sign In `InfoCard` row but on a
/// white card so it can be grouped inside an [OpdCard].
class OpdDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const OpdDetailRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4FA),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: const Color(0xFFDCE6F2)),
            ),
            child: Icon(icon, size: 20, color: const Color(0xFF0E274D)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: context.fs(11.5),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF7E90A6),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Light informational panel — identical treatment to `InfoCard`.
class OpdInfoPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Color accent;

  const OpdInfoPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.accent = const Color(0xFF062B72),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDCE6F2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: context.fs(11.5),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF657991),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill badge used for roles / specialisations.
class OpdPill extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;

  const OpdPill({
    super.key,
    required this.label,
    this.icon,
    this.color = const Color(0xFF163B6E),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FA),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFDCE6F2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(12),
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty / no-results state shared by all menu screens.
class OpdEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Optional action rendered under the subtitle — used by error states that
  /// need a Retry. Defaults to no action, so every existing call site keeps
  /// its current appearance.
  final Widget? action;

  const OpdEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                color: Color(0xFFF0F4FA),
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                  BorderSide(color: Color(0xFFDCE6F2)),
                ),
              ),
              child: Icon(icon, size: 40, color: const Color(0xFF7E90A6)),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(15.5),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(13),
                fontWeight: FontWeight.w500,
                color: const Color(0xFF657991),
                height: 1.4,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 10), action!],
          ],
        ),
      ),
    );
  }
}

/// Metallic segmented selector, lifted verbatim from `SignInScreen` so tab
/// groups (e.g. Media / Links / Docs) look identical to the login role tabs.
class OpdSegmentedSelector<T> extends StatelessWidget {
  final List<({T value, String label, IconData icon})> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const OpdSegmentedSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final controlHeight = context.rsp(52).clamp(48.0, 56.0).toDouble();
    return Container(
      height: controlHeight,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFD4DCE6), Color(0xFFE8EEF5), Color(0xFFC2CDDC)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFBAC6D5)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F1E32).withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          for (int i = 0; i < options.length; i++) ...[
            if (i > 0) Container(width: 1, height: 24, color: Colors.black12),
            Expanded(
              child: _SegmentButton(
                label: options[i].label,
                icon: options[i].icon,
                isSelected: options[i].value == selected,
                height: controlHeight - 8,
                onTap: () => onChanged(options[i].value),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final double height;

  const _SegmentButton({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: isSelected
              ? const LinearGradient(
                  colors: [
                    Color(0xFF183359),
                    Color(0xFF0F2445),
                    Color(0xFF08162D),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                )
              : const LinearGradient(
                  colors: [
                    Color(0xFFE9EFF6),
                    Color(0xFFDBE4EF),
                    Color(0xFFCAD6E4),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF0A192D).withValues(alpha: 0.3),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? Colors.white : const Color(0xFF384C66),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(12),
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  color: isSelected ? Colors.white : const Color(0xFF384C66),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small pill-shaped count/label used above lists.
class OpdCounterChip extends StatelessWidget {
  final String text;

  const OpdCounterChip(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F4FA),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0xFFDCE6F2)),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(12),
            fontWeight: FontWeight.w500,
            color: const Color(0xFF657991),
          ),
        ),
      ),
    );
  }
}

/// Localized loading indicator. Always sized to the content it sits inside —
/// the menu screens never show a full-screen spinner.
class OpdInlineLoader extends StatelessWidget {
  final String? label;
  final double size;

  const OpdInlineLoader({super.key, this.label, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final spinner = SizedBox(
      width: size,
      height: size,
      child: const CircularProgressIndicator(
        strokeWidth: 2.5,
        color: Color(0xFF062B72),
      ),
    );

    if (label == null) return Center(child: spinner);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          spinner,
          const SizedBox(height: 12),
          Text(
            label!,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(13),
              fontWeight: FontWeight.w500,
              color: const Color(0xFF657991),
            ),
          ),
        ],
      ),
    );
  }
}
