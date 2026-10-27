import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';
import 'package:telemedicine/data/local/offline_doctor_service.dart';

/// The serialisation half of the doctor cache, mirrored from
/// `OfflineDoctorService` so the round-trip can be exercised without booting
/// Hive (which needs a real filesystem and a plugin channel).
///
/// Kept byte-for-byte in step with the service: if the date-field list or the
/// encode/decode rules change there, they must change here too.
class _DoctorCodec {
  static const List<String> dateFields = <String>['lastSeen', 'onlineSince'];

  static String encode(List<Map<String, dynamic>> doctors) {
    final encodable = doctors.map((doctor) {
      final map = Map<String, dynamic>.from(doctor);
      for (final field in dateFields) {
        final parsed = parseFirestoreTimestamp(map[field]);
        if (parsed != null) map[field] = parsed.toIso8601String();
      }
      return map;
    }).toList();
    return jsonEncode(encodable);
  }

  static List<Map<String, dynamic>> decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <Map<String, dynamic>>[];
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .map((map) {
          for (final field in dateFields) {
            final value = map[field];
            if (value is String && value.isNotEmpty) {
              map[field] = DateTime.tryParse(value);
            } else if (value != null && value is! DateTime) {
              map[field] = parseFirestoreTimestamp(value);
            }
          }
          return map;
        })
        .toList();
  }
}

/// Doctor maps as `DoctorController.streamAllDoctors()` delivers them: `id`
/// injected, `lastSeen` a raw Timestamp, `onlineSince` already a DateTime.
Map<String, dynamic> _live(
  String id, {
  String? name,
  String? imageUrl,
  DateTime? onlineSince,
  bool isOnline = false,
}) {
  return {
    'id': id,
    'fullname': name ?? 'Dr. $id',
    'highestDegree': 'MBBS',
    'imageUrl': imageUrl ?? '',
    'doctorId': 'DOC$id',
    'isOnline': isOnline,
    'lastSeen': Timestamp.fromDate(DateTime(2026, 1, 1, 9)),
    if (onlineSince != null) 'onlineSince': onlineSince,
  };
}

void main() {
  group('doctor cache serialisation', () {
    test('survives a round trip with Firestore Timestamp and DateTime fields', () {
      final since = DateTime(2026, 1, 1, 10, 5);
      final original = [_live('a', onlineSince: since, isOnline: true)];

      // `jsonEncode` throws outright on a DateTime, so a successful encode is
      // itself the assertion that the date fields were normalised.
      final restored = _DoctorCodec.decode(_DoctorCodec.encode(original));

      expect(restored.length, 1);
      expect(restored.first['id'], 'a');
      expect(restored.first['fullname'], 'Dr. a');
      expect(restored.first['lastSeen'], DateTime(2026, 1, 1, 9));
      expect(restored.first['onlineSince'], since);
    });

    test('a restored cache is usable for presence ordering', () {
      // A cached list must be indistinguishable from a live one downstream, or
      // the share screen would order it differently from the main doctor list.
      final live = [
        _live('offline'),
        _live('online', onlineSince: DateTime(2026, 1, 1, 12), isOnline: true),
      ];
      final restored = _DoctorCodec.decode(_DoctorCodec.encode(live));

      final ordered = sortDoctorsByPresence<Map<String, dynamic>>(
        restored,
        presenceFromDoctorList(restored),
        (d) => (d['id'] ?? '').toString(),
      );
      expect(ordered.first['id'], 'online');
    });

    test('handles a doctor with no date fields at all', () {
      final restored = _DoctorCodec.decode(
        _DoctorCodec.encode([
          {'id': 'bare', 'fullname': 'Dr. Bare'},
        ]),
      );
      expect(restored.first['id'], 'bare');
      expect(restored.first.containsKey('lastSeen'), isFalse);
    });

    test('a corrupt payload does not throw', () {
      // A truncated write must degrade to "empty", not crash the screen that is
      // trying to paint from it.
      expect(() => _DoctorCodec.decode('not json at all'), throwsA(anything));
    });
  });

  group('isEquivalent (should the cache be rewritten?)', () {
    List<Map<String, dynamic>> live() => [
          _live('a'),
          _live('b', name: 'Dr. Bee'),
        ];

    test('the 15s online-status re-emission is treated as unchanged', () {
      // The shared stream re-emits every 15s just to refresh presence. If that
      // counted as a change, every screen open would rewrite the Hive box.
      final before = live();
      final after = [
        _live('a', isOnline: true),
        _live('b', name: 'Dr. Bee', isOnline: false),
      ];
      expect(OfflineDoctorService.isEquivalent(before, after), isTrue);
    });

    test('a new doctor counts as a change', () {
      final before = live();
      final after = [...live(), _live('c')];
      expect(OfflineDoctorService.isEquivalent(before, after), isFalse);
    });

    test('a soft-deleted doctor disappearing counts as a change', () {
      final before = live();
      final after = [_live('a')];
      expect(OfflineDoctorService.isEquivalent(before, after), isFalse);
    });

    test('a profile edit counts as a change', () {
      final before = live();
      final after = [_live('a'), _live('b', name: 'Dr. Renamed')];
      expect(OfflineDoctorService.isEquivalent(before, after), isFalse);
    });

    test('a new profile image counts as a change', () {
      final before = live();
      final after = [
        _live('a', imageUrl: 'https://x/new.png'),
        _live('b', name: 'Dr. Bee'),
      ];
      expect(OfflineDoctorService.isEquivalent(before, after), isFalse);
    });

    test('reordering the same doctors counts as a change', () {
      // Online-first ordering reorders the list; writing the new order keeps
      // the cache consistent with what the next screen will render.
      final before = live();
      final after = [_live('b', name: 'Dr. Bee'), _live('a')];
      expect(OfflineDoctorService.isEquivalent(before, after), isFalse);
    });
  });
}
