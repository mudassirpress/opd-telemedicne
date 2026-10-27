/**
 * The ONE incoming-call push builder/sender.
 *
 * Both entry points use it:
 *   • `sendIncomingCallNotification` (Firestore `calls/{callId}` create, used
 *     when the caller writes the call document directly), and
 *   • `requestDoctorCall` (callable path, which creates the document as
 *     `probing` and only promotes it to `ringing` after the probe).
 *
 * The callable path cannot rely on the create trigger (the document already
 * exists when it becomes `ringing`), so it calls this function explicitly after
 * the update. The deterministic claim id makes a future update-trigger or a
 * retry harmless.
 */

const admin = require("firebase-admin");
const {
    NOTIFICATION_SCHEMA_VERSION,
    buildCallExpiresAt,
    isCallInvitationExpired,
    isUnrecoverableTokenError,
    isUsableImageUrl,
    notificationEventId,
} = require("./fcm_helpers");
const {
    findFcmToken,
    findUserInfo,
    clearStaleFcmToken,
    claimNotificationEvent,
} = require("./notification_shared");

const CALL_RING_TTL_FALLBACK_SECONDS = 60;

function nonEmptyString(value) {
    return typeof value === "string" && value.trim().length > 0;
}

/**
 * Validates and sends the incoming-call push for `callId`.
 *
 * @returns {Promise<{sent: boolean, reason?: string}>}
 */
async function sendIncomingCallNotificationForCall(callId) {
    if (!callId) return {sent: false, reason: "missing-call-id"};

    const snap = await admin.firestore()
        .collection("calls")
        .doc(callId)
        .get();
    if (!snap.exists) {
        console.log(`[CALL_NOTIFICATION] CALL_NOT_FOUND callId=${callId}`);
        return {sent: false, reason: "call-not-found"};
    }

    const data = snap.data() || {};
    if (data.callStatus !== "ringing") {
        return {sent: false, reason: `not-ringing(${data.callStatus || "unknown"})`};
    }

    const callerId = data.callerId;
    const receiverId = data.receiverId;

    if (!nonEmptyString(callerId)) {
        console.log(`[CALL_NOTIFICATION] CALLER_ID_MISSING callId=${callId}`);
        return {sent: false, reason: "caller-missing"};
    }
    if (!nonEmptyString(receiverId)) {
        console.log(`[CALL_NOTIFICATION] RECEIVER_ID_MISSING callId=${callId}`);
        return {sent: false, reason: "receiver-missing"};
    }
    if (callerId === receiverId) {
        console.log(`[CALL_NOTIFICATION] SELF_CALL_REJECTED callId=${callId}`);
        return {sent: false, reason: "self-call"};
    }
    if (!nonEmptyString(data.channelId)) {
        console.log(`[CALL_NOTIFICATION] CHANNEL_ID_MISSING callId=${callId}`);
        return {sent: false, reason: "channel-missing"};
    }
    if (data.callType !== "audio" && data.callType !== "video") {
        console.log(
            `[CALL_NOTIFICATION] CALL_TYPE_INVALID callId=${callId} `
            + `callType=${data.callType}`
        );
        return {sent: false, reason: "call-type-invalid"};
    }

    // A push that arrives after the caller stopped ringing would show a dead
    // "Incoming call" that cannot be answered.
    const expiresAt = buildCallExpiresAt(data.startTime);
    if (isCallInvitationExpired(expiresAt)) {
        console.log(
            `[CALL_NOTIFICATION] EXPIRED_INVITATION_SKIPPED callId=${callId} `
            + `expiresAt=${expiresAt}`
        );
        return {sent: false, reason: "expired"};
    }

    let receiverToken = null;
    try {
        receiverToken = await findFcmToken(receiverId);
    } catch (error) {
        // The caller's ring timeout handles the no-push case.
        console.error(
            `[CALL_NOTIFICATION] TOKEN_LOOKUP_FAILED callId=${callId}: `,
            error
        );
        return {sent: false, reason: "token-lookup-failed"};
    }
    if (!receiverToken) {
        console.log(
            `[CALL_NOTIFICATION] RECEIVER_TOKEN_MISSING receiverId=${receiverId} `
            + `callId=${callId}`
        );
        return {sent: false, reason: "receiver-token-missing"};
    }

    // Caller identity comes from the caller's own profile, not from the call
    // document's display fields (a client can write any name/image there).
    let callerInfo = null;
    try {
        callerInfo = await findUserInfo(callerId);
    } catch (error) {
        console.error(
            `[CALL_NOTIFICATION] CALLER_INFO_LOOKUP_FAILED callId=${callId}: `,
            error
        );
        return {sent: false, reason: "caller-lookup-failed"};
    }
    if (!callerInfo) {
        console.log(
            `[CALL_NOTIFICATION] CALLER_PROFILE_MISSING callId=${callId} `
            + `callerId=${callerId}`
        );
        return {sent: false, reason: "caller-profile-missing"};
    }

    const callerName = callerInfo.name
        || (callerInfo.type === "doctor" ? "Doctor" : "Patient");
    const callerImage = isUsableImageUrl(callerInfo.image)
        ? callerInfo.image
        : "";
    const callerType = callerInfo.type;
    const callType = data.callType;
    const channelId = data.channelId;

    const callBody = callType === "video"
        ? "Incoming video call..."
        : "Incoming audio call...";

    const remainingSeconds = Math.ceil((expiresAt - Date.now()) / 1000);
    if (remainingSeconds <= 0) {
        console.log(
            `[CALL_NOTIFICATION] CALL_EXPIRED_BEFORE_SEND callId=${callId} `
            + `expiresAt=${expiresAt}`
        );
        return {sent: false, reason: "expired"};
    }

    const ttlSeconds = Math.min(
        CALL_RING_TTL_FALLBACK_SECONDS,
        Math.max(remainingSeconds, 1)
    );

    const message = {
        token: receiverToken,
        data: {
            schemaVersion: NOTIFICATION_SCHEMA_VERSION,
            type: "call",
            callId: String(callId),
            callerId: String(callerId),
            callerName: String(callerName),
            callerImage: String(callerImage || ""),
            callerType: String(callerType || ""),
            receiverId: String(receiverId),
            recipientId: String(receiverId),
            callType: String(callType),
            callStatus: "ringing",
            channelId: String(channelId),
            roomId: String(channelId),
            createdAt: String(data.startTime || new Date().toISOString()),
            expiresAt: String(expiresAt),
            sentAt: new Date().toISOString(),
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            timestamp: Date.now().toString(),
        },
        android: {
            priority: "high",
            ttl: `${ttlSeconds}s`,
        },
        apns: {
            headers: {
                "apns-priority": "10",
            },
            payload: {
                aps: {
                    alert: {
                        title: callerName,
                        body: callBody,
                    },
                    sound: "call_ringtoun.caf",
                    badge: 1,
                    category: "incoming_call",
                    "content-available": 1,
                },
            },
        },
    };

    const claimed = await claimNotificationEvent(
        notificationEventId("call", callId),
        {
            type: "call",
            callId,
            recipientId: receiverId,
            callerId,
        }
    );
    if (!claimed) return {sent: false, reason: "duplicate"};

    // Transient FCM failures (backend unavailable, internal error, timeout)
    // are retried in-process with a short backoff before giving up.
    const TRANSIENT_SEND_RETRY_DELAYS_MS = [500, 1500];
    let messageId = null;

    for (let attempt = 0; ; attempt++) {
        try {
            console.log(`[CALL_NOTIFICATION] FCM_SEND_STARTED callId=${callId} attempt=${attempt + 1}`);
            messageId = await admin.messaging().send(message);
            console.log(`[CALL_NOTIFICATION] FCM_SEND_SUCCESS callId=${callId} messageId=${messageId}`);
            return {sent: true, messageId};
        } catch (sendError) {
            const transient =
                sendError &&
                (sendError.code === "messaging/internal-error" ||
                    sendError.code === "messaging/server-unavailable" ||
                    sendError.code === "messaging/timeout" ||
                    (typeof sendError.code === "string" && sendError.code.includes("unavailable")));
            if (transient && attempt < TRANSIENT_SEND_RETRY_DELAYS_MS.length) {
                console.warn(
                    `[CALL_NOTIFICATION] TRANSIENT_SEND_ERROR retrying callId=${callId} attempt=${attempt + 1}: `,
                    sendError
                );
                await new Promise((resolve) => setTimeout(resolve, TRANSIENT_SEND_RETRY_DELAYS_MS[attempt]));
                continue;
            }

            console.error(
                `[CALL_NOTIFICATION] FCM_SEND_FAILED callId=${callId} code=${sendError && sendError.code}: `,
                sendError && sendError.message
            );
            if (isUnrecoverableTokenError(sendError)) {
                try {
                    await clearStaleFcmToken(receiverId, receiverToken);
                } catch (clearError) {
                    console.error(
                        `[CALL_NOTIFICATION] TOKEN_CLEAR_FAILED callId=${callId}: `,
                        clearError && clearError.message
                    );
                }
            } else {
                console.warn(
                    `[CALL_NOTIFICATION] TOKEN_PRESERVED code=${sendError && sendError.code} `
                    + `callId=${callId} receiverId=${receiverId}`
                );
            }
            return {sent: false, reason: "send-failed"};
        }
    }
}

