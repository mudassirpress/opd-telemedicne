import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';

/// Doctors are identified by their Firestore document id, as in the real list.
class _Doc {
  final String id;
  const _Doc(this.id);
}

DoctorPresenceData _online(DateTime since) =>
    DoctorPresenceData(isOnline: true, lastSeen: since, onlineSince: since);

DoctorPresenceData _offline() => const DoctorPresenceData(isOnline: false);

void main() {
  group('sortDoctorsByPresence', () {
    test('puts online doctors before offline doctors', () {
      final result = sortDoctorsByPresence<_Doc>(
        const [_Doc('a'), _Doc('b')],
        {'a': _offline(), 'b': _online(DateTime(2026, 1, 1, 10))},
        (d) => d.id,
      );
      expect(result.map((d) => d.id), ['b', 'a']);
    });

    test('most recently online doctor is first', () {
      // A comes online at 10:00, B at 10:05 -> B above A.
      final result = sortDoctorsByPresence<_Doc>(
        const [_Doc('a'), _Doc('b')],
        {
          'a': _online(DateTime(2026, 1, 1, 10, 0)),
          'b': _online(DateTime(2026, 1, 1, 10, 5)),
        },
        (d) => d.id,
      );
      expect(result.map((d) => d.id), ['b', 'a']);
    });

    test('a doctor going offline drops below the still-online ones', () {
      // A was online at 10:00, B at 10:05, then A drops offline.
      final result = sortDoctorsByPresence<_Doc>(
        const [_Doc('a'), _Doc('b')],
        {'a': _offline(), 'b': _online(DateTime(2026, 1, 1, 10, 5))},
        (d) => d.id,
      );
      expect(result.map((d) => d.id), ['b', 'a']);
    });

    test('full mix: online newest-first, then offline in original order', () {
      final result = sortDoctorsByPresence<_Doc>(
        const [_Doc('off1'), _Doc('onOld'), _Doc('off2'), _Doc('onNew')],
        {
          'off1': _offline(),
          'off2': _offline(),
          'onOld': _online(DateTime(2026, 1, 1, 9, 0)),
          'onNew': _online(DateTime(2026, 1, 1, 11, 0)),
        },
        (d) => d.id,
      );
      expect(result.map((d) => d.id), ['onNew', 'onOld', 'off1', 'off2']);
    });

    test('doctor with no onlineSince sorts below those that have one', () {
      final result = sortDoctorsByPresence<_Doc>(
        const [_Doc('legacy'), _Doc('known')],
        {
          'legacy': const DoctorPresenceData(isOnline: true),
          'known': _online(DateTime(2026, 1, 1, 8, 0)),
        },
        (d) => d.id,
      );
      expect(result.map((d) => d.id), ['known', 'legacy']);
    });

    test('missing presence entry is treated as offline', () {
      final result = sortDoctorsByPresence<_Doc>(
        const [_Doc('unknown'), _Doc('known')],
        {'known': _online(DateTime(2026, 1, 1, 7, 0))},
        (d) => d.id,
      );
      expect(result.map((d) => d.id), ['known', 'unknown']);
    });

    test('does not mutate the input list', () {
      final input = <_Doc>[const _Doc('a'), const _Doc('b')];
      sortDoctorsByPresence<_Doc>(input, {
        'a': _offline(),
        'b': _online(DateTime(2026, 1, 1, 12)),
      }, (d) => d.id);
      expect(input.map((d) => d.id), ['a', 'b']);
    });

    test('empty list is handled', () {
      expect(
        sortDoctorsByPresence<_Doc>(const [], const {}, (d) => d.id),
        isEmpty,
      );
    });
  });

  group('presenceFromDoctorList', () {
    // Regression: doctor maps carry `lastSeen` as a raw Firestore Timestamp
    // while `onlineSince` is a DateTime. Casting both to DateTime? threw
    // "type 'Timestamp' is not a subtype of type 'DateTime?'".
    test('accepts a Timestamp for lastSeen and a DateTime for onlineSince', () {
      final since = DateTime(2026, 1, 1, 10, 5);
      final presence = presenceFromDoctorList([
        {
          'id': 'a',
          'isOnline': true,
          'lastSeen': Timestamp.fromDate(since),
          'onlineSince': since,
        },
      ]);

      expect(presence['a']!.isOnline, isTrue);
      expect(presence['a']!.lastSeen, since);
      expect(presence['a']!.onlineSince, since);
    });

    test('accepts a Timestamp for onlineSince too', () {
      final since = DateTime(2026, 1, 1, 9);
      final presence = presenceFromDoctorList([
        {'id': 'a', 'isOnline': true, 'onlineSince': Timestamp.fromDate(since)},
      ]);
      expect(presence['a']!.onlineSince, since);
    });

    test('tolerates missing and null date fields', () {
      final presence = presenceFromDoctorList([
        {'id': 'a', 'isOnline': true},
        {'id': 'b', 'isOnline': false, 'lastSeen': null, 'onlineSince': null},
      ]);
      expect(presence['a']!.lastSeen, isNull);
      expect(presence['a']!.onlineSince, isNull);
      expect(presence['b']!.lastSeen, isNull);
      expect(presence['b']!.isOnline, isFalse);
    });

    test('skips entries without a document id', () {
      final presence = presenceFromDoctorList([
        {'isOnline': true},
        {'id': '', 'isOnline': true},
        {'id': 'c', 'isOnline': true},
      ]);
      expect(presence.keys, ['c']);
    });

    test(
      'doctor maps straight from streamAllDoctors order without throwing',
      () {
        final result = sortDoctorsByPresence<Map<String, dynamic>>(
          [
            {'id': 'off', 'isOnline': false, 'lastSeen': Timestamp.now()},
            {
              'id': 'on',
              'isOnline': true,
              'lastSeen': Timestamp.now(),
              'onlineSince': DateTime(2026, 1, 1, 12),
            },
          ],
          presenceFromDoctorList([
            {
              'id': 'on',
              'isOnline': true,
              'lastSeen': Timestamp.now(),
              'onlineSince': DateTime(2026, 1, 1, 12),
            },
            {'id': 'off', 'isOnline': false, 'lastSeen': Timestamp.now()},
          ]),
          (d) => (d['id'] ?? '').toString(),
        );
        expect(result.first['id'], 'on');
      },
    );
  });

  group('presenceForDoctorList', () {
    test('centralized entries win over the list-derived ones', () {
      // The list stream still says "online" (its 15s re-evaluation has not
      // fired yet) while the centralized service has already gone offline.
      final merged = presenceForDoctorList(
        [
          {
            'id': 'a',
            'isOnline': true,
            'lastSeen': DateTime(2026, 1, 1, 10),
            'onlineSince': DateTime(2026, 1, 1, 10),
          },
        ],
        {'a': const DoctorPresenceData(isOnline: false)},
      );

      expect(merged['a']!.isOnline, isFalse);
    });

    test('falls back to the list-derived entry when the service has none', () {
      final merged = presenceForDoctorList([
        {'id': 'a', 'isOnline': true, 'onlineSince': DateTime(2026, 1, 1, 10)},
      ], const <String, DoctorPresenceData>{});

      expect(merged['a']!.isOnline, isTrue);
      expect(merged['a']!.onlineSince, DateTime(2026, 1, 1, 10));
    });

    test('an empty centralized map behaves exactly like the list alone', () {
      final doctors = [
        {'id': 'a', 'isOnline': false},
        {'id': 'b', 'isOnline': true, 'onlineSince': DateTime(2026, 1, 1, 9)},
      ];
      expect(
        presenceForDoctorList(doctors, const {}).keys,
        presenceFromDoctorList(doctors).keys,
      );
    });
  });
}
