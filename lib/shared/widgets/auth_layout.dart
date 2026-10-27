import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';

// --- ECG Watermark Painter ---
class ECGWatermarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueGrey
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(-20, 105)
      ..lineTo(75, 105)
      ..lineTo(90, 65)
      ..lineTo(105, 145)
      ..lineTo(125, 20)
      ..lineTo(142, 150)
      ..lineTo(155, 95)
      ..lineTo(170, 105)
      ..lineTo(260, 105);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- LogoCard Widget ---
class LogoCard extends StatelessWidget {
  const LogoCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cardWidth = context.isSmallPhone ? context.sw * 0.5 : 190.0;
    final cardHeight = cardWidth * 116 / 190;
    return Container(
      width: cardWidth,
      height: cardHeight,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Colors.white, Color(0xFFF5F8FC)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFDCE6F2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF12263F).withValues(alpha: 0.16),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Image.asset(
        'assets/images/opd online.png',
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return const Icon(
            Icons.medical_services,
            size: 60,
            color: Color(0xFF062B72),
          );
        },
      ),
    );
  }
}

// --- Metallic Beveled Input ---
class MetallicInput extends StatefulWidget {
  final String hintText;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool isPassword;
  final bool obscureText;
  final VoidCallback? onVisibilityToggle;
  final TextEditingController? controller;
  final String? Function(String?)? validator;
  final bool enabled;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final bool showLabel;
  final String? labelText;
  final ValueChanged<String>? onChanged;
  final String? errorText;
  final FocusNode? focusNode;
  final bool readOnly;
  final Widget? suffixIcon;
  final AutovalidateMode autovalidateMode;

  const MetallicInput({
    super.key,
    required this.hintText,
    required this.icon,
    this.keyboardType,
    this.isPassword = false,
    this.obscureText = false,
    this.onVisibilityToggle,
    this.controller,
    this.validator,
    this.enabled = true,
    this.inputFormatters,
    this.maxLength,
    this.showLabel = false,
    this.labelText,
    this.onChanged,
    this.errorText,
    this.focusNode,
    this.readOnly = false,
    this.suffixIcon,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
  });

  @override
  State<MetallicInput> createState() => _MetallicInputState();
}

class _MetallicInputState extends State<MetallicInput> {
  late bool _obscureText;
  late final TextEditingController _internalController;
  final GlobalKey<FormFieldState<String>> _fieldKey =
      GlobalKey<FormFieldState<String>>();

  TextEditingController get _effectiveController =>
      widget.controller ?? _internalController;

  @override
  void initState() {
    super.initState();
    _obscureText = widget.obscureText;
    _internalController = TextEditingController();
    _effectiveController.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (_fieldKey.currentState != null &&
        _fieldKey.currentState!.value != _effectiveController.text) {
      _fieldKey.currentState!.didChange(_effectiveController.text);
    }
  }

