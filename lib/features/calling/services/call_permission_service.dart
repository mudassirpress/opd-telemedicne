// lib/features/calling/services/call_permission_service.dart

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class CallPermissionService {
  CallPermissionService._();
  static final CallPermissionService instance = CallPermissionService._();

  /// Requests microphone permission if not already granted.
  /// Returns `true` if granted, `false` otherwise.
  Future<bool> checkAndRequestMicrophonePermission() async {
    try {
      final status = await Permission.microphone.status;
      if (status.isGranted) return true;

      final result = await Permission.microphone.request();
      if (result.isGranted) return true;

      if (result.isPermanentlyDenied) {
        debugPrint(
          '⚠️ [CallPermissionService] Microphone permanently denied. User must open app settings.',
        );
      }
      return false;
    } catch (e) {
      debugPrint('❌ [CallPermissionService] Permission request failed: $e');
      return false;
    }
  }

  Future<bool> hasMicrophonePermission() async {
    return await Permission.microphone.isGranted;
  }
}

