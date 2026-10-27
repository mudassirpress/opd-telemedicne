import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

export 'package:telemedicine/shared/widgets/auth_layout.dart'
    show MetallicInput, GradientButton, ECGWatermarkPainter, InfoCard;

/// ---------------------------------------------------------------------------
/// Admin UI design system
///
/// Every token and widget below is derived from the Sign In screen so the
/// Admin Portal feels like part of the same application.
/// ---------------------------------------------------------------------------

abstract final class AdminPalette {
  // Screen background (same as Sign In)
  static const Color background = Color(0xFFEDF2F8);

  // Text colors (same as Sign In)
  static const Color textPrimary = Color(0xFF1F2F44);
  static const Color textSecondary = Color(0xFF657991);
  static const Color textMuted = Color(0xFF7E90A6);
  static const Color textInput = Color(0xFF1E2F44);
  static const Color iconPrimary = Color(0xFF0E274D);
  static const Color iconSecondary = Color(0xFF647890);

  // Brand (same deep navy used across the app / Sign In links)
  static const Color brand = AppColors.primaryRed;
  static const Color brandLight = AppColors.primaryRedLight;
  static const Color brandDark = AppColors.primaryRedDark;

  // Brand gradient (Sign In button)
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF284F85),
      Color(0xFF15386A),
      Color(0xFF0D264E),
      Color(0xFF081938),
    ],
  );
  static const Color brandBorder = Color(0xFF132D56);
  static const Color brandShadow = Color(0xFF0B2041);

  // Cards (Sign In logo card)
  static const LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.white, Color(0xFFF5F8FC)],
  );
  static const Color cardBorder = Color(0xFFDCE6F2);
  static const Color cardShadow = Color(0xFF12263F);

  // Metallic input (Sign In text fields)
  static const LinearGradient inputOuterGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFE3EAF2),
      Color(0xFFF5F8FC),
      Color(0xFFE2E9F2),
    ],
  );
  static const Color inputOuterBorder = Color(0xFFBAC7D8);
  static const LinearGradient inputInnerGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFF3F7FB),
      Colors.white,
      Color(0xFFF0F4F9),
    ],
  );

  // Segmented selector (Sign In tabs)
  static const LinearGradient selectedGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF183359),
      Color(0xFF0F2445),
      Color(0xFF08162D),
    ],
  );
  static const LinearGradient segmentGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFD4DCE6),
      Color(0xFFE8EEF5),
      Color(0xFFC2CDDC),
    ],
  );
  static const Color segmentBorder = Color(0xFFBAC6D5);
  static const Color unselectedText = Color(0xFF384C66);
  static const LinearGradient unselectedSegmentGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFE9EFF6),
      Color(0xFFDBE4EF),
      Color(0xFFCAD6E4),
    ],
  );

  // Info / help card (Sign In patient-card helper)
  static const Color infoBg = Color(0xFFF0F4FA);
  static const Color infoBorder = Color(0xFFDCE6F2);

  // Divider / hairline
  static const Color divider = Color(0xFFBAC6D5);
  static const Color dividerSoft = Color(0xFFCAD4E0);

  // Status
  static const Color success = AppColors.success;
  static const Color error = AppColors.error;
  static const Color warning = AppColors.warning;
  static const Color info = AppColors.info;
  static const Color frozen = Colors.orange;
}

abstract final class AdminTextStyles {
  // Headings use the same font family as the Sign In title (Quicksand)
  static TextStyle title({double size = 16, Color color = AdminPalette.textPrimary}) =>
      TextStyle(
        fontSize: size,
        fontWeight: FontWeight.bold,
        color: color,
        letterSpacing: -0.4,
      );

  // Body / headings use Poppins (same as rest of Sign In)
  static TextStyle heading({
    double size = 14,
    Color color = AdminPalette.textPrimary,
    FontWeight weight = FontWeight.w600,
  }) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color);

  static TextStyle body({
    double size = 13,
    Color color = AdminPalette.textSecondary,
    FontWeight weight = FontWeight.w500,
    double? height,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      );

  static TextStyle label({
    double size = 12,
    Color color = AdminPalette.textMuted,
    FontWeight weight = FontWeight.w500,
  }) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color);

  static TextStyle small({
    double size = 11,
    Color color = AdminPalette.textMuted,
    FontWeight weight = FontWeight.w500,
  }) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color);
}

