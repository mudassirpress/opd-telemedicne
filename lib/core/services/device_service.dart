import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Utility class for device identification and persistent device-ID storage.
///
/// This is a stateless utility – all methods are static and hold no instance
/// state, so they can be called from anywhere without needing a reference to
/// a controller or provider.
class DeviceService {
  DeviceService._();

  static const String _storageKey = 'installation_device_id';
  static const String _legacyPrefsKey = 'persistent_device_id';
  static const String _legacyIosKey = 'persistent_device_id_ios';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// Validates whether a device identifier is a real unique installation UUID
  /// rather than an Android OS build string like 'BP2A.250605.031.A3'.
  static bool isValidInstallationId(String? id) {
    if (id == null || id.trim().isEmpty) return false;
    final trimmed = id.trim();
    // Android Build.ID strings commonly contain periods (e.g. BP2A.250605.031.A3, UP1A.231005.007)
    // or standard build release tags. They are software build IDs, not installation IDs.
    if (trimmed.contains('.') ||
        trimmed.startsWith('BP2A') ||
        trimmed.startsWith('TP1A') ||
        trimmed.startsWith('UP1A') ||
        trimmed.startsWith('AP1A')) {
      return false;
    }
    // A standard UUID has 36 characters: 8-4-4-4-12
    final uuidRegex = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return uuidRegex.hasMatch(trimmed);
  }

  /// Returns a persistent unique installation/device identifier.
  ///
  /// Guarantees that the returned ID is a unique UUID persisted securely across
  /// app restarts and updates, and never an Android OS build string.
  static Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Try reading from FlutterSecureStorage
      try {
        final secureId = await _secureStorage.read(key: _storageKey);
        if (isValidInstallationId(secureId)) {
          // Sync with SharedPreferences
          await prefs.setString(_storageKey, secureId!);
          await prefs.setString(_legacyPrefsKey, secureId);
          return secureId;
        }
      } catch (e) {
        debugPrint('⚠️ [DeviceService] SecureStorage read error: $e');
      }

      // 2. Try reading from SharedPreferences
      final prefsId =
          prefs.getString(_storageKey) ?? prefs.getString(_legacyPrefsKey);
      if (isValidInstallationId(prefsId)) {
        try {
          await _secureStorage.write(key: _storageKey, value: prefsId!);
        } catch (_) {}
        return prefsId!;
      }

      // 3. iOS legacy key check
      if (Platform.isIOS) {
        try {
          final legacyIos = await _secureStorage.read(key: _legacyIosKey);
          if (isValidInstallationId(legacyIos)) {
            await _secureStorage.write(key: _storageKey, value: legacyIos!);
            await prefs.setString(_storageKey, legacyIos);
            await prefs.setString(_legacyPrefsKey, legacyIos);
            return legacyIos;
          }
        } catch (_) {}
      }

      // 4. Generate new cryptographically unique installation UUID
      const uuid = Uuid();
      final newId = uuid.v4();

      try {
        await _secureStorage.write(key: _storageKey, value: newId);
        if (Platform.isIOS) {
          await _secureStorage.write(key: _legacyIosKey, value: newId);
        }
      } catch (e) {
        debugPrint('⚠️ [DeviceService] SecureStorage write error: $e');
      }

      await prefs.setString(_storageKey, newId);
      await prefs.setString(_legacyPrefsKey, newId);

      debugPrint(
        '📱 [DeviceService] Established persistent installation ID: $newId',
      );
      return newId;
    } catch (e) {
      debugPrint('❌ [DeviceService] Error getting device ID: $e');
      const uuid = Uuid();
      return uuid.v4();
    }
  }

  /// Clears the persistent device ID (call on logout or factory reset if needed).
  static Future<void> clearPersistentDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
      await prefs.remove(_legacyPrefsKey);
      try {
        await _secureStorage.delete(key: _storageKey);
        if (Platform.isIOS) {
          await _secureStorage.delete(key: _legacyIosKey);
        }
      } catch (_) {}
      debugPrint('🗑️ [DeviceService] Persistent installation ID cleared');
    } catch (e) {
      debugPrint('Error clearing device ID: $e');
    }
  }
}
