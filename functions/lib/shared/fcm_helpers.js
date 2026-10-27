/**
 * Pure notification helpers shared by functions/index.js.
 *
 * Everything in this file is deliberately free of Firebase imports so it can
 * be unit-tested with `node --test` and no project, emulator or secret:
 *
 *   cd functions && npm test
 *
 * Anything that needs Firestore or the Admin SDK stays in index.js.
 */

/**
 * Longest message preview a chat push will show.
 *
 * Two reasons this is not "the whole message":
 *   • privacy — the body is what Android renders on the status bar and, on a
 *     device without a secure lock screen, on the lock screen. A preview
 *     matches how every messaging app behaves and keeps one message's text
 *     from being fully exposed;
 *   • size — the FCM HTTP v1 API caps the *entire* message at 4096 bytes and
 *     the chat push carries this text three times (data payload for the cache,
 *     android.notification for the OS, apns alert for iOS). An unbounded body
 *     is how a long message turns into a silent messaging/payload-size-
 *     limit-exceeded failure.
 *
 * `data.messageText` is NOT truncated: that field mirrors the message into the
 * offline Hive cache and a shortened value there would store a wrong message
 * row until the next Firestore sync.
 */
const CHAT_NOTIFICATION_BODY_MAX_CHARS = 120;

/**
 * Version of the FCM `data` contract written by every chat/call sender.
 *
 * The client parses old payloads defensively, but a payload with no
 * `schemaVersion` is treated as v0 (legacy). Bump this only for a breaking
 * change; additive fields do not require a bump.
 */
const NOTIFICATION_SCHEMA_VERSION = "1.0";

/** Must match AppLimits.ringTimeoutSeconds in the Flutter client. */
const CALL_RING_TIMEOUT_MS = 45 * 1000;

/** Extra slack so a push arriving just as the caller's timer fires is ignored. */
const CALL_EXPIRY_GRACE_MS = 15 * 1000;

/** Firestore collection holding one claim document per notification event. */
const NOTIFICATION_EVENT_COLLECTION = "notification_delivery_events";

/**
 * Collapses whitespace and caps a string at [maxChars] code points, appending
 * an ellipsis when it had to cut. Code points (not UTF-16 units) so a cut can
 * never split an emoji into an unpaired surrogate.
 */
function truncateForNotification(value, maxChars) {
    const limit = typeof maxChars === "number" && maxChars > 0
        ? maxChars
        : CHAT_NOTIFICATION_BODY_MAX_CHARS;
    // `String(null)` is the literal "null" — a null message must not put the
    // word "null" on the user's status bar.
    const collapsed = (value == null ? "" : String(value))
        .replace(/\s+/g, " ")
        .trim();
    const codePoints = Array.from(collapsed);
    if (codePoints.length <= limit) {
        return collapsed;
    }
    return codePoints.slice(0, limit - 1).join("") + "\u2026";
}

/**
 * Builds the user-visible body of a chat push.
 *
 * Media types get a fixed label (their real content is a filename or a blob
 * and means nothing in a notification); text messages get a bounded preview.
 * Returns a non-empty string for every input, so the OS never draws a
 * blank-headed notification.
 */
function buildChatNotificationBody(message, messageType) {
    const text = message == null ? "" : String(message);

    switch (messageType) {
        case "image":
            return "📷 Sent an image";
        case "voice":
        case "audio":
            return "🎤 Sent a voice message";
        case "video":
            return "🎥 Sent a video";
        case "call_recording":
            return "🎙️ Sent a call recording";
        case "document": {
            // The stored message already carries its own "📄 file.pdf" prefix,
            // so adding the emoji again rendered "📄 📄 file.pdf".
            const raw = text || "Sent a document";
            return truncateForNotification(raw.startsWith("📄") ? raw : `📄 ${raw}`);
        }
        default:
            return truncateForNotification(text) || "Sent an attachment";
    }
}

/**
 * Pulls a usable registration token off a patient/doctor document, or null.
 *
 * Checks `fcmToken`, with fallback to `token`, `fcm_token`, or `deviceToken`
 * to guarantee interoperability across different client/auth write operations.
 */