/**
 * Sends a high-priority call cancellation/termination data push to dismiss the
 * incoming call notification and stop the ringtone immediately when a call is
 * cancelled by the caller, declined, or timed out.
 */
async function sendCallTerminationNotificationForCall(callId, oldStatus, newStatus) {
    if (!callId) return {sent: false, reason: "missing-call-id"};

    try {
        const snap = await admin.firestore().collection("calls").doc(callId).get();
        if (!snap.exists) return {sent: false, reason: "call-not-found"};

        const data = snap.data() || {};
        const receiverId = data.receiverId;
        if (!receiverId) return {sent: false, reason: "missing-receiver"};

        const receiverToken = await findFcmToken(receiverId);
        if (!receiverToken) return {sent: false, reason: "receiver-token-missing"};

        const message = {
            token: receiverToken,
            data: {
                schemaVersion: NOTIFICATION_SCHEMA_VERSION,
                type: "call_cancel",
                callId: String(callId),
                oldStatus: String(oldStatus || ""),
                newStatus: String(newStatus || ""),
                callStatus: String(newStatus || ""),
                timestamp: Date.now().toString(),
            },
            android: {
                priority: "high",
                ttl: "30s",
            },
        };

        const messageId = await admin.messaging().send(message);
        console.log(`[CALL_TERMINATION] Sent call_cancel push callId=${callId} status=${newStatus} messageId=${messageId}`);
        return {sent: true, messageId};
    } catch (e) {
        console.error(`[CALL_TERMINATION] Failed to send call_cancel for callId=${callId}:`, e);
        return {sent: false, reason: e.message};
    }
}

module.exports = {
    sendIncomingCallNotificationForCall,
    sendCallTerminationNotificationForCall,
};
