import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';
import 'package:telemedicine/data/models/user_model.dart';

/// A raw Firestore reactivation-request document, as the admin list receives it.
Map<String, dynamic> _request(String id, Object? submittedAt) => {
      'id': id,
      'submittedAt': submittedAt,
    };

/// A patient payment record, as `getFilteredPaymentRequests` sees it.
UserModel _patient(String id, Object? submittedAt) => UserModel.fromMap({
      'id': id,
      'fullname': 'Patient $id',
      'paymentImage': 'https://example.com/$id.png',
      'paymentStatus': 'pending',
      'paymentSubmittedAt': submittedAt,
    });

void main() {
  group('parseFirestoreTimestamp', () {
    final expected = DateTime(2026, 3, 4, 5, 6, 7);

    test('parses an ISO String (how the patient writes paymentSubmittedAt)', () {
      expect(parseFirestoreTimestamp(expected.toIso8601String()), expected);
    });

    test('parses a Firestore Timestamp (how reactivation writes submittedAt)', () {
      expect(parseFirestoreTimestamp(Timestamp.fromDate(expected)), expected);
    });

    test('parses a DateTime and an epoch int', () {
      expect(parseFirestoreTimestamp(expected), expected);
      expect(
        parseFirestoreTimestamp(expected.millisecondsSinceEpoch),
        expected,
      );
    });

    test('returns null for missing, null and unparseable values', () {
      // A throw here would blank the whole admin list.
      expect(parseFirestoreTimestamp(null), isNull);
      expect(parseFirestoreTimestamp('not-a-date'), isNull);
      expect(parseFirestoreTimestamp(<String>['unexpected']), isNull);
    });
  });

  group('sortByTimestampDesc', () {
    test('newest submission is first', () {
      final result = sortByTimestampDesc<_Doc>(
        [
          _Doc('old', DateTime(2026, 1, 1, 9)),
          _Doc('new', DateTime(2026, 1, 1, 11)),
          _Doc('mid', DateTime(2026, 1, 1, 10)),
        ],
        (d) => d.at,
      );
      expect(result.map((d) => d.id), ['new', 'mid', 'old']);
    });

    test('reorders an arbitrary (document-id) input order', () {
      // This is the real bug: the query has no orderBy, so Firestore delivers
      // document-id order, which is arbitrary for UUID patient ids. Ids and
      // timestamps are deliberately set so that id order (a, m, z) is the exact
      // reverse of the correct newest-first order — only a real timestamp sort
      // can produce the expected result.
      final result = sortByTimestampDesc<_Doc>(
        [
          _Doc('a', DateTime(2026, 1, 1, 9)), // oldest, first by id
          _Doc('z', DateTime(2026, 1, 1, 12)), // newest, last by id
          _Doc('m', DateTime(2026, 1, 1, 10)),
        ],
        (d) => d.at,
      );
      expect(result.map((d) => d.id), ['z', 'm', 'a']);
    });

    test('items with no timestamp sink to the bottom but are NOT dropped', () {
      // The reason this is a client-side sort and not a Firestore orderBy:
      // orderBy would silently exclude documents lacking the field, hiding an
      // un-reviewed payment record from the admin.
      final result = sortByTimestampDesc<_Doc>(
        [
          const _Doc('legacy1'),
          _Doc('real', DateTime(2026, 1, 1, 12)),
          const _Doc('legacy2'),
        ],
        (d) => d.at,
        tieBreakOf: (d) => d.id,
      );
      expect(result.map((d) => d.id), ['real', 'legacy2', 'legacy1']);
    });

    test('a newly submitted item jumps to the top', () {
      final before = sortByTimestampDesc<_Doc>(
        [
          _Doc('a', DateTime(2026, 1, 1, 9)),
          _Doc('b', DateTime(2026, 1, 1, 10)),
        ],
        (d) => d.at,
      );
      expect(before.map((d) => d.id), ['b', 'a']);

      // Same list, one new proof arrives.
      final after = sortByTimestampDesc<_Doc>(
        [
          _Doc('a', DateTime(2026, 1, 1, 9)),
          _Doc('b', DateTime(2026, 1, 1, 10)),
          _Doc('fresh', DateTime(2026, 1, 1, 11)),
        ],
        (d) => d.at,
      );
      expect(after.map((d) => d.id), ['fresh', 'b', 'a']);
    });

    test('is stable for equal timestamps (no reshuffle between emissions)', () {
      final same = DateTime(2026, 1, 1, 12);
      final result = sortByTimestampDesc<_Doc>(
        [
          _Doc('one', same),
          _Doc('two', same),
          _Doc('three', same),
        ],
        (d) => d.at,
      );
      expect(result.map((d) => d.id), ['one', 'two', 'three']);
    });

    test('does not mutate the input list', () {
      final input = <_Doc>[
        _Doc('old', DateTime(2026, 1, 1, 9)),
        _Doc('new', DateTime(2026, 1, 1, 12)),
      ];
      sortByTimestampDesc<_Doc>(input, (d) => d.at);
      expect(input.map((d) => d.id), ['old', 'new']);
    });

    test('empty and single-item lists are handled', () {
      expect(sortByTimestampDesc<_Doc>(const [], (_) => null), isEmpty);
      expect(
        sortByTimestampDesc<_Doc>(const [_Doc('only')], (_) => null)
            .map((d) => d.id),
        ['only'],
      );
    });
  });

  group('payment records', () {
    test('orders reactivation requests newest-first from raw documents', () {
      final docs = [
        _request('a', Timestamp.fromDate(DateTime(2026, 1, 1, 9))),
        _request('b', Timestamp.fromDate(DateTime(2026, 1, 1, 11))),
        _request('c', Timestamp.fromDate(DateTime(2026, 1, 1, 10))),
      ];

      final result = sortByTimestampDesc<Map<String, dynamic>>(
        docs,
        (r) => parseFirestoreTimestamp(r['submittedAt']),
        tieBreakOf: (r) => (r['id'] ?? '').toString(),
      );
      expect(result.map((r) => r['id']), ['b', 'c', 'a']);
    });

    test('orders payment requests newest-first from UserModel', () {
      final users = [
        _patient('a', DateTime(2026, 1, 1, 9).toIso8601String()),
        _patient('b', DateTime(2026, 1, 1, 11).toIso8601String()),
        _patient('c', DateTime(2026, 1, 1, 10).toIso8601String()),
      ];

      final result = sortByTimestampDesc<UserModel>(
        users,
        (u) => u.paymentSubmittedAt,
        tieBreakOf: (u) => u.id,
      );
      expect(result.map((u) => u.id), ['b', 'c', 'a']);
    });

    test('a payment record with a Timestamp submission time does not throw', () {
      // Regression: UserModel.fromMap used a bare DateTime.tryParse, which only
      // accepts String and threw on a Timestamp — blanking the payment screen.
      final user = _patient('a', Timestamp.fromDate(DateTime(2026, 1, 1, 12)));
      expect(user.paymentSubmittedAt, DateTime(2026, 1, 1, 12));
    });

    test('a payment record with no submission time loads as null', () {
      final user = _patient('a', null);
      expect(user.paymentSubmittedAt, isNull);
      expect(
        sortByTimestampDesc<UserModel>([user], (u) => u.paymentSubmittedAt),
        hasLength(1),
      );
    });
  });
}

class _Doc {
  final String id;
  final DateTime? at;
  const _Doc(this.id, [this.at]);
}