function pickFcmToken(userData) {
    if (!userData || typeof userData !== "object") return null;
    const rawToken = userData.fcmToken || userData.token || userData.fcm_token || userData.deviceToken;
    if (typeof rawToken !== "string" || rawToken.trim().length === 0) return null;
    return rawToken.trim();
}

/** Error codes that can only ever mean "this token is dead, forever". */
const DEAD_TOKEN_ERROR_CODES = new Set([
    "messaging/registration-token-not-registered",
    "messaging/invalid-registration-token",
]);

/**
 * True only when the failure is specific to *this device's registration
 * token*, i.e. it is safe to delete the token from the user document.
 *
 * The previous implementation returned true for two codes that are routinely
 * NOT about the token, and `clearStaleFcmToken` then deleted a perfectly good
 * token from Firestore:
 *
 *   • `messaging/authentication-error` — firebase-admin documents this as
 *     "the credential used to authenticate this SDK has the proper
 *     permissions". It is about *our* service account, not the device. One
 *     credential hiccup would strip the token from every user it was sent to.
 *
 *   • `messaging/invalid-argument` — FCM returns this both for a malformed
 *     registration token and for a malformed *message* (unknown field, a
 *     non-string `data` value, a bad color, a missing target). firebase-admin
 *     also throws it client-side from `validateMessage()` before the request
 *     is ever sent. Any rejected payload therefore looked like a dead token.
 *
 * Both produced the same visible symptom: the token disappears, every later
 * chat and call push fails with RECEIVER_TOKEN_MISSING, and the user gets
 * nothing until they happen to reopen the app and re-register.
 */
function isUnrecoverableTokenError(error) {
    const code = error && error.code;
    if (typeof code !== "string") return false;
    if (DEAD_TOKEN_ERROR_CODES.has(code)) return true;
    if (code !== "messaging/invalid-argument") return false;

    // Only an invalid-argument whose message names the registration token is
    // about the token. Firebase's wording is consistently
    // "… the registration token …" / "Invalid registration token …".
    const message = String(error.message || "").toLowerCase();
    return message.includes("registration token") ||
        message.includes("registration_token");
}

/** Trimmed string, or "" for null/undefined/objects. */
function asId(value) {
    if (typeof value === "string") return value.trim();
    if (typeof value === "number") return String(value);
    return "";
}

/**
 * Resolves the person a chat push must go to from the *trusted* conversation
 * document, never from the client-supplied `receiverId` alone.
 *
 * Conversations created by the app store `participants: [patientId, doctorId]`.
 * For a normal message the sender must be one participant and the recipient is
 * the other one; a `receiverId` that disagrees with that is ignored (and
 * reported) instead of being used. Admin messages are the one exception: the
 * admin is not a participant, so the recipient is the participant named in
 * `receiverId` — still validated against the participant list, so an admin
 * message can never be aimed at an unrelated account.
 *
 * @param {{message?: object, chatData?: object}} input
 * @returns {{ok: boolean, reason?: string, recipientId?: string,
 *            senderId?: string, isAdmin?: boolean, receiverMismatch?: boolean}}
 */
