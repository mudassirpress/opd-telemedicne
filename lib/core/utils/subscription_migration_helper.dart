// lib/core/utils/subscription_migration_helper.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Client-side migration utility to backfill legacy patient card records
/// with `subscriptionPlan: 'six_months'` and `durationMonths: 6` without
/// touching or resetting existing expiry dates.
class SubscriptionMigrationHelper {
  const SubscriptionMigrationHelper._();

  /// Scans `patient_ids` and `telemedicine_patient` collections and safely backfills
  /// missing `subscriptionPlan` and `durationMonths` fields.
  static Future<Map<String, int>> runBackfill({bool dryRun = false}) async {
    final firestore = FirebaseFirestore.instance;
    int patientIdsUpdated = 0;
    int patientsUpdated = 0;

    try {
      // 1. Backfill patient_ids
      final pidSnapshot = await firestore.collection('patient_ids').get();
      WriteBatch pidBatch = firestore.batch();
      int pidBatchCount = 0;

      for (final doc in pidSnapshot.docs) {
        final data = doc.data();
        if (data['subscriptionPlan'] == null ||
            data['durationMonths'] == null) {
          if (!dryRun) {
            pidBatch.update(doc.reference, {
              'subscriptionPlan': data['subscriptionPlan'] ?? 'six_months',
              'durationMonths': data['durationMonths'] ?? 6,
            });
            pidBatchCount++;
            if (pidBatchCount >= 400) {
              await pidBatch.commit();
              pidBatch = firestore.batch();
              pidBatchCount = 0;
            }
          }
          patientIdsUpdated++;
        }
      }

      if (!dryRun && pidBatchCount > 0) {
        await pidBatch.commit();
      }

      // 2. Backfill telemedicine_patient
      final patientSnapshot = await firestore
          .collection('telemedicine_patient')
          .get();
      WriteBatch patientBatch = firestore.batch();
      int patientBatchCount = 0;

      for (final doc in patientSnapshot.docs) {
        final data = doc.data();
        final bool isCardPatient =
            data['patientId'] != null ||
            data['expiryDate'] != null ||
            data['loginType'] == 'patientId';

        if (isCardPatient &&
            (data['subscriptionPlan'] == null ||
                data['durationMonths'] == null)) {
          if (!dryRun) {
            patientBatch.update(doc.reference, {
              'subscriptionPlan': data['subscriptionPlan'] ?? 'six_months',
              'durationMonths': data['durationMonths'] ?? 6,
            });
            patientBatchCount++;
            if (patientBatchCount >= 400) {
              await patientBatch.commit();
              patientBatch = firestore.batch();
              patientBatchCount = 0;
            }
          }
          patientsUpdated++;
        }
      }

      if (!dryRun && patientBatchCount > 0) {
        await patientBatch.commit();
      }

      debugPrint(
        'SubscriptionMigrationHelper finished: patient_ids=$patientIdsUpdated, '
        'telemedicine_patient=$patientsUpdated (dryRun=$dryRun)',
      );

      return {
        'patientIdsUpdated': patientIdsUpdated,
        'patientsUpdated': patientsUpdated,
      };
    } catch (e) {
      debugPrint('SubscriptionMigrationHelper error: $e');
      rethrow;
    }
  }
}
