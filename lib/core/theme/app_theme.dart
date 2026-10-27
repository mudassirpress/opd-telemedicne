import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppColors {
  // Primary Colors
  static const Color primaryRed = Color(0xFF062B72);
  static const Color primaryRedLight = Color(0xFF1A3F8A);
  static const Color primaryRedDark = Color(0xFF041F54);

  // Secondary Colors
  static const Color secondaryBlue = Color(0xFF11B7A8);
  static const Color secondaryGreen = Color(0xFF37D2C2);
  static const Color secondaryYellow = Color(0xFF4AD6C8);
  static const Color secondaryOrange = Color(0xFF0E9A8E);

  // Neutral Colors
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color black87 = Color(0xDD000000);
  static const Color black54 = Color(0x8A000000);

  // Grey Shades
  static const Color grey50 = Color(0xFFFAFAFA);
  static const Color grey100 = Color(0xFFF5F5F5);
  static const Color grey200 = Color(0xFFEEEEEE);
  static const Color grey300 = Color(0xFFE0E0E0);
  static const Color grey400 = Color(0xFFBDBDBD);
  static const Color grey500 = Color(0xFF9E9E9E);
  static const Color grey600 = Color(0xFF757575);
  static const Color grey700 = Color(0xFF616161);
  static const Color grey800 = Color(0xFF424242);
  static const Color grey900 = Color(0xFF212121);

  // Background Colors
  static const Color backgroundLight = Color(0xFFF8F9FA);
  static const Color backgroundDark = Color(0xFF121212);
  static const Color backgroundGrey = grey50;

  // Status Colors
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFE53935);
  static const Color warning = Color(0xFFFFC107);
  static const Color info = Color(0xFF2196F3);

  // Overlay Colors
  static const Color overlayLight = Color(0x0D000000);
  static const Color overlayMedium = Color(0x1A000000);
  static const Color overlayDark = Color(0x33000000);

  // Chat Specific Colors
  static const Color chatBubbleMe = primaryRed;
  static const Color chatBubbleOther = white;
  static const Color chatTextMe = white;
  static const Color chatTextOther = black87;
  static const Color chatTimestampMe = Color(0xB3FFFFFF);
  static const Color chatTimestampOther = grey500;
  static const Color chatReadReceipt = secondaryBlue;

  // Gradient Colors
  static const Gradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryRed, primaryRedLight],
  );

  static const Gradient secondaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [secondaryBlue, secondaryGreen],
  );

  static const Gradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [white, grey50],
  );

  // Shadow Colors
  static const Color shadowLight = Color(0x0D000000);
  static const Color shadowMedium = Color(0x1A000000);
  static const Color shadowDark = Color(0x33000000);

  // Method to get color with opacity
  static Color withOpacity(Color color, double opacity) {
    return color.withOpacity(opacity);
  }

  // Helper method to get appropriate text color based on background
  static Color getTextColorForBackground(Color backgroundColor) {
    final luminance =
        (0.299 * backgroundColor.red +
            0.587 * backgroundColor.green +
            0.114 * backgroundColor.blue) /
        255;

    return luminance > 0.5 ? black87 : white;
  }
}

/// App-wide theme. Keeps the exact Material 3 color scheme the app already
/// ships with and only compacts the *default* text sizes, so widgets that do
/// not set an explicit style (dialogs, menus, default AppBars, snackbars,
/// buttons) use the same small, WhatsApp-like scale as the rest of the UI.
class AppTheme {
  AppTheme._();

  /// Compact text scale used everywhere an explicit `fontSize` is not set.
  ///
  /// Mirrors Material 3 roles but one step smaller: titles 17 instead of 22,
  /// body 13-14 instead of 14-16, labels 13 instead of 14.
  static TextTheme compactTextTheme([TextTheme? base]) {
    final t = base ?? const TextTheme();

    TextStyle? style(TextStyle? s, double size,
        {FontWeight? weight, double? height}) {
      if (s == null) return null;
      return s.copyWith(
        fontSize: size,
        fontWeight: weight ?? s.fontWeight,
        height: height ?? s.height,
      );
    }

    return t.copyWith(
      displayLarge: style(t.displayLarge, 32, height: 1.15),
      displayMedium: style(t.displayMedium, 28, height: 1.15),
      displaySmall: style(t.displaySmall, 24, height: 1.2),
      headlineLarge: style(t.headlineLarge, 22, height: 1.2),
      headlineMedium: style(t.headlineMedium, 20, height: 1.25),
      headlineSmall: style(t.headlineSmall, 18, height: 1.3),
      titleLarge: style(t.titleLarge, 17,
          weight: FontWeight.w600, height: 1.3),
      titleMedium: style(t.titleMedium, 14.5,
          weight: FontWeight.w600, height: 1.35),
      titleSmall: style(t.titleSmall, 13,
          weight: FontWeight.w600, height: 1.35),
      bodyLarge: style(t.bodyLarge, 14, height: 1.45),
      bodyMedium: style(t.bodyMedium, 13, height: 1.45),
      bodySmall: style(t.bodySmall, 11.5, height: 1.4),
      labelLarge: style(t.labelLarge, 13.5,
          weight: FontWeight.w600, height: 1.3),
      labelMedium: style(t.labelMedium, 11.5, height: 1.3),
      labelSmall: style(t.labelSmall, 10.5, height: 1.25),
    );
  }

  /// The app theme: unchanged colors, compact typography.
  static ThemeData light() {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      useMaterial3: true,
      typography: Typography.material2021(platform: defaultTargetPlatform),
    );

    return base.copyWith(textTheme: compactTextTheme(base.textTheme));
  }
}
