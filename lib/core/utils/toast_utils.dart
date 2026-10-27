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

  // Show success toast using AppColors
  void showSuccess(
    String message, {
    ToastGravity gravity = ToastGravity.BOTTOM,
    
  }) {
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

  // Show error toast using AppColors
  void showError(String message, {ToastGravity gravity = ToastGravity.BOTTOM}) {
    Fluttertoast.showToast(
      msg: message,
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
    Fluttertoast.showToast(
      msg: message,
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
    Fluttertoast.showToast(
      msg: message,
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
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      timeInSecForIosWeb: 2,
      backgroundColor: isError ? AppColors.error : AppColors.success,
      textColor: AppColors.white,
      fontSize: 14.0,
    );
  }

  // Show toast with gradient background (using AppColors gradient)
  void showGradient(String message, {bool isError = false}) {
    // Note: Fluttertoast doesn't support gradients directly
    // We'll use solid colors from your gradient
    Fluttertoast.showToast(
      msg: message,
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
    Fluttertoast.showToast(
      msg: message,
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
