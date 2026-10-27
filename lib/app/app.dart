import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/features/splash/splash_screen.dart';

/// Root application widget.
///
/// This widget configures the MaterialApp and provides the app-level
/// navigation key for notification-driven navigation.
class TelemedicineApp extends StatelessWidget {
  const TelemedicineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: NotificationService.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Telemedicine App',
      theme: AppTheme.light(),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final clamped = mq.textScaler.scale(1.0).clamp(0.9, 1.25);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(clamped)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const FirstSplashScreen(),
    );
  }
}
