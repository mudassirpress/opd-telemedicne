/// Centralized error handling utilities.
///
/// Provides a consistent way to handle errors across the app without
/// exposing sensitive internal details to users.
class AppError {
  final String message;
  final String? code;
  final dynamic originalError;

  const AppError({
    required this.message,
    this.code,
    this.originalError,
  });

  /// Create an AppError from a caught exception.
  factory AppError.fromException(dynamic e) {
    if (e is AppError) return e;
    return AppError(
      message: _userFriendlyMessage(e),
      originalError: e,
    );
  }

  /// Convert technical errors to user-friendly messages.
  static String _userFriendlyMessage(dynamic error) {
    final msg = error.toString().toLowerCase();

    if (msg.contains('network') || msg.contains('timeout')) {
      return 'Network error. Please check your connection and try again.';
    }
    if (msg.contains('permission')) {
      return 'Permission denied. Please grant the required permissions.';
    }
    if (msg.contains('not-found') || msg.contains('not found')) {
      return 'The requested resource was not found.';
    }
    if (msg.contains('unauthorized') || msg.contains('permission-denied')) {
      return 'You do not have permission to perform this action.';
    }
    if (msg.contains('quota') || msg.contains('limit')) {
      return 'Service limit reached. Please try again later.';
    }

    return 'Something went wrong. Please try again.';
  }

  @override
  String toString() => 'AppError(message: $message, code: $code)';
}

/// Extension on Object? for easy error wrapping.
extension ErrorWrap on Object? {
  AppError toAppError() => AppError.fromException(this);
}