function resolveChatNotificationRecipient({message, chatData} = {}) {
    const msg = message && typeof message === "object" ? message : {};
    const chat = chatData && typeof chatData === "object" ? chatData : {};

    const senderId = asId(msg.senderId);
    const claimedReceiverId = asId(msg.receiverId);
    const isAdmin = msg.isAdminMessage === true;

    if (!senderId) return {ok: false, reason: "sender-missing"};

    const participants = Array.isArray(chat.participants)
        ? [...new Set(chat.participants.map(asId).filter(Boolean))]
        : [];
    if (participants.length < 2) {
        return {ok: false, reason: "participants-missing"};
    }

    let recipientId = "";
    let receiverMismatch = false;

    if (isAdmin) {
        // The admin is not a participant; the claimed receiver must be one.
        if (!claimedReceiverId || !participants.includes(claimedReceiverId)) {
            return {ok: false, reason: "admin-receiver-not-participant"};
        }
        recipientId = claimedReceiverId;
    } else {
        if (!participants.includes(senderId)) {
            return {ok: false, reason: "sender-not-participant"};
        }
        const others = participants.filter((id) => id !== senderId);
        if (others.length === 1) {
            recipientId = others[0];
        } else if (claimedReceiverId && participants.includes(claimedReceiverId)) {
            recipientId = claimedReceiverId;
        }
        if (!recipientId) return {ok: false, reason: "recipient-not-resolved"};
        receiverMismatch =
            claimedReceiverId.length > 0 && claimedReceiverId !== recipientId;
    }

    if (recipientId === senderId) {
        return {ok: false, reason: "self-notification"};
    }

    return {
        ok: true,
        recipientId,
        senderId,
        isAdmin,
        receiverMismatch,
    };
}

/** Only http(s) URLs of a sane length are ever put into a push payload. */
function isUsableImageUrl(value) {
    if (typeof value !== "string") return false;
    const url = value.trim();
    if (url.length === 0 || url.length > 2048) return false;
    return /^https?:\/\//i.test(url);
}

/** Parses the timestamp shapes found on call documents into epoch millis. */
function parseCallStartMillis(value) {
    if (value == null) return null;
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (value instanceof Date) {
        const millis = value.getTime();
        return Number.isNaN(millis) ? null : millis;
    }
    if (typeof value.toMillis === "function") {
        try {
            const millis = value.toMillis();
            return Number.isFinite(millis) ? millis : null;
        } catch (_) {
            return null;
        }
    }
    if (typeof value.toDate === "function") {
        try {
            const date = value.toDate();
            const millis = date instanceof Date ? date.getTime() : NaN;
            return Number.isNaN(millis) ? null : millis;
        } catch (_) {
            return null;
        }
    }
    if (typeof value === "string") {
        const trimmed = value.trim();
        if (trimmed === "") return null;
        // The push contract serialises epoch millis as a string.
        if (/^\d+$/.test(trimmed)) {
            const millis = Number(trimmed);
            return Number.isFinite(millis) ? millis : null;
        }
        const millis = Date.parse(trimmed);
        return Number.isNaN(millis) ? null : millis;
    }
    return null;
}

/**
 * Expiry carried in the call push. A call document written without a usable
 * `startTime` gets a full ring window from now, which is the same behaviour the
 * client's own ring timer has.
 */
function buildCallExpiresAt(startTime, nowMillis = Date.now()) {
    const started = parseCallStartMillis(startTime);
    const base = started == null ? nowMillis : started;
    return base + CALL_RING_TIMEOUT_MS + CALL_EXPIRY_GRACE_MS;
}

/** True when an invitation is too old to show/accept. */
function isCallInvitationExpired(expiresAt, nowMillis = Date.now()) {
    const expiry = parseCallStartMillis(expiresAt);
    // 0/negative means "no expiry supplied" (legacy payload), not 1970.
    return expiry != null && expiry > 0 && expiry <= nowMillis;
}

/** Deterministic idempotency key. Firestore ids cannot contain a slash. */
function notificationEventId(type, ...parts) {
    const clean = parts
        .map((part) => asId(part).replace(/[^A-Za-z0-9_-]/g, "_"))
        .filter(Boolean);
    return [type, ...clean].join("__");
}

module.exports = {
    CHAT_NOTIFICATION_BODY_MAX_CHARS,
    NOTIFICATION_SCHEMA_VERSION,
    NOTIFICATION_EVENT_COLLECTION,
    CALL_RING_TIMEOUT_MS,
    CALL_EXPIRY_GRACE_MS,
    truncateForNotification,
    buildChatNotificationBody,
    pickFcmToken,
    isUnrecoverableTokenError,
    asId,
    resolveChatNotificationRecipient,
    isUsableImageUrl,
    parseCallStartMillis,
    buildCallExpiresAt,
    isCallInvitationExpired,
    notificationEventId,
};
