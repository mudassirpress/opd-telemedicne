import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/core/utils/phone_utils.dart';
import 'package:telemedicine/features/auth/data/services/phone_verification_service.dart';

void main() {
  group('PhoneUtils E.164 Normalization Tests', () {
    test('isValidE164 checks standard E.164 strings strictly', () {
      expect(PhoneUtils.isValidE164('+923001234567'), isTrue);
      expect(PhoneUtils.isValidE164('+12025550123'), isTrue);
      expect(PhoneUtils.isValidE164('+447911123456'), isTrue);
      expect(PhoneUtils.isValidE164('+971501234567'), isTrue);

      expect(PhoneUtils.isValidE164('03001234567'), isFalse);
      expect(PhoneUtils.isValidE164('923001234567'), isFalse);
      expect(PhoneUtils.isValidE164('+03001234567'), isFalse);
      expect(PhoneUtils.isValidE164('+123'), isFalse);
      expect(PhoneUtils.isValidE164(''), isFalse);
      expect(PhoneUtils.isValidE164(null), isFalse);
    });

    test('normalizePhone converts various Pakistani phone formats to +92 E.164', () {
      expect(PhoneUtils.normalizePhone('03001234567'), equals('+923001234567'));
      expect(PhoneUtils.normalizePhone('0300-1234567'), equals('+923001234567'));
      expect(PhoneUtils.normalizePhone('0300 1234567'), equals('+923001234567'));
      expect(PhoneUtils.normalizePhone('+92 300 1234567'), equals('+923001234567'));
      expect(PhoneUtils.normalizePhone('923001234567'), equals('+923001234567'));
      expect(PhoneUtils.normalizePhone('00923001234567'), equals('+923001234567'));
      expect(PhoneUtils.normalizePhone('3001234567'), equals('+923001234567'));
    });

    test('normalizePhone converts international phone numbers to E.164', () {
      expect(PhoneUtils.normalizePhone('+1 (202) 555-0123'), equals('+12025550123'));
      expect(PhoneUtils.normalizePhone('0012025550123'), equals('+12025550123'));
      expect(PhoneUtils.normalizePhone('+44 7911 123456'), equals('+447911123456'));
      expect(
        PhoneUtils.normalizePhone('07911123456', defaultDialCode: '+44'),
        equals('+447911123456'),
      );
    });

    test('phoneLookupVariants contains all historical database formats', () {
      final variants = PhoneUtils.phoneLookupVariants('+923001234567');
      expect(variants, contains('+923001234567'));
      expect(variants, contains('03001234567'));
      expect(variants, contains('923001234567'));
      expect(variants, contains('3001234567'));
    });

    test('maskPhone hides subscriber identity for logs and safe display', () {
      expect(PhoneUtils.maskPhone('+923001234567'), equals('+923***4567'));
      expect(PhoneUtils.maskPhone('03001234567'), equals('0300***4567'));
      expect(PhoneUtils.maskPhone('123'), equals('***'));
    });
  });

  group('PhoneAvailabilityResult model tests', () {
    test('available result factory initializes fields correctly', () {
      final res = PhoneAvailabilityResult.available('+923001234567');
      expect(res.isAvailable, isTrue);
      expect(res.isRegistered, isFalse);
      expect(res.normalizedPhone, equals('+923001234567'));
    });

    test('alreadyRegistered factory initializes fields correctly', () {
      final res = PhoneAvailabilityResult.alreadyRegistered(
        normalizedPhone: '+923001234567',
        role: 'patient',
        userId: 'p123',
        hasPatientId: true,
      );
      expect(res.isAvailable, isFalse);
      expect(res.isRegistered, isTrue);
      expect(res.role, equals('patient'));
      expect(res.userId, equals('p123'));
      expect(res.hasPatientId, isTrue);
      expect(res.message, contains('already registered'));
    });
  });

  group('SignInScreen pre-filled phone test', () {
    testWidgets('pre-fills phoneController when initialPhone is provided', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: SignInScreen(
              initialPhone: '03001234567',
              initialLoginMode: 0,
            ),
          ),
        ),
      );

      // Verify widget rendered
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.text('03001234567'), findsOneWidget);
    });
  });
}
