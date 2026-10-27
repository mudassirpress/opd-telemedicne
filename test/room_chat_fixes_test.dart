import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/local/offline_doctor_service.dart';

void main() {
  group('Bug 1: Hive Doctor Serialization & Timestamp Sanitization', () {
    test('sanitizeForStorage converts Timestamp to ISO-8601 string', () {
      final now = DateTime(2026, 10, 23, 12, 0, 0);
      final timestamp = Timestamp.fromDate(now);

      final result = OfflineDoctorService.sanitizeForStorage(timestamp);
      expect(result, isA<String>());
      expect(result, now.toIso8601String());
    });

    test('sanitizeForStorage recursively cleans nested maps and lists with Timestamps', () {
      final ts1 = Timestamp.fromDate(DateTime(2026, 1, 1));
      final ts2 = Timestamp.fromDate(DateTime(2026, 6, 1));

      final rawDoctorMap = <String, dynamic>{
        'id': 'doc_123',
        'fullname': 'Dr. Test',
        'createdAt': ts1,
        'activityLogs': [
          {'timestamp': ts2, 'action': 'login'},
        ],
        'nested': {
          'lastSeen': ts1,
          'count': 5,
        },
      };

      final sanitized = OfflineDoctorService.sanitizeForStorage(rawDoctorMap);

      // Verify that jsonEncode succeeds without throwing
      // "Converting object to an encodable object failed: Instance of 'Timestamp'"
      expect(() => jsonEncode(sanitized), returnsNormally);

      final jsonStr = jsonEncode(sanitized);
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(decoded['createdAt'], isA<String>());
      expect(decoded['activityLogs'][0]['timestamp'], isA<String>());
      expect(decoded['nested']['lastSeen'], isA<String>());
    });
  });
}
