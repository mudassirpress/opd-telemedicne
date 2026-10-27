// lib/core/services/account_expiry_service.dart
//
// PATIENT ACCOUNT EXPIRY WARNING
// ==============================
//
// A Patient ID is valid for 6 calendar months. Once 5 of those months have
// elapsed — i.e. inside the final calendar month — the patient is warned that
// the account is about to expire and is offered a direct route into the
// existing reactivation / payment-proof flow.
//
// Two things this file is careful about:
//
//   1. THE EXPIRY ITSELF IS NOT THIS FILE'S JOB. The 6-month expiry, the
//      automatic logout and `UserModel.isExpired` are the existing contract and
//      are left untouched. This only *reads* the same authoritative expiry date
//      to decide whether the warning window is open.
//
//   2. THE WARNING MUST NOT NAG. The account is still fully valid during the
//      warning window, so a modal on every screen would be hostile. Two layers
//      are used, both rate-limited by a SharedPreferences marker keyed on
//      userId + expiryDate:
//        • a dismissible in-app banner (dismissible for the session), and
//        • a single heads-up toast per warning period.
//      Because the marker embeds the expiry date, an admin reactivation that
//      issues a new 6-month period automatically re-arms the warning — no
//      manual reset, and no stale "already warned" suppression.

import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';

/// Immutable snapshot of a patient's account validity at a point in time.
class PatientExpiryStatus {
  /// Authoritative expiry date, or `null` when the account has no time-based
  /// validity (e.g. a normal, non Patient-ID patient). Fails open: no date
  /// means nothing to warn about.
  final DateTime? expiryDate;

  /// Whole days until [expiryDate]. Negative once expired, `null` when there is
  /// no expiry date.
  final int? daysRemaining;

  /// The instant this status was evaluated against.
  ///
  /// Held rather than calling the clock on every read so [isExpired] and
  /// [isExpiringSoon] are deterministic and directly testable; `null` in
  /// practice (constructed via [AccountExpiryService.evaluate]) means "use the
  /// real clock".
  final DateTime? evaluatedAt;

  /// Duration in months of the patient's assigned subscription plan.
  final int durationMonths;

  const PatientExpiryStatus({
    this.expiryDate,
    this.daysRemaining,
    this.evaluatedAt,
    this.durationMonths = 6,
  });

  /// Factory for the "no validity period" case.
  const PatientExpiryStatus.none()
    : expiryDate = null,
      daysRemaining = null,
      evaluatedAt = null,
      durationMonths = 6;

  DateTime get _now => evaluatedAt ?? DateTime.now();

  bool get hasExpiry => expiryDate != null;

  /// The account has passed its expiry date. Mirrors `UserModel.isExpired`
  /// semantics; the caller still owns the actual expiry/logout behaviour.
  bool get isExpired => expiryDate != null && _now.isAfter(expiryDate!);

  /// Inside the warning window: validity is running out but has not ended.
  ///
  /// Strictly excludes the already-expired case — an expired patient is handled
  /// by the existing expiry/logout flow and must not also be nagged with a
  /// "will expire soon" banner.
  bool get isExpiringSoon =>
      hasExpiry &&
      !isExpired &&
      !_now.isBefore(
        AccountExpiryService.warningThresholdFor(
          expiryDate!,
          durationMonths: durationMonths,
        ),
      );

  /// Stable identity for the current warning period. Two evaluations of the
  /// same account within the same validity period produce the same key, which
  /// is what makes once-per-period de-duplication work.
  String periodKeyFor(String userId) {
    if (expiryDate == null) return '$userId:no-expiry';
    return '$userId@${expiryDate!.toIso8601String()}';
  }
}

class AccountExpiryService {
  const AccountExpiryService._();

