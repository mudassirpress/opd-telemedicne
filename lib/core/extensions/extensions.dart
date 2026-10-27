import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Common Dart/Flutter extensions used across the app.
extension StringExtension on String {
  /// Capitalize first letter.
  String get capitalized =>
      isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';

  /// Check if string is a valid email (basic check).
  bool get isValidEmail => RegExp(r'^[\w-]+(\.[\w-]+)*@([\w-]+\.)+[a-zA-Z]{2,7}$').hasMatch(this);

  /// Mask phone number for display: 03XX***XXX.
  String get maskedPhone {
    if (length < 7) return this;
    return '${substring(0, 4)}***${substring(length - 3)}';
  }
}

extension DateTimeExtension on DateTime {
  /// Format as: "Jan 15, 2024"
  String get shortDate => DateFormat('MMM d, yyyy').format(this);

  /// Format as: "3:45 PM"
  String get shortTime => DateFormat('h:mm a').format(this);

  /// Format as: "Jan 15, 3:45 PM"
  String get shortDateTime => DateFormat('MMM d, h:mm a').format(this);

  /// Format as: "Today" / "Yesterday" / "Jan 15"
  String get relativeDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateOnly = DateTime(year, month, day);

    if (dateOnly == today) return 'Today';
    if (dateOnly == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return shortDate;
  }

  /// Time ago string: "Just now", "5m ago", "2h ago", "Jan 15"
  String get timeAgo {
    final diff = DateTime.now().difference(this);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return shortDate;
  }
}

extension BuildContextExtension on BuildContext {
  /// Screen width
  double get screenWidth => MediaQuery.of(this).size.width;

  /// Screen height
  double get screenHeight => MediaQuery.of(this).size.height;

  /// Keyboard is visible
  bool get isKeyboardVisible => MediaQuery.of(this).viewInsets.bottom > 0;

  /// Show a snackbar with a message.
  void showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
