import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/auth/data/services/patient_password_reset_service.dart';

/// Client-side mirrors of the server rules. The server always re-validates,
/// so these exist purely for instant UI feedback — they must stay in lockstep
/// with `functions/password_reset_helpers.js`.
void main() {
  group('PatientPasswordResetService.normalizePkPhone', () {
    test('accepts every common Pakistani format', () {
      const expected = '+923451234567';
      expect(PatientPasswordResetService.normalizePkPhone('03451234567'), expected);
      expect(PatientPasswordResetService.normalizePkPhone('+923451234567'), expected);
      expect(PatientPasswordResetService.normalizePkPhone('923451234567'), expected);
      expect(PatientPasswordResetService.normalizePkPhone('00923451234567'), expected);
      expect(PatientPasswordResetService.normalizePkPhone('3451234567'), expected);
      expect(PatientPasswordResetService.normalizePkPhone(' 0345 123 4567 '), expected);
      expect(PatientPasswordResetService.normalizePkPhone('(0345) 123-4567'), expected);
    });

    test('rejects non-Pakistani and malformed numbers', () {
      expect(PatientPasswordResetService.normalizePkPhone(''), isNull);
      expect(PatientPasswordResetService.normalizePkPhone(null), isNull);
      expect(PatientPasswordResetService.normalizePkPhone('0345123456'), isNull);
      expect(PatientPasswordResetService.normalizePkPhone('034512345678'), isNull);
      expect(PatientPasswordResetService.normalizePkPhone('02131234567'), isNull);
      expect(PatientPasswordResetService.normalizePkPhone('+15551234567'), isNull);
      expect(PatientPasswordResetService.normalizePkPhone('abc'), isNull);
    });

    test('is consistent with the OTP delivery number format', () {
      // The E.164 value is what the backend hashes and what SendPK receives
      // (minus the `+`), so both sides must agree on the canonical form.
      final normalized = PatientPasswordResetService.normalizePkPhone('03356975643');
      expect(normalized, '+923356975643');
      expect(normalized!.replaceFirst('+', ''), '923356975643');
    });
  });

  group('PatientPasswordResetService.validateNewPassword', () {
    test('accepts strong passwords', () {
      expect(PatientPasswordResetService.validateNewPassword('Password1'), isNull);
      expect(PatientPasswordResetService.validateNewPassword('  Password1  '), isNull);
      expect(PatientPasswordResetService.validateNewPassword('abc12345'), isNull);
      expect(
        PatientPasswordResetService.validateNewPassword('A1${'a' * 62}'),
        isNull,
      );
    });

    test('rejects weak or malformed passwords with a message', () {
      expect(PatientPasswordResetService.validateNewPassword('Ab1'), isNotNull);
      expect(PatientPasswordResetService.validateNewPassword('abcdefgh'), isNotNull);
      expect(PatientPasswordResetService.validateNewPassword('12345678'), isNotNull);
      expect(PatientPasswordResetService.validateNewPassword('        '), isNotNull);
      expect(PatientPasswordResetService.validateNewPassword(''), isNotNull);
      expect(PatientPasswordResetService.validateNewPassword(null), isNotNull);
      expect(
        PatientPasswordResetService.validateNewPassword('A1${'a' * 70}'),
        isNotNull,
      );
    });

    test('matches the server policy boundaries exactly', () {
      // 8 chars with letter + digit → OK; 7 → rejected.
      expect(PatientPasswordResetService.validateNewPassword('Abc12de'), isNotNull);
      expect(PatientPasswordResetService.validateNewPassword('Abc12def'), isNull);
      // 64 chars → OK; 65 → rejected.
      expect(
        PatientPasswordResetService.validateNewPassword('A1${'a' * 62}'),
        isNull,
      );
      expect(
        PatientPasswordResetService.validateNewPassword('A1${'a' * 63}'),
        isNotNull,
      );
    });
  });

  group('PatientPasswordResetService.normalizePhone', () {
    test('normalizes international numbers to E.164', () {
      expect(PatientPasswordResetService.normalizePhone('+12025550123'), '+12025550123');
      expect(PatientPasswordResetService.normalizePhone('0012025550123'), '+12025550123');
      expect(PatientPasswordResetService.normalizePhone('2025550123', defaultDialCode: '+1'), '+12025550123');

      expect(PatientPasswordResetService.normalizePhone('+447911123456'), '+447911123456');
      expect(PatientPasswordResetService.normalizePhone('07911123456', defaultDialCode: '+44'), '+447911123456');

      expect(PatientPasswordResetService.normalizePhone('+971501234567'), '+971501234567');
      expect(PatientPasswordResetService.normalizePhone('0501234567', defaultDialCode: '+971'), '+971501234567');

      // Pakistani backwards compatibility
      expect(PatientPasswordResetService.normalizePhone('03001234567'), '+923001234567');
      expect(PatientPasswordResetService.normalizePhone('+923001234567'), '+923001234567');
      expect(PatientPasswordResetService.normalizePhone('3001234567', defaultDialCode: '+92'), '+923001234567');
    });

    test('rejects malformed numbers', () {
      expect(PatientPasswordResetService.normalizePhone(''), isNull);
      expect(PatientPasswordResetService.normalizePhone(null), isNull);
      expect(PatientPasswordResetService.normalizePhone('123'), isNull);
      expect(PatientPasswordResetService.normalizePhone('+0123456'), isNull);
    });

    test('produces correct lookup variants for international and PK numbers', () {
      final pkVariants = PatientPasswordResetService.phoneLookupVariants('+923001234567');
      expect(pkVariants, contains('03001234567'));
      expect(pkVariants, contains('+923001234567'));
      expect(pkVariants, contains('923001234567'));
      expect(pkVariants, contains('3001234567'));

      final usVariants = PatientPasswordResetService.phoneLookupVariants('+12025550123');
      expect(usVariants, contains('+12025550123'));
      expect(usVariants, contains('12025550123'));
      expect(usVariants, contains('0012025550123'));

      final ukVariants = PatientPasswordResetService.phoneLookupVariants('+447911123456');
      expect(ukVariants, contains('+447911123456'));
      expect(ukVariants, contains('447911123456'));
      expect(ukVariants, contains('07911123456'));
    });
  });

  group('PasswordResetException', () {
    test('rate-limit flag drives the resend countdown', () {
      const limited = PasswordResetException(
        PasswordResetException.rateLimited,
        'Too many requests.',
        resendInSeconds: 42,
      );
      expect(limited.isRateLimit, isTrue);
      expect(limited.resendInSeconds, 42);

      const invalidOtp = PasswordResetException(
        PasswordResetException.otpInvalid,
        'Invalid or expired code.',
      );
      expect(invalidOtp.isRateLimit, isFalse);
      expect(invalidOtp.resendInSeconds, isNull);
    });
  });
}