/// A sign-in-style screen shell: ECG watermark, gradient navy header with
/// rounded bottom corners, consistent spacing and a light background.
class AdminScreen extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showBack;
  final List<Widget>? actions;
  final Widget? bottom;
  final Widget body;
  final Widget? floatingActionButton;

  const AdminScreen({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = false,
    this.actions,
    this.bottom,
    required this.body,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminPalette.background,
      body: Stack(
        children: [
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.12,
              child: CustomPaint(
                size: const Size(220, 160),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),
          Column(
            children: [
              _buildHeader(context),
              Expanded(child: body),
            ],
          ),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: AdminPalette.brandGradient,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
        boxShadow: [
          BoxShadow(
            color: AdminPalette.brandShadow.withValues(alpha: 0.25),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.rsp(16),
                10,
                context.rsp(16),
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (showBack) ...[
                    CircularBackButton(onPressed: () => Navigator.pop(context)),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: -0.3,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(11.5),
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (actions != null) ...actions!,
                ],
              ),
            ),
            if (bottom != null) ...[
              SizedBox(height: context.rsp(12)),
              bottom!,
            ],
            SizedBox(height: context.rsp(14)),
          ],
        ),
      ),
    );
  }
}

/// Circular icon button used for header actions (same as Sign In back button).
class AdminHeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final int badgeCount;

  const AdminHeaderAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      icon: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: BadgeIndicator(
          count: badgeCount,
          offset: const Offset(-2, -2),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// The Sign-In logo-card look applied to content cards.
class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool filled;
  final Color? borderColor;
  final double? shadowStrength;

  const AdminCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.radius = 20,
    this.filled = false,
    this.borderColor,
    this.shadowStrength = 0.10,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        gradient: filled ? null : AdminPalette.cardGradient,
        color: filled ? Colors.white : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? AdminPalette.cardBorder),
        boxShadow: [
          BoxShadow(
            color: AdminPalette.cardShadow.withValues(alpha: shadowStrength!),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Section heading (icon + Quicksand title) used across admin content.
class AdminSectionTitle extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? subtitle;
  final double? iconSize;

  const AdminSectionTitle({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: AdminPalette.brand, size: iconSize ?? 20),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AdminTextStyles.title(size: context.fs(15.5)),
              ),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: AdminTextStyles.body(size: context.fs(12.5)),
          ),
        ],
      ],
    );
  }
}

/// Uppercase micro heading for list sections (settings etc.).
class AdminSectionLabel extends StatelessWidget {
  final String title;
  final EdgeInsetsGeometry padding;

  const AdminSectionLabel(this.title, {super.key, this.padding = const EdgeInsets.all(0)});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        title.toUpperCase(),
        style: AdminTextStyles.label(
          size: context.fs(12),
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Primary CTA modeled directly on the Sign In button.
class AdminPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final IconData? leadingIcon;
  final VoidCallback? onPressed;
  final bool isLoading;
  final double height;
  final bool fullWidth;

  const AdminPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.leadingIcon,
    this.onPressed,
    this.isLoading = false,
    this.height = 50,
    this.fullWidth = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: fullWidth ? double.infinity : null,
      decoration: BoxDecoration(
        gradient: AdminPalette.brandGradient,
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: AdminPalette.brandBorder),
        boxShadow: [
          BoxShadow(
            color: AdminPalette.brandShadow.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
        onPressed: isLoading ? null : onPressed,
        child: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (leadingIcon != null) ...[
                    Icon(leadingIcon, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(14.5),
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  if (icon != null) ...[
                    const SizedBox(width: 8),
                    Icon(icon, color: Colors.white, size: 18),
                  ],
                ],
              ),
      ),
    );
  }
}

