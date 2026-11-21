// lib/core/services/card_rate_limiter_service.dart

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service protecting Patient Scratch Card verification against brute-force / guessing attacks.
/// Enforces client-side rate-limiting and temporary account lockout on repeated failed attempts.
class CardRateLimiterService {
  CardRateLimiterService._();
  static final CardRateLimiterService instance = CardRateLimiterService._();

  static const String _keyFailedAttempts = 'card_verify_failed_attempts';
  static const String _keyLockedUntil = 'card_verify_locked_until';
  static const String _keyLastAttempt = 'card_verify_last_attempt';

  /// Maximum failed card verification attempts before temporary lockout.
  static const int maxFailedAttempts = 5;

  /// Lockout duration when max attempts are exceeded (15 minutes).
  static const Duration lockoutDuration = Duration(minutes: 15);

  /// Inactivity timeout after which the failed attempts counter resets (1 hour).
  static const Duration attemptResetTimeout = Duration(hours: 1);

  /// Checks if card verification is currently locked out.
  Future<bool> isLockedOut() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lockedUntilMs = prefs.getInt(_keyLockedUntil) ?? 0;
      if (lockedUntilMs <= 0) return false;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now < lockedUntilMs) {
        return true;
      } else {
        // Lockout expired: clear lockout timestamp and reset failed attempts
        await prefs.remove(_keyLockedUntil);
        await prefs.setInt(_keyFailedAttempts, 0);
        return false;
      }
    } catch (e) {
      debugPrint('⚠️ [CardRateLimiter] isLockedOut error: $e');
      return false;
    }
  }

  /// Returns remaining lockout time in minutes (minimum 1 minute if locked).
  Future<int> getRemainingLockoutMinutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lockedUntilMs = prefs.getInt(_keyLockedUntil) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (lockedUntilMs > now) {
        final diffSeconds = (lockedUntilMs - now) ~/ 1000;
        final minutes = (diffSeconds / 60).ceil();
        return minutes > 0 ? minutes : 1;
      }
    } catch (_) {}
    return 0;
  }

  /// Returns how many remaining attempts the user has before being locked out.
  Future<int> getRemainingAttempts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _checkInactivityReset(prefs);

      final current = prefs.getInt(_keyFailedAttempts) ?? 0;
      final remaining = maxFailedAttempts - current;
      return remaining > 0 ? remaining : 0;
    } catch (_) {
      return maxFailedAttempts;
    }
  }

  /// Records a failed card verification attempt.
  /// Returns the updated remaining attempts (or 0 if locked out).
  Future<int> recordFailedAttempt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _checkInactivityReset(prefs);

      int attempts = (prefs.getInt(_keyFailedAttempts) ?? 0) + 1;
      await prefs.setInt(_keyFailedAttempts, attempts);
      await prefs.setInt(_keyLastAttempt, DateTime.now().millisecondsSinceEpoch);

      debugPrint('🛡️ [CardRateLimiter] Failed card attempt #$attempts of $maxFailedAttempts');

      if (attempts >= maxFailedAttempts) {
        final lockedUntil = DateTime.now().add(lockoutDuration).millisecondsSinceEpoch;
        await prefs.setInt(_keyLockedUntil, lockedUntil);
        debugPrint('🔒 [CardRateLimiter] Too many failed attempts. Locked out for ${lockoutDuration.inMinutes} minutes.');
        return 0;
      }

      return maxFailedAttempts - attempts;
    } catch (e) {
      debugPrint('⚠️ [CardRateLimiter] recordFailedAttempt error: $e');
      return maxFailedAttempts;
    }
  }

  /// Resets all failed attempts on successful card verification.
  Future<void> recordSuccess() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyFailedAttempts);
      await prefs.remove(_keyLockedUntil);
      await prefs.remove(_keyLastAttempt);
      debugPrint('✅ [CardRateLimiter] Card verified successfully. Rate limit counter reset.');
    } catch (e) {
      debugPrint('⚠️ [CardRateLimiter] recordSuccess error: $e');
    }
  }

  void _checkInactivityReset(SharedPreferences prefs) {
    final lastAttemptMs = prefs.getInt(_keyLastAttempt) ?? 0;
    if (lastAttemptMs > 0) {
      final lastAttempt = DateTime.fromMillisecondsSinceEpoch(lastAttemptMs);
      if (DateTime.now().difference(lastAttempt) > attemptResetTimeout) {
        prefs.remove(_keyFailedAttempts);
        prefs.remove(_keyLockedUntil);
      }
    }
  }
}

