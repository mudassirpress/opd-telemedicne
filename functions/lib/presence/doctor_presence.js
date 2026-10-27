/**
 * Backend Authoritative Doctor Presence, Heartbeat & Call Handshake Module
 * Built for Firebase Functions v2 (region: "asia-south1").
 */

const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const {
    DEFAULT_HEARTBEAT_TIMEOUT_MS,
    evaluateDoctorEligibility,
    buildProbePushPayload,
} = require("./doctor_presence_helpers.js");
const { isUnrecoverableTokenError } = require("../shared/fcm_helpers.js");
const {
    sendIncomingCallNotificationForCall,
} = require("../calls/call_notification.js");

const REGION = "asia-south1";

// ─────────────────────────────────────────────────────────────────────────────
// 1. Manual Availability Toggle (Doctor shifts availability ON or OFF)
// ─────────────────────────────────────────────────────────────────────────────
const setDoctorAvailability = onCall({
    region: REGION,
    timeoutSeconds: 15,
    memory: "256MiB",
}, async (request) => {
    const { doctorId, manualAvailability, deviceInfo, fcmToken, revision } = request.data || {};

    if (!doctorId || typeof manualAvailability !== "boolean") {
        throw new HttpsError("invalid-argument", "doctorId and boolean manualAvailability are required.");
    }

    const db = admin.firestore();
    const doctorRef = db.collection("telemedicine_doctors").doc(doctorId);
    const doctorDoc = await doctorRef.get();

    if (!doctorDoc.exists) {
        throw new HttpsError("not-found", `Doctor with ID ${doctorId} not found.`);
    }

    const data = doctorDoc.data() || {};
    const now = Date.now();

    // Turning ON
    if (manualAvailability === true) {
        // Enforce account approval & active status
        if (data.isActive === false || data.isDeleted === true || data.isSuspended === true || (data.accountStatus && data.accountStatus !== "Active")) {
            return {
                success: false,
                reason: "ACCOUNT_INELIGIBLE",
                message: "Doctor account is not active, pending admin approval, or suspended.",
                effectiveStatus: "OFFLINE",
                manualAvailability: false,
            };
        }

        const expiresAt = new Date(now + DEFAULT_HEARTBEAT_TIMEOUT_MS);
        const updatePayload = {
            manualAvailability: true,
            effectiveStatus: "ONLINE",
            isOnline: true, // backwards-compatibility with existing screens
            isAvailable: true,
            presenceStale: false,
            deviceReachable: true,
            lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
            lastHeartbeatAt: admin.firestore.FieldValue.serverTimestamp(),
            heartbeatExpiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
            lastVerifiedInternetAt: admin.firestore.FieldValue.serverTimestamp(),
            manualAvailabilityUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };

        if (fcmToken && typeof fcmToken === "string") {
            updatePayload.fcmToken = fcmToken;
            updatePayload.tokenUpdatedAt = admin.firestore.FieldValue.serverTimestamp();
        }

        if (deviceInfo && typeof deviceInfo === "object") {
            updatePayload.deviceInfo = {
                ...(data.deviceInfo || {}),
                ...deviceInfo,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            };
        }

        await doctorRef.update(updatePayload);
        console.log(`[DOCTOR_PRESENCE] Doctor ${doctorId} TOGGLED ON -> effectiveStatus=ONLINE`);

        return {
            success: true,
            manualAvailability: true,
            effectiveStatus: "ONLINE",
            heartbeatExpiresAtMs: expiresAt.getTime(),
        };
    }

    // Turning OFF
    const updatePayload = {
        manualAvailability: false,
        effectiveStatus: "OFFLINE",
        isOnline: false,
        isAvailable: false,
        presenceStale: true,
        deviceReachable: false,
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        manualAvailabilityUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await doctorRef.update(updatePayload);
    console.log(`[DOCTOR_PRESENCE] Doctor ${doctorId} TOGGLED OFF -> effectiveStatus=OFFLINE`);

    return {
        success: true,
        manualAvailability: false,
        effectiveStatus: "OFFLINE",
    };
});

// ─────────────────────────────────────────────────────────────────────────────
// 2. Doctor Heartbeat Loop (Client pings every 15-20s while app is active)
// ─────────────────────────────────────────────────────────────────────────────
const sendDoctorHeartbeat = onCall({
    region: REGION,
    timeoutSeconds: 15,
    memory: "256MiB",
}, async (request) => {
    const { doctorId, networkType, deviceInfo } = request.data || {};

    if (!doctorId) {
        throw new HttpsError("invalid-argument", "doctorId is required.");
    }

    const db = admin.firestore();
    const doctorRef = db.collection("telemedicine_doctors").doc(doctorId);
    const doctorDoc = await doctorRef.get();

    if (!doctorDoc.exists) {
        throw new HttpsError("not-found", `Doctor with ID ${doctorId} not found.`);
    }

    const data = doctorDoc.data() || {};

    // Invariant: A doctor cannot be marked ONLINE if manualAvailability is false
    if (data.manualAvailability !== true) {
        return {
            success: false,
            reason: "MANUAL_OFF",
            message: "Doctor manual availability is OFF. Heartbeat rejected.",
            effectiveStatus: "OFFLINE",
            manualAvailability: false,
        };
    }

    // Check account status
    if (data.isActive === false || data.isDeleted === true || data.isSuspended === true || (data.accountStatus && data.accountStatus !== "Active")) {
        await doctorRef.update({
            manualAvailability: false,
            effectiveStatus: "OFFLINE",
            isOnline: false,
            isAvailable: false,
            presenceStale: true,
            deviceReachable: false,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return {
            success: false,
            reason: "ACCOUNT_INELIGIBLE",
            effectiveStatus: "OFFLINE",
            manualAvailability: false,
        };
    }

    const now = Date.now();
    const expiresAt = new Date(now + DEFAULT_HEARTBEAT_TIMEOUT_MS);
    const isBusy = !!(data.activeCallId || data.currentCallId);
    const effectiveStatus = isBusy ? "BUSY" : "ONLINE";

    const updatePayload = {
        effectiveStatus: effectiveStatus,
        isOnline: effectiveStatus === "ONLINE",
        lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
        lastHeartbeatAt: admin.firestore.FieldValue.serverTimestamp(),
        heartbeatExpiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        lastVerifiedInternetAt: admin.firestore.FieldValue.serverTimestamp(),
        presenceStale: false,
        deviceReachable: true,
    };

    if (networkType || deviceInfo) {
        updatePayload.deviceInfo = {
            ...(data.deviceInfo || {}),
            ...(deviceInfo || {}),
            ...(networkType ? { networkType } : {}),
            lastHeartbeatAt: admin.firestore.FieldValue.serverTimestamp(),
        };
    }

    await doctorRef.update(updatePayload);

    return {
        success: true,
        effectiveStatus: effectiveStatus,
        manualAvailability: true,
        heartbeatExpiresAtMs: expiresAt.getTime(),
    };
});

// ─────────────────────────────────────────────────────────────────────────────
// 3. Lightweight Health & Reachability Endpoint (HTTP GET)
// ─────────────────────────────────────────────────────────────────────────────
const pingPresenceHealth = onRequest({
    region: REGION,
    cors: true,
    maxInstances: 10,
}, (req, res) => {
    // Ultra-fast HTTP response returning 200 with server timestamp
    res.set("Cache-Control", "no-store, no-cache, must-revalidate, proxy-revalidate");
    return res.status(200).json({
        status: "ok",
        service: "opd-presence",
        timestamp: Date.now(),
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// 4. Pre-Call Handshake Request (Patient initiates call)
// ─────────────────────────────────────────────────────────────────────────────
const requestDoctorCall = onCall({
    region: REGION,
    timeoutSeconds: 20,
    memory: "256MiB",
}, async (request) => {
    const {
        callerId,
        callerName,
        callerImage,
        callerType = "patient",
        doctorId,
        callType = "audio",
        channelId,
    } = request.data || {};

    if (!callerId || !doctorId) {
        throw new HttpsError("invalid-argument", "callerId and doctorId are required.");
    }

    const db = admin.firestore();
    const doctorRef = db.collection("telemedicine_doctors").doc(doctorId);
    const doctorDoc = await doctorRef.get();

    if (!doctorDoc.exists) {
        throw new HttpsError("not-found", "Doctor not found.");
    }

    const doctorData = doctorDoc.data() || {};
    const now = Date.now();

    // 1. Strict Eligibility Check
    const { eligible, reason } = evaluateDoctorEligibility(doctorData, now, 90 * 1000);
    if (!eligible) {
        console.log(`[PRE_CALL] Doctor ${doctorId} ineligible: reason=${reason}`);
        return {
            success: false,
            reason: reason === "MANUAL_OFF" ? "DOCTOR_OFFLINE" : "DOCTOR_UNREACHABLE",
            message: "Doctor is currently offline or unreachable.",
            callId: null,
        };
    }

    // 2. Doctor Busy Check
    if (doctorData.activeCallId || doctorData.currentCallId) {
        console.log(`[PRE_CALL] Doctor ${doctorId} is already on another call`);
        return {
            success: false,
            reason: "DOCTOR_BUSY",
            message: `${doctorData.fullname || "Doctor"} is attending another patient.`,
            callId: null,
        };
    }

    // 3. FCM Token Check
    const fcmToken = doctorData.fcmToken;
    if (!fcmToken) {
        console.warn(`[PRE_CALL] Doctor ${doctorId} has no FCM token registered`);
        return {
            success: false,
            reason: "NO_FCM_TOKEN",
            message: "Doctor device is not registered to receive incoming calls.",
            callId: null,
        };
    }

    // 4. Create Call Record in 'probing' State
    const callId = db.collection("calls").doc().id;
    const probeId = `probe_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    const effectiveChannelId = channelId || `call_${callId}`;

    const callRef = db.collection("calls").doc(callId);
    await callRef.set({
        callId: callId,
        callerId: callerId,
        callerName: callerName || "Patient",
        callerImage: callerImage || "",
        callerType: callerType,
        receiverId: doctorId,
        receiverName: doctorData.fullname || doctorData.fullName || "Doctor",
        receiverImage: doctorData.image || doctorData.imageUrl || "",
        receiverType: "doctor",
        callType: callType,
        channelId: effectiveChannelId,
        roomId: effectiveChannelId,
        callStatus: "probing",
        probeId: probeId,
        probeDispatchedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        startTime: new Date().toISOString(),
    });

    // 5. Send High-Priority FCM Probe Message to Doctor Device
    const probePayload = buildProbePushPayload({
        token: fcmToken,
        callId: callId,
        probeId: probeId,
        callerId: callerId,
        callerName: callerName,
        callerType: callerType,
        callType: callType,
        channelId: effectiveChannelId,
        receiverId: doctorId,
    });

    try {
        await admin.messaging().send(probePayload);
        console.log(`[PRE_CALL] Probe ${probeId} dispatched for call ${callId} to doc ${doctorId}`);
    } catch (err) {
        console.error(`[PRE_CALL] Probe dispatch failed: ${err.message}`);
        await callRef.update({
            callStatus: "unreachable",
            endedReason: "push_dispatch_failed",
            endedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        if (isUnrecoverableTokenError(err)) {
            await doctorRef.update({ fcmToken: admin.firestore.FieldValue.delete() });
        }
        return {
            success: false,
            reason: "PUSH_DELIVERY_FAILED",
            message: "Failed to ping doctor device.",
            callId: callId,
        };
    }

    // 6. Promote immediately. The probe above is a best-effort wake-up, not a
    // gate: waiting for its acknowledgement made an online doctor look
    // unreachable whenever the headless isolate was slow to start (cold device,
    // OEM battery saver) and then demoted their manual ONLINE duty. The real
    // incoming-call push below is the authoritative delivery attempt, and the
    // caller's normal ring timeout handles a device that never receives it.
    //
    // Promote first, then use the SAME sender as the create-trigger path.
    // The call document is updated (not re-created), so the
    // `sendIncomingCallNotification` create-trigger correctly stays skipped;
    // this explicit call is the only incoming-call push for this call.
    console.log(`[PRE_CALL] Promoting call ${callId} to ringing (probe ${probeId} is advisory).`);
    await callRef.update({
        callStatus: "ringing",
        ringStartedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const pushResult = await sendIncomingCallNotificationForCall(callId);
    if (!pushResult.sent) {
        console.warn(
            `[PRE_CALL] Incoming-call push not sent for ${callId}: `
            + `${pushResult.reason}`
        );
    }

    return {
        success: true,
        callId: callId,
        status: "ringing",
        channelId: effectiveChannelId,
    };
});

// ─────────────────────────────────────────────────────────────────────────────
// 5. Pre-Call Probe Acknowledgement (Hit by Doctor Device in BG / FG / Terminated)
// ─────────────────────────────────────────────────────────────────────────────
const acknowledgeCallProbe = onCall({
    region: REGION,
    timeoutSeconds: 10,
    memory: "256MiB",
}, async (request) => {
    const { probeId, callId, doctorId } = request.data || {};

    if (!probeId || !callId) {
        throw new HttpsError("invalid-argument", "probeId and callId are required.");
    }

    const db = admin.firestore();
    const callRef = db.collection("calls").doc(callId);
    await callRef.update({
        probeAckId: probeId,
        probeAckReceivedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    if (doctorId) {
        db.collection("telemedicine_doctors").doc(doctorId).update({
            lastCallAckAt: admin.firestore.FieldValue.serverTimestamp(),
            lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        }).catch((e) => console.error(`Error updating doctor ack: ${e}`));
    }

    return { success: true, acknowledged: true };
});

// Also provide HTTP onRequest variant for fastest background ping from headless isolate
const acknowledgeCallProbeHttp = onRequest({
    region: REGION,
    cors: true,
    maxInstances: 10,
}, async (req, res) => {
    const { probeId, callId, doctorId } = req.body || {};
    if (!probeId || !callId) {
        return res.status(400).json({ error: "Missing probeId or callId" });
    }

    const db = admin.firestore();
    try {
        await db.collection("calls").doc(callId).update({
            probeAckId: probeId,
            probeAckReceivedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        if (doctorId) {
            db.collection("telemedicine_doctors").doc(doctorId).update({
                lastCallAckAt: admin.firestore.FieldValue.serverTimestamp(),
                lastSeen: admin.firestore.FieldValue.serverTimestamp(),
            }).catch(() => {});
        }
        return res.status(200).json({ success: true, acknowledged: true });
    } catch (e) {
        console.error(`[acknowledgeCallProbeHttp] Error: ${e.message}`);
        return res.status(500).json({ error: e.message });
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// 6. Scheduled Presence Sweeper (Worker TTL running every 1 minute)
// ─────────────────────────────────────────────────────────────────────────────
const sweepDoctorPresence = onSchedule({
    schedule: "every 1 minutes",
    timeZone: "Asia/Karachi",
    retryCount: 1,
}, async () => {
    const db = admin.firestore();
    const cutoff = new Date(Date.now() - DEFAULT_HEARTBEAT_TIMEOUT_MS);

    try {
        // Query active doctors who missed their heartbeat cutoff
        const snapshot = await db.collection("telemedicine_doctors")
            .where("isOnline", "==", true)
            .where("lastHeartbeat", "<", cutoff)
            .limit(200)
            .get();

        if (snapshot.empty) {
            return null;
        }

        const batch = db.batch();
        let swept = 0;

        for (const doc of snapshot.docs) {
            const data = doc.data();

            // The manual duty switch outranks heartbeat age. Heartbeats are
            // only sent while the app is in the foreground, so sweeping a
            // manually-online doctor here would silently end their shift.
            if (data.manualAvailability === true) {
                continue;
            }

            batch.update(doc.ref, {
                effectiveStatus: "OFFLINE",
                isOnline: false,
                isAvailable: false,
                presenceStale: true,
                deviceReachable: false,
                lastSeen: admin.firestore.FieldValue.serverTimestamp(),
            });
            swept++;
        }

        if (swept > 0) {
            await batch.commit();
            console.log(`[sweepDoctorPresence] Swept ${swept} doctors with expired heartbeats to OFFLINE`);
        }
    } catch (err) {
        console.error("[sweepDoctorPresence] Sweeper error:", err);
    }
    return null;
});

module.exports = {
    setDoctorAvailability,
    sendDoctorHeartbeat,
    pingPresenceHealth,
    requestDoctorCall,
    acknowledgeCallProbe,
    acknowledgeCallProbeHttp,
    sweepDoctorPresence,
};