/// Solid colored action button (Approve / Retry etc.).
class AdminSolidButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback? onPressed;
  final bool isLoading;
  final double height;

  const AdminSolidButton({
    super.key,
    required this.label,
    this.icon,
    required this.color,
    this.onPressed,
    this.isLoading = false,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: isLoading ? null : onPressed,
        child: isLoading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 17, color: Colors.white),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(13.5),
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Outlined action button (Reject etc.).
class AdminOutlineButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback? onPressed;
  final double height;

  const AdminOutlineButton({
    super.key,
    required this.label,
    this.icon,
    required this.color,
    this.onPressed,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          side: BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Colored status pill (same silhouette as sign-in info chip).
class AdminPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final double fontSize;

  const AdminPill({
    super.key,
    required this.text,
    required this.color,
    this.icon,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(fontSize),
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

/// Segmented control copied from the Sign In role selector.
class AdminSegmentOption<T> {
  final T value;
  final String label;
  final IconData icon;

  const AdminSegmentOption(this.value, this.label, this.icon);
}

class AdminSegmentedControl<T> extends StatelessWidget {
  final List<AdminSegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  const AdminSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    final controlHeight = context.rsp(height).clamp(48.0, 56.0).toDouble();
    return Container(
      height: controlHeight,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        gradient: AdminPalette.segmentGradient,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AdminPalette.segmentBorder),
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
            if (i > 0)
              Container(
                width: 1,
                height: 26,
                margin: const EdgeInsets.symmetric(vertical: 8),
                color: Colors.black12,
              ),
            Expanded(child: _buildSegment(context, options[i], controlHeight)),
          ],
        ],
      ),
    );
  }

  Widget _buildSegment(
    BuildContext context,
    AdminSegmentOption<T> option,
    double controlHeight,
  ) {
    final isSelected = option.value == value;

    return GestureDetector(
      onTap: () => onChanged(option.value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        height: controlHeight - 8,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: isSelected
              ? AdminPalette.selectedGradient
              : AdminPalette.unselectedSegmentGradient,
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
              option.icon,
              size: 15,
              color: isSelected ? Colors.white : AdminPalette.unselectedText,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(12),
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  color: isSelected ? Colors.white : AdminPalette.unselectedText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Filter chip styled to match the sign-in segmented selector.
class AdminFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const AdminFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: selected
              ? AdminPalette.selectedGradient
              : AdminPalette.unselectedSegmentGradient,
          border: Border.all(
            color: selected
                ? AdminPalette.brandBorder
                : AdminPalette.segmentBorder,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AdminPalette.brandShadow.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(12),
            fontWeight: selected ? FontWeight.bold : FontWeight.w600,
            color:
                selected ? Colors.white : AdminPalette.unselectedText,
          ),
        ),
      ),
    );
  }
}

/// Search field rendered with the Sign In metallic input style.
class AdminSearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final bool hasQuery;
  final String hintText;
  final EdgeInsetsGeometry? margin;

  const AdminSearchField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onClear,
    this.hasQuery = false,
    this.hintText = 'Search...',
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        gradient: AdminPalette.inputOuterGradient,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AdminPalette.inputOuterBorder, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Container(
        height: 46,
        padding: const EdgeInsets.only(left: 16, right: 6),
        decoration: BoxDecoration(
          gradient: AdminPalette.inputInnerGradient,
          borderRadius: BorderRadius.circular(27),
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: AdminPalette.iconPrimary, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w500,
                  color: AdminPalette.textInput,
                ),
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: TextStyle(
                    color: AdminPalette.textMuted,
                    fontSize: context.fs(13),
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (hasQuery)
              IconButton(
                onPressed: onClear,
                icon: const Icon(
                  Icons.clear_rounded,
                  color: AdminPalette.iconSecondary,
                  size: 20,
                ),
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(),
              ),
          ],
        ),
      ),
    );
  }
}