  /// The instant the warning window opens for a given expiry date and subscription plan duration.
  ///
  /// - For 1 Month plan (duration <= 1 month): opens 7 days before expiry.
  /// - For 6 Months & 1 Year plans: opens 1 calendar month before expiry.
  static DateTime warningThresholdFor(
    DateTime expiryDate, {
    int durationMonths = 6,
  }) {
    return SubscriptionCalculator.warningThresholdFor(
      expiryDate,
      durationMonths: durationMonths,
    );
  }

  /// Evaluates an expiry date into a [PatientExpiryStatus].
  ///
  /// `now` is injectable so the arithmetic can be tested without waiting for
  /// real time to pass.
  static PatientExpiryStatus evaluate({
    required DateTime? expiryDate,
    DateTime? now,
    int durationMonths = 6,
  }) {
    if (expiryDate == null) return const PatientExpiryStatus.none();

    final reference = now ?? DateTime.now();
    // Ceiling division so "expires later today" reports 1 day, not 0.
    final days = expiryDate.difference(reference).inHours;
    final daysRemaining = (days / 24).ceil();

    return PatientExpiryStatus(
      expiryDate: expiryDate,
      daysRemaining: daysRemaining,
      evaluatedAt: reference,
      durationMonths: durationMonths,
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // Frequency control
  // ───────────────────────────────────────────────────────────────────────

  /// Whether the one-time heads-up warning should fire for [status].
  ///
  /// Returns false when: there is no expiry, the account is not in the warning
  /// window, a reactivation is already pending review (nagging someone whose
  /// proof is already in the queue is pointless), or this exact warning period
  /// has already produced a toast.
  static Future<bool> shouldWarn({
    required PatientExpiryStatus status,
    required String userId,
    bool hasPendingReactivation = false,
  }) async {
    if (userId.isEmpty) return false;
    if (!status.isExpiringSoon) return false;
    if (hasPendingReactivation) return false;

    final warnedPeriod = await _readWarnedPeriod();
    return warnedPeriod != status.periodKeyFor(userId);
  }

  /// Records that the warning has been shown for this period.
  static Future<void> markWarned({
    required PatientExpiryStatus status,
    required String userId,
  }) async {
    if (!status.hasExpiry) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AccountExpiry.warnedPeriodKey,
        status.periodKeyFor(userId),
      );
    } catch (e) {
      // Never let frequency-tracking bookkeeping break the app; the worst case
      // is a repeated toast.
      return;
    }
  }

  /// Whether the banner was dismissed in this session.
  ///
  /// Deliberately session-scoped (in-memory) rather than persisted: the patient
  /// chose to dismiss it, but a fresh app launch is a new session and the
  /// banner is worth showing again while the account is still in the warning
  /// window. The persistent once-per-period rule belongs to the toast, not the
  /// banner.
  static final Set<String> _dismissedBannerPeriods = {};

  static bool isBannerDismissed(PatientExpiryStatus status, String userId) {
    return _dismissedBannerPeriods.contains(status.periodKeyFor(userId));
  }

  static void dismissBanner(PatientExpiryStatus status, String userId) {
    _dismissedBannerPeriods.add(status.periodKeyFor(userId));
  }

  /// Clears session state for sign-out / account switch.
  static void resetSessionState() {
    _dismissedBannerPeriods.clear();
  }

  static Future<String?> _readWarnedPeriod() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(AccountExpiry.warnedPeriodKey);
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // Formatting
  // ───────────────────────────────────────────────────────────────────────

  /// Short, human phrasing of the remaining validity for the banner.
  ///
  /// Falls back to a date when the remainder is under a day, so the banner
  /// never reads "expires in 0 days" on the expiry day itself.
  static String describeRemaining(PatientExpiryStatus status) {
    final days = status.daysRemaining;
    if (days == null) return '';

    if (days <= 0) return 'today';
    if (days == 1) return 'tomorrow';
    if (days < 31) return 'in $days days';

    final expiry = status.expiryDate!;
    return 'on ${expiry.day}/${expiry.month}/${expiry.year}';
  }
}
