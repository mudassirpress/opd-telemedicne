import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class CustomTextField extends StatefulWidget {
  final bool obscureText;
  final String? hintText;
  final String? labelText;
  final bool showSuffixIcon;
  final IconData prefixIcon;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final TextEditingController? controller;
  final double fontSize;
  final EdgeInsetsGeometry? contentPadding;
  final TextInputType? keyboardType;
  final bool readOnly;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  final double borderRadius;

  const CustomTextField({
    super.key,
    this.obscureText = false,
    this.hintText,
    this.labelText,
    this.showSuffixIcon = false,
    required this.prefixIcon,
    this.onChanged,
    this.validator,
    this.controller,
    this.fontSize = 14,
    this.contentPadding,
    this.keyboardType,
    this.readOnly = false,
    this.inputFormatters,
    this.enabled = true,
    this.borderRadius = 28,
  });

  @override
  State<CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<CustomTextField> {
  late bool isObscured;
  late final TextEditingController _internalController;
  final GlobalKey<FormFieldState<String>> _fieldKey =
      GlobalKey<FormFieldState<String>>();

  TextEditingController get _effectiveController =>
      widget.controller ?? _internalController;

  @override
  void initState() {
    super.initState();
    isObscured = widget.obscureText;
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
        final hasError = fieldState.hasError;
        final errorText = fieldState.errorText;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                color: Colors.white,
                border: Border.all(
                  color: hasError ? Colors.red : const Color(0xFFBAC7D8),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (hasError ? Colors.red : Colors.grey)
                        .withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: TextField(
                enabled: widget.enabled,
                readOnly: widget.readOnly,
                keyboardType: widget.keyboardType,
                controller: _effectiveController,
                inputFormatters: widget.inputFormatters,
                obscureText: widget.showSuffixIcon ? isObscured : false,
                onChanged: (val) {
                  fieldState.didChange(val);
                  widget.onChanged?.call(val);
                },
                style: TextStyle(
                  color: Colors.black,
                  fontSize: context.fs(widget.fontSize),
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.transparent,
                  hintText: widget.hintText,
                  labelText: widget.labelText,
                  hintStyle: TextStyle(
                    color: Colors.grey[400],
                    fontSize: context.fs(13),
                  ),
                  labelStyle: TextStyle(
                    color: Colors.grey[400],
                    fontSize: context.fs(13),
                  ),
                  prefixIcon: Icon(
                    widget.prefixIcon,
                    color: hasError ? Colors.red : AppColors.primaryRed,
                  ),
                  suffixIcon: widget.showSuffixIcon
                      ? IconButton(
                          onPressed: () {
                            setState(() {
                              isObscured = !isObscured;
                            });
                          },
                          icon: Icon(
                            isObscured
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: Colors.grey,
                          ),
                        )
                      : null,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorStyle: const TextStyle(fontSize: 0, height: 0),
                  contentPadding: widget.contentPadding ??
                      EdgeInsets.symmetric(
                        vertical: context.rsp(14),
                        horizontal: context.rsp(18),
                      ),
                ),
              ),
            ),
            if (hasError && errorText != null && errorText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 20, right: 20),
                child: Text(
                  errorText,
                  style: TextStyle(
                    color: Colors.red[700] ?? Colors.red,
                    fontSize: context.fs(12),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            SizedBox(height: context.rsp(16)),
          ],
        );
      },
    );
  }
}