/// Info / help banner (matches Sign In's patient-card helper card).
class AdminInfoBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Color? color;

  const AdminInfoBanner({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AdminPalette.brand;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AdminPalette.infoBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AdminPalette.infoBorder),
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
                  style: AdminTextStyles.heading(size: context.fs(13)),
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: AdminTextStyles.body(size: context.fs(11.5)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Key/value row used inside lists and detail cards.
class AdminInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  final Color? valueColor;

  const AdminInfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.color,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AdminPalette.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.body(
              size: context.fs(12),
              color: AdminPalette.textSecondary,
              weight: FontWeight.w500,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AdminTextStyles.body(
                size: context.fs(12),
                color: valueColor ?? AdminPalette.textPrimary,
                weight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Standard confirmation dialog styled like the rest of the app.
Future<bool> showAdminConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  Color? confirmColor,
  Widget? extraContent,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AdminConfirmDialog(
      title: title,
      content: content,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      confirmColor: confirmColor,
      extraContent: extraContent,
    ),
  );
  return result ?? false;
}

/// Reason-input dialog (reject flows) in the app's metallic style.
Future<void> showAdminReasonDialog({
  required BuildContext context,
  required String title,
  required String prompt,
  required String confirmLabel,
  Color? confirmColor,
  required void Function(String reason) onConfirm,
}) async {
  final reasonController = TextEditingController();
  final formKey = GlobalKey<FormState>();

  await showDialog<void>(
    context: context,
    builder: (context) => AdminReasonDialog(
      title: title,
      prompt: prompt,
      confirmLabel: confirmLabel,
      confirmColor: confirmColor,
      controller: reasonController,
      formKey: formKey,
      onConfirm: onConfirm,
    ),
  );
  reasonController.dispose();
}

class AdminConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmLabel;
  final String cancelLabel;
  final Color? confirmColor;
  final Widget? extraContent;

  const AdminConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    required this.cancelLabel,
    this.confirmColor,
    this.extraContent,
  });

  @override
  Widget build(BuildContext context) {
    final color = confirmColor ?? AdminPalette.brand;
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      title: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AdminTextStyles.title(size: context.fs(16)),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              content,
              textAlign: TextAlign.center,
              style: AdminTextStyles.body(
                size: context.fs(13),
                height: 1.4,
              ),
            ),
            if (extraContent != null) ...[
              const SizedBox(height: 14),
              extraContent!,
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      actions: [
        Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: AdminPalette.background,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: AdminPalette.cardBorder),
                ),
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: Text(
                    cancelLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminTextStyles.heading(
                      size: context.fs(13),
                      color: AdminPalette.textMuted,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  gradient: color == AdminPalette.brand
                      ? AdminPalette.brandGradient
                      : null,
                  color:
                      color == AdminPalette.brand ? null : color,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: color == AdminPalette.brand
                        ? AdminPalette.brandBorder
                        : color,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AdminPalette.brandShadow.withValues(alpha: 0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: Text(
                    confirmLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class AdminReasonDialog extends StatelessWidget {
  final String title;
  final String prompt;
  final String confirmLabel;
  final Color? confirmColor;
  final TextEditingController controller;
  final GlobalKey<FormState> formKey;
  final void Function(String reason) onConfirm;

  const AdminReasonDialog({
    super.key,
    required this.title,
    required this.prompt,
    required this.confirmLabel,
    this.confirmColor,
    required this.controller,
    required this.formKey,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final color = confirmColor ?? AdminPalette.brand;
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      title: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AdminTextStyles.title(size: context.fs(16)),
      ),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                prompt,
                style: AdminTextStyles.body(
                  size: context.fs(13),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  gradient: AdminPalette.inputOuterGradient,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AdminPalette.inputOuterBorder,
                    width: 1.5,
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    gradient: AdminPalette.inputInnerGradient,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: TextFormField(
                    controller: controller,
                    maxLines: 3,
                    minLines: 2,
                    style: TextStyle(
                      fontSize: context.fs(13.5),
                      fontWeight: FontWeight.w500,
                      color: AdminPalette.textInput,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type reason here...',
                      hintStyle: TextStyle(
                        color: AdminPalette.textMuted,
                        fontSize: context.fs(13),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(200),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      actions: [
        Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: AdminPalette.background,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: AdminPalette.cardBorder),
                ),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: Text(
                    'Cancel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminTextStyles.heading(
                      size: context.fs(13),
                      color: AdminPalette.textMuted,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  gradient: color == AdminPalette.brand
                      ? AdminPalette.brandGradient
                      : null,
                  color: color == AdminPalette.brand ? null : color,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: color == AdminPalette.brand
                        ? AdminPalette.brandBorder
                        : color,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AdminPalette.brandShadow.withValues(alpha: 0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: TextButton(
                  onPressed: () {
                    if (!formKey.currentState!.validate()) return;
                    Navigator.pop(context);
                    onConfirm(controller.text.trim());
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: Text(
                    confirmLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Empty state in the Sign In visual language.
class AdminEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const AdminEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: AdminPalette.cardBorder),
                boxShadow: [
                  BoxShadow(
                    color: AdminPalette.cardShadow.withValues(alpha: 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(icon, size: 38, color: AdminPalette.textMuted),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AdminTextStyles.title(size: context.fs(15.5)),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: AdminTextStyles.body(size: context.fs(12.5)),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-screen loading state in the app's style.
class AdminLoading extends StatelessWidget {
  final String? label;

  const AdminLoading({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: AdminPalette.brand,
              backgroundColor: AdminPalette.brand.withValues(alpha: 0.1),
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(
              label!,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AdminTextStyles.body(size: context.fs(13)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Error state with optional retry (used for async load failures).
class AdminErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const AdminErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AdminPalette.error.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 38,
                color: AdminPalette.error,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AdminTextStyles.body(size: context.fs(13)),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              AdminSolidButton(
                label: 'Retry',
                icon: Icons.refresh,
                color: AdminPalette.brand,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Section header used inside scrollable admin bodies.
class AdminHeaderBar extends StatelessWidget {
  final String title;
  final Widget? action;

  const AdminHeaderBar({super.key, required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.title(size: context.fs(16)),
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}