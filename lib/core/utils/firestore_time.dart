import 'package:cloud_firestore/cloud_firestore.dart';

/// Normalises a Firestore date field to a [DateTime].
///
/// A single logical timestamp can be written in several shapes across this
/// codebase, and the same field can be written by different clients:
///
///   * `FieldValue.serverTimestamp()` -> `Timestamp`
///   * `DateTime.now().toIso8601String()` -> `String`  (how the patient writes
///     `telemedicine_patient.paymentSubmittedAt`)
///   * a native `DateTime`, e.g. handed back from a local conversion
///   * epoch `int`
///   * absent entirely, on records written before the field existed
///
/// Returns `null` for anything unrecognised rather than throwing, so a single
/// malformed record can never take down a list screen.
DateTime? parseFirestoreTimestamp(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is Timestamp) return value.toDate();
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}

/// Orders items newest-first by a timestamp, for admin review lists.
///
/// Contract:
///   * newest first — the most recently submitted item is at index 0;
///   * items with **no parseable timestamp sink to the bottom** and are NOT
///     dropped. This is the reason the admin lists sort client-side rather than
///     using a Firestore `orderBy`: a server-side `orderBy` silently excludes
///     documents that lack the field, so a record written before the field
///     existed would vanish from the admin's review list entirely;
///   * the sort is **stable** — equal timestamps keep the order the underlying
///     snapshot delivered, so the list does not reshuffle between the 15s
///     re-emissions or on an unrelated field update;
///   * when [tieBreakOf] is supplied, records sharing a timestamp are ordered by
///     it (descending) so two proofs submitted in the same millisecond have a
///     deterministic order instead of depending on snapshot order.
///
/// Returns a new list; [items] is left untouched.
List<T> sortByTimestampDesc<T>(
  List<T> items,
  DateTime? Function(T item) timestampOf, {
  String Function(T item)? tieBreakOf,
}) {
  final indexed = <({int index, T item, DateTime? ts, String tie})>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    indexed.add((
      index: i,
      item: item,
      ts: timestampOf(item),
      tie: tieBreakOf?.call(item) ?? '',
    ));
  }

  indexed.sort((a, b) {
    // A record with no timestamp always sorts after one that has one, whatever
    // the tie-break says.
    if (a.ts == null && b.ts == null) {
      final byTie = b.tie.compareTo(a.tie);
      return byTie != 0 ? byTie : a.index.compareTo(b.index);
    }
    if (a.ts == null) return 1;
    if (b.ts == null) return -1;

    final byTime = b.ts!.compareTo(a.ts!); // newest first
    if (byTime != 0) return byTime;

    if (tieBreakOf != null) {
      final byTie = b.tie.compareTo(a.tie);
      if (byTie != 0) return byTie;
    }
    return a.index.compareTo(b.index); // stable
  });

  return indexed.map((e) => e.item).toList(growable: false);
}
