import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Categories of authentication and authorization errors.
enum AuthErrorCategory {
  invalidCredentials,
  userNotFound,
  sessionExpired,
  noActiveSession,
  networkFailure,
  rateLimited,
  accountConflict,
  profileIncomplete,
  general,
}

/// Structured, user-ready error model.
class AuthError {
  final String message;
  final String code;
  final AuthErrorCategory category;
  final String? recoverySuggestion;

  const AuthError({
    required this.message,
    required this.code,
    required this.category,
    this.recoverySuggestion,
  });

  @override
  String toString() => 'AuthError($code: $message)';
}

/// Custom domain exception for lost or missing patient sessions.
class AuthSessionException implements Exception {
  final String message;
  final String? code;
  final dynamic details;

  const AuthSessionException(
    this.message, {
    this.code = 'no-active-session',
    this.details,
  });

  @override
  String toString() => 'AuthSessionException($code: $message)';
}

/// Centralized, production-grade error mapping service.
///
/// Ensures technical stack traces and internal Firebase codes are cleanly logged
/// for developers while users receive standardized, friendly, actionable messages.
class AuthErrorHandler {
  AuthErrorHandler._();

  /// Maps any caught error/exception into a structured [AuthError].
  static AuthError handle(
    dynamic error, [
    StackTrace? stackTrace,
    String? contextLabel,
  ]) {
    // Always log internal diagnostics for developers
    final label = contextLabel != null ? '[$contextLabel] ' : '';
    debugPrint('🚨 ${label}Auth Error Occurred: $error');
    if (stackTrace != null) {
      debugPrint('Stack Trace:\n$stackTrace');
    }

    if (error is AuthError) {
      return error;
    }

    if (error is FirebaseAuthException) {
      return _mapFirebaseAuthException(error);
    }

    if (error is AuthSessionException) {
      return AuthError(
        message: error.message,
        code: error.code ?? 'no-active-session',
        category: AuthErrorCategory.noActiveSession,
        recoverySuggestion: 'Please verify your credentials or log in again.',
      );
    }

    if (error is SocketException || error is TimeoutException) {
      return const AuthError(
        message:
            'Unable to reach the server. Please check your internet connection and try again.',
        code: 'network-unavailable',
        category: AuthErrorCategory.networkFailure,
        recoverySuggestion: 'Verify Wi-Fi or mobile data connectivity.',
      );
    }

    if (error is FormatException) {
      return const AuthError(
        message:
            'The submitted format is invalid. Please check the entered information.',
        code: 'invalid-format',
        category: AuthErrorCategory.general,
      );
    }

    // Handle generic string/exception checks without exposing raw tech messages
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('no active patient session')) {
      return const AuthError(
        message:
            'Your active session could not be found. Please log in again to continue.',
        code: 'session-not-found',
        category: AuthErrorCategory.noActiveSession,
        recoverySuggestion: 'Return to login screen.',
      );
    }

    if (errorStr.contains('network') || errorStr.contains('connection')) {
      return const AuthError(
        message:
            'A network error occurred. Please check your internet connection.',
        code: 'network-error',
        category: AuthErrorCategory.networkFailure,
      );
    }

    return const AuthError(
      message: 'An unexpected error occurred. Please try again in a moment.',
      code: 'unknown-error',
      category: AuthErrorCategory.general,
      recoverySuggestion: 'If the issue persists, contact support.',
    );
  }

  /// Maps standard Firebase Auth error codes to standardized user messages.
  static AuthError _mapFirebaseAuthException(FirebaseAuthException exception) {
    final code = exception.code.trim().toLowerCase();

    switch (code) {
      case 'user-not-found':
        return const AuthError(
          message:
              'No account found with these credentials. Please check and try again.',
          code: 'user-not-found',
          category: AuthErrorCategory.userNotFound,
        );

      case 'wrong-password':
      case 'invalid-credential':
        return const AuthError(
          message:
              'The credentials provided are incorrect. Please verify and try again.',
          code: 'invalid-credential',
          category: AuthErrorCategory.invalidCredentials,
        );

      case 'invalid-verification-code':
      case 'invalid-otp':
        return const AuthError(
          message:
              'The verification code you entered is invalid. Please check your SMS code.',
          code: 'invalid-verification-code',
          category: AuthErrorCategory.invalidCredentials,
        );

      case 'session-expired':
      case 'code-expired':
        return const AuthError(
          message:
              'The verification session has expired. Please request a new code.',
          code: 'session-expired',
          category: AuthErrorCategory.sessionExpired,
        );

      case 'email-already-in-use':
      case 'phone-number-already-exists':
        return const AuthError(
          message: 'This account already exists. Please log in instead.',
          code: 'account-exists',
          category: AuthErrorCategory.accountConflict,
        );

      case 'too-many-requests':
        return const AuthError(
          message:
              'Too many attempts. For your security, this request has been temporarily blocked. Please wait a few minutes.',
          code: 'too-many-requests',
          category: AuthErrorCategory.rateLimited,
        );

      case 'network-request-failed':
        return const AuthError(
          message:
              'Network connection failed. Please check your internet connection and try again.',
          code: 'network-request-failed',
          category: AuthErrorCategory.networkFailure,
        );

      case 'invalid-phone-number':
        return const AuthError(
          message:
              'The phone number format is invalid. Please enter a valid number with country code.',
          code: 'invalid-phone-number',
          category: AuthErrorCategory.invalidCredentials,
        );

      case 'user-disabled':
        return const AuthError(
          message:
              'This account has been disabled. Please contact support for assistance.',
          code: 'user-disabled',
          category: AuthErrorCategory.general,
        );

      case 'quota-exceeded':
        return const AuthError(
          message:
              'SMS verification limit reached for today. Please try again later.',
          code: 'quota-exceeded',
          category: AuthErrorCategory.rateLimited,
        );

      case 'operation-not-allowed':
        return const AuthError(
          message:
              'This login method is currently not enabled. Please contact support.',
          code: 'operation-not-allowed',
          category: AuthErrorCategory.general,
        );

      default:
        return AuthError(
          message:
              'Authentication failed. Please check your information and try again.',
          code: exception.code,
          category: AuthErrorCategory.general,
        );
    }
  }
}
