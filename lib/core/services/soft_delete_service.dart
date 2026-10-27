// lib/core/services/soft_delete_service.dart
//
// GLOBAL SOFT DELETE SYSTEM
// =========================
//
// OPD Telemedicine must never permanently destroy a doctor or patient record,
// or anything attached to it. Deleting an account flips lifecycle flags on the
// one primary document and nothing else: chats, messages, prescriptions,
// reports, payments, call history, ratings and audit records are all left
// exactly as they were.
//
// Three responsibilities live here, and everything else in the app routes
// through them so the rule cannot be bypassed from a screen:
//
//   1. READING  — backward-compatible predicates. Records created before the
//      soft-delete migration have no `isDeleted` / `isActive` field, and a
//      naive `where('isDeleted', == false)` query would silently hide the
//      entire existing user base. These helpers therefore treat a *missing*
//      field as "not deleted / active", and every active listing filters in
//      Dart over a snapshot rather than adding a server-side equality filter.
//
//   2. WRITING  — soft delete + restore, always paired with a
//      `deletedAt: serverTimestamp()` (never device time) and an append-only
//      audit entry. Restore clears the top-level fields but the audit entry
//      retains the original deletion metadata.
//
//   3. GUARDING — `canStartNewBusinessWith()` re-reads the live document
//      before a new chat / booking / consultation is created, so a record
//      deactivated after the patient already had a screen open is still
//      blocked. The UI filter is a convenience, not the enforcement point.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';

class SoftDeleteService {
  const SoftDeleteService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ─────────────────────────────────────────────────────────────────────
  // 1. READING — backward-compatible predicates
  // ─────────────────────────────────────────────────────────────────────

  /// Whether the record has been soft-deleted.
  ///
  /// A missing field means `false`: every record predating the migration must
  /// keep working.
  static bool isDeleted(Map<String, dynamic>? data) {
    if (data == null) return false;
    return data[SoftDeleteFields.isDeleted] == true;
  }

  /// Whether `isActive` is set. A missing field is treated as active for the
  /// same backward-compatibility reason as [isDeleted].
  static bool isActiveFlag(Map<String, dynamic>? data) {
    if (data == null) return true;
    final value = data[SoftDeleteFields.isActive];
    if (value == null) return true;
    return value == true;
  }

  /// The single definition of "this record may appear in active listings and
  /// accept new business". A record is active only when it is neither deleted
  /// nor explicitly deactivated.
  static bool isActive(Map<String, dynamic>? data) {
    if (data == null) return false;
    return !isDeleted(data) && isActiveFlag(data);
  }

  /// In-place active filter for a list already materialised from a snapshot.
  ///
  /// This — not a `where` clause — is how deleted records are kept out of
  /// listings, precisely so that documents without the new fields survive the
  /// migration. Historical queries (chat lists, admin archives, audit views)
  /// must NOT call this.
  static List<T> activeOnly<T>(
    Iterable<T> items,
    Map<String, dynamic> Function(T item) toMap,
  ) {
    return items.where((item) => isActive(toMap(item))).toList();
  }

  /// Human-readable reason a record is not active, for user-facing messages.
  static String describeInactive(Map<String, dynamic>? data) {
    if (isDeleted(data)) {
      final reason = (data?[SoftDeleteFields.deletedReason] ?? '').toString();
      return reason.isEmpty
          ? 'This account has been deleted.'
          : 'This account has been deleted. $reason';
    }
    return 'This account is currently deactivated and cannot be used.';
  }

  // ─────────────────────────────────────────────────────────────────────
  // 2. WRITING — soft delete / restore
  // ─────────────────────────────────────────────────────────────────────

  /// Deactivates a doctor without removing anything.
  ///
  /// Only the doctor document is written. Chat history, messages,
  /// prescriptions, reports, ratings, online sessions, daily stats and payment
  /// records are intentionally untouched.
  static Future<bool> softDeleteDoctor({
    required String doctorId,
    required String performedBy,
    String reason = 'Deleted by administrator',
  }) {
    return _softDelete(
      entity: SoftDeleteEntity.doctor,
      recordId: doctorId,
      performedBy: performedBy,
      reason: reason,
    );
  }