  @override
  void dispose() {
    _effectiveController.removeListener(_onControllerChanged);
    _internalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormField<String>(
      key: _fieldKey,
      initialValue: _effectiveController.text,
      validator: widget.validator != null
          ? (_) => widget.validator!(_effectiveController.text)
          : null,
      autovalidateMode: widget.autovalidateMode,
      builder: (FormFieldState<String> fieldState) {
        final effectiveError =
            (widget.errorText != null && widget.errorText!.isNotEmpty)
            ? widget.errorText
            : fieldState.errorText;
        final hasError = effectiveError != null && effectiveError.isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showLabel && widget.labelText != null) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  widget.labelText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ),
            ],
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFFE3EAF2),
                    Color(0xFFF5F8FC),
                    Color(0xFFE2E9F2),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: hasError ? Colors.red : const Color(0xFFBAC7D8),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (hasError ? Colors.red : const Color(0xFF0F233C))
                        .withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFF3F7FB),
                      Colors.white,
                      Color(0xFFF0F4F9),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.icon,
                      color: hasError ? Colors.red : const Color(0xFF0E274D),
                      size: 18,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _effectiveController,
                        focusNode: widget.focusNode,
                        keyboardType: widget.keyboardType,
                        obscureText: widget.isPassword ? _obscureText : false,
                        enabled: widget.enabled,
                        readOnly: widget.readOnly,
                        inputFormatters: widget.inputFormatters,
                        maxLength: widget.maxLength,
                        onChanged: (val) {
                          fieldState.didChange(val);
                          widget.onChanged?.call(val);
                        },
                        style: TextStyle(
                          fontSize: context.fs(14),
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF1E2F44),
                        ),
                        decoration: InputDecoration(
                          hintText: widget.hintText,
                          hintStyle: TextStyle(
                            color: const Color(0xFF7E90A6),
                            fontSize: context.fs(13.5),
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          counterText: widget.maxLength != null ? '' : null,
                          errorStyle: const TextStyle(fontSize: 0, height: 0),
                        ),
                      ),
                    ),
                    if (widget.suffixIcon != null) ...[
                      widget.suffixIcon!,
                    ] else if (widget.isPassword) ...[
                      Container(
                        height: 24,
                        width: 1.5,
                        color: const Color(0xFFCAD4E0),
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _obscureText = !_obscureText;
                          });
                          widget.onVisibilityToggle?.call();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          child: Icon(
                            _obscureText
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: const Color(0xFF647890),
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 20, right: 20),
                child: Text(
                  effectiveError!,
                  style: TextStyle(
                    color: Colors.red[700] ?? Colors.red,
                    fontSize: context.fs(12),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// --- Metallic Dropdown ---
class MetallicDropdown<T> extends StatelessWidget {
  final String? labelText;
  final bool showLabel;
  final String hintText;
  final IconData icon;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? Function(T?)? validator;
  final String? errorText;
  final bool enabled;

  const MetallicDropdown({
    super.key,
    this.labelText,
    this.showLabel = false,
    required this.hintText,
    required this.icon,
    required this.value,
    required this.items,
    this.onChanged,
    this.validator,
    this.errorText,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return FormField<T>(
      initialValue: value,
      validator: validator,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      builder: (FormFieldState<T> state) {
        final effectiveError = (errorText != null && errorText!.isNotEmpty)
            ? errorText
            : state.errorText;
        final hasError = effectiveError != null && effectiveError.isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showLabel && labelText != null) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  labelText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ),
            ],
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFFE3EAF2),
                    Color(0xFFF5F8FC),
                    Color(0xFFE2E9F2),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: hasError ? Colors.red : const Color(0xFFBAC7D8),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (hasError ? Colors.red : const Color(0xFF0F233C))
                        .withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFF3F7FB),
                      Colors.white,
                      Color(0xFFF0F4F9),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      color: hasError ? Colors.red : const Color(0xFF0E274D),
                      size: 18,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<T>(
                          value: items.any((item) => item.value == value)
                              ? value
                              : null,
                          isExpanded: true,
                          hint: Text(
                            hintText,
                            style: TextStyle(
                              color: const Color(0xFF7E90A6),
                              fontSize: context.fs(13.5),
                            ),
                          ),
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Color(0xFF647890),
                            size: 20,
                          ),
                          style: TextStyle(
                            fontSize: context.fs(14),
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF1E2F44),
                          ),
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          items: items,
                          onChanged: enabled
                              ? (val) {
                                  state.didChange(val);
                                  onChanged?.call(val);
                                }
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 20, right: 20),
                child: Text(
                  effectiveError!,
                  style: TextStyle(
                    color: Colors.red[700] ?? Colors.red,
                    fontSize: context.fs(12),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// --- Gender Dropdown Field ---
class GenderDropdownField extends StatelessWidget {
  final String? value;
  final ValueChanged<String?>? onChanged;
  final String? Function(String?)? validator;
  final bool showLabel;
  final String? labelText;
  final bool enabled;
  final String? errorText;

  const GenderDropdownField({
    super.key,
    this.value,
    this.onChanged,
    this.validator,
    this.showLabel = false,
    this.labelText = 'Gender',
    this.enabled = true,
    this.errorText,
  });

  static const List<String> options = ['Male', 'Female', 'Other'];

  @override
  Widget build(BuildContext context) {
    return MetallicDropdown<String>(
      showLabel: showLabel,
      labelText: labelText,
      hintText: 'Select Gender',
      icon: Icons.wc_rounded,
      value: (value != null && options.contains(value)) ? value : null,
      enabled: enabled,
      validator:
          validator ??
          (val) =>
              (val == null || val.isEmpty) ? 'Please select your gender' : null,
      errorText: errorText,
      items: options.map((gender) {
        IconData optIcon;
        switch (gender) {
          case 'Male':
            optIcon = Icons.male_rounded;
            break;
          case 'Female':
            optIcon = Icons.female_rounded;
            break;
          default:
            optIcon = Icons.transgender_rounded;
        }
        return DropdownMenuItem<String>(
          value: gender,
          child: Row(
            children: [
              Icon(optIcon, size: 16, color: const Color(0xFF163B6E)),
              const SizedBox(width: 8),
              Text(
                gender,
                style: TextStyle(
                  fontSize: context.fs(14),
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF1E2F44),
                ),
              ),
            ],
          ),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}

// --- Gradient Button ---
class GradientButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;

  const GradientButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF284F85),
            Color(0xFF15386A),
            Color(0xFF0D264E),
            Color(0xFF081938),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF132D56)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2041).withValues(alpha: 0.32),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
        onPressed: isLoading ? null : onPressed,
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(14.5),
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.5,
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

// --- Circular Back Button ---
class CircularBackButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const CircularBackButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed ?? () => Navigator.pop(context),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFE8EDF3),
        ),
        child: const Icon(
          Icons.arrow_back_rounded,
          color: Color(0xFF062B72),
          size: 22,
        ),
      ),
    );
  }
}

// --- Divider with Text ---
class DividerWithText extends StatelessWidget {
  final String text;

  const DividerWithText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            color: const Color(0xFFBAC6D5).withValues(alpha: 0.6),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(13.5),
              fontWeight: FontWeight.w500,
              color: const Color(0xFF657991),
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            color: const Color(0xFFBAC6D5).withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

// --- Info Card (for help text boxes) ---
class InfoCard extends StatelessWidget {
  final String title;
  final String description;

  const InfoCard({super.key, required this.title, required this.description});

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
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: AppColors.primaryRed,
          ),
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

// --- Auth Screen Layout Wrapper ---
class AuthScreenLayout extends StatelessWidget {
  final Widget? child;
  final String? title;
  final String? subtitle;
  final bool showLogo;
  final bool showBottomBar;
  final Widget? bottom;

  const AuthScreenLayout({
    super.key,
    this.child,
    this.title,
    this.subtitle,
    this.showLogo = true,
    this.showBottomBar = true,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // Background ECG Watermark
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

          // Main Content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: context.rsp(24),
                  vertical: 16,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    children: [
                      // Logo
                      if (showLogo) ...[
                        const SizedBox(height: 8),
                        const LogoCard(),
                        SizedBox(height: context.rsp(28)),
                      ],

                      // Title
                      if (title != null) ...[
                        Text(
                          title!,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(20),
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1F2F44),
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],

                      // Subtitle
                      if (subtitle != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            subtitle!,
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
                        ),
                        SizedBox(height: context.rsp(28)),
                      ],

                      // Child Content
                      if (child != null) child!,

                      // Bottom
                      if (bottom != null) ...[
                        SizedBox(height: context.rsp(24)),
                        bottom!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
