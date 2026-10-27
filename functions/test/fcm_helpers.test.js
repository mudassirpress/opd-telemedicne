/**
 * Unit tests for the pure FCM notification helpers.
 *
 * Run from `functions/`:
 *   npm test        (node --test)
 *
 * No Firebase project, emulator or secret is needed: fcm_helpers.js has zero
 * Firebase imports by design.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const h = require("../lib/shared/fcm_helpers.js");

// ─────────────────────────────────────────────────────────────────────────────
// isUnrecoverableTokenError
// ─────────────────────────────────────────────────────────────────────────────

test("isUnrecoverableTokenError accepts the codes that only ever mean a dead token", () => {
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/registration-token-not-registered",
        message: "The provided registration token is not registered.",
    }), true);
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-registration-token",
        message: "Invalid registration token provided.",
    }), true);
});

test("isUnrecoverableTokenError accepts invalid-argument when it names the token", () => {
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-argument",
        message: "The registration token is not a valid FCM registration token.",
    }), true);
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-argument",
        message: "Invalid registration token provided. Make sure it matches the registration token the client app receives from registering with FCM.",
    }), true);
});

test("isUnrecoverableTokenError rejects the generic client-side validateMessage error", () => {
    // firebase-admin throws this from validateMessage() BEFORE the request is
    // sent, for things like a non-string data value or a malformed target.
    // The old implementation cleared the user's token on it.
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-argument",
        message: "Invalid argument provided.",
    }), false);
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-argument",
        message: "data must only contain string values",
    }), false);
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-argument",
        message: "Exactly one of topic, token or condition is required",
    }), false);
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/invalid-argument",
        message: "android.notification.color must be in the form #RRGGBB",
    }), false);
});

test("isUnrecoverableTokenError rejects messaging/authentication-error", () => {
    // Our own service-account credential failing is not a property of the
    // device's token; clearing on it stripped working tokens from users.
    assert.equal(h.isUnrecoverableTokenError({
        code: "messaging/authentication-error",
        message: "An error occurred when trying to authenticate to the FCM servers. Make sure the credential used to authenticate this SDK has the proper permissions.",
    }), false);
});

test("isUnrecoverableTokenError rejects every other failure class", () => {
    for (const code of [
        "messaging/invalid-payload",
        "messaging/payload-size-limit-exceeded",
        "messaging/internal-error",
        "messaging/server-unavailable",
        "messaging/third-party-auth-error",
        "messaging/device-message-rate-exceeded",
        "messaging/unknown-error",
    ]) {
        assert.equal(h.isUnrecoverableTokenError({code, message: "boom"}), false, code);
    }
});

test("isUnrecoverableTokenError is safe on malformed input", () => {
    assert.equal(h.isUnrecoverableTokenError(null), false);
    assert.equal(h.isUnrecoverableTokenError(undefined), false);
    assert.equal(h.isUnrecoverableTokenError({}), false);
    assert.equal(h.isUnrecoverableTokenError({code: null}), false);
    assert.equal(h.isUnrecoverableTokenError({code: 404}), false);
    assert.equal(h.isUnrecoverableTokenError("boom"), false);
});

// ─────────────────────────────────────────────────────────────────────────────
// pickFcmToken
// ─────────────────────────────────────────────────────────────────────────────

test("pickFcmToken returns a usable token verbatim", () => {
    const token = "eXaMpLe_T0ken-abc123";
    assert.equal(h.pickFcmToken({fcmToken: token}), token);
});

test("pickFcmToken rejects everything that is not a usable token", () => {
    assert.equal(h.pickFcmToken({}), null);
    assert.equal(h.pickFcmToken({fcmToken: null}), null);
    assert.equal(h.pickFcmToken({fcmToken: undefined}), null);
    assert.equal(h.pickFcmToken({fcmToken: ""}), null);
    assert.equal(h.pickFcmToken({fcmToken: "   "}), null);
    assert.equal(h.pickFcmToken({fcmToken: 12345}), null);
    assert.equal(h.pickFcmToken({fcmToken: {value: "x"}}), null);
    assert.equal(h.pickFcmToken({fcmToken: true}), null);
    assert.equal(h.pickFcmToken(null), null);
    assert.equal(h.pickFcmToken(undefined), null);
});

// ─────────────────────────────────────────────────────────────────────────────
// truncateForNotification
// ─────────────────────────────────────────────────────────────────────────────

test("truncateForNotification leaves short text alone but collapses whitespace", () => {
    assert.equal(h.truncateForNotification("hello world"), "hello world");
    assert.equal(h.truncateForNotification("  hello   world  "), "hello world");
    assert.equal(h.truncateForNotification("line one\nline two"), "line one line two");
    assert.equal(h.truncateForNotification(""), "");
    assert.equal(h.truncateForNotification(null), "");
    assert.equal(h.truncateForNotification(undefined), "");
});

test("truncateForNotification caps at the default limit with an ellipsis", () => {
    const input = "a".repeat(h.CHAT_NOTIFICATION_BODY_MAX_CHARS + 50);
    const out = h.truncateForNotification(input);
    assert.equal(Array.from(out).length, h.CHAT_NOTIFICATION_BODY_MAX_CHARS);
    assert.equal(out.endsWith("\u2026"), true);
    assert.equal(out.startsWith("aaa"), true);
});

test("truncateForNotification does not touch text that exactly fits", () => {
    const input = "b".repeat(h.CHAT_NOTIFICATION_BODY_MAX_CHARS);
    const out = h.truncateForNotification(input);
    assert.equal(out, input);
    assert.equal(out.includes("\u2026"), false);
});

test("truncateForNotification honours an explicit limit", () => {
    const out = h.truncateForNotification("abcdefghij", 4);
    assert.equal(out, "abc\u2026");
    assert.equal(Array.from(out).length, 4);
});

test("truncateForNotification never splits an emoji at the cut", () => {
    const out = h.truncateForNotification("\u{1F4F8}".repeat(300));
    const limit = h.CHAT_NOTIFICATION_BODY_MAX_CHARS;
    assert.equal(Array.from(out).length, limit);
    // The final slot is the ellipsis, so every other slot must be a *whole*
    // emoji. With the `u` flag a lone surrogate cannot match the pattern, so
    // a count of limit-1 proves the cut did not leave half an emoji behind.
    assert.equal((out.match(/\u{1F4F8}/gu) || []).length, limit - 1);
    assert.equal(out.endsWith("\u2026"), true);
});

// ─────────────────────────────────────────────────────────────────────────────
// buildChatNotificationBody
// ─────────────────────────────────────────────────────────────────────────────

test("buildChatNotificationBody uses a fixed label for media types", () => {
    assert.equal(h.buildChatNotificationBody("some-blob", "image"), "📷 Sent an image");
    assert.equal(h.buildChatNotificationBody("some-blob", "audio"), "🎤 Sent a voice message");
    assert.equal(h.buildChatNotificationBody("some-blob", "video"), "🎥 Sent a video");
    assert.equal(h.buildChatNotificationBody("some-blob", "call_recording"), "🎙️ Sent a call recording");
});

test("buildChatNotificationBody does not double the document emoji", () => {
    assert.equal(
        h.buildChatNotificationBody("📄 report.pdf", "document"),
        "📄 report.pdf"
    );
    assert.equal(
        h.buildChatNotificationBody("report.pdf", "document"),
        "📄 report.pdf"
    );
    assert.equal(
        h.buildChatNotificationBody("", "document"),
        "📄 Sent a document"
    );
});

test("buildChatNotificationBody bounds and single-lines a text preview", () => {
    const long = "word ".repeat(200);
    const out = h.buildChatNotificationBody(long, "text");
    assert.equal(Array.from(out).length <= h.CHAT_NOTIFICATION_BODY_MAX_CHARS, true);
    assert.equal(out.includes("\n"), false);
    assert.equal(out.includes("  "), false);
    assert.equal(out.endsWith("\u2026"), true);
});

test("buildChatNotificationBody never returns an empty body", () => {
    // An empty body makes Android draw a heads-up with no content.
    assert.equal(h.buildChatNotificationBody("", "text"), "Sent an attachment");
    assert.equal(h.buildChatNotificationBody(null, "text"), "Sent an attachment");
    assert.equal(h.buildChatNotificationBody(undefined, "text"), "Sent an attachment");
    assert.equal(h.buildChatNotificationBody("   ", "text"), "Sent an attachment");
    assert.equal(h.buildChatNotificationBody(null, undefined), "Sent an attachment");
});

test("buildChatNotificationBody keeps a short message untouched", () => {
    assert.equal(
        h.buildChatNotificationBody("Are you free at 5?", "text"),
        "Are you free at 5?"
    );
});

// -----------------------------------------------------------------------------
// resolveChatNotificationRecipient (trusted membership)
// -----------------------------------------------------------------------------

test("resolveChatNotificationRecipient resolves the other participant in both directions", () => {
    const patientToDoctor = h.resolveChatNotificationRecipient({
        message: {senderId: "patient-1", receiverId: "doctor-1"},
        chatData: {participants: ["patient-1", "doctor-1"]},
    });
    assert.equal(patientToDoctor.ok, true);
    assert.equal(patientToDoctor.recipientId, "doctor-1");
    assert.equal(patientToDoctor.isAdmin, false);

    const doctorToPatient = h.resolveChatNotificationRecipient({
        message: {senderId: "doctor-1", receiverId: "patient-1"},
        chatData: {participants: ["patient-1", "doctor-1"]},
    });
    assert.equal(doctorToPatient.ok, true);
    assert.equal(doctorToPatient.recipientId, "patient-1");
});

test("resolveChatNotificationRecipient ignores a spoofed receiverId", () => {
    const result = h.resolveChatNotificationRecipient({
        message: {senderId: "patient-1", receiverId: "attacker-target"},
        chatData: {participants: ["patient-1", "doctor-1"]},
    });
    assert.equal(result.ok, true);
    assert.equal(result.recipientId, "doctor-1");
    assert.equal(result.receiverMismatch, true);
});

test("resolveChatNotificationRecipient rejects self, outsiders and missing participants", () => {
    assert.deepEqual(
        h.resolveChatNotificationRecipient({
            message: {senderId: "patient-1", receiverId: "patient-1"},
            chatData: {participants: ["patient-1", "doctor-1"]},
        }).ok,
        true // participant list wins: recipient is doctor-1, never the sender
    );
    assert.equal(h.resolveChatNotificationRecipient({
        message: {senderId: "intruder", receiverId: "doctor-1"},
        chatData: {participants: ["patient-1", "doctor-1"]},
    }).ok, false);
    assert.equal(h.resolveChatNotificationRecipient({
        message: {senderId: "patient-1", receiverId: "doctor-1"},
        chatData: {participants: []},
    }).ok, false);
    assert.equal(h.resolveChatNotificationRecipient({
        message: {senderId: "", receiverId: "doctor-1"},
        chatData: {participants: ["patient-1", "doctor-1"]},
    }).ok, false);
});

test("resolveChatNotificationRecipient allows admin messages only to a participant", () => {
    const adminToDoctor = h.resolveChatNotificationRecipient({
        message: {
            senderId: "admin-1",
            receiverId: "doctor-1",
            isAdminMessage: true,
        },
        chatData: {participants: ["patient-1", "doctor-1"]},
    });
    assert.equal(adminToDoctor.ok, true);
    assert.equal(adminToDoctor.recipientId, "doctor-1");
    assert.equal(adminToDoctor.isAdmin, true);

    const adminToOutsider = h.resolveChatNotificationRecipient({
        message: {
            senderId: "admin-1",
            receiverId: "attacker-target",
            isAdminMessage: true,
        },
        chatData: {participants: ["patient-1", "doctor-1"]},
    });
    assert.equal(adminToOutsider.ok, false);
    assert.equal(adminToOutsider.reason, "admin-receiver-not-participant");
});

test("resolveChatNotificationRecipient never delivers to the sender", () => {
    const result = h.resolveChatNotificationRecipient({
        message: {senderId: "doctor-1", receiverId: "doctor-1"},
        chatData: {participants: ["doctor-1"]},
    });
    assert.equal(result.ok, false);
});

// -----------------------------------------------------------------------------
// Call expiry and payload hygiene
// -----------------------------------------------------------------------------

test("buildCallExpiresAt uses startTime plus ring window plus grace", () => {
    const start = Date.parse("2026-01-01T10:00:00.000Z");
    assert.equal(
        h.buildCallExpiresAt("2026-01-01T10:00:00.000Z", start + 1000),
        start + h.CALL_RING_TIMEOUT_MS + h.CALL_EXPIRY_GRACE_MS
    );
});

test("buildCallExpiresAt falls back to now for an unusable startTime", () => {
    const now = 1_800_000_000_000;
    assert.equal(
        h.buildCallExpiresAt("not-a-date", now),
        now + h.CALL_RING_TIMEOUT_MS + h.CALL_EXPIRY_GRACE_MS
    );
});

test("isCallInvitationExpired treats a missing expiry as still valid", () => {
    assert.equal(h.isCallInvitationExpired(0, 1000), false);
    assert.equal(h.isCallInvitationExpired("", 1000), false);
    assert.equal(h.isCallInvitationExpired(null, 1000), false);
    assert.equal(h.isCallInvitationExpired("1000", 1000), true);
    assert.equal(h.isCallInvitationExpired("2000", 1000), false);
});

test("isUsableImageUrl rejects unsafe or oversized values", () => {
    assert.equal(h.isUsableImageUrl("https://cdn.example.com/a.jpg"), true);
    assert.equal(h.isUsableImageUrl("http://cdn.example.com/a.jpg"), true);
    assert.equal(h.isUsableImageUrl("javascript:alert(1)"), false);
    assert.equal(h.isUsableImageUrl("data:image/png;base64,AAAA"), false);
    assert.equal(h.isUsableImageUrl(""), false);
    assert.equal(h.isUsableImageUrl(null), false);
    assert.equal(h.isUsableImageUrl("https://x/" + "a".repeat(3000)), false);
});

test("notificationEventId is deterministic and safe as a Firestore id", () => {
    const a = h.notificationEventId("chat", "chat/with/slash", "msg 1");
    const b = h.notificationEventId("chat", "chat/with/slash", "msg 1");
    assert.equal(a, b);
    assert.equal(a.includes("/"), false);
    assert.equal(a.startsWith("chat__"), true);
    assert.notEqual(a, h.notificationEventId("call", "chat/with/slash", "msg 1"));
});
