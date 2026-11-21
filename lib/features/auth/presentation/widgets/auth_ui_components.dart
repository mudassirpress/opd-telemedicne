import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';

/// Top AppBar shared across the auth screens with a back arrow and centered title.
class AuthAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onBack;
  final List<Widget>? actions;

  const AuthAppBar({super.key, required this.title, this.onBack, this.actions});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      leading: IconButton(
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
      ),
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

/// Custom tooth (molar) icon painter for the Dental Consultation badge.
class ToothIcon extends StatelessWidget {
  final double size;
  final Color color;

  const ToothIcon({
    super.key,
    this.size = 22,
    this.color = const Color(0xFF0E9A8E),
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _ToothPainter(color: color),
    );
  }
}

class _ToothPainter extends CustomPainter {
  final Color color;

  _ToothPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    final path = Path();
    // Crown top
    path.moveTo(w * 0.25, h * 0.2);
    path.cubicTo(w * 0.35, h * 0.08, w * 0.65, h * 0.08, w * 0.75, h * 0.2);
    // Right crown
    path.cubicTo(w * 0.95, h * 0.25, w * 0.95, h * 0.5, w * 0.82, h * 0.65);
    // Right root
    path.cubicTo(w * 0.8, h * 0.8, w * 0.75, h * 0.95, w * 0.68, h * 0.95);
    path.cubicTo(w * 0.62, h * 0.95, w * 0.58, h * 0.78, w * 0.5, h * 0.68);
    // Left root
    path.cubicTo(w * 0.42, h * 0.78, w * 0.38, h * 0.95, w * 0.32, h * 0.95);
    path.cubicTo(w * 0.25, h * 0.95, w * 0.2, h * 0.8, w * 0.18, h * 0.65);
    // Left crown
    path.cubicTo(w * 0.05, h * 0.5, w * 0.05, h * 0.25, w * 0.25, h * 0.2);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A clean, rounded input text field that respects the app's theme.
class AuthTextField extends StatefulWidget {
  final String hintText;
  final IconData prefixIcon;
  final TextEditingController? controller;
  final bool isPassword;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final int? maxLength;
  final FocusNode? focusNode;
  final String? errorText;

  const AuthTextField({
    super.key,
    required this.hintText,
    required this.prefixIcon,
    this.controller,
    this.isPassword = false,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
    this.onChanged,
    this.enabled = true,
    this.maxLength,
    this.focusNode,
    this.errorText,
  });

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  bool _obscureText = true;
  late final TextEditingController _internalController;
  final GlobalKey<FormFieldState<String>> _fieldKey =
      GlobalKey<FormFieldState<String>>();

  TextEditingController get _effectiveController =>
      widget.controller ?? _internalController;

  @override
  void initState() {
    super.initState();
    _obscureText = widget.isPassword;
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
      autovalidateMode: AutovalidateMode.onUserInteraction,
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
            Container(
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hasError ? AppColors.error : const Color(0xFFD3DFEC),
                  width: hasError ? 1.5 : 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: hasError
                        ? AppColors.error.withValues(alpha: 0.08)
                        : const Color(0xFF0F233C).withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 14, right: 10),
                    child: Icon(
                      widget.prefixIcon,
                      size: 20,
                      color: hasError
                          ? AppColors.error
                          : const Color(0xFF4A607A),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _effectiveController,
                      focusNode: widget.focusNode,
                      enabled: widget.enabled,
                      keyboardType: widget.keyboardType,
                      obscureText: widget.isPassword ? _obscureText : false,
                      inputFormatters: widget.inputFormatters,
                      maxLength: widget.maxLength,
                      onChanged: (val) {
                        fieldState.didChange(val);
                        widget.onChanged?.call(val);
                      },
                      style: TextStyle(
                        fontSize: context.fs(14),
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF1F2F44),
                      ),
                      decoration: InputDecoration(
                        hintText: widget.hintText,
                        hintStyle: TextStyle(
                          fontSize: context.fs(13.5),
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF8FA3B8),
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                        counterText: '',
                      ),
                    ),
                  ),
                  if (widget.isPassword)
                    IconButton(
                      icon: Icon(
                        _obscureText
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20,
                        color: const Color(0xFF657991),
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureText = !_obscureText;
                        });
                      },
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            if (hasError && effectiveError != null && effectiveError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 14, top: 5, bottom: 2),
                child: Text(
                  effectiveError,
                  style: TextStyle(
                    fontSize: context.fs(11.5),
                    fontWeight: FontWeight.w500,
                    color: AppColors.error,
                  ),
                ),
              ),
            const SizedBox(height: 14),
          ],
        );
      },
    );
  }
}

/// Primary action button with navy gradient and right arrow.
class AuthActionButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? trailingIcon;
  final IconData? leadingIcon;
  final Gradient? gradient;

  const AuthActionButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.trailingIcon = Icons.arrow_forward_rounded,
    this.leadingIcon,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveGradient =
        gradient ??
        const LinearGradient(
          colors: [Color(0xFF0F3260), Color(0xFF0A2244), Color(0xFF061830)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        );

    return Container(
      height: 52,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: effectiveGradient,
        borderRadius: BorderRadius.circular(26),
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
          borderRadius: BorderRadius.circular(26),
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

/// Reusable helper to show Terms & Conditions or Privacy Policy dialog.
class TermsAndPrivacyModal {
  static void show(BuildContext context, {required bool isPrivacyPolicy}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          expand: false,
          builder: (_, scrollController) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: ListView(
                controller: scrollController,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    isPrivacyPolicy ? 'Privacy Policy' : 'Terms & Conditions',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isPrivacyPolicy
                        ? 'OPD Telemedicine is committed to protecting your privacy and confidential medical records. '
                              'All health documents, call histories, and consult notes are encrypted and securely stored. '
                              'Your data is never shared with third parties without your explicit consent.\n\n'
                              '1. Information Collection: We collect contact details, consultation logs, and medical files uploaded by you.\n'
                              '2. Usage: Collected information is used solely to provide telemedicine, diagnostic scheduling, and prescription services.\n'
                              '3. Security: All communications adhere to healthcare privacy compliance and end-to-end encryption.'
                        : 'Welcome to OPD Telemedicine. By registering for and using our platform, you agree to these Terms & Conditions:\n\n'
                              '1. Medical Consultation: Online consultations are provided by certified medical professionals. In medical emergencies, immediately contact emergency services or visit the nearest hospital.\n'
                              '2. Account Responsibility: You are responsible for keeping your credentials and card information secure.\n'
                              '3. Telemedicine Card: Subscription cards are strictly non-transferable and activated per individual/family policy terms.\n'
                              '4. Code of Conduct: Mutual respect and lawful communication with attending physicians and staff is mandatory.',
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: Color(0xFF657991),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F3260),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
