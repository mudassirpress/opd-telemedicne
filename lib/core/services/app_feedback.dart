import 'package:flutter/material.dart';
import 'package:telemedicine/core/errors/auth_error_handler.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

/// Feedback types for standard styling.
enum FeedbackType {
  success,
  error,
  warning,
  info,
}

/// Standardized, production-grade UI notification and feedback service.
///
/// Presents clean, branded SnackBars without duplicated inline styling or
/// hardcoded layout parameters.
class AppFeedback {
  AppFeedback._();

  static const Duration _defaultDuration = Duration(seconds: 4);

  /// Shows a success snackbar.
  static void showSuccess(
    BuildContext? context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = _defaultDuration,
  }) {
    _showSnackBar(
      context: context,
      message: message,
      type: FeedbackType.success,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Shows an error snackbar.
  static void showError(
    BuildContext? context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = _defaultDuration,
  }) {
    _showSnackBar(
      context: context,
      message: message,
      type: FeedbackType.error,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Shows a warning snackbar.
  static void showWarning(
    BuildContext? context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = _defaultDuration,
  }) {
    _showSnackBar(
      context: context,
      message: message,
      type: FeedbackType.warning,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Shows an info snackbar.
  static void showInfo(
    BuildContext? context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = _defaultDuration,
  }) {
    _showSnackBar(
      context: context,
      message: message,
      type: FeedbackType.info,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Shows an [AuthError] directly, including optional recovery suggestions.
  static void showAuthError(
    BuildContext? context,
    AuthError authError, {
    VoidCallback? onRetry,
  }) {
    final fullMessage = authError.recoverySuggestion != null
        ? '${authError.message} ${authError.recoverySuggestion}'
        : authError.message;

    showError(
      context,
      fullMessage,
      actionLabel: onRetry != null ? 'Retry' : null,
      onAction: onRetry,
    );
  }

  static void _showSnackBar({
    required BuildContext? context,
    required String message,
    required FeedbackType type,
    String? actionLabel,
    VoidCallback? onAction,
    required Duration duration,
  }) {
    final effectiveContext = context ?? NotificationService.navigatorKey.currentContext;

    if (effectiveContext == null) {
      // Fallback to ToastService if no BuildContext is mounted yet
      switch (type) {
        case FeedbackType.success:
          ToastService.instance.showSuccess(message);
          break;
        case FeedbackType.error:
          ToastService.instance.showError(message);
          break;
        case FeedbackType.warning:
          ToastService.instance.showWarning(message);
          break;
        case FeedbackType.info:
          ToastService.instance.showInfo(message);
          break;
      }
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(effectiveContext);
    if (messenger == null) {
      ToastService.instance.showInfo(message);
      return;
    }

    final visualConfig = _getVisualConfig(type);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        elevation: 6,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        backgroundColor: visualConfig.backgroundColor,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: visualConfig.borderColor, width: 1),
        ),
        content: Row(
          children: [
            Icon(
              visualConfig.icon,
              color: visualConfig.foregroundColor,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: visualConfig.foregroundColor,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(
                label: actionLabel,
                textColor: visualConfig.actionColor,
                onPressed: onAction,
              )
            : null,
      ),
    );
  }

  static _FeedbackVisualConfig _getVisualConfig(FeedbackType type) {
    switch (type) {
      case FeedbackType.success:
        return const _FeedbackVisualConfig(
          backgroundColor: Color(0xFFE8F5E9),
          borderColor: Color(0xFFA5D6A7),
          foregroundColor: Color(0xFF2E7D32),
          actionColor: Color(0xFF1B5E20),
          icon: Icons.check_circle_rounded,
        );
      case FeedbackType.error:
        return const _FeedbackVisualConfig(
          backgroundColor: Color(0xFFFFEBEE),
          borderColor: Color(0xFFEF9A9A),
          foregroundColor: Color(0xFFC62828),
          actionColor: Color(0xFFB71C1C),
          icon: Icons.error_rounded,
        );
      case FeedbackType.warning:
        return const _FeedbackVisualConfig(
          backgroundColor: Color(0xFFFFF8E1),
          borderColor: Color(0xFFFFE082),
          foregroundColor: Color(0xFFF57F17),
          actionColor: Color(0xFFE65100),
          icon: Icons.warning_rounded,
        );
      case FeedbackType.info:
        return const _FeedbackVisualConfig(
          backgroundColor: Color(0xFFE3F2FD),
          borderColor: Color(0xFF90CAF9),
          foregroundColor: AppColors.primaryRed,
          actionColor: Color(0xFF0D47A1),
          icon: Icons.info_rounded,
        );
    }
  }
}

class _FeedbackVisualConfig {
  final Color backgroundColor;
  final Color borderColor;
  final Color foregroundColor;
  final Color actionColor;
  final IconData icon;

  const _FeedbackVisualConfig({
    required this.backgroundColor,
    required this.borderColor,
    required this.foregroundColor,
    required this.actionColor,
    required this.icon,
  });
}
