/**
 * Pure helper functions for Doctor Presence, Heartbeat & Call Handshake.
 * Free of Firebase Admin imports so it can be strictly unit tested with node --test.
 */

const DEFAULT_HEARTBEAT_TIMEOUT_MS = 60 * 1000; // 60s TTL
const PRE_CALL_PROBE_TIMEOUT_MS = 3500; // 3.5s pre-call probe wait

/**
 * Normalises Firestore Timestamp, Date, string, or number to milliseconds since epoch.
 */
function parseTimestampMillis(value) {
    if (!value) return null;
    if (typeof value === "number") return value;
    if (typeof value.toMillis === "function") return value.toMillis();
    if (typeof value.toDate === "function") return value.toDate().getTime();
    if (value instanceof Date) return value.getTime();
    if (typeof value === "string") {
        const parsed = Date.parse(value);
        return isNaN(parsed) ? null : parsed;
    }
    return null;
}

/**
 * Checks whether a given heartbeat timestamp is within the freshness window.
 */
function isHeartbeatFresh(lastHeartbeat, nowMs, timeoutMs = DEFAULT_HEARTBEAT_TIMEOUT_MS) {
    const hbMillis = parseTimestampMillis(lastHeartbeat);
    if (!hbMillis) return false;
    const now = typeof nowMs === "number" ? nowMs : Date.now();
    const diff = now - hbMillis;
    return diff >= 0 && diff < timeoutMs;
}

/**
 * Comprehensive eligibility evaluation for a doctor.
 *
 * A doctor is eligible while they have deliberately turned duty ON:
 *   1. manualAvailability == true (legacy isOnline is accepted as a fallback)
 *   2. approved & active (isActive != false)
 *   3. not soft-deleted (isDeleted != true)
 *   4. accountStatus is Active
 *   5. not suspended (isSuspended != true)
 *
 * Heartbeat freshness is deliberately NOT part of eligibility. A heartbeat is
 * only written while the Flutter timer runs in the foreground, so treating an
 * old heartbeat as "offline" silently cancelled a doctor's manual ONLINE duty
 * whenever the app was backgrounded. Reachability is verified by the FCM
 * probe / incoming-call push instead, which is the only signal that actually
 * proves the device is reachable right now.
 *
 * `nowMs` and `timeoutMs` are kept in the signature for backwards
 * compatibility with existing callers; they no longer gate eligibility.
 */
function evaluateDoctorEligibility(doctorData, nowMs, timeoutMs = DEFAULT_HEARTBEAT_TIMEOUT_MS) {
    if (!doctorData || typeof doctorData !== "object") {
        return { eligible: false, reason: "INVALID_DATA" };
    }

    if (doctorData.manualAvailability !== true && doctorData.isOnline !== true) {
        return { eligible: false, reason: "MANUAL_OFF" };
    }

    if (doctorData.isActive === false) {
        return { eligible: false, reason: "INACTIVE" };
    }

    if (doctorData.isDeleted === true) {
        return { eligible: false, reason: "DELETED" };
    }

    if (doctorData.isSuspended === true) {
        return { eligible: false, reason: "SUSPENDED" };
    }

    const accountStatus = doctorData.accountStatus;
    if (accountStatus && accountStatus !== "Active") {
        return { eligible: false, reason: "ACCOUNT_NOT_ACTIVE" };
    }

    return { eligible: true, reason: null };
}

/**
 * Computes authoritative effective status:
 *   - 'BUSY' if doctor is actively in a call
 *   - 'ONLINE' if all eligibility rules pass
 *   - 'OFFLINE' otherwise
 */
function computeEffectiveStatus(doctorData, nowMs, timeoutMs = DEFAULT_HEARTBEAT_TIMEOUT_MS) {
    if (!doctorData || typeof doctorData !== "object") return "OFFLINE";
    if (doctorData.activeCallId || doctorData.currentCallId) return "BUSY";

    const { eligible } = evaluateDoctorEligibility(doctorData, nowMs, timeoutMs);
    return eligible ? "ONLINE" : "OFFLINE";
}

/**
 * Builds data-only high-priority FCM payload for Pre-Call Probe.
 * Short 5s TTL ensures delayed network delivery does not wake a doctor long after the call aborted.
 */
function buildProbePushPayload({
    token,
    callId,
    probeId,
    callerId,
    callerName,
    callerType = "patient",
    callType = "audio",
    channelId,
    receiverId,
}) {
    return {
        token: token,
        data: {
            type: "call_probe",
            probeId: String(probeId),
            callId: String(callId),
            doctorId: String(receiverId || ""),
            receiverId: String(receiverId || ""),
            callerId: String(callerId || ""),
            callerName: String(callerName || "Patient"),
            callerType: String(callerType || "patient"),
            callType: String(callType || "audio"),
            channelId: String(channelId || callId),
            roomId: String(channelId || callId),
            timestamp: Date.now().toString(),
        },
        android: {
            priority: "high",
            ttl: "5s",
        },
        apns: {
            headers: {
                "apns-priority": "10",
                "apns-push-type": "background",
            },
            payload: {
                aps: {
                    "content-available": 1,
                },
            },
        },
    };
}

module.exports = {
    DEFAULT_HEARTBEAT_TIMEOUT_MS,
    PRE_CALL_PROBE_TIMEOUT_MS,
    parseTimestampMillis,
    isHeartbeatFresh,
    evaluateDoctorEligibility,
    computeEffectiveStatus,
    buildProbePushPayload,
};
