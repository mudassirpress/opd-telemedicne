import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';

import 'hive_db_service.dart';

/// Local mirror of the `telemedicine_doctors` collection.
///
/// Pure persistence: this class knows nothing about Firestore or Riverpod. Its
/// job is to make a previously-fetched doctor list readable *synchronously* so
/// a doctor picker can paint on the first frame instead of showing a spinner
/// while the network round-trip completes.
///
/// The backend remains the source of truth; this is only a cache that the
/// background sync keeps current.
class OfflineDoctorService {
  OfflineDoctorService._();

  static final OfflineDoctorService instance = OfflineDoctorService._();

  /// Single key — the whole list is one snapshot, not a per-doctor box, because
  /// the list is always read and written as a unit.
  static const String listKey = 'doctor_list';

  /// Doctor fields that hold a date. Serialised as ISO 8601 strings because
  /// `jsonEncode` throws outright on a `DateTime`, and the Firestore stream
  /// delivers `lastSeen` as a `Timestamp` and `onlineSince` as a `DateTime`.
  static const List<String> _dateFields = <String>['lastSeen', 'onlineSince'];

  Box<String>? get _box => HiveDBService.doctorListBox;

  bool get _ready => HiveDBService.doctorListBoxReady;

  /// True when a usable doctor list is already on disk.
  ///
  /// False on a genuinely first launch, which is the only case where a
  /// consumer should have to wait for Firestore.
  bool get hasCachedDoctors {
    if (!_ready) return false;
    try {
      final raw = _box!.get(listKey);
      return raw != null && raw.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Reads the cached doctor list.
  ///
  /// Synchronous by design: an already-open Hive box serves reads from memory,
  /// so a consumer can have data in hand during `build()`. Returns an empty
  /// list — never null, never throws — when the cache is absent, empty or
  /// corrupt, so callers can render unconditionally.
  List<Map<String, dynamic>> readDoctors() {
    if (!_ready) return const <Map<String, dynamic>>[];
    try {
      final raw = _box!.get(listKey);
      if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Map<String, dynamic>>[];

      return decoded
          .map((item) {
            if (item is! Map) return <String, dynamic>{};
            final map = Map<String, dynamic>.from(item);
            // Restore the date fields to `DateTime` so a cached map has the same
            // shape as a live one. Consumers such as `presenceFromDoctorList`
            // would cope with either, but keeping the shapes identical means a
            // cached value and a synced value are indistinguishable downstream.
            for (final field in _dateFields) {
              final value = map[field];
              if (value is String && value.isNotEmpty) {
                map[field] = DateTime.tryParse(value);
              } else if (value != null && value is! DateTime) {
                map[field] = parseFirestoreTimestamp(value);
              }
            }
            return map;
          })
          .where((map) => (map['id'] ?? '').toString().isNotEmpty)
          .toList();
    } catch (e) {
      // A corrupt or old-format cache must degrade to "empty", never crash the
      // screen that is trying to render from it.
      print('Error reading doctor list from Hive: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// Recursively converts Firestore [Timestamp] and [DateTime] objects to
  /// encodable ISO-8601 strings across maps and lists.
  static dynamic sanitizeForStorage(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Map) {
      final sanitized = <String, dynamic>{};
      for (final entry in value.entries) {
        sanitized[entry.key.toString()] = sanitizeForStorage(entry.value);
      }
      return sanitized;
    }
    if (value is Iterable) {
      return value.map(sanitizeForStorage).toList();
    }
    return value;
  }

  /// Persists the doctor list. Silently no-ops when the box is unavailable.
  Future<void> saveDoctors(List<Map<String, dynamic>> doctors) async {
    if (!_ready) return;
    try {
      final encodable = doctors.map((doctor) {
        final sanitized = sanitizeForStorage(doctor) as Map<String, dynamic>;
        for (final field in _dateFields) {
          final parsed = parseFirestoreTimestamp(sanitized[field]);
          if (parsed != null) sanitized[field] = parsed.toIso8601String();
        }
        return sanitized;
      }).toList();
      await _box!.put(
        listKey,
        jsonEncode(
          encodable,
          toEncodable: (nonEncodable) {
            if (nonEncodable is Timestamp) {
              return nonEncodable.toDate().toIso8601String();
            }
            if (nonEncodable is DateTime) {
              return nonEncodable.toIso8601String();
            }
            return nonEncodable.toString();
          },
        ),
      );
    } catch (e) {
      print('Error saving doctor list to Hive: $e');
    }
  }

  /// Cheap check used to avoid rewriting an unchanged snapshot.
  ///
  /// Compares the doctor ids and the fields the UI actually renders, rather
  /// than the whole JSON: the shared stream re-emits every 15 seconds purely to
  /// refresh online status, and treating that as a change would rewrite the
  /// Hive box on every tick.
  ///
  /// Static, and free of Hive state, so it can be unit-tested directly.
  static bool isEquivalent(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i]['id'] ?? '').toString() != (b[i]['id'] ?? '').toString()) {
        return false;
      }
      if ((a[i]['fullname'] ?? '').toString() !=
          (b[i]['fullname'] ?? '').toString()) {
        return false;
      }
      if ((a[i]['imageUrl'] ?? '').toString() !=
          (b[i]['imageUrl'] ?? '').toString()) {
        return false;
      }
      if ((a[i]['highestDegree'] ?? '').toString() !=
          (b[i]['highestDegree'] ?? '').toString()) {
        return false;
      }
      // The booking list renders the doctor's price, so a price edit has to
      // invalidate the mirror. Compared through the same null-tolerant shape
      // as the rest: an old cached snapshot simply has no `price` key.
      if ((a[i]['price'] ?? a[i]['consultationFee'] ?? '').toString() !=
          (b[i]['price'] ?? b[i]['consultationFee'] ?? '').toString()) {
        return false;
      }
      if ((a[i]['description'] ?? '').toString() !=
          (b[i]['description'] ?? '').toString()) {
        return false;
      }
    }
    return true;
  }

  /// Drops the local mirror. Used when the cached snapshot is untrustworthy.
  Future<void> clear() async {
    if (!_ready) return;
    try {
      await _box!.delete(listKey);
    } catch (e) {
      print('Error clearing doctor list cache: $e');
    }
  }
}
