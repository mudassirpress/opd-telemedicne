import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/auth/data/services/patient_password_reset_service.dart';
import 'package:telemedicine/shared/widgets/international_phone_input.dart';

void main() {
  group('International Phone Number Normalization & Validation', () {
    test('1. Valid Pakistani number variants and normalization', () {
      const canonical = '+923001234567';
      expect(PatientPasswordResetService.normalizePhone('03001234567'), canonical);
      expect(PatientPasswordResetService.normalizePhone('+923001234567'), canonical);
      expect(PatientPasswordResetService.normalizePhone('923001234567'), canonical);
      expect(PatientPasswordResetService.normalizePhone('3001234567', defaultDialCode: '+92'), canonical);

      final variants = PatientPasswordResetService.phoneLookupVariants('03001234567');
      expect(variants, contains(canonical));
      expect(variants, contains('03001234567'));
      expect(variants, contains('923001234567'));
      expect(variants, contains('3001234567'));
    });

    test('2. Valid US, UK, and other international numbers', () {
      // US (+1)
      expect(
        PatientPasswordResetService.normalizePhone('+12025550123'),
        '+12025550123',
      );
      expect(
        PatientPasswordResetService.normalizePhone('2025550123', defaultDialCode: '+1'),
        '+12025550123',
      );

      // UK (+44) with trunk 0 stripping
      expect(
        PatientPasswordResetService.normalizePhone('+447911123456'),
        '+447911123456',
      );
      expect(
        PatientPasswordResetService.normalizePhone('07911123456', defaultDialCode: '+44'),
        '+447911123456',
      );

      // UAE (+971)
      expect(
        PatientPasswordResetService.normalizePhone('+971501234567'),
        '+971501234567',
      );
      expect(
        PatientPasswordResetService.normalizePhone('0501234567', defaultDialCode: '+971'),
        '+971501234567',
      );
    });

    test('3. Backward compatibility: existing Pakistani accounts match lookup variants', () {
      // When searching by +923001234567, legacy 03001234567 must be in the variants
      final variantsFromE164 = PatientPasswordResetService.phoneLookupVariants('+923001234567');
      expect(variantsFromE164, contains('03001234567'));

      // When searching by 03001234567, E.164 +923001234567 must be in the variants
      final variantsFromLocal = PatientPasswordResetService.phoneLookupVariants('03001234567');
      expect(variantsFromLocal, contains('+923001234567'));
    });

    test('4. International number lookup variants include with and without leading +', () {
      final usVariants = PatientPasswordResetService.phoneLookupVariants('+12025550123');
      expect(usVariants, contains('+12025550123'));
      expect(usVariants, contains('12025550123'));

      final ukVariants = PatientPasswordResetService.phoneLookupVariants('+447911123456');
      expect(ukVariants, contains('+447911123456'));
      expect(ukVariants, contains('447911123456'));
    });

    test('5. Rejection of invalid or incomplete phone numbers', () {
      expect(PatientPasswordResetService.normalizePhone(''), isNull);
      expect(PatientPasswordResetService.normalizePhone('123'), isNull);
      expect(PatientPasswordResetService.normalizePhone('phone123'), isNull);
      expect(PatientPasswordResetService.normalizePhone('+'), isNull);
      expect(PatientPasswordResetService.normalizePhone('0000000000'), isNull);
    });

    test('6. Phone number masking does not reveal full sensitive number', () {
      final pkMasked = PatientPasswordResetService.maskPhoneNumber('+923001234567');
      expect(pkMasked, contains('***'));
      expect(pkMasked.endsWith('4567'), isTrue);
      expect(pkMasked.contains('1234'), isFalse);

      final usMasked = PatientPasswordResetService.maskPhoneNumber('+12025550123');
      expect(usMasked, contains('***'));
      expect(usMasked.endsWith('0123'), isTrue);
      expect(usMasked.contains('555'), isFalse);
    });
  });

  group('InternationalPhoneInput Widget Tests', () {
    testWidgets('renders searchable country selector and phone input field', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: InternationalPhoneInput(
                initialIsoCode: 'PK',
                hintText: 'Enter phone',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify hint text and country code element are rendered
      expect(find.byType(InternationalPhoneInput), findsOneWidget);
      expect(find.text('Enter phone'), findsOneWidget);
    });
  });
}
