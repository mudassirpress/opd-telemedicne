// test/subscription_lifecycle_test.dart
//
// COMPREHENSIVE UNIT TEST SUITE FOR 3 PATIENT CARD SUBSCRIPTION PLANS:
// 1 Month ('one_month'), 6 Months ('six_months'), 1 Year ('one_year')
//

import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/account_expiry_service.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';
import 'package:telemedicine/data/models/patient_id_model.dart';
import 'package:telemedicine/data/models/reactivation_request_model.dart';
import 'package:telemedicine/data/models/user_model.dart';

void main() {
  group('1. Safe Calendar Arithmetic & Month-End Clamping', () {
    test('1 Month plan: standard month addition preserves day', () {
      final start = DateTime(2026, 3, 15, 10, 30);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneMonth,
      );
      expect(expiry, DateTime(2026, 4, 15, 10, 30));
    });

    test('1 Month plan: month-end clamping (Jan 31 non-leap year -> Feb 28)', () {
      // Dart's native DateTime(2026, 1 + 1, 31) rolls over to March 3.
      // SubscriptionCalculator must clamp safely to Feb 28.
      final start = DateTime(2026, 1, 31, 14, 0);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneMonth,
      );
      expect(expiry, DateTime(2026, 2, 28, 14, 0));
    });

    test('1 Month plan: month-end clamping in leap year (Jan 31 2024 -> Feb 29)', () {
      final start = DateTime(2024, 1, 31, 12, 0);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneMonth,
      );
      expect(expiry, DateTime(2024, 2, 29, 12, 0));
    });

    test('1 Month plan: 31-day month to 30-day month (May 31 -> June 30)', () {
      final start = DateTime(2026, 5, 31);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneMonth,
      );
      expect(expiry, DateTime(2026, 6, 30));
    });

    test('6 Months plan: standard 6-month addition', () {
      final start = DateTime(2026, 2, 10, 9, 15);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.sixMonths,
      );
      expect(expiry, DateTime(2026, 8, 10, 9, 15));
    });

    test('6 Months plan: rolls into next year across boundary (July 10 -> Jan 10)', () {
      final start = DateTime(2026, 7, 10);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.sixMonths,
      );
      expect(expiry, DateTime(2027, 1, 10));
    });

    test('6 Months plan: month-end clamping (Aug 31 2026 -> Feb 28 2027)', () {
      final start = DateTime(2026, 8, 31, 18, 45);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.sixMonths,
      );
      expect(expiry, DateTime(2027, 2, 28, 18, 45));
    });

    test('6 Months plan: month-end clamping in leap year (Aug 31 2023 -> Feb 29 2024)', () {
      final start = DateTime(2023, 8, 31);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.sixMonths,
      );
      expect(expiry, DateTime(2024, 2, 29));
    });

    test('1 Year plan: standard 1-year addition', () {
      final start = DateTime(2026, 5, 20, 8, 0);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneYear,
      );
      expect(expiry, DateTime(2027, 5, 20, 8, 0));
    });

    test('1 Year plan: leap-day grant to non-leap year (Feb 29 2024 -> Feb 28 2025)', () {
      final start = DateTime(2024, 2, 29, 11, 20);
      final expiry = SubscriptionCalculator.calculateExpiry(
        start,
        plan: SubscriptionPlan.oneYear,
      );
      expect(expiry, DateTime(2025, 2, 28, 11, 20));
    });
  });

  group('2. Renewal Policy (Active vs Expired)', () {
    test('Renewing an ACTIVE subscription extends from existing expiry date', () {
      // Patient has 15 days left before expiry on 2026-06-30
      final currentExpiry = DateTime(2026, 6, 30, 12, 0);
      final now = DateTime(2026, 6, 15, 12, 0); // Still active

      // Patient renews with 1 Month plan
      final newExpiry1m = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: currentExpiry,
        now: now,
        durationMonths: 1,
      );
      // Must extend from currentExpiry (June 30 + 1 mo = July 30), NOT from now
      expect(newExpiry1m, DateTime(2026, 7, 30, 12, 0));

      // Patient renews with 6 Months plan
      final newExpiry6m = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: currentExpiry,
        now: now,
        durationMonths: 6,
      );
      // June 30 + 6 mo = Dec 30
      expect(newExpiry6m, DateTime(2026, 12, 30, 12, 0));

      // Patient renews with 1 Year plan
      final newExpiry1y = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: currentExpiry,
        now: now,
        durationMonths: 12,
      );
      expect(newExpiry1y, DateTime(2027, 6, 30, 12, 0));
    });

    test('Renewing an ALREADY EXPIRED subscription extends from new activation date (now)', () {
      // Patient expired 10 days ago on 2026-06-01
      final currentExpiry = DateTime(2026, 6, 1, 10, 0);
      final now = DateTime(2026, 6, 11, 14, 0); // Already expired

      final newExpiry1m = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: currentExpiry,
        now: now,
        durationMonths: 1,
      );
      // Must extend from now (June 11 + 1 mo = July 11), NOT from past expiry
      expect(newExpiry1m, DateTime(2026, 7, 11, 14, 0));

      final newExpiry6m = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: currentExpiry,
        now: now,
        durationMonths: 6,
      );
      expect(newExpiry6m, DateTime(2026, 12, 11, 14, 0));

      final newExpiry1y = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: currentExpiry,
        now: now,
        durationMonths: 12,
      );
      expect(newExpiry1y, DateTime(2027, 6, 11, 14, 0));
    });

    test('Renewing with null currentExpiry activates from now', () {
      final now = DateTime(2026, 4, 1, 10, 0);
      final newExpiry = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: null,
        now: now,
        durationMonths: 6,
      );
      expect(newExpiry, DateTime(2026, 10, 1, 10, 0));
    });
  });

  group('3. Dynamic Warning Windows for Each Plan', () {
    test('1 Month plan: opens exactly 7 days before expiry', () {
      final expiry = DateTime(2026, 5, 20, 12, 0);
      final threshold = SubscriptionCalculator.warningThresholdFor(
        expiry,
        durationMonths: 1,
      );
      expect(threshold, DateTime(2026, 5, 13, 12, 0));

      // 8 days before -> silent
      final status8Days = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2026, 5, 12, 12, 0),
        durationMonths: 1,
      );
      expect(status8Days.isExpiringSoon, isFalse);

      // 7 days before -> warning opens
      final status7Days = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2026, 5, 13, 12, 0),
        durationMonths: 1,
      );
      expect(status7Days.isExpiringSoon, isTrue);

      // 1 day before -> warning still open
      final status1Day = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2026, 5, 19, 12, 0),
        durationMonths: 1,
      );
      expect(status1Day.isExpiringSoon, isTrue);

      // At expiry or after -> expired, not expiring-soon
      final statusExpired = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2026, 5, 21, 12, 0),
        durationMonths: 1,
      );
      expect(statusExpired.isExpired, isTrue);
      expect(statusExpired.isExpiringSoon, isFalse);
    });

    test('6 Months plan: opens 1 calendar month before expiry', () {
      final expiry = DateTime(2026, 7, 10, 12, 0);
      final threshold = SubscriptionCalculator.warningThresholdFor(
        expiry,
        durationMonths: 6,
      );
      expect(threshold, DateTime(2026, 6, 10, 12, 0));

      final status2Months = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2026, 5, 10, 12, 0),
        durationMonths: 6,
      );
      expect(status2Months.isExpiringSoon, isFalse);

      final status1Month = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2026, 6, 10, 12, 0),
        durationMonths: 6,
      );
      expect(status1Month.isExpiringSoon, isTrue);
    });

    test('1 Year plan: opens 1 calendar month before expiry', () {
      final expiry = DateTime(2027, 4, 15, 10, 0);
      final threshold = SubscriptionCalculator.warningThresholdFor(
        expiry,
        durationMonths: 12,
      );
      expect(threshold, DateTime(2027, 3, 15, 10, 0));

      final status3Months = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2027, 1, 15, 10, 0),
        durationMonths: 12,
      );
      expect(status3Months.isExpiringSoon, isFalse);

      final statusInWindow = AccountExpiryService.evaluate(
        expiryDate: expiry,
        now: DateTime(2027, 3, 20, 10, 0),
        durationMonths: 12,
      );
      expect(statusInWindow.isExpiringSoon, isTrue);
    });
  });

  group('4. Models and Legacy Compatibility', () {
    test('PatientIdModel parses new subscription fields and falls back to 6 months for legacy', () {
      // Legacy record without subscriptionPlan
      final legacyModel = PatientIdModel.fromMap({
        'id': 'doc1',
        'patientId': '100000000001',
        'status': 'Available',
        'batchNumber': 'BATCH-001',
      });
      expect(legacyModel.subscriptionPlan, 'six_months');
      expect(legacyModel.durationMonths, 6);
      expect(legacyModel.plan, SubscriptionPlan.sixMonths);

      // 1 Month plan model
      final oneMonthModel = PatientIdModel.fromMap({
        'id': 'doc2',
        'patientId': '100000000002',
        'status': 'Available',
        'batchNumber': 'BATCH-002',
        'subscriptionPlan': 'one_month',
        'durationMonths': 1,
      });
      expect(oneMonthModel.subscriptionPlan, 'one_month');
      expect(oneMonthModel.durationMonths, 1);
      expect(oneMonthModel.plan, SubscriptionPlan.oneMonth);

      // 1 Year plan model
      final oneYearModel = PatientIdModel.fromMap({
        'id': 'doc3',
        'patientId': '100000000003',
        'status': 'Available',
        'batchNumber': 'BATCH-003',
        'subscriptionPlan': 'one_year',
        'durationMonths': 12,
      });
      expect(oneYearModel.subscriptionPlan, 'one_year');
      expect(oneYearModel.durationMonths, 12);
      expect(oneYearModel.plan, SubscriptionPlan.oneYear);

      // toMap includes subscriptionPlan and durationMonths
      final map = oneYearModel.toMap();
      expect(map['subscriptionPlan'], 'one_year');
      expect(map['durationMonths'], 12);
    });

    test('UserModel parses subscription plan and preserves legacy records safely', () {
      final legacyUser = UserModel.fromMap({
        'id': 'u1',
        'fullname': 'Legacy Patient',
        'patientId': '100000000001',
        'loginType': 'patientId',
        'expiryDate': DateTime(2026, 12, 1).toIso8601String(),
      });
      expect(legacyUser.subscriptionPlan, isNull);
      // Defaults to 6 months without failing
      expect(legacyUser.plan, SubscriptionPlan.sixMonths);
      expect(legacyUser.effectiveDurationMonths, 6);

      final userWithPlan = UserModel.fromMap({
        'id': 'u2',
        'fullname': '1 Month Patient',
        'patientId': '100000000002',
        'subscriptionPlan': 'one_month',
        'durationMonths': 1,
        'subscriptionStartDate': DateTime(2026, 1, 1).toIso8601String(),
        'expiryDate': DateTime(2026, 2, 1).toIso8601String(),
      });
      expect(userWithPlan.subscriptionPlan, 'one_month');
      expect(userWithPlan.durationMonths, 1);
      expect(userWithPlan.plan, SubscriptionPlan.oneMonth);
      expect(userWithPlan.effectiveDurationMonths, 1);
      expect(userWithPlan.subscriptionStartDate, DateTime(2026, 1, 1));
    });

    test('ReactivationRequestModel serializes and deserializes plan fields', () {
      final req = ReactivationRequestModel(
        id: 'r1',
        patientUserId: 'u1',
        patientId: '100000000001',
        patientName: 'Jane Doe',
        paymentProofUrl: 'https://example.com/receipt.jpg',
        status: 'pending',
        submittedAt: DateTime(2026, 5, 1),
        subscriptionPlan: 'one_year',
        durationMonths: 12,
      );
      expect(req.plan, SubscriptionPlan.oneYear);
      expect(req.effectiveDurationMonths, 12);

      final map = req.toMap();
      expect(map['subscriptionPlan'], 'one_year');
      expect(map['durationMonths'], 12);

      final fromMap = ReactivationRequestModel.fromMap(map);
      expect(fromMap.subscriptionPlan, 'one_year');
      expect(fromMap.durationMonths, 12);
    });
  });

  group('5. Access Control and Routing for 3 Subscription Plans', () {
    test('Active 1-Month patient routes to chatRoom', () {
      final user = UserModel(
        id: 'p1',
        fullname: 'Active User',
        deviceId: 'd1',
        idcard: '123',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234567',
        ispayment: false,
        totalPayment: 0,
        loginType: 'patientId',
        subscriptionPlan: 'one_month',
        durationMonths: 1,
        expiryDate: DateTime.now().add(const Duration(days: 15)),
      );
      expect(user.isExpired, isFalse);
      expect(
        AuthRoutingService.evaluatePatientDestination(user),
        PatientAuthDestination.chatRoom,
      );
    });

    test('Expired 1-Month patient routes to cardExpired (re-activation screen)', () {
      final user = UserModel(
        id: 'p1',
        fullname: 'Expired User',
        deviceId: 'd1',
        idcard: '123',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234567',
        ispayment: false,
        totalPayment: 0,
        loginType: 'patientId',
        subscriptionPlan: 'one_month',
        durationMonths: 1,
        expiryDate: DateTime.now().subtract(const Duration(days: 2)),
      );
      expect(user.isExpired, isTrue);
      expect(
        AuthRoutingService.evaluatePatientDestination(user),
        PatientAuthDestination.cardExpired,
      );
    });

    test('Active 1-Year patient routes to chatRoom', () {
      final user = UserModel(
        id: 'p2',
        fullname: 'Active Year User',
        deviceId: 'd2',
        idcard: '456',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234568',
        ispayment: false,
        totalPayment: 0,
        loginType: 'patientId',
        subscriptionPlan: 'one_year',
        durationMonths: 12,
        expiryDate: DateTime.now().add(const Duration(days: 300)),
      );
      expect(user.isExpired, isFalse);
      expect(
        AuthRoutingService.evaluatePatientDestination(user),
        PatientAuthDestination.chatRoom,
      );
    });

    test('Doctor and Admin roles are not blocked by subscription expiry', () {
      final doctor = UserModel(
        id: 'doc1',
        fullname: 'Dr. Smith',
        deviceId: 'd3',
        idcard: '789',
        password: 'pass',
        token: 'tok',
        role: 'doctor',
        phoneNumber: '+923001234569',
        ispayment: true,
        totalPayment: 0,
        expiryDate: DateTime.now().subtract(const Duration(days: 100)),
      );
      expect(doctor.isExpired, isFalse);

      final admin = UserModel(
        id: 'adm1',
        fullname: 'Admin User',
        deviceId: 'd4',
        idcard: '000',
        password: 'pass',
        token: 'tok',
        role: 'admin',
        phoneNumber: '+923001234570',
        ispayment: true,
        totalPayment: 0,
        expiryDate: DateTime.now().subtract(const Duration(days: 100)),
      );
      expect(admin.isExpired, isFalse);
    });
  });
}
