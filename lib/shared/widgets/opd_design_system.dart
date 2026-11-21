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
                Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, context.rsp(24), 0),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: context.contentMaxWidth < 440
                            ? context.contentMaxWidth
                            : 440,
                      ),
                      child: Row(
                        children: [
                          CircularBackButton(
                            onPressed: () => Navigator.maybePop(context),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                OpdTitle(title),
                                if (subtitle != null) ...[
                                  const SizedBox(height: 4),
                                  OpdSubtitle(subtitle!),
                                ],
                              ],
                            ),
                          ),
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
    return Text(
      text,
      textAlign: TextAlign.start,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: context.fs(13.5),
        fontWeight: FontWeight.w500,
        color: const Color(0xFF657991),
        height: 1.4,
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
        mainAxisSize: MainAxisSize.max,
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

/// Standardized top AppBar matching the authentication screens:
/// Clean circular back chevron on the left, bold centered title, and optional actions.
class OpdAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onBack;
  final List<Widget>? actions;
  final bool showBackButton;

  const OpdAppBar({
    super.key,
    required this.title,
    this.onBack,
    this.actions,
    this.showBackButton = true,
  });

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      automaticallyImplyLeading: false,
      leading: showBackButton
          ? IconButton(
              icon: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8EDF3),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFDCE6F2)),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 16,
                  color: Color(0xFF062B72),
                ),
              ),
              onPressed: onBack ?? () => Navigator.maybePop(context),
            )
          : null,
      title: Text(
        title,
        style: TextStyle(
          fontSize: context.fs(17),
          fontWeight: FontWeight.w700,
          color: const Color(0xFF1F2F44),
          letterSpacing: -0.3,
        ),
      ),
      actions: actions,
    );
  }
}

/// Interactive selection card tile matching the "Sign Up Selection" card design:
/// rounded 18, border 0xFFD6E3F0, soft shadow, leading icon badge in a
/// soft-colored container, bold title, description, and trailing chevron arrow.
class OpdSelectionCard extends StatelessWidget {
  final IconData? icon;
  final Widget? customIcon;
  final Color iconBgColor;
  final Color iconColor;
  final String title;
  final String description;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? bottomWidget;

  const OpdSelectionCard({
    super.key,
    this.icon,
    this.customIcon,
    this.iconBgColor = const Color(0xFFE2F5F3),
    this.iconColor = const Color(0xFF0E9A8E),
    required this.title,
    required this.description,
    this.onTap,
    this.trailing,
    this.bottomWidget,
  }) : assert(icon != null || customIcon != null);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFD6E3F0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Icon Box
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: iconBgColor,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: customIcon ??
                          Icon(
                            icon,
                            size: 24,
                            color: iconColor,
                          ),
                    ),
                    const SizedBox(width: 14),

                    // Title & Description
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(15.5),
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF1F2F44),
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(12.5),
                              fontWeight: FontWeight.w400,
                              color: const Color(0xFF657991),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Trailing
                    trailing ??
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 22,
                          color: Color(0xFF7E90A6),
                        ),
                  ],
                ),
                if (bottomWidget != null) ...[
                  const SizedBox(height: 12),
                  bottomWidget!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Info / Status Card matching the "Info Notice" design from the card verification screen:
/// soft-background rounded container with leading info icon and clean helper copy.
class OpdNoticeCard extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color backgroundColor;
  final Color borderColor;
  final Color iconColor;
  final Color textColor;
  final Widget? trailing;

  const OpdNoticeCard({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.backgroundColor = const Color(0xFFE8F2FA),
    this.borderColor = const Color(0xFFCCE0F2),
    this.iconColor = const Color(0xFF0F4C81),
    this.textColor = const Color(0xFF1F2F44),
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 20,
            color: iconColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: context.fs(12.5),
                fontWeight: FontWeight.w500,
                color: textColor,
                height: 1.35,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Quick Action Badge model for the 4-column services grid layout.
class OpdQuickActionItem {
  final String label;
  final IconData? icon;
  final Widget? customIcon;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? bgColor;

  const OpdQuickActionItem({
    required this.label,
    this.icon,
    this.customIcon,
    required this.onTap,
    this.iconColor,
    this.bgColor,
  });
}

/// 4-column rounded badge card layout matching the Landing Screen services feature grid.
class OpdQuickActionGrid extends StatelessWidget {
  final List<OpdQuickActionItem> items;

  const OpdQuickActionGrid({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: items.map((item) {
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _buildBadge(context, item),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBadge(BuildContext context, OpdQuickActionItem item) {
    final bgColor = item.bgColor ?? const Color(0xFFE4F6F4);
    final iconColor = item.iconColor ?? const Color(0xFF0E9A8E);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE0EAF3), width: 1),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F233C).withValues(alpha: 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: item.customIcon ??
                    Icon(
                      item.icon,
                      size: 19,
                      color: iconColor,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                item.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(10.5),
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF1F2F44),
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Outlined button matching secondary actions from authentication screens.
class OpdOutlinedButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  final IconData? trailingIcon;
  final Color borderColor;
  final Color textColor;
  final double height;

  const OpdOutlinedButton({
    super.key,
    required this.text,
    this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.borderColor = const Color(0xFF062B72),
    this.textColor = const Color(0xFF062B72),
    this.height = 50,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: borderColor, width: 1.3),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(height / 2),
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (leadingIcon != null) ...[
                  Icon(leadingIcon, color: textColor, size: 18),
                  const SizedBox(width: 8),
                ],
                Text(
                  text,
                  style: TextStyle(
                    fontSize: context.fs(14.5),
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    letterSpacing: 0.2,
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 8),
                  Icon(trailingIcon, color: textColor, size: 18),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Primary action button with navy gradient and right arrow (alias/wrapper for auth style).
class OpdPrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? trailingIcon;
  final IconData? leadingIcon;
  final double height;

  const OpdPrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.trailingIcon = Icons.arrow_forward_rounded,
    this.leadingIcon,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F3260), Color(0xFF0A2244), Color(0xFF061830)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(height / 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF091E3B).withValues(alpha: 0.3),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(height / 2),
          onTap: isLoading ? null : onPressed,
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (leadingIcon != null) ...[
                        Icon(leadingIcon, color: Colors.white, size: 19),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: context.fs(15),
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (trailingIcon != null) ...[
                        const SizedBox(width: 8),
                        Icon(trailingIcon, color: Colors.white, size: 18),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

