import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/services/device_service.dart';

void main() {
  group('Device Identifier Validation Tests', () {
    test('Rejects Android Build.ID strings', () {
      // The exact error string from the issue
      expect(DeviceService.isValidInstallationId('BP2A.250605.031.A3'), isFalse);
      expect(DeviceService.isValidInstallationId('UP1A.231005.007'), isFalse);
      expect(DeviceService.isValidInstallationId('TP1A.220624.014'), isFalse);
      expect(DeviceService.isValidInstallationId('AP1A.240305.019.A1'), isFalse);
      expect(DeviceService.isValidInstallationId('any.build.string'), isFalse);
    });

    test('Rejects null, empty, and invalid strings', () {
      expect(DeviceService.isValidInstallationId(null), isFalse);
      expect(DeviceService.isValidInstallationId(''), isFalse);
      expect(DeviceService.isValidInstallationId('   '), isFalse);
      expect(DeviceService.isValidInstallationId('short-id'), isFalse);
      expect(DeviceService.isValidInstallationId('12345'), isFalse);
    });

    test('Accepts valid cryptographically unique UUIDs', () {
      expect(
        DeviceService.isValidInstallationId('cacaaab0-996c-4fa8-ac52-087817e7208e'),
        isTrue,
      );
      expect(
        DeviceService.isValidInstallationId('e2a4b88d-71b3-463e-9669-e93dc49c5e31'),
        isTrue,
      );
      expect(
        DeviceService.isValidInstallationId('00000000-0000-0000-0000-000000000000'),
        isTrue,
      );
    });
  });

  group('Session State Evaluation Logic Tests', () {
    test('Null or missing remote session does not trigger remote revocation', () {
      const currentDeviceId = 'cacaaab0-996c-4fa8-ac52-087817e7208e';
      const String? activeDeviceId = null;
      const bool isLoggedIn = false;

      // Evaluation:
      final isMatching = activeDeviceId == currentDeviceId;
      final isRemoteRevocation = activeDeviceId != null &&
          activeDeviceId.isNotEmpty &&
          activeDeviceId != currentDeviceId;
      final isUninitialized = activeDeviceId == null || activeDeviceId.isEmpty;

      expect(isMatching, isFalse);
      expect(isRemoteRevocation, isFalse);
      expect(isUninitialized, isTrue);
    });

    test('Matching active device ID is recognized as valid session', () {
      const currentDeviceId = 'cacaaab0-996c-4fa8-ac52-087817e7208e';
      const String? activeDeviceId = 'cacaaab0-996c-4fa8-ac52-087817e7208e';
      const bool isLoggedIn = true;

      final isMatching = activeDeviceId == currentDeviceId && isLoggedIn;
      final isRemoteRevocation = activeDeviceId != null &&
          activeDeviceId.isNotEmpty &&
          activeDeviceId != currentDeviceId;

      expect(isMatching, isTrue);
      expect(isRemoteRevocation, isFalse);
    });

    test('Distinct remote device ID triggers revocation', () {
      const currentDeviceId = 'cacaaab0-996c-4fa8-ac52-087817e7208e';
      const String? activeDeviceId = 'e2a4b88d-71b3-463e-9669-e93dc49c5e31';

      final isMatching = activeDeviceId == currentDeviceId;
      final isRemoteRevocation = activeDeviceId != null &&
          activeDeviceId.isNotEmpty &&
          activeDeviceId != currentDeviceId;

      expect(isMatching, isFalse);
      expect(isRemoteRevocation, isTrue);
    });
  });
}