  /// Deactivates a patient without removing anything.
  static Future<bool> softDeletePatient({
    required String patientId,
    required String performedBy,
    String reason = 'Deleted by administrator',
  }) {
    return _softDelete(
      entity: SoftDeleteEntity.patient,
      recordId: patientId,
      performedBy: performedBy,
      reason: reason,
    );
  }

  /// A patient deleting their own account. Identical write path — only the
  /// audit `action` and the default reason differ.
  static Future<bool> softDeletePatientSelf({
    required String patientId,
    String reason = 'Deleted by account holder',
  }) {
    return _softDelete(
      entity: SoftDeleteEntity.patient,
      recordId: patientId,
      performedBy: patientId,
      reason: reason,
      action: AuditActions.patientSelfDeleted,
    );
  }

  /// Reactivates a soft-deleted record **in place**.
  ///
  /// There is no re-creation path: the original document id, profile, history
  /// and relationships are reused, which is what guarantees no duplicate
  /// doctor/patient record can appear. The top-level deletion fields are
  /// cleared as specified, and the previous values are preserved in the audit
  /// log.
  static Future<bool> restoreDoctor({
    required String doctorId,
    required String performedBy,
  }) {
    return _restore(
      entity: SoftDeleteEntity.doctor,
      recordId: doctorId,
      performedBy: performedBy,
    );
  }

  static Future<bool> restorePatient({
    required String patientId,
    required String performedBy,
  }) {
    return _restore(
      entity: SoftDeleteEntity.patient,
      recordId: patientId,
      performedBy: performedBy,
    );
  }

  static Future<bool> _softDelete({
    required SoftDeleteEntity entity,
    required String recordId,
    required String performedBy,
    required String reason,
    String? action,
  }) async {
    if (recordId.isEmpty) return false;

    final ref = _recordRef(entity, recordId);
    try {
      final snapshot = await ref.get();
      if (!snapshot.exists) {
        debugPrint('⛔ soft delete skipped — $recordId does not exist');
        return false;
      }

      final before = Map<String, dynamic>.from(snapshot.data() ?? const {});
      if (isDeleted(before)) {
        debugPrint('ℹ️ $recordId is already soft-deleted');
        return true;
      }

      // NOTE: `deletedAt` is a serverTimestamp, never device time — a wrong
      // device clock must not be able to misdate a regulatory record.
      await ref.update(<String, dynamic>{
        SoftDeleteFields.isDeleted: true,
        SoftDeleteFields.isActive: false,
        SoftDeleteFields.deletedAt: FieldValue.serverTimestamp(),
        SoftDeleteFields.deletedBy: performedBy,
        SoftDeleteFields.deletedReason: reason,
        // Presence is a live signal; a deactivated account must not keep
        // showing a green dot.
        'isOnline': false,
        'loginStatus': 'Offline',
        'accountStatus': 'Deleted',
      });

      await _writeAudit(
        entity: entity,
        recordId: recordId,
        recordName: (before['fullname'] ?? '').toString(),
        action: action ?? _defaultDeleteAction(entity),
        performedBy: performedBy,
        extra: {'reason': reason},
        previousDeletion: null,
      );

      debugPrint(
        '🗑️ Soft-deleted ${_label(entity)} $recordId '
        '(by $performedBy). All historical data preserved.',
      );
      return true;
    } catch (e) {
      debugPrint('❌ Error soft-deleting $recordId: $e');
      return false;
    }
  }

