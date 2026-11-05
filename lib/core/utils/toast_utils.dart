import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:telemedicine/app/theme/app_theme.dart';

class ToastService {
  static ToastService? _instance;

  // Private constructor
  ToastService._internal();

  // Singleton instance
  static ToastService get instance {
    _instance ??= ToastService._internal();
    return _instance!;
  }

  String? _lastMessage;
  DateTime? _lastMessageTime;
  static const Duration _throttleDuration = Duration(milliseconds: 1800);

  bool _isThrottled(String msg) {
    final now = DateTime.now();
    if (_lastMessage == msg && _lastMessageTime != null) {
      if (now.difference(_lastMessageTime!) < _throttleDuration) {
        return true;
      }
    }
    _lastMessage = msg;
    _lastMessageTime = now;
    return false;
  }

  /// Sanitizes raw exceptions, SDK error codes, and technical stack traces
  /// so end users never see developer-internal details.
  String sanitizeErrorMessage(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return 'An unexpected error occurred. Please try again.';
    }
    final trimmed = raw.trim();
    final lower = trimmed.toLowerCase();

    // Already user-friendly call states
    if (trimmed == 'Call ended' ||
        trimmed == 'Call declined' ||
        trimmed == 'Call failed. Please try again.' ||
        trimmed == 'Call disconnected' ||
        trimmed == 'Line is busy' ||
        trimmed == 'The call was cancelled.' ||
        trimmed == 'Call timed out') {
      return trimmed;
    }

    // Call status mappings
    if (lower.contains('declined') || lower.contains('rejected')) {
      return 'Call declined';
    }
    if (lower.contains('busy') || lower.contains('occupied')) {
      return 'Line is busy';
    }
    if (lower.contains('missed') || lower.contains('timeout') || lower.contains('timed out')) {
      return 'Call timed out';
    }
    if (lower.contains('cancelled') || lower.contains('canceled')) {
      return 'Call cancelled';
    }
    if (lower.contains('ended') || lower.contains('hung up') || lower.contains('disconnected')) {
      return 'Call ended';
    }

    // Network / connectivity issues
    if (lower.contains('socketexception') ||
        lower.contains('network_request_failed') ||
        lower.contains('client-offline') ||
        lower.contains('no internet') ||
        lower.contains('handshakeexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection refused') ||
        lower.contains('connection closed') ||
        lower.contains('network error') ||
        lower.contains('connection error')) {
      return 'Network connection error. Please check your internet connection.';
    }

    // Permissions
    if (lower.contains('permission') && (lower.contains('microphone') || lower.contains('record_audio'))) {
      return 'Microphone permission is required for voice calls.';
    }

    // Technical SDK / Firebase / Zego / stack traces / code dumps
    final isTechnical = lower.contains('exception') ||
        lower.contains('error:') ||
        lower.contains('zego') ||
        lower.contains('firebase') ||
        lower.contains('fcm') ||
        lower.contains('token') ||
        lower.contains('stacktrace') ||
        lower.contains('platformexception') ||
        lower.contains('nosuchmethod') ||
        lower.contains('assertion') ||
        lower.contains('typeerror') ||
        lower.contains('null check') ||
        lower.contains('unhandled') ||
        lower.contains('internal error');

    if (isTechnical) {
      try {
        FirebaseCrashlytics.instance.recordError(
          trimmed,
          null,
          reason: 'Sanitized technical user toast',
          fatal: false,
        );
      } catch (_) {}
      return 'An unexpected error occurred. Please try again.';
    }

