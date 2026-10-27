import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';
import 'package:telemedicine/data/models/user_model.dart';

UserModel createTestUser({
  required String id,
  required String fullname,
  required String role,
  String phoneNumber = '+923001234567',
  String? patientId,
  String? loginType,
  DateTime? expiryDate,
  String? paymentImage,
  String? paymentStatus,
}) {
  return UserModel(
    id: id,
    fullname: fullname,
    deviceId: 'test_device_id',
    idcard: '1234567890123',
    password: 'password123',
    token: 'test_token',
    role: role,
    phoneNumber: phoneNumber,
    ispayment: false,
    totalPayment: 0,
    patientId: patientId,
    loginType: loginType,
    expiryDate: expiryDate,
    paymentImage: paymentImage,
    paymentStatus: paymentStatus,
  );
}

void main() {
  group('1. Patient Card 12-Digit Validation Rules', () {
    test('12-digit Patient Card validation criteria', () {
      bool isValidCardId(String input) {
        final trimmed = input.trim();
        return trimmed.length == 12 && RegExp(r'^\d{12}$').hasMatch(trimmed);
      }

      // Valid 12 digits
      expect(isValidCardId('123456789012'), isTrue);
      expect(isValidCardId('000123456789'), isTrue);
      expect(isValidCardId('999999999999'), isTrue);

      // Invalid lengths
      expect(isValidCardId('12345678901'), isFalse); // 11 digits
      expect(isValidCardId('1234567890123'), isFalse); // 13 digits
      expect(isValidCardId(''), isFalse); // empty
      expect(isValidCardId('   '), isFalse);

      // Non-digit characters
      expect(isValidCardId('12345678901a'), isFalse);
      expect(isValidCardId('1234-5678-90'), isFalse);
      expect(isValidCardId('12345678901!'), isFalse);
    });
  });

  group('2. Doctor Login 4-Digit Validation Rules', () {
    test('4-digit Doctor ID validation criteria', () {
      bool isValidDoctorId(String input) {
        final trimmed = input.trim();
        return trimmed.length == 4 && RegExp(r'^\d{4}$').hasMatch(trimmed);
      }

      // Valid 4 digits
      expect(isValidDoctorId('1001'), isTrue);
      expect(isValidDoctorId('0001'), isTrue);
      expect(isValidDoctorId('9999'), isTrue);

      // Invalid lengths
      expect(isValidDoctorId('100'), isFalse); // 3 digits
      expect(isValidDoctorId('10001'), isFalse); // 5 digits
      expect(isValidDoctorId(''), isFalse);

      // Non-digit characters
      expect(isValidDoctorId('100a'), isFalse);
      expect(isValidDoctorId('10-1'), isFalse);
    });
  });

  group('3. Guest Mode Model & Routing', () {
    test('UserModel.guest() factory produces read-only guest identity', () {
      final guest = UserModel.guest();

      expect(guest.id, equals('guest_user'));
      expect(guest.role, equals('guest'));
      expect(guest.isGuest, isTrue);
      expect(guest.fullname, equals('Guest User'));
      expect(guest.phoneNumber, isEmpty);
      expect(guest.paymentStatus, isNull);
    });

    test('Regular patient is not identified as guest', () {
      final patient = createTestUser(
        id: 'patient_123',
        fullname: 'Ali Khan',
        role: 'patient',
      );

      expect(patient.isGuest, isFalse);
      expect(patient.role, equals('patient'));
    });

    test('Doctor is not identified as guest', () {
      final doctor = createTestUser(
        id: 'doc_123',
        fullname: 'Dr. Fatima',
        role: 'doctor',
      );

      expect(doctor.isGuest, isFalse);
    });

    test('AuthRoutingService routes Guest to chatRoom/portal directly', () {
      final guest = UserModel.guest();
      final destination = AuthRoutingService.evaluatePatientDestination(guest);

      expect(destination, equals(PatientAuthDestination.chatRoom));
    });

    test('AuthRoutingService routes Valid Patient Card to chatRoom', () {
      final validCardPatient = createTestUser(
        id: 'patient_card_user',
        fullname: 'Sara Ahmed',
        role: 'patient',
        patientId: '123456789012',
        loginType: 'patientId',
        expiryDate: DateTime.now().add(const Duration(days: 90)),
      );

      final destination = AuthRoutingService.evaluatePatientDestination(validCardPatient);
      expect(destination, equals(PatientAuthDestination.chatRoom));
    });

    test('AuthRoutingService routes Expired Patient Card to cardExpired', () {
      final expiredCardPatient = createTestUser(
        id: 'patient_card_user_exp',
        fullname: 'Sara Ahmed',
        role: 'patient',
        patientId: '123456789012',
        loginType: 'patientId',
        expiryDate: DateTime.now().subtract(const Duration(days: 5)),
      );

      final destination = AuthRoutingService.evaluatePatientDestination(expiredCardPatient);
      expect(destination, equals(PatientAuthDestination.cardExpired));
    });

    test('AuthRoutingService routes Phone Patient without payment proof to paymentProof', () {
      final phonePatient = createTestUser(
        id: 'patient_phone_new',
        fullname: 'Bilal Khan',
        role: 'patient',
        loginType: 'phone',
        paymentImage: null,
      );

      final destination = AuthRoutingService.evaluatePatientDestination(phonePatient);
      expect(destination, equals(PatientAuthDestination.paymentProof));
    });

    test('AuthRoutingService routes Approved Phone Patient to chatRoom', () {
      final approvedPhonePatient = createTestUser(
        id: 'patient_phone_approved',
        fullname: 'Bilal Khan',
        role: 'patient',
        loginType: 'phone',
        paymentImage: 'https://cloudinary.com/proof.jpg',
        paymentStatus: 'approved',
      );

      final destination = AuthRoutingService.evaluatePatientDestination(approvedPhonePatient);
      expect(destination, equals(PatientAuthDestination.chatRoom));
    });
  });

  group('4. Subscription Pricing & Calculator', () {
    test('Plans match requirements: 1M, 6M, 1Y', () {
      expect(SubscriptionPlan.oneMonth.durationMonths, equals(1));
      expect(SubscriptionPlan.sixMonths.durationMonths, equals(6));
      expect(SubscriptionPlan.oneYear.durationMonths, equals(12));
    });

    test('Calendar-safe expiry calculation for plans', () {
      final start = DateTime(2026, 1, 15, 12, 0);

      final expiry1M = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneMonth,
      );
      expect(expiry1M.year, equals(2026));
      expect(expiry1M.month, equals(2));
      expect(expiry1M.day, equals(15));

      final expiry6M = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.sixMonths,
      );
      expect(expiry6M.year, equals(2026));
      expect(expiry6M.month, equals(7));
      expect(expiry6M.day, equals(15));

      final expiry1Y = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneYear,
      );
      expect(expiry1Y.year, equals(2027));
      expect(expiry1Y.month, equals(1));
      expect(expiry1Y.day, equals(15));
    });
  });
}