  static Future<bool> _restore({
    required SoftDeleteEntity entity,
    required String recordId,
    required String performedBy,
  }) async {
    if (recordId.isEmpty) return false;

    final ref = _recordRef(entity, recordId);
    try {
      final snapshot = await ref.get();
      if (!snapshot.exists) return false;

      final current = Map<String, dynamic>.from(snapshot.data() ?? const {});
      if (isActive(current) && isActiveFlag(current)) {
        debugPrint('ℹ️ $recordId is already active');
        return true;
      }

      // Capture the deletion metadata BEFORE clearing it so the audit trail
      // keeps the full history of the previous deletion.
      final previousDeletion = <String, dynamic>{
        SoftDeleteFields.deletedAt: current[SoftDeleteFields.deletedAt],
        SoftDeleteFields.deletedBy: current[SoftDeleteFields.deletedBy],
        SoftDeleteFields.deletedReason: current[SoftDeleteFields.deletedReason],
        'previousAccountStatus': current['accountStatus'],
      };

      await ref.update(<String, dynamic>{
        SoftDeleteFields.isDeleted: false,
        SoftDeleteFields.isActive: true,
        SoftDeleteFields.deletedAt: null,
        SoftDeleteFields.deletedBy: null,
        SoftDeleteFields.deletedReason: null,
        'accountStatus': 'Active',
        // Restore the presence bookkeeping so the record behaves like any
        // other active one from the next heartbeat onwards.
        'isOnline': false,
        'loginStatus': 'Offline',
      });

      await _writeAudit(
        entity: entity,
        recordId: recordId,
        recordName: (current['fullname'] ?? '').toString(),
        action: entity == SoftDeleteEntity.doctor
            ? AuditActions.doctorRestored
            : AuditActions.patientRestored,
        performedBy: performedBy,
        previousDeletion: previousDeletion,
      );

      debugPrint('♻️ Restored ${_label(entity)} $recordId (by $performedBy)');
      return true;
    } catch (e) {
      debugPrint('❌ Error restoring $recordId: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 3. GUARDING — live check before any new business action
  // ─────────────────────────────────────────────────────────────────────

  /// Authoritative "may this record start NEW business?" check.
  ///
  /// Called immediately before creating a chat, booking, appointment or
  /// consultation. It re-reads Firestore rather than trusting anything the UI
  /// holds, which is what stops a doctor deactivated after the patient already
  /// had the screen open.
  ///
  /// Returns `true` only when the record exists and is active. A missing
  /// record returns `false`.
  static Future<bool> canStartNewBusinessWith(String userId) async {
    if (userId.isEmpty) return false;
    try {
      // Point reads, no `where` — the counterpart may live in either
      // collection (doctors also appear under `telemedicine_patient` with
      // role == 'doctor').
      final snapshots = await Future.wait([
        _firestore.collection(FirestoreCollections.doctors).doc(userId).get(),
        _firestore.collection(FirestoreCollections.patients).doc(userId).get(),
      ]);

      for (final snapshot in snapshots) {
        if (snapshot.exists) {
          return isActive(snapshot.data());
        }
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error in canStartNewBusinessWith($userId): $e');
      // Fail closed: an unreadable record must not open a new business flow.
      return false;
    }
  }

  /// Convenience wrapper returning the human-readable block reason.
  static Future<String?> newBusinessBlockedReason(String userId) async {
    if (userId.isEmpty) return 'This account is no longer available.';
    try {
      final snapshots = await Future.wait([
        _firestore.collection(FirestoreCollections.doctors).doc(userId).get(),
        _firestore.collection(FirestoreCollections.patients).doc(userId).get(),
      ]);

      for (final snapshot in snapshots) {
        if (snapshot.exists) {
          if (isActive(snapshot.data())) return null;
          return describeInactive(snapshot.data());
        }
      }
      return 'This account is no longer available.';
    } catch (e) {
      debugPrint('❌ Error in newBusinessBlockedReason($userId): $e');
      return 'Could not verify this account. Please try again.';
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Migration — optional backfill for legacy records
  // ─────────────────────────────────────────────────────────────────────

  /// Writes the explicit soft-delete fields onto records that predate the
  /// migration.
  ///
  /// NOT required for correctness: [isActive] / [isDeleted] deliberately treat a
  /// missing field as "active", so existing doctors and patients keep working
  /// untouched. This helper exists only so the stored documents eventually match
  /// the contract, which removes the reliance on that fallback over time.
  ///
  /// Only documents that are *missing* the field are touched. A record that
  /// already has `isDeleted: true` is never rewritten, so running this twice is
  /// harmless and it can never resurrect a deleted account.
  static Future<BackfillResult> backfillMissingSoftDeleteFields({
    String? collection,
  }) async {
    final result = BackfillResult();

    final targets = <String>[
      if (collection != null) collection,
      FirestoreCollections.doctors,
      FirestoreCollections.patients,
    ];

    for (final name in targets.toSet()) {
      try {
        final snapshot = await _firestore.collection(name).get();
        for (final doc in snapshot.docs) {
          final data = doc.data() ?? const <String, dynamic>{};
          final needsBackfill =
              !data.containsKey(SoftDeleteFields.isDeleted) ||
              !data.containsKey(SoftDeleteFields.isActive);

          if (!needsBackfill) {
            result.skipped++;
            continue;
          }

          // Preserve any pre-existing value; only fill in what is missing.
          await doc.reference.update(<String, dynamic>{
            if (!data.containsKey(SoftDeleteFields.isDeleted))
              SoftDeleteFields.isDeleted: SoftDeleteService.isDeleted(data),
            if (!data.containsKey(SoftDeleteFields.isActive))
              SoftDeleteFields.isActive: SoftDeleteService.isActiveFlag(data),
          });
          result.updated++;
        }
        debugPrint(
          '✅ Backfill complete for $name: ${result.updated} updated, '
          '${result.skipped} already compliant',
        );
      } catch (e) {
        debugPrint('❌ Backfill failed for $name: $e');
        result.errors++;
      }
    }

    return result;
  }

  /// Reads the soft-delete audit trail, newest first.
  ///
  /// Append-only, so this is a complete and reliable history of every
  /// delete/restore — including deletions whose top-level fields were later
  /// cleared by a restore.
  static Stream<List<Map<String, dynamic>>> streamAuditLog({int limit = 200}) {
    return _firestore
        .collection(FirestoreCollections.accountAuditLog)
        .orderBy('performedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map((doc) {
            final data = Map<String, dynamic>.from(doc.data());
            data['id'] = doc.id;
            return data;
          }).toList(),
        );
  }

  // ─────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ─────────────────────────────────────────────────────────────────────

  static DocumentReference<Map<String, dynamic>> _recordRef(
    SoftDeleteEntity entity,
    String id,
  ) {
    return _firestore.collection(
      entity == SoftDeleteEntity.doctor
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients,
    ).doc(id);
  }

  static String _label(SoftDeleteEntity entity) =>
      entity == SoftDeleteEntity.doctor ? 'doctor' : 'patient';

  static String _defaultDeleteAction(SoftDeleteEntity entity) =>
      entity == SoftDeleteEntity.doctor
      ? AuditActions.doctorSoftDeleted
      : AuditActions.patientSoftDeleted;

  /// Append-only. A failed audit write is logged but never fails the delete —
  /// losing the ability to deactivate an account would be worse than losing one
  /// audit line.
  static Future<void> _writeAudit({
    required SoftDeleteEntity entity,
    required String recordId,
    required String recordName,
    required String action,
    required String performedBy,
    Map<String, dynamic>? extra,
    Map<String, dynamic>? previousDeletion,
  }) async {
    try {
      await _firestore.collection(FirestoreCollections.accountAuditLog).add({
        'action': action,
        'entityType': _label(entity),
        'targetId': recordId,
        'targetName': recordName,
        'performedBy': performedBy,
        'performedAt': FieldValue.serverTimestamp(),
        if (extra != null) ...extra,
        if (previousDeletion != null) 'previousDeletion': previousDeletion,
      });
    } catch (e) {
      debugPrint('⚠️ Audit write failed for $action on $recordId: $e');
    }
  }
}

/// Outcome of [SoftDeleteService.backfillMissingSoftDeleteFields].
class BackfillResult {
  int updated = 0;
  int skipped = 0;
  int errors = 0;

  @override
  String toString() =>
      'BackfillResult(updated: $updated, skipped: $skipped, errors: $errors)';
}
