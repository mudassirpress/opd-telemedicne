import 'package:flutter/material.dart';
import 'package:intl_phone_number_input/intl_phone_number_input.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/auth/data/services/patient_password_reset_service.dart';

/// Value emitted whenever the phone number or country changes.
class InternationalPhoneValue {
  final String e164;
  final String nationalNumber;
  final String dialCode;
  final String isoCode;
  final bool isValid;

  const InternationalPhoneValue({
    required this.e164,
    required this.nationalNumber,
    required this.dialCode,
    required this.isoCode,
    required this.isValid,
  });

  @override
  String toString() => 'InternationalPhoneValue($e164, valid: $isValid)';
}

/// A metallic-styled international phone number input with a searchable country
/// selector (flags, names, dial codes), country code pill, and validation.
class InternationalPhoneInput extends StatefulWidget {
  final String? initialPhoneNumber;
  final String initialIsoCode;
  final String hintText;
  final bool enabled;
  final ValueChanged<InternationalPhoneValue>? onChanged;
  final ValueChanged<bool>? onValidated;
  final TextEditingController? controller;
  final String? Function(String?)? validator;
  final String? errorText;
  final bool showLabel;
  final String? labelText;

  const InternationalPhoneInput({
    super.key,
    this.initialPhoneNumber,
    this.initialIsoCode = 'PK',
    this.hintText = 'Phone Number',
    this.enabled = true,
    this.onChanged,
    this.onValidated,
    this.controller,
    this.validator,
    this.errorText,
    this.showLabel = false,
    this.labelText,
  });

  @override
  State<InternationalPhoneInput> createState() =>
      _InternationalPhoneInputState();
}

class _InternationalPhoneInputState extends State<InternationalPhoneInput> {
  late final TextEditingController _internalController;
  final GlobalKey<FormFieldState<String>> _fieldKey =
      GlobalKey<FormFieldState<String>>();

  TextEditingController get _effectiveController =>
      widget.controller ?? _internalController;

  PhoneNumber _currentNumber = PhoneNumber(isoCode: 'PK', dialCode: '+92');
  bool _isValid = false;

  @override
  void initState() {
    super.initState();
    _internalController = TextEditingController();

    _currentNumber = PhoneNumber(
      isoCode: widget.initialIsoCode.toUpperCase(),
      dialCode: widget.initialIsoCode.toUpperCase() == 'PK' ? '+92' : null,
    );

    _initFromInitialNumber();
  }

  Future<void> _initFromInitialNumber() async {
    final raw = widget.initialPhoneNumber;
    if (raw == null || raw.trim().isEmpty) return;

    final trimmed = raw.trim();
    // If it's a Pakistani local number like 03001234567
    if (trimmed.startsWith('03') && trimmed.length == 11) {
      _currentNumber = PhoneNumber(
        phoneNumber: '+92${trimmed.substring(1)}',
        isoCode: 'PK',
        dialCode: '+92',
      );
      _effectiveController.text = trimmed.substring(1);
    } else {
      try {
        final parsed = await PhoneNumber.getRegionInfoFromPhoneNumber(
          trimmed,
          widget.initialIsoCode,
        );
        if (mounted) {
          setState(() {
            _currentNumber = parsed;
            if (parsed.parseNumber().isNotEmpty) {
              _effectiveController.text = parsed.parseNumber();
            }
          });
        }
      } catch (_) {
        _effectiveController.text = trimmed;
      }
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _internalController.dispose();
    }
    super.dispose();
  }

  void _notify(PhoneNumber number) {
    _currentNumber = number;

    final dialCode = number.dialCode ?? '+92';
    final iso = number.isoCode ?? 'PK';
    var national = number.parseNumber().replaceAll(RegExp(r'\D'), '');

    // If national starts with a trunk 0 (e.g. 03... or 07...), strip for PK/UK
    if (national.startsWith('0') && national.length > 8) {
      national = national.substring(1);
    }

    // Canonical E.164 normalization
    final e164 =
        PatientPasswordResetService.normalizePhone(
          national,
          defaultDialCode: dialCode,
        ) ??
        (number.phoneNumber ?? '');

    // Validate using libphonenumber or fallback length check
    final valid = _isValid || RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(e164);

    final value = InternationalPhoneValue(
      e164: e164,
      nationalNumber: national,
      dialCode: dialCode,
      isoCode: iso,
      isValid: valid,
    );

    widget.onChanged?.call(value);
    widget.onValidated?.call(valid);
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
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 10),
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
                      Icons.phone_rounded,
                      color: hasError ? Colors.red : const Color(0xFF0E274D),
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: InternationalPhoneNumberInput(
                        onInputChanged: (PhoneNumber number) {
                          _notify(number);
                          fieldState.didChange(_effectiveController.text);
                        },
                        onInputValidated: (bool value) {
                          setState(() => _isValid = value);
                          widget.onValidated?.call(value);
                          fieldState.didChange(_effectiveController.text);
                        },
                        selectorConfig: const SelectorConfig(
                          selectorType: PhoneInputSelectorType.BOTTOM_SHEET,
                          showFlags: true,
                          useEmoji: true,
                          setSelectorButtonAsPrefixIcon: true,
                          leadingPadding: 0,
                          trailingSpace: false,
                        ),
                        ignoreBlank: false,
                        autoValidateMode: AutovalidateMode.disabled,
                        selectorTextStyle: TextStyle(
                          fontSize: context.fs(13.5),
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF163B6E),
                        ),
                        textStyle: TextStyle(
                          fontSize: context.fs(14),
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF1E2F44),
                        ),
                        initialValue: _currentNumber,
                        textFieldController: _effectiveController,
                        formatInput: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          signed: false,
                          decimal: false,
                        ),
                        inputBorder: InputBorder.none,
                        inputDecoration: InputDecoration(
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
                          errorStyle: const TextStyle(fontSize: 0, height: 0),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 12,
                          ),
                        ),
                        isEnabled: widget.enabled,
                        spaceBetweenSelectorAndTextField: 4,
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
