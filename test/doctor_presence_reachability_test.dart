import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';

void main() {
  group('DoctorPresenceData Model & Eligibility Logic', () {
    test('default empty presence is offline and ineligible', () {
      const data = DoctorPresenceData.empty;
      expect(data.isOnline, isFalse);
      expect(data.effectiveStatus, 'OFFLINE');
      expect(data.manualAvailability, isFalse);
    });

    test(
      'manualAvailability false forces offline even with fresh heartbeat',
      () {
        final now = DateTime.now();
        final data = DoctorPresenceData(
          isOnline: false,
          effectiveStatus: 'OFFLINE',
          manualAvailability: false,
          lastHeartbeat: now.subtract(const Duration(seconds: 5)),
          lastSeen: now.subtract(const Duration(seconds: 5)),
          accountStatus: 'Active',
          isEligible: true,
        );

        expect(data.isOnline, isFalse);
        expect(data.effectiveStatus, 'OFFLINE');
        expect(data.manualAvailability, isFalse);
      },
    );

    test('stale heartbeat does not end a manually online shift', () {
      final now = DateTime.now();
      final data = DoctorPresenceData(
        isOnline: true,
        effectiveStatus: 'ONLINE',
        manualAvailability: true,
        isAppConnected: false,
        lastHeartbeat: now.subtract(const Duration(seconds: 75)), // Expired TTL
        lastSeen: now.subtract(const Duration(seconds: 75)),
        accountStatus: 'Active',
        isEligible: true,
      );

      expect(data.isOnline, isTrue);
      expect(data.effectiveStatus, 'ONLINE');
      expect(data.manualAvailability, isTrue);
      expect(data.isAppConnected, isFalse);
    });

    test(
      'suspended doctor is offline even with manual availability and fresh heartbeat',
      () {
        final now = DateTime.now();
        final data = DoctorPresenceData(
          isOnline: false,
          effectiveStatus: 'OFFLINE',
          manualAvailability: true,
          lastHeartbeat: now.subtract(const Duration(seconds: 5)),
          accountStatus: 'Suspended',
          isEligible: false,
        );

        expect(data.isOnline, isFalse);
        expect(data.isEligible, isFalse);
        expect(data.effectiveStatus, 'OFFLINE');
      },
    );

    test('active call in progress reports BUSY status', () {
      final now = DateTime.now();
      final data = DoctorPresenceData(
        isOnline: false,
        effectiveStatus: 'BUSY',
        manualAvailability: true,
        lastHeartbeat: now.subtract(const Duration(seconds: 5)),
        accountStatus: 'Active',
        isEligible: true,
      );

      expect(data.isOnline, isFalse);
      expect(data.effectiveStatus, 'BUSY');
    });

    test('all conditions satisfied reports ONLINE', () {
      final now = DateTime.now();
      final data = DoctorPresenceData(
        isOnline: true,
        effectiveStatus: 'ONLINE',
        manualAvailability: true,
        lastHeartbeat: now.subtract(const Duration(seconds: 10)),
        lastSeen: now.subtract(const Duration(seconds: 10)),
        onlineSince: now.subtract(const Duration(minutes: 5)),
        lastVerifiedInternet: now.subtract(const Duration(seconds: 10)),
        accountStatus: 'Active',
        isEligible: true,
      );

      expect(data.isOnline, isTrue);
      expect(data.effectiveStatus, 'ONLINE');
      expect(data.manualAvailability, isTrue);
      expect(data.isEligible, isTrue);
    });
  });

  group('Doctor Presence Map Evaluation & Sorting', () {
    test(
      'sortDoctorsByPresence handles online, busy, and expired doctors correctly',
      () {
        final now = DateTime.now();

        final doctors = [
          {'id': 'doc_offline_manual', 'name': 'Dr. Offline'},
          {'id': 'doc_online_fresh', 'name': 'Dr. Available'},
          {'id': 'doc_stale_heartbeat', 'name': 'Dr. Stale'},
        ];

        final presenceMap = {
          'doc_offline_manual': const DoctorPresenceData(
            isOnline: false,
            effectiveStatus: 'OFFLINE',
            manualAvailability: false,
          ),
          'doc_online_fresh': DoctorPresenceData(
            isOnline: true,
            effectiveStatus: 'ONLINE',
            manualAvailability: true,
            onlineSince: now.subtract(const Duration(minutes: 10)),
          ),
          'doc_stale_heartbeat': const DoctorPresenceData(
            isOnline: false,
            effectiveStatus: 'OFFLINE',
            manualAvailability: true, // Manual toggle on, but TTL expired
          ),
        };

        final sorted = sortDoctorsByPresence<Map<String, dynamic>>(
          doctors,
          presenceMap,
          (d) => d['id'] as String,
        );

        expect(sorted.map((d) => d['id']), [
          'doc_online_fresh',
          'doc_offline_manual',
          'doc_stale_heartbeat',
        ]);
      },
    );

    test(
      'presenceFromDoctorList handles legacy isOnline format with server timestamps',
      () {
        final now = DateTime.now();
        final rawDocs = [
          {
            'id': 'legacy_doc_1',
            'isOnline': true,
            'manualAvailability': true,
            'lastHeartbeat': Timestamp.fromDate(now),
            'accountStatus': 'Active',
          },
          {
            'id': 'legacy_doc_2',
            'isOnline': false,
            'manualAvailability': false,
            'lastHeartbeat': Timestamp.fromDate(
              now.subtract(const Duration(hours: 1)),
            ),
            'accountStatus': 'Active',
          },
        ];

        final presence = presenceFromDoctorList(rawDocs);
        expect(presence.containsKey('legacy_doc_1'), isTrue);
        expect(presence['legacy_doc_1']!.isOnline, isTrue);
        expect(presence.containsKey('legacy_doc_2'), isTrue);
        expect(presence['legacy_doc_2']!.isOnline, isFalse);
      },
    );
  });
}
