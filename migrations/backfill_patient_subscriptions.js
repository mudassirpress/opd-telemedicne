// migrations/backfill_patient_subscriptions.js
//
// LEGACY PATIENT SUBSCRIPTION BACKFILL SCRIPT
// ============================================
//
// Existing patients have 6-month subscriptions created before multi-plan support.
// This script safely backfills `subscriptionPlan: 'six_months'` and `durationMonths: 6`
// on legacy `patient_ids` and `telemedicine_patient` documents WITHOUT modifying or resetting
// existing expiry dates.
//
// Usage:
//   node migrations/backfill_patient_subscriptions.js [--dry-run]
//

const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const isDryRun = process.argv.includes('--dry-run');

async function backfillPatientIds() {
  console.log(`[patient_ids] Starting scan... (dryRun=${isDryRun})`);
  const snapshot = await db.collection('patient_ids').get();
  let updated = 0;
  let skipped = 0;

  const batchSize = 400;
  let batch = db.batch();
  let batchCount = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    if (!data.subscriptionPlan || !data.durationMonths) {
      if (!isDryRun) {
        batch.update(doc.ref, {
          subscriptionPlan: data.subscriptionPlan || 'six_months',
          durationMonths: data.durationMonths || 6,
        });
        batchCount++;
        if (batchCount >= batchSize) {
          await batch.commit();
          batch = db.batch();
          batchCount = 0;
        }
      }
      updated++;
    } else {
      skipped++;
    }
  }

  if (!isDryRun && batchCount > 0) {
    await batch.commit();
  }

  console.log(`[patient_ids] Backfill finished. Updated: ${updated}, Already valid: ${skipped}`);
}

async function backfillPatients() {
  console.log(`[telemedicine_patient] Starting scan... (dryRun=${isDryRun})`);
  const snapshot = await db.collection('telemedicine_patient').get();
  let updated = 0;
  let skipped = 0;

  const batchSize = 400;
  let batch = db.batch();
  let batchCount = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    // Only backfill patients who have a patientId (card users) or an expiryDate
    const isCardPatient = data.patientId || data.expiryDate || data.loginType === 'patientId';
    if (isCardPatient && (!data.subscriptionPlan || !data.durationMonths)) {
      if (!isDryRun) {
        batch.update(doc.ref, {
          subscriptionPlan: data.subscriptionPlan || 'six_months',
          durationMonths: data.durationMonths || 6,
        });
        batchCount++;
        if (batchCount >= batchSize) {
          await batch.commit();
          batch = db.batch();
          batchCount = 0;
        }
      }
      updated++;
    } else {
      skipped++;
    }
  }

  if (!isDryRun && batchCount > 0) {
    await batch.commit();
  }

  console.log(`[telemedicine_patient] Backfill finished. Updated: ${updated}, Skipped: ${skipped}`);
}

async function run() {
  try {
    await backfillPatientIds();
    await backfillPatients();
    console.log('✅ Migration script finished successfully.');
    process.exit(0);
  } catch (error) {
    console.error('❌ Migration failed:', error);
    process.exit(1);
  }
}

run();
