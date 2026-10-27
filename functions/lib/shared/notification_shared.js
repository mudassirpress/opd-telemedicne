/**
 * Shared Admin-SDK helpers for the notification senders.
 *
 * These live outside `index.js` because the callable `requestDoctorCall`
 * (doctor_presence.js) and the Firestore call trigger (index.js) must use the
 * exact same identity/token/idempotency code. Duplicating it is how the two
 * call paths drifted apart in the first place.
 */

const admin = require("firebase-admin");
const {pickFcmToken, NOTIFICATION_EVENT_COLLECTION} = require("./fcm_helpers.js");

/**
 * Look up the latest FCM registration token for a user. The user may live in
 * either the patient collection or the doctor collection, so both are checked.
 */
async function findFcmToken(userId) {
    if (!userId) return null;
    const patientDoc = await admin.firestore()
        .collection("telemedicine_patient")
        .doc(userId)
        .get();
    if (patientDoc.exists) {
        const patientToken = pickFcmToken(patientDoc.data());
        if (patientToken) return patientToken;
    }
    const doctorDoc = await admin.firestore()
        .collection("telemedicine_doctors")
        .doc(userId)
        .get();
    if (doctorDoc.exists) {
        return pickFcmToken(doctorDoc.data());
    }
    return null;
}

/**
 * Get display info (name / image / role type) for a user.
 * Falls back gracefully when the user cannot be found (e.g. admin sender).
 */
async function findUserInfo(userId) {
    if (!userId) return null;
    const patientDoc = await admin.firestore()
        .collection("telemedicine_patient")
        .doc(userId)
        .get();
    if (patientDoc.exists) {
        const data = patientDoc.data();
        return {
            name: data.fullname || data.fullName || "A patient",
            image: data.image || data.imageUrl || "",
            // Collection membership is authoritative; `role` can be capitalised
            // or stale on older documents.
            type: "patient",
        };
    }
    const doctorDoc = await admin.firestore()
        .collection("telemedicine_doctors")
        .doc(userId)
        .get();
    if (doctorDoc.exists) {
        const data = doctorDoc.data();
        return {
            name: data.fullname || data.fullName || "A doctor",
            image: data.image || data.imageUrl || "",
            type: "doctor",
        };
    }
    return null;
}

/**
 * Removes an FCM token that FCM has rejected as undeliverable.
 *
 * A rotated or uninstalled token can never be delivered to again, and while
 * it sits on the user document every chat / call push for that user fails
 * silently. Clearing it makes the failure visible on the document (and in the
 * logs); the client re-registers a fresh token on its next app open.
 */
async function clearStaleFcmToken(userId, staleToken) {
    if (!userId || !staleToken) return;
    const db = admin.firestore();
    for (const collection of ["telemedicine_patient", "telemedicine_doctors"]) {
        const ref = db.collection(collection).doc(userId);
        const doc = await ref.get();
        if (doc.exists && doc.data().fcmToken === staleToken) {
            await ref.set({
                fcmToken: admin.firestore.FieldValue.delete(),
                lastTokenClearedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, {merge: true});
            console.log(`[FCM] STALE_TOKEN_CLEARED collection=${collection} userId=${userId}`);
        }
    }
}

/**
 * Claims a notification event exactly once.
 *
 * Firestore triggers are at-least-once: a retried invocation or a duplicated
 * event would otherwise send the same chat/call push twice. The claim document
 * id is derived from the event itself (chatId + messageId, callId, outbox id),
 * so the second invocation finds it and returns false.
 *
 * The claim is written BEFORE the FCM send. Keeping it after a failed send is
 * deliberate: the senders already retry transient FCM errors in-process, and
 * re-sending a permanently rejected payload would only duplicate risk. A
 * failed notification never affects the underlying chat message or call.
 */
async function claimNotificationEvent(eventId, details = {}) {
    if (!eventId) return true;
    const ref = admin.firestore()
        .collection(NOTIFICATION_EVENT_COLLECTION)
        .doc(eventId);
    try {
        await ref.create({
            ...details,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return true;
    } catch (error) {
        const code = error && (error.code || "");
        const alreadyExists =
            code === 6 ||
            code === "6" ||
            String(code).includes("already-exists") ||
            String((error && error.message) || "").includes("ALREADY_EXISTS");
        if (alreadyExists) {
            console.log(`[NOTIFICATION_EVENT] DUPLICATE_SKIPPED eventId=${eventId}`);
            return false;
        }
        console.warn(`[NOTIFICATION_EVENT] CLAIM_FAILED eventId=${eventId}: `, error);
        return true;
    }
}

/**
 * Resolves all authorized administrator accounts that have a registered FCM token.
 *
 * Checks both `telemedicine_patient` and `telemedicine_doctors` collections
 * where role is 'admin', returning a deduplicated array of admin recipient records:
 * `[{ userId, token, collection }]`.
 */
async function findAuthorizedAdminRecipients() {
    const db = admin.firestore();
    const adminMap = new Map();

    try {
        const patientAdminsSnap = await db.collection("telemedicine_patient")
            .where("role", "==", "admin")
            .where("fcmToken", ">", "")
            .get();
        for (const doc of patientAdminsSnap.docs) {
            const token = pickFcmToken(doc.data());
            if (token) {
                adminMap.set(doc.id, {
                    userId: doc.id,
                    token: token,
                    collection: "telemedicine_patient",
                });
            }
        }
    } catch (e) {
        console.error("[FCM_ADMIN] Error fetching patient admins:", e);
    }

    try {
        const doctorAdminsSnap = await db.collection("telemedicine_doctors")
            .where("role", "==", "admin")
            .where("fcmToken", ">", "")
            .get();
        for (const doc of doctorAdminsSnap.docs) {
            const token = pickFcmToken(doc.data());
            if (token && !adminMap.has(doc.id)) {
                adminMap.set(doc.id, {
                    userId: doc.id,
                    token: token,
                    collection: "telemedicine_doctors",
                });
            }
        }
    } catch (e) {
        console.error("[FCM_ADMIN] Error fetching doctor admins:", e);
    }

    return Array.from(adminMap.values());
}

module.exports = {
    findFcmToken,
    findUserInfo,
    findAuthorizedAdminRecipients,
    clearStaleFcmToken,
    claimNotificationEvent,
};