    return trimmed;
  }

  // Show success toast using AppColors
  void showSuccess(
    String message, {
    ToastGravity gravity = ToastGravity.BOTTOM,
  }) {
    if (_isThrottled(message)) return;
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: gravity,
      timeInSecForIosWeb: 2,
      backgroundColor: AppColors.primaryRed.withOpacity(0.1),
      textColor: AppColors.primaryRed,
      fontSize: 14.0,
    );
  }

  // Show error toast using AppColors with automatic sanitization and rate-limiting
  void showError(String message, {ToastGravity gravity = ToastGravity.BOTTOM}) {
    final sanitized = sanitizeErrorMessage(message);
    if (_isThrottled(sanitized)) return;
    Fluttertoast.showToast(
      msg: sanitized,
      toastLength: Toast.LENGTH_SHORT,
      gravity: gravity,
      timeInSecForIosWeb: 2,
      backgroundColor: AppColors.error.withOpacity(0.1),
      textColor: AppColors.error,
      fontSize: 14.0,
    );
  }

  // Show warning toast using AppColors
  void showWarning(
    String message, {
    ToastGravity gravity = ToastGravity.BOTTOM,
  }) {
    if (_isThrottled(message)) return;
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: gravity,
      timeInSecForIosWeb: 2,
      backgroundColor: AppColors.warning.withOpacity(0.1),
      textColor: AppColors.warning,
      fontSize: 14.0,
    );
  }

  // Show info toast using AppColors
  void showInfo(String message, {ToastGravity gravity = ToastGravity.BOTTOM}) {
    if (_isThrottled(message)) return;
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: gravity,
      timeInSecForIosWeb: 2,
      backgroundColor: AppColors.primaryRed.withOpacity(0.1),
      textColor: AppColors.primaryRed,
      fontSize: 14.0,
    );
  }

  // Show primary themed toast (using your primaryRed)
  void showPrimary(
    String message, {
    ToastGravity gravity = ToastGravity.BOTTOM,
  }) {
    if (_isThrottled(message)) return;
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: gravity,
      timeInSecForIosWeb: 2,
      backgroundColor: AppColors.primaryRed,
      textColor: AppColors.white,
      fontSize: 14.0,
    );
  }

  // Show custom toast with AppColors
  void showCustom({
    required String message,
    Color? backgroundColor,
    Color? textColor,
    ToastGravity gravity = ToastGravity.BOTTOM,
    double fontSize = 14.0,
  }) {
    if (_isThrottled(message)) return;
    Fluttertoast.showToast(
      msg: message,
      gravity: gravity,
      timeInSecForIosWeb: 2,
      backgroundColor: backgroundColor ?? AppColors.grey700,
      textColor: textColor ?? AppColors.white,
      fontSize: fontSize,
    );
  }

  // Show long duration toast
  void showLong(String message, {bool isError = false}) {
    final text = isError ? sanitizeErrorMessage(message) : message;
    if (_isThrottled(text)) return;
    Fluttertoast.showToast(
      msg: text,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
      timeInSecForIosWeb: 3,
      backgroundColor: isError
          ? AppColors.error.withOpacity(0.1)
          : AppColors.primaryRed.withOpacity(0.1),
      textColor: isError ? AppColors.error : AppColors.primaryRed,
      fontSize: 14.0,
    );
  }

  // Show top positioned toast
  void showTop(String message, {bool isError = false}) {
    final text = isError ? sanitizeErrorMessage(message) : message;
    if (_isThrottled(text)) return;
    Fluttertoast.showToast(
      msg: text,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.TOP,
      timeInSecForIosWeb: 2,
      backgroundColor: isError ? AppColors.error : AppColors.success,
      textColor: AppColors.white,
      fontSize: 14.0,
    );
  }

  // Show center positioned toast
  void showCenter(String message, {bool isError = false}) {
    final text = isError ? sanitizeErrorMessage(message) : message;
    if (_isThrottled(text)) return;
    Fluttertoast.showToast(
      msg: text,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      timeInSecForIosWeb: 2,
      backgroundColor: isError ? AppColors.error : AppColors.success,
      textColor: AppColors.white,
      fontSize: 14.0,
    );
  }

  // Show toast with gradient background
  void showGradient(String message, {bool isError = false}) {
    final text = isError ? sanitizeErrorMessage(message) : message;
    if (_isThrottled(text)) return;
    Fluttertoast.showToast(
      msg: text,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      timeInSecForIosWeb: 2,
      backgroundColor: isError ? AppColors.error : AppColors.primaryRed,
      textColor: AppColors.white,
      fontSize: 14.0,
    );
  }

  // Show toast with dynamic color based on theme
  void showThemed(
    String message, {
    required bool isDarkMode,
    bool isError = false,
  }) {
    final text = isError ? sanitizeErrorMessage(message) : message;
    if (_isThrottled(text)) return;
    Fluttertoast.showToast(
      msg: text,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      timeInSecForIosWeb: 2,
      backgroundColor: isError
          ? AppColors.error
          : (isDarkMode ? AppColors.primaryRedLight : AppColors.primaryRed),
      textColor: AppColors.white,
      fontSize: 14.0,
    );
  }

  // Cancel all toasts
  void cancelAll() {
    Fluttertoast.cancel();
  }
}
