import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// BatteryOptimizationService helps prevent aggressive OEM battery managers
/// (Xiaomi MIUI/HyperOS, Samsung, Vivo, Oppo/Realme, Huawei) from killing background
/// FCM workers and CallKit services in deep sleep or Doze Mode.
class BatteryOptimizationService {
  BatteryOptimizationService._();
  static final BatteryOptimizationService instance =
      BatteryOptimizationService._();

  static const MethodChannel _channel = MethodChannel(
    'telemedicine/call_platform',
  );

  /// Checks if the application is currently exempted from Android Doze battery optimizations.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final isIgnoring = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return isIgnoring ?? false;
    } on PlatformException catch (e) {
      debugPrint('[BatteryOptimization] isIgnoring check failed: $e');
      return false;
    }
  }

  /// Opens the system prompt requesting the user to whitelist the app from battery restrictions.
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final requested = await _channel.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
      return requested ?? false;
    } on PlatformException catch (e) {
      debugPrint('[BatteryOptimization] request failed: $e');
      return false;
    }
  }

  /// Attempts to launch manufacturer-specific Auto-Start / Background Run management screens
  /// (e.g., Xiaomi Security center, Samsung Smart Manager, Oppo/Vivo permission center).
  Future<bool> openAutoStartSettings() async {
    if (!Platform.isAndroid) return true;
    try {
      final opened = await _channel.invokeMethod<bool>('openAutoStartSettings');
      return opened ?? false;
    } on PlatformException catch (e) {
      debugPrint('[BatteryOptimization] openAutoStartSettings failed: $e');
      return false;
    }
  }

  /// Shows an unobtrusive bottom sheet or dialog educating the user on enabling unrestricted
  /// background execution to ensure 100% incoming call delivery.
  Future<void> showOptimizationDialog(
    BuildContext context, {
    required VoidCallback onCompleted,
  }) async {
    if (!Platform.isAndroid) return;
    final isIgnored = await isIgnoringBatteryOptimizations();
    if (isIgnored || !context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF0F223D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.battery_alert_rounded,
                      color: Color(0xFF4AD6C8),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'Ensure Reliable Incoming Calls',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'To ring immediately when your doctor or patient calls while your phone is locked or in your pocket, please allow unrestricted background activity.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white60,
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Later'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await requestIgnoreBatteryOptimizations();
                        onCompleted();
                      },
                      child: const Text('Allow Background Run'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
