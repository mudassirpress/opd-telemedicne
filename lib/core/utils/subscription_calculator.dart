// lib/core/utils/subscription_calculator.dart

/// The three supported patient card subscription plans.
enum SubscriptionPlan {
  oneMonth('one_month', 1, '1 Month', 300.0),
  sixMonths('six_months', 6, '6 Months', 1000.0),
  oneYear('one_year', 12, '1 Year', 1500.0);

  final String planId;
  final int durationMonths;
  final String displayName;
  final double amount;

  const SubscriptionPlan(
    this.planId,
    this.durationMonths,
    this.displayName,
    this.amount,
  );

  /// Resolves a [SubscriptionPlan] from a string plan ID.
  /// Defaults to [SubscriptionPlan.sixMonths] for legacy backwards compatibility.
  static SubscriptionPlan fromPlanId(String? planId) {
    if (planId == null) return SubscriptionPlan.sixMonths;
    switch (planId.toLowerCase().trim()) {
      case 'one_month':
      case '1_month':
      case '1month':
      case 'one month':
        return SubscriptionPlan.oneMonth;
      case 'one_year':
      case '1_year':
      case '1year':
      case '12_months':
      case 'one year':
        return SubscriptionPlan.oneYear;
      case 'six_months':
      case '6_months':
      case '6months':
      case 'six months':
      default:
        return SubscriptionPlan.sixMonths;
    }
  }

  /// Resolves a [SubscriptionPlan] from a duration in months.
  static SubscriptionPlan fromDurationMonths(int? months) {
    if (months == null) return SubscriptionPlan.sixMonths;
    if (months <= 1) return SubscriptionPlan.oneMonth;
    if (months >= 12) return SubscriptionPlan.oneYear;
    return SubscriptionPlan.sixMonths;
  }
}

/// Provides safe calendar arithmetic for subscription lifecycles,
/// month-end clamping, leap-year calculations, renewal extension policies,
/// and dynamic warning thresholds.
class SubscriptionCalculator {
  const SubscriptionCalculator._();

  /// Adds [monthsToAdd] calendar months to [from], strictly clamping the day of month
  /// to the last valid day of the target month.
  ///
  /// For example:
  /// - Jan 31 + 1 month in 2026 -> Feb 28, 2026
  /// - Jan 31 + 1 month in 2024 (leap year) -> Feb 29, 2024
  /// - Feb 29, 2024 + 1 year (12 months) -> Feb 28, 2025
  /// - Aug 31, 2026 + 6 months -> Feb 28, 2027
  ///
  /// This prevents Dart's native `DateTime(year, month + n, day)` overflow
  /// which rolls excess days into the following month (e.g. Jan 31 + 1 month -> Mar 3).
  static DateTime addCalendarMonths(DateTime from, int monthsToAdd) {
    final int totalMonths = from.year * 12 + (from.month - 1) + monthsToAdd;
    final int targetYear = totalMonths ~/ 12;
    final int targetMonth = (totalMonths % 12) + 1;

    // In Dart, day 0 of (targetMonth + 1) is the last day of targetMonth.
    final int daysInTargetMonth = DateTime(targetYear, targetMonth + 1, 0).day;
    final int targetDay = from.day > daysInTargetMonth ? daysInTargetMonth : from.day;

    return DateTime(
      targetYear,
      targetMonth,
      targetDay,
      from.hour,
      from.minute,
      from.second,
      from.millisecond,
      from.microsecond,
    );
  }

  /// Calculates expiry date from [activationDate] for the specified [plan] or [durationMonths].
  static DateTime calculateExpiry(
    DateTime activationDate, {
    SubscriptionPlan? plan,
    int? durationMonths,
  }) {
    final int months = durationMonths ?? plan?.durationMonths ?? 6;
    return addCalendarMonths(activationDate, months);
  }

  /// Calculates renewal expiry according to the standard renewal policy:
  /// - If [currentExpiry] is active ([now] is strictly before [currentExpiry]),
  ///   the subscription is extended from [currentExpiry].
  /// - If the subscription has already expired ([now] is at or after [currentExpiry]
  ///   or [currentExpiry] is null), it is activated afresh starting from [now].
  static DateTime calculateRenewalExpiry({
    required DateTime? currentExpiry,
    required DateTime now,
    required int durationMonths,
  }) {
    final bool isStillActive = currentExpiry != null && now.isBefore(currentExpiry);
    final DateTime baseDate = isStillActive ? currentExpiry : now;
    return addCalendarMonths(baseDate, durationMonths);
  }

  /// Calculates the warning threshold before [expiryDate] for a given [durationMonths].
  ///
  /// - 1 Month plan (duration <= 1 month): warn 7 days before expiry.
  /// - 6 Months & 1 Year plans: warn 1 calendar month (or 30 days) before expiry.
  static DateTime warningThresholdFor(
    DateTime expiryDate, {
    int durationMonths = 6,
  }) {
    if (durationMonths <= 1) {
      return expiryDate.subtract(const Duration(days: 7));
    }
    return addCalendarMonths(expiryDate, -1);
  }
}
