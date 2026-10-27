/// Shared E.164 phone normalization, formatting, and validation utilities.
class PhoneUtils {
  PhoneUtils._();

  /// Validates whether [phone] is in strict canonical E.164 format:
  /// `+` followed by country code and subscriber number (8 to 15 digits total, no leading 0 after +).
  static bool isValidE164(String? phone) {
    if (phone == null) return false;
    final trimmed = phone.trim();
    return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(trimmed);
  }

  /// Normalises a Pakistani mobile number to standard E.164 `+923XXXXXXXXX`.
  /// Returns null when the input is not a valid Pakistani mobile number.
  static String? normalizePkPhone(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 32) return null;
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty || digits.length > 15) return null;

    String national;
    if (digits.startsWith('0092')) {
      national = digits.substring(4);
    } else if (digits.startsWith('92') && digits.length >= 12) {
      national = digits.substring(2);
    } else if (digits.startsWith('0')) {
      national = digits.substring(1);
    } else {
      national = digits;
    }
    if (!RegExp(r'^3\d{9}$').hasMatch(national)) return null;
    return '+92$national';
  }

  /// Normalises any international or Pakistani phone number to standard E.164.
  ///
  /// Supported formats:
  ///   - Pakistani mobile: `03001234567`, `+923001234567`, `923001234567`, `00923001234567`
  ///   - International with plus: `+12025550123`, `+447911123456`
  ///   - International with 00: `0012025550123` -> `+12025550123`
  ///   - National + dialCode: e.g. dialCode: `+1`, input: `2025550123` -> `+12025550123`
  static String? normalizePhone(String? raw, {String? defaultDialCode = '+92'}) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return null;

    // Check if it's already a valid Pakistani mobile
    final pk = normalizePkPhone(trimmed);
    if (pk != null) return pk;

    var cleaned = trimmed.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
    if (cleaned.startsWith('00')) {
      cleaned = '+${cleaned.substring(2)}';
    }

    if (cleaned.startsWith('+')) {
      final digits = cleaned.substring(1).replaceAll(RegExp(r'\D'), '');
      if (RegExp(r'^[1-9]\d{6,14}$').hasMatch(digits)) {
        if (digits.startsWith('92')) {
          final pkCheck = normalizePkPhone('+$digits');
          if (pkCheck != null) return pkCheck;
        }
        return '+$digits';
      }
      return null;
    }

    if (defaultDialCode != null && defaultDialCode.isNotEmpty) {
      final dialDigits = defaultDialCode.replaceAll(RegExp(r'\D'), '');
      var nationalDigits = cleaned.replaceAll(RegExp(r'\D'), '');
      if (dialDigits.isNotEmpty && nationalDigits.isNotEmpty) {
        if (nationalDigits.startsWith('0') && nationalDigits.length > 7) {
          nationalDigits = nationalDigits.substring(1);
        }
        if (nationalDigits.startsWith(dialDigits) &&
            nationalDigits.length > dialDigits.length + 5) {
          final candidate = '+$nationalDigits';
          if (RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(candidate)) return candidate;
        }
        final candidate = '+$dialDigits$nationalDigits';
        if (RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(candidate)) {
          if (dialDigits == '92') return normalizePkPhone(candidate);
          return candidate;
        }
      }
    }

    final onlyDigits = cleaned.replaceAll(RegExp(r'\D'), '');
    if (RegExp(r'^[1-9]\d{7,14}$').hasMatch(onlyDigits)) {
      if (onlyDigits.startsWith('923') && onlyDigits.length == 12) {
        return '+$onlyDigits';
      }
      if (onlyDigits.length >= 10) {
        return '+$onlyDigits';
      }
    }
    return null;
  }

  /// Returns historical string variants used in database documents.
  static List<String> phoneLookupVariants(String raw, {String? defaultDialCode = '+92'}) {
    final normalized = normalizePhone(raw, defaultDialCode: defaultDialCode) ?? raw.trim();
    if (normalized.startsWith('+92')) {
      final national = normalized.replaceFirst('+92', '');
      return [
        '0$national',
        normalized,
        '92$national',
        national,
      ];
    }
    final digits = normalized.replaceFirst('+', '').replaceAll(RegExp(r'\D'), '');
    final variants = <String>[
      normalized,
      digits,
      '00$digits',
    ];
    if (normalized.startsWith('+44') && digits.length >= 11) {
      variants.add('0${digits.substring(2)}');
    } else if (normalized.startsWith('+971') && digits.length >= 11) {
      variants.add('0${digits.substring(3)}');
    }
    return variants.toSet().toList();
  }

  /// Masks a phone number for UI privacy and logs (e.g. `+923***4567`).
  static String maskPhone(String phone) {
    if (phone.length <= 6) return '***';
    final start = phone.length > 8 ? 4 : 2;
    return '${phone.substring(0, start)}***${phone.substring(phone.length - 4)}';
  }
}
