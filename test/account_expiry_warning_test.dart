// Tests for the account-expiry warning window and its frequency control.
//
// The date arithmetic is the part most likely to regress silently, so it is
// pinned here against the exact convention the app uses to grant validity:
//
//     expiry = DateTime(now.year, now.month + 6, now.day)
//
// (calendar months, NOT 180 days — which would drift across February and leap
// years and desynchronise the warning from the real expiry).

import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/account_expiry_service.dart';

/// Mirrors how the app actually grants a 6-month validity.
DateTime grantValidity(DateTime from) =>
    DateTime(from.year, from.month + AccountExpiry.validityMonths, from.day);

void main() {
  group('warningThresholdFor', () {
    test('opens exactly one calendar month before expiry', () {
      // Validity granted 2026-01-10 → expires 2026-07-10.
      final expiry = grantValidity(DateTime(2026, 1, 10));
      expect(expiry, DateTime(2026, 7, 10));

      // 5 of the 6 months elapsed on 2026-06-10.
      expect(
        AccountExpiryService.warningThresholdFor(expiry),
        DateTime(2026, 6, 10),
      );
    });

    test('matches a December grant that rolls into the next year', () {
      // 2026-12-05 + 6 months → 2027-06-05 (month overflow normalisation).
      final expiry = grantValidity(DateTime(2026, 12, 5));
      expect(expiry, DateTime(2027, 6, 5));
      expect(
        AccountExpiryService.warningThresholdFor(expiry),
        DateTime(2027, 5, 5),
      );
    });

    test('handles a grant that rolls back across a year boundary', () {
      // Expiry in January → threshold lands in the previous December.
      final expiry = DateTime(2027, 1, 15);
      expect(
        AccountExpiryService.warningThresholdFor(expiry),
        DateTime(2026, 12, 15),
      );
    });

    test('preserves the time-of-day component', () {
      final expiry = DateTime(2026, 7, 10, 14, 30, 45);
      expect(
        AccountExpiryService.warningThresholdFor(expiry),
        DateTime(2026, 6, 10, 14, 30, 45),
      );
    });
  });

  group('evaluate / isExpiringSoon', () {
    test('a null expiry date never warns', () {
      const status = PatientExpiryStatus.none();
      expect(status.hasExpiry, isFalse);
      expect(status.isExpired, isFalse);
      expect(status.isExpiringSoon, isFalse);
    });

    test('daysRemaining is ceil-divided so a partial day is not zero', () {
      // Expires 6 hours after the reference point.
      final now = DateTime(2026, 6, 10, 12);
      final status = AccountExpiryService.evaluate(
        expiryDate: now.add(const Duration(hours: 6)),
        now: now,
      );
      expect(status.daysRemaining, 1);
    });

    test('daysRemaining is negative once expired', () {
      final now = DateTime(2026, 6, 10, 12);
      final status = AccountExpiryService.evaluate(
        expiryDate: now.subtract(const Duration(days: 3)),
        now: now,
      );
      expect(status.daysRemaining, -3);
    });

    // 6-month validity granted 2026-01-10 → expires 2026-07-10,
    // warning window opens 2026-06-10.
    final granted = DateTime(2026, 1, 10);
    final expiry = grantValidity(granted);
    final threshold = AccountExpiryService.warningThresholdFor(expiry);

    PatientExpiryStatus on(DateTime when) =>
        AccountExpiryService.evaluate(expiryDate: expiry, now: when);

    test('is silent for the first four months of validity', () {
      expect(on(DateTime(2026, 1, 11)).isExpiringSoon, isFalse);
      expect(on(DateTime(2026, 3, 10)).isExpiringSoon, isFalse);
      expect(on(DateTime(2026, 5, 10)).isExpiringSoon, isFalse);
    });

    test('is still silent one second before the 5-month mark', () {
      expect(
        on(threshold.subtract(const Duration(seconds: 1))).isExpiringSoon,
        isFalse,
      );
    });

    test('opens exactly on the 5-month anniversary', () {
      expect(on(threshold).isExpiringSoon, isTrue);
      expect(
        on(threshold.add(const Duration(seconds: 1))).isExpiringSoon,
        isTrue,
      );
    });

    test('stays open through the final month', () {
      expect(on(DateTime(2026, 6, 20)).isExpiringSoon, isTrue);
      expect(
        on(expiry.subtract(const Duration(days: 1))).isExpiringSoon,
        isTrue,
      );
    });

    test('closes once the account is actually expired', () {
      // The expired case belongs to the existing expiry/logout flow — the
      // banner must not also claim the account "will expire soon".
      final expired = on(expiry.add(const Duration(seconds: 1)));
      expect(expired.isExpired, isTrue);
      expect(expired.isExpiringSoon, isFalse);
    });

    test('never warns for an account already past expiry at evaluation time', () {
      // Mirrors the real sign-in path: a validity that lapsed while the app was
      // closed must route to the expired flow, not the warning.
      final lapsed = grantValidity(
        DateTime.now().subtract(const Duration(days: 200)),
      );
      final status = AccountExpiryService.evaluate(expiryDate: lapsed);
      expect(status.isExpired, isTrue);
      expect(status.isExpiringSoon, isFalse);
    });
  });

  group('periodKeyFor', () {
    test('is stable within one validity period', () {
      final expiry = DateTime(2026, 7, 10, 9, 30);
      final a = AccountExpiryService.evaluate(expiryDate: expiry);
      final b = AccountExpiryService.evaluate(expiryDate: expiry);
      expect(a.periodKeyFor('user1'), b.periodKeyFor('user1'));
    });

    test('changes when reactivation grants a new expiry', () {
      final old = AccountExpiryService.evaluate(
        expiryDate: DateTime(2026, 7, 10),
      );
      final renewed = AccountExpiryService.evaluate(
        expiryDate: DateTime(2026, 12, 10),
      );
      expect(old.periodKeyFor('user1'), isNot(renewed.periodKeyFor('user1')));
    });

    test('differs per user so accounts cannot suppress each other', () {
      final status = AccountExpiryService.evaluate(
        expiryDate: DateTime(2026, 7, 10),
      );
      expect(status.periodKeyFor('user1'), isNot(status.periodKeyFor('user2')));
    });
  });

  group('describeRemaining', () {
    test('never renders a bare "in 0 days"', () {
      final status = PatientExpiryStatus(
        expiryDate: DateTime.now(),
        daysRemaining: 0,
      );
      expect(AccountExpiryService.describeRemaining(status), 'today');
    });

    test('formats day counts and falls back to a date past a month', () {
      expect(
        AccountExpiryService.describeRemaining(
          PatientExpiryStatus(expiryDate: DateTime.now(), daysRemaining: 12),
        ),
        'in 12 days',
      );
      expect(
        AccountExpiryService.describeRemaining(
          PatientExpiryStatus(
            expiryDate: DateTime(2030, 3, 4),
            daysRemaining: 90,
          ),
        ),
        'on 4/3/2030',
      );
    });

    test('is empty when there is no expiry', () {
      expect(
        AccountExpiryService.describeRemaining(
          const PatientExpiryStatus.none(),
        ),
        '',
      );
    });
  });
}
