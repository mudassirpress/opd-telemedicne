const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const {setGlobalOptions} = require("firebase-functions/v2");
const {
    NOTIFICATION_SCHEMA_VERSION,
    isUnrecoverableTokenError,
    buildChatNotificationBody,
    resolveChatNotificationRecipient,
    isUsableImageUrl,
    notificationEventId,
} = require("./fcm_helpers");

admin.initializeApp();

// Set global options if needed (e.g. region)
setGlobalOptions({ maxInstances: 10 });

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
//
// Token lookup, profile lookup, dead-token cleanup and the idempotency claim
// live in ./notification_shared.js so the callable call path
// (doctor_presence.js) and the Firestore triggers use exactly the same code.
// ─────────────────────────────────────────────────────────────────────────────

const {
    findFcmToken,
    findUserInfo,
    findAuthorizedAdminRecipients,
    clearStaleFcmToken,
    claimNotificationEvent,
} = require("./notification_shared");
const {
    sendIncomingCallNotificationForCall,
    sendCallTerminationNotificationForCall,
} = require("./call_notification");

// True only for failures that are specific to the recipient's registration
// token. Implementation lives in ./fcm_helpers.js (unit-tested) — in
// particular, `messaging/authentication-error` (our own credential) and a
// payload-shaped `messaging/invalid-argument` are NOT token errors and must
// never delete a working token. See isUnrecoverableTokenError there.

// ─────────────────────────────────────────────────────────────────────────────
// Auto-mark users offline if lastHeartbeat > 45 seconds ago.
// Runs every 30 seconds via Cloud Scheduler.
//
// Presence logic:
//   Patients are ONLINE only if isOnline==true AND lastHeartbeat is fresh.
//   Doctors are controlled by their manual duty switch: `manualAvailability`
//   is never cleared here, because heartbeats stop when the app leaves the
//   foreground and that must not end a doctor's shift. Only legacy doctor
//   records without a manual switch are reaped from stale heartbeats.
// ─────────────────────────────────────────────────────────────────────────────
exports.autoMarkOffline = onSchedule({
    schedule: "every 1 minutes",
    timeZone: "Asia/Karachi",
    retryCount: 1,
}, async (event) => {
    const db = admin.firestore();
    const now = Date.now();
    const HEARTBEAT_TIMEOUT_MS = 45 * 1000; // 45 seconds (3 × 15s heartbeat)
    const cutoff = new Date(now - HEARTBEAT_TIMEOUT_MS);
    let totalUpdated = 0;

    // ── Process patients ──────────────────────────────────────────────────
    try {
        const patientSnap = await db.collection("telemedicine_patient")
            .where("isOnline", "==", true)
            .get();

        const batch1 = db.batch();
        for (const doc of patientSnap.docs) {
            const data = doc.data();
            const lastHeartbeat = data.lastHeartbeat;
            const lastSeen = data.lastSeen;
            const reference = lastHeartbeat || lastSeen;

            // Mark offline if no heartbeat within timeout
            if (!reference || reference.toDate() < cutoff) {
                batch1.update(doc.ref, {
                    isOnline: false,
                    lastSeen: admin.firestore.FieldValue.serverTimestamp(),
                });
                totalUpdated++;
            }
        }
        if (totalUpdated > 0) {
            await batch1.commit();
        }
        console.log(`[autoMarkOffline] Patients: ${patientSnap.docs.length} checked, ${totalUpdated} marked offline`);
    } catch (error) {
        console.error("[autoMarkOffline] Patient batch error:", error);
    }

    // ── Process doctors ───────────────────────────────────────────────────
    let doctorUpdated = 0;
    try {
        const doctorSnap = await db.collection("telemedicine_doctors")
            .where("isOnline", "==", true)
            .get();

        const batch2 = db.batch();
        for (const doc of doctorSnap.docs) {
            const data = doc.data();

            // Manual availability is the doctor's explicit duty switch. A
            // heartbeat is only produced by the foreground Flutter timer, so
            // using its age to clear `isOnline` silently took a doctor off
            // duty whenever the app was backgrounded or killed. Never
            // overwrite manual ON; only reap legacy records that are online
            // without a manual switch.
            if (data.manualAvailability === true) {
                continue;
            }

            const lastHeartbeat = data.lastHeartbeat;
            const lastSeen = data.lastSeen;
            const reference = lastHeartbeat || lastSeen;

            if (!reference || reference.toDate() < cutoff) {
                batch2.update(doc.ref, {
                    isOnline: false,
                    isAvailable: false,
                    presenceStale: true,
                    deviceReachable: false,
                    lastSeen: admin.firestore.FieldValue.serverTimestamp(),
                });
                doctorUpdated++;
            }
        }
        if (doctorUpdated > 0) {
            await batch2.commit();
        }
        console.log(`[autoMarkOffline] Doctors: ${doctorSnap.docs.length} checked, ${doctorUpdated} marked offline`);
    } catch (error) {
        console.error("[autoMarkOffline] Doctor batch error:", error);
    }

    console.log(`[autoMarkOffline] Done. Total marked offline: ${totalUpdated + doctorUpdated}`);
    return null;
});

// ─────────────────────────────────────────────────────────────────────────────
// sweepStaleCalls.
//
// A `ringing` call is normally closed by the caller's 45s client timer or the
// callee's auto-miss. If BOTH apps die during the ring, no client ever runs
// and the doc stays `ringing` forever — which busy-locked both users
// (isUserOnCall) and re-rang the callee on every app launch via the
// active-call Firestore watcher. This sweep is the server-side safety net.
//
// `startTime` is stored as an ISO-8601 string (CallModel.toMap), so the age
// check parses the string instead of comparing Firestore timestamps.
// ─────────────────────────────────────────────────────────────────────────────
exports.sweepStaleCalls = onSchedule({
    schedule: "every 1 minutes",
    timeZone: "Asia/Karachi",
    retryCount: 1,
}, async (event) => {
    const db = admin.firestore();
    const RING_STALE_MS = 90 * 1000; // client ring timeout is 45s
    const cutoff = new Date(Date.now() - RING_STALE_MS);

    try {
        const snap = await db.collection("calls")
            .where("callStatus", "==", "ringing")
            .limit(200)
            .get();

        if (snap.empty) return null;

        const batch = db.batch();
        let swept = 0;
        for (const doc of snap.docs) {
            const raw = doc.data().startTime;
            let started = null;
            if (raw && typeof raw.toDate === "function") {
                started = raw.toDate();
            } else if (typeof raw === "string") {
                started = new Date(raw);
            }
            // Unparseable timestamps are left alone — safer than ending a
            // call that might still be live.
            if (started && !Number.isNaN(started.getTime()) && started < cutoff) {
                batch.update(doc.ref, {
                    callStatus: "missed",
                    endedAt: new Date().toISOString(),
                });
                swept++;
            }
        }
        if (swept > 0) {
            await batch.commit();
        }
        console.log(`[sweepStaleCalls] Checked ${snap.docs.length}, swept ${swept} stale ringing calls`);
    } catch (error) {
        console.error("[sweepStaleCalls] Error:", error);
    }
    return null;
});


// ─────────────────────────────────────────────────────────────────────────────
// CHAT_MESSAGE notification.
//
// Triggered whenever a new chat message document is created under:
//   chats/{chatId}/messages/{messageId}
//
// Sends an FCM message that carries BOTH:
//   - an Android `notification` block so the OS shows a system notification in
//     the background / terminated state EVEN IF the Flutter headless isolate is
//     unavailable, and
//   - a full `data` payload (type=chat_message, chatId, messageId, sender
//     profile, receiverId, messageText, timestamp) used for routing/taps.
//
// Foreground display is intentionally left to the app (onMessage) so the
// WhatsApp-style notification with the sender image can be rendered there.
// The background Flutter handler skips local display when it sees this
// system notification (see main.dart), preventing duplicates.
// ─────────────────────────────────────────────────────────────────────────────
exports.sendChatNotification = onDocumentCreated("chats/{chatId}/messages/{messageId}", async (event) => {
    const snap = event.data;
    if (!snap) {
        console.log("[CHAT_NOTIFICATION] No data associated with the event");
        return;
    }

    const newValue = snap.data();
    const chatId = event.params.chatId;
    const messageId = event.params.messageId;

    const senderId = newValue.senderId;
    let receiverId = newValue.receiverId;

    console.log(`[CHAT_NOTIFICATION] MESSAGE_SAVED messageId=${messageId} chatId=${chatId} senderId=${senderId} receiverId=${receiverId}`);

    if (!senderId) {
        console.log(`[CHAT_NOTIFICATION] SENDER_ID_MISSING messageId=${messageId}`);
        return null;
    }

    // A call event is written into the conversation as a message so history
    // reads correctly, and it is announced by the dedicated call notification.
    // Without this guard every call transition (ringing, accepted, ended)
    // produced a chat heads-up mislabelled as a voice message, competing with
    // the incoming-call notification itself.
    if (newValue.callData || newValue.messageType === "call_audio" || newValue.messageType === "call_video") {
        console.log(`[CHAT_NOTIFICATION] SKIPPED call event messageId=${messageId}`);
        return null;
    }

    // Recipient resolution is based on the conversation document, not on the
    // `receiverId` the client wrote on the message. A modified client could
    // otherwise put any account id there and have the backend push to it.
    let chatData = null;
    try {
        const chatSnap = await admin.firestore()
            .collection("chats")
            .doc(chatId)
            .get();
        if (!chatSnap.exists) {
            console.log(`[CHAT_NOTIFICATION] CHAT_NOT_FOUND chatId=${chatId} messageId=${messageId}`);
            return null;
        }
        chatData = chatSnap.data() || {};
    } catch (error) {
        console.error(`[CHAT_NOTIFICATION] CHAT_LOOKUP_FAILED chatId=${chatId} messageId=${messageId}: `, error);
        return null;
    }

    const resolution = resolveChatNotificationRecipient({
        message: newValue,
        chatData,
    });
    if (!resolution.ok) {
        console.log(
            `[CHAT_NOTIFICATION] RECIPIENT_REJECTED chatId=${chatId} `
            + `messageId=${messageId} reason=${resolution.reason}`
        );
        return null;
    }
    if (resolution.receiverMismatch) {
        console.warn(
            `[CHAT_NOTIFICATION] RECEIVER_MISMATCH_OVERRIDDEN chatId=${chatId} `
            + `messageId=${messageId} claimed=${receiverId} `
            + `resolved=${resolution.recipientId}`
        );
    }
    receiverId = resolution.recipientId;
    const isAdminMessage = resolution.isAdmin === true;
    console.log(`[CHAT_NOTIFICATION] RECEIVER_ID_FOUND receiverId=${receiverId} isAdmin=${isAdminMessage}`);

    // EVERYTHING below is inside one try/catch.
    //
    // The lookups (`findFcmToken` / `findUserInfo`) used to be awaited OUTSIDE
    // any try/catch. A single transient Firestore read error — a network blip
    // on the function instance, a brief permission hiccup — therefore crashed
    // the whole invocation, and because v2 Firestore functions do NOT retry by
    // default the chat notification for that message was lost forever. The
    // call path had the same shape but its failures are covered by the app's
    // Firestore ringing-watcher safety net, which is why calls looked reliable
    // while chats did not.
    let receiverToken = null;
    try {
        // Look up the receiver's latest FCM token (patient OR doctor collection).
        receiverToken = await findFcmToken(receiverId);
        console.log(`[CHAT_NOTIFICATION] receiverId=${receiverId} receiverTokenExists=${!!receiverToken} messageId=${messageId} chatId=${chatId}`);

        if (!receiverToken) {
            console.log(`[CHAT_NOTIFICATION] RECEIVER_TOKEN_MISSING receiverId=${receiverId} (token is null/empty in Firestore)`);
            return null;
        }
        console.log("[CHAT_NOTIFICATION] RECEIVER_TOKEN_FOUND");

        // Look up sender's info (name / image / role) from patient or doctor
        // collection. Admin messages carry the admin's display name on the
        // message itself because `/admins` has no profile document.
        let senderName = isAdminMessage
            ? String(newValue.adminName || "Admin")
            : "A user";
        let senderProfileImage = "";
        let senderRole = isAdminMessage ? "admin" : "patient";

        const senderInfo = await findUserInfo(senderId);
        if (senderInfo) {
            senderName = senderInfo.name || senderName;
            senderProfileImage = senderInfo.image || "";
            senderRole = senderInfo.type || senderRole;
        }
        const senderImageUrl = isUsableImageUrl(senderProfileImage)
            ? senderProfileImage
            : "";

        // Human-readable body for the OS/iOS banner: a fixed label for media,
        // a bounded single-line preview for text. See
        // fcm_helpers.CHAT_NOTIFICATION_BODY_MAX_CHARS for why it is bounded.
        // `data.messageText` below stays untruncated — it feeds the offline
        // cache and must be the real message.
        const messageBody = buildChatNotificationBody(
            newValue.message,
            newValue.messageType
        );

        const message = {
            token: receiverToken,
            // Top-level notification block: FCM HTTP v1 standard for OS-level
            // display across all platforms (Android & iOS) in background/killed states.
            notification: {
                title: senderName,
                body: messageBody,
            },
            // Structured data payload used for routing + taps + foreground display.
            // Every value MUST be a string — the FCM HTTP v1 API rejects
            // non-string data values, and one rejected field fails the send.
            data: {
                schemaVersion: NOTIFICATION_SCHEMA_VERSION,
                type: "chat_message",
                chatId: chatId,
                messageId: messageId,
                senderId: senderId,
                senderName: senderName,
                senderProfileImage: senderImageUrl,
                senderRole: senderRole,
                receiverId: receiverId,
                recipientId: receiverId,
                messageText: String(newValue.message ?? ""),
                messageType: String(newValue.messageType || "text"),
                sentAt: new Date().toISOString(),
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                timestamp: Date.now().toString(),
            },
            // Android: actual notification payload so the OS always displays the
            // message in background/terminated, using the app's chat channel.
            android: {
                priority: "high",
                ttl: "3600s",
                notification: {
                    title: senderName,
                    body: messageBody,
                    // Must match NotificationChannels.chat on the client.
                    channelId: "chat_notifications_channel",
                    channel_id: "chat_notifications_channel",
                    icon: "ic_notification",
                    ...(senderImageUrl ? {imageUrl: senderImageUrl} : {}),
                    tag: `chat_${chatId}`,
                    clickAction: "FLUTTER_NOTIFICATION_CLICK",
                    click_action: "FLUTTER_NOTIFICATION_CLICK",
                    sound: "default",
                    priority: "max",
                    defaultSound: true,
                    defaultVibrateTimings: true,
                    visibility: "private",
                },
            },
            // iOS: notification payload with high priority and background wakeup.
            apns: {
                headers: {
                    "apns-priority": "10",
                },
                payload: {
                    aps: {
                        alert: {
                            title: senderName,
                            body: messageBody,
                        },
                        sound: "default",
                        badge: 1,
                        "content-available": 1,
                    },
                },
            },
        };

        // One claim per (chat, message). A retried Firestore event or a second
        // invocation must not produce a second tray notification.
        const eventId = notificationEventId("chat", chatId, messageId);
        const claimed = await claimNotificationEvent(eventId, {
            type: "chat_message",
            chatId,
            messageId,
            recipientId: receiverId,
        });
        if (!claimed) return null;

        // Transient FCM failures (backend unavailable, internal error, timeout)
        // are retried in-process. A chat message is a one-shot create event —
        // if this invocation gives up, nothing else re-sends the push.
        const TRANSIENT_SEND_RETRY_DELAYS_MS = [1000, 3000];
        for (let attempt = 0; ; attempt++) {
            try {
                console.log(`[CHAT_NOTIFICATION] FCM_SEND_STARTED receiverId=${receiverId} messageId=${messageId} attempt=${attempt + 1}`);
                await admin.messaging().send(message);
                console.log(`[CHAT_NOTIFICATION] FCM_SEND_SUCCESS receiverId=${receiverId} messageId=${messageId}`);
                break;
            } catch (sendError) {
                const transient =
                    sendError &&
                    (sendError.code === "messaging/internal-error" ||
                        sendError.code === "messaging/server-unavailable" ||
                        sendError.code === "messaging/timeout" ||
                        (typeof sendError.code === "string" && sendError.code.includes("unavailable")));
                if (transient && attempt < TRANSIENT_SEND_RETRY_DELAYS_MS.length) {
                    console.warn(`[CHAT_NOTIFICATION] TRANSIENT_SEND_ERROR retrying messageId=${messageId} attempt=${attempt + 1}: `, sendError);
                    await new Promise((resolve) => setTimeout(resolve, TRANSIENT_SEND_RETRY_DELAYS_MS[attempt]));
                    continue;
                }
                throw sendError;
            }
        }
    } catch (error) {
        console.error(`[CHAT_NOTIFICATION] FCM_SEND_FAILED receiverId=${receiverId} messageId=${messageId}: `, error);
        // Same self-healing as the call path: a rotated or uninstalled token
        // can never be delivered to again. The chat function used to only log
        // the failure, so the dead token stayed on the user document and every
        // subsequent chat push failed silently against it — while the call
        // function cleared the same token on its next failure, making calls
        // look healthy and chats look broken. Clearing it here keeps both
        // pipelines honest; the client re-registers on its next app open.
        if (isUnrecoverableTokenError(error) && receiverToken) {
            try {
                await clearStaleFcmToken(receiverId, receiverToken);
            } catch (clearError) {
                console.error(
                    `[CHAT_NOTIFICATION] TOKEN_CLEAR_FAILED messageId=${messageId}: `,
                    clearError
                );
            }
        } else if (receiverToken) {
            // Not a dead token — the payload, the credentials or the FCM
            // backend failed. The token stays so the next message can still
            // be delivered; this line is what distinguishes the two in the logs.
            console.warn(
                `[CHAT_NOTIFICATION] TOKEN_PRESERVED code=${error && error.code} `
                + `messageId=${messageId} receiverId=${receiverId}`
            );
        }
    }

    return null;
});

// ─────────────────────────────────────────────────────────────────────────────
// INCOMING_CALL notification.
//
// One sender: ./call_notification.js. This trigger covers calls created
// directly as `ringing` (doctor → patient). Patient → doctor calls are created
// as `probing` by `requestDoctorCall` and sent explicitly after promotion, so
// the create event does not double-send.
// ─────────────────────────────────────────────────────────────────────────────
exports.sendIncomingCallNotification = onDocumentCreated("calls/{callId}", async (event) => {
    if (!event.data) return null;
    const callId = event.params.callId;
    const data = event.data.data();
    console.log(
        `[CALL_NOTIFICATION] CALL_CREATED callId=${callId} `
        + `callerId=${data.callerId} receiverId=${data.receiverId} `
        + `status=${data.callStatus}`
    );
    if (!data || data.callStatus !== "ringing") {
        // The callable path sends after promoting probing → ringing.
        return null;
    }
    await sendIncomingCallNotificationForCall(callId);
    return null;
});

// Sends call_cancel high-priority push when caller cancels or call terminates
exports.handleCallStatusUpdate = onDocumentUpdated("calls/{callId}", async (event) => {
    if (!event.data) return null;
    const beforeData = event.data.before ? event.data.before.data() : null;
    const afterData = event.data.after ? event.data.after.data() : null;
    if (!beforeData || !afterData) return null;

    const callId = event.params.callId;
    const oldStatus = beforeData.callStatus;
    const newStatus = afterData.callStatus;

    if (oldStatus === "ringing" && newStatus && newStatus !== "ringing") {
        console.log(`[CALL_UPDATE] Call ${callId} status changed: ${oldStatus} -> ${newStatus}`);
        await sendCallTerminationNotificationForCall(callId, oldStatus, newStatus);
    }
    return null;
});

// ─────────────────────────────────────────────────────────────────────────────
// PASSWORD_RESET notification.
//
// Triggered when a document is created under: password_reset_requests/{userId}
// Sends the "Do you want to reset your password?" push to that user's device.
// ─────────────────────────────────────────────────────────────────────────────
exports.sendPasswordResetNotifications = onDocumentCreated("password_reset_requests/{userId}", async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    const userId = event.params.userId;
    const resetToken = data.resetToken || "";
    if (!userId || !resetToken) {
        console.log("[PASSWORD_RESET] Missing userId/resetToken");
        return;
    }

    const receiverToken = await findFcmToken(userId);
    console.log(`[PASSWORD_RESET] userId=${userId} receiverTokenExists=${!!receiverToken}`);
    if (!receiverToken) {
        console.log(`[PASSWORD_RESET] RECEIVER_TOKEN_MISSING userId=${userId}`);
        return;
    }

    const message = {
        token: receiverToken,
        data: {
            type: "password_reset",
            resetToken: resetToken,
            userId: userId,
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            timestamp: Date.now().toString(),
        },
        notification: {
            title: "Password Reset Request",
            body: "Do you want to reset your password?",
        },
        android: {
            priority: "high",
            ttl: "30s",
            notification: {
                channel_id: "password_reset_notifications",
                sound: "default",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                color: "#FF0000",
            },
        },
        apns: {
            headers: { "apns-priority": "10" },
            payload: {
                aps: {
                    sound: "default",
                    badge: 1,
                    "content-available": 1,
                    category: "password_reset_category",
                },
            },
        },
    };

    try {
        console.log(`[PASSWORD_RESET] FCM_SEND_STARTED userId=${userId}`);
        await admin.messaging().send(message);
        console.log(`[PASSWORD_RESET] FCM_SEND_SUCCESS userId=${userId}`);
    } catch (error) {
        console.error(`[PASSWORD_RESET] FCM_SEND_FAILED userId=${userId}: `, error);
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// PAYMENT_SUBMITTED notification (patient submits a new payment proof).
//
// Triggered when a patient document transitions to paymentStatus="pending".
// Notifies every admin (role == "admin") that has an FCM token.
//
// This is a RELIABILITY BACKUP for the client-side push in
// PatientController._notifyAdminsOfPaymentProof — it covers the case where the
// patient's device dies between the Firestore write and the HTTP send. The
// client's send and this function therefore race on purpose: both use the
// `paymentId` / `lastPaymentNotificationId` already persisted on the patient
// document, and the receiving app de-duplicates on those ids (and derives a
// stable local notification id from them), so a double delivery collapses to a
// single notification and a single navigation.
// ─────────────────────────────────────────────────────────────────────────────
exports.sendAdminPaymentProofNotifications = onDocumentUpdated("telemedicine_patient/{userId}", async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};

    if (after.paymentStatus === "pending" && before.paymentStatus !== "pending") {
        const patientId = event.params.userId;
        const patientName = after.fullname || after.fullName || "A patient";
        const amount = after.totalPayment != null
            ? Number(after.totalPayment).toFixed(2)
            : "0";
        const paymentId = after.paymentId || "";
        const notificationId = after.lastPaymentNotificationId || "";
        const paymentType = after.paymentType || "account_activation";
        const isReactivation = paymentType === "account_reactivation";
        const notifTitle = isReactivation ? "New Account Reactivation Payment" : "New Account Activation Payment";
        const notifBody = isReactivation
            ? `${patientName} submitted account reactivation payment proof.`
            : `${patientName} submitted account activation payment proof.`;

        console.log(`[PAYMENT_SUBMITTED] paymentStatus became pending patientId=${patientId} patientName=${patientName} amount=${amount} paymentType=${paymentType}`);

        const db = admin.firestore();

        // Save persistent record to admin_notifications
        const adminNotifId = `notif_${notificationId || paymentId || patientId}`;
        try {
            await db.collection("admin_notifications").doc(adminNotifId).set({
                notificationId: adminNotifId,
                type: "payment_proof_submitted",
                paymentType: paymentType,
                title: notifTitle,
                body: notifBody,
                patientUid: patientId,
                patientId: after.patientId || null,
                patientName: patientName,
                paymentId: paymentId || null,
                amount: amount,
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            console.log(`[PAYMENT_SUBMITTED] Persistent notification saved adminNotifId=${adminNotifId}`);
        } catch (err) {
            console.error(`[PAYMENT_SUBMITTED] Error saving persistent admin notification: `, err);
        }

        const adminRecipients = await findAuthorizedAdminRecipients();
        console.log(`[PAYMENT_SUBMITTED] Found ${adminRecipients.length} authorized admin recipients for patientId=${patientId}`);

        for (const adminRecip of adminRecipients) {
            const eventId = notificationEventId("admin_payment_proof", patientId, paymentId || notificationId, adminRecip.userId);
            const claimed = await claimNotificationEvent(eventId, {
                type: "payment_proof_submitted",
                patientId,
                paymentId,
                adminUid: adminRecip.userId,
            });
            if (!claimed) {
                console.log(`[PAYMENT_SUBMITTED] Duplicate push skipped for admin ${adminRecip.userId}`);
                continue;
            }

            const message = {
                token: adminRecip.token,
                data: {
                    schemaVersion: NOTIFICATION_SCHEMA_VERSION,
                    type: "payment_proof_submitted",
                    paymentType: paymentType,
                    patientId: patientId,
                    patientName: patientName,
                    amount: amount,
                    paymentId: paymentId,
                    notificationId: notificationId,
                    sentAt: new Date().toISOString(),
                    click_action: "FLUTTER_NOTIFICATION_CLICK",
                    timestamp: Date.now().toString(),
                },
                notification: {
                    title: notifTitle,
                    body: notifBody,
                },
                android: {
                    priority: "high",
                    ttl: "3600s",
                    notification: {
                        channel_id: "general_notifications",
                        sound: "default",
                        click_action: "FLUTTER_NOTIFICATION_CLICK",
                    },
                },
                apns: {
                    headers: { "apns-priority": "10" },
                    payload: {
                        aps: {
                            alert: { title: notifTitle, body: notifBody },
                            sound: "default",
                            badge: 1,
                            "content-available": 1,
                        },
                    },
                },
            };

            try {
                await admin.messaging().send(message);
                console.log(`[PAYMENT_SUBMITTED] FCM_SEND_SUCCESS adminId=${adminRecip.userId}`);
            } catch (error) {
                console.error(`[PAYMENT_SUBMITTED] FCM_SEND_FAILED adminId=${adminRecip.userId}: `, error);
                if (isUnrecoverableTokenError(error)) {
                    await clearStaleFcmToken(adminRecip.userId, adminRecip.token);
                }
            }
        }
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// APPOINTMENT PAYMENT notification (patient submits appointment payment proof).
//
// Triggered on new document creation in `appointment_payments/{paymentId}`.
// Creates persistent record in `admin_notifications` and sends FCM push to admins.
// ─────────────────────────────────────────────────────────────────────────────
exports.sendAdminAppointmentPaymentNotifications = onDocumentCreated("appointment_payments/{paymentId}", async (event) => {
    const snap = event.data;
    if (!snap) return;

    const payment = snap.data() || {};
    const paymentId = event.params.paymentId;
    const paymentStatus = payment.paymentStatus || "pending";
    if (paymentStatus !== "pending") return;

    const patientId = payment.patientId || "";
    const patientName = payment.patientName || "A patient";
    const doctorName = payment.doctorName || "a doctor";
    const amount = payment.payableAmount != null ? Number(payment.payableAmount).toFixed(0) : "0";
    const notificationId = payment.notificationId || `notif_${paymentId}`;

    const notifTitle = "New Appointment Payment";
    const notifBody = `${patientName} submitted payment proof for an appointment with Dr. ${doctorName}.`;

    const db = admin.firestore();
    const adminNotifId = `notif_${notificationId}`;

    try {
        await db.collection("admin_notifications").doc(adminNotifId).set({
            notificationId: adminNotifId,
            type: "payment_proof_submitted",
            paymentType: "appointment_booking",
            title: notifTitle,
            body: notifBody,
            paymentId: paymentId,
            patientUid: patientId,
            patientName: patientName,
            doctorName: doctorName,
            amount: amount,
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
    } catch (err) {
        console.error("[APPOINTMENT_PAYMENT] Error saving persistent admin notification:", err);
    }

    const adminRecipients = await findAuthorizedAdminRecipients();
    console.log(`[APPOINTMENT_PAYMENT] Found ${adminRecipients.length} authorized admin recipients for paymentId=${paymentId}`);

    for (const adminRecip of adminRecipients) {
        const eventId = notificationEventId("admin_appt_payment", paymentId || notificationId, adminRecip.userId);
        const claimed = await claimNotificationEvent(eventId, {
            type: "appointment_payment_submitted",
            paymentId,
            patientId,
            adminUid: adminRecip.userId,
        });
        if (!claimed) {
            console.log(`[APPOINTMENT_PAYMENT] Duplicate push skipped for admin ${adminRecip.userId}`);
            continue;
        }

        const message = {
            token: adminRecip.token,
            data: {
                schemaVersion: NOTIFICATION_SCHEMA_VERSION,
                type: "payment_proof_submitted",
                paymentType: "appointment_booking",
                patientId: patientId,
                patientName: patientName,
                doctorName: doctorName,
                amount: amount,
                paymentId: paymentId,
                notificationId: notificationId,
                sentAt: new Date().toISOString(),
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                timestamp: Date.now().toString(),
            },
            notification: {
                title: notifTitle,
                body: notifBody,
            },
            android: {
                priority: "high",
                ttl: "3600s",
                notification: {
                    channel_id: "general_notifications",
                    sound: "default",
                    click_action: "FLUTTER_NOTIFICATION_CLICK",
                },
            },
            apns: {
                headers: { "apns-priority": "10" },
                payload: {
                    aps: {
                        alert: { title: notifTitle, body: notifBody },
                        sound: "default",
                        badge: 1,
                        "content-available": 1,
                    },
                },
            },
        };

        try {
            await admin.messaging().send(message);
            console.log(`[APPOINTMENT_PAYMENT] FCM_SEND_SUCCESS adminId=${adminRecip.userId}`);
        } catch (error) {
            console.error(`[APPOINTMENT_PAYMENT] FCM_SEND_FAILED adminId=${adminRecip.userId}: `, error);
            if (isUnrecoverableTokenError(error)) {
                await clearStaleFcmToken(adminRecip.userId, adminRecip.token);
            }
        }
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// PAYMENT_COMPLAINT notification (patient submits a payment complaint/inquiry).
//
// Triggered on new document creation in `payment_complaints/{complaintId}`.
// Idempotently creates/ensures persistent record in `admin_notifications` collection
// and sends FCM push notification with type: "payment_complaint" to all authorized
// admins with an FCM token.
// ─────────────────────────────────────────────────────────────────────────────
exports.sendAdminPaymentComplaintNotifications = onDocumentCreated("payment_complaints/{complaintId}", async (event) => {
    const snap = event.data;
    if (!snap) return;

    const complaint = snap.data() || {};
    const complaintId = event.params.complaintId;
    const patientUid = complaint.patientUid || "";
    const patientName = complaint.patientName || "Patient";
    const category = complaint.category || "Payment Complaint";
    const rawMessage = (complaint.message || "").trim();
    const paymentId = complaint.paymentId || "";
    const paymentStatus = complaint.paymentStatusAtSubmission || "not_submitted";
    const notificationId = `notif_${complaintId}`;

    const previewMessage = rawMessage.length > 70
        ? `${rawMessage.substring(0, 67)}...`
        : rawMessage;

    const notifTitle = "New Patient Complaint";
    const notifBody = `${patientName} (${category}): "${previewMessage}"`;

    const db = admin.firestore();

    // Idempotent persistent admin notification record
    try {
        await db.collection("admin_notifications").doc(notificationId).set({
            notificationId: notificationId,
            type: "payment_complaint",
            title: notifTitle,
            body: notifBody,
            complaintId: complaintId,
            patientUid: patientUid,
            patientId: complaint.patientId || null,
            patientName: patientName,
            paymentId: paymentId || null,
            paymentStatus: paymentStatus,
            category: category,
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        console.log(`[PAYMENT_COMPLAINT] Persistent notification saved notificationId=${notificationId}`);
    } catch (err) {
        console.error(`[PAYMENT_COMPLAINT] Error saving persistent notification: `, err);
    }

    // Resolve authorized admin recipients
    const adminRecipients = await findAuthorizedAdminRecipients();
    console.log(`[PAYMENT_COMPLAINT] Sending push to ${adminRecipients.length} authorized admins for complaintId=${complaintId}`);

    for (const adminRecip of adminRecipients) {
        const eventId = notificationEventId("admin_complaint", complaintId, adminRecip.userId);
        const claimed = await claimNotificationEvent(eventId, {
            type: "payment_complaint",
            complaintId,
            patientUid,
            adminUid: adminRecip.userId,
        });
        if (!claimed) {
            console.log(`[PAYMENT_COMPLAINT] Duplicate push skipped for admin ${adminRecip.userId}`);
            continue;
        }

        const message = {
            token: adminRecip.token,
            data: {
                schemaVersion: NOTIFICATION_SCHEMA_VERSION,
                type: "payment_complaint",
                complaintId: complaintId,
                patientUid: patientUid,
                paymentId: paymentId,
                notificationId: notificationId,
                sentAt: new Date().toISOString(),
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                timestamp: Date.now().toString(),
            },
            notification: {
                title: notifTitle,
                body: notifBody,
            },
            android: {
                priority: "high",
                ttl: "3600s",
                notification: {
                    channel_id: "general_notifications",
                    sound: "default",
                    click_action: "FLUTTER_NOTIFICATION_CLICK",
                },
            },
            apns: {
                headers: { "apns-priority": "10" },
                payload: {
                    aps: {
                        alert: { title: notifTitle, body: notifBody },
                        sound: "default",
                        badge: 1,
                        "content-available": 1,
                    },
                },
            },
        };

        try {
            await admin.messaging().send(message);
            console.log(`[PAYMENT_COMPLAINT] FCM_SEND_SUCCESS adminId=${adminRecip.userId}`);
        } catch (error) {
            console.error(`[PAYMENT_COMPLAINT] FCM_SEND_FAILED adminId=${adminRecip.userId}: `, error);
            if (isUnrecoverableTokenError(error)) {
                await clearStaleFcmToken(adminRecip.userId, adminRecip.token);
            }
        }
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// COMPLAINT STATUS / ADMIN RESPONSE notification (admin responds to patient).
//
// Triggered when a document in `payment_complaints/{complaintId}` is updated.
// Sends `complaint_reply` push to the patient when an admin responds or updates status.
// ─────────────────────────────────────────────────────────────────────────────
exports.handleComplaintStatusUpdate = onDocumentUpdated("payment_complaints/{complaintId}", async (event) => {
    if (!event.data) return null;
    const beforeData = event.data.before ? event.data.before.data() : null;
    const afterData = event.data.after ? event.data.after.data() : null;
    if (!beforeData || !afterData) return null;

    const complaintId = event.params.complaintId;
    const patientUid = afterData.patientUid;
    if (!patientUid) return null;

    const hasNewResponse = Boolean(
        afterData.adminResponse &&
        afterData.adminResponse.trim().length > 0 &&
        afterData.adminResponse.trim() !== (beforeData.adminResponse || "").trim()
    );
    const hasStatusChange = Boolean(
        afterData.status &&
        afterData.status !== beforeData.status
    );

    if (!hasNewResponse && !hasStatusChange) return null;

    const receiverToken = await findFcmToken(patientUid);
    if (!receiverToken) {
        console.log(`[COMPLAINT_UPDATE] No FCM token for patientUid=${patientUid} complaintId=${complaintId}`);
        return null;
    }

    const title = hasNewResponse
        ? "Admin Replied to Your Complaint"
        : `Complaint Status: ${String(afterData.status || "").toUpperCase()}`;
    const rawBody = hasNewResponse
        ? afterData.adminResponse.trim()
        : `Your complaint status has been updated to ${afterData.status}.`;
    const body = rawBody.length > 100 ? `${rawBody.substring(0, 97)}...` : rawBody;

    const eventTime = afterData.updatedAt
        ? String(afterData.updatedAt.toMillis ? afterData.updatedAt.toMillis() : afterData.updatedAt)
        : Date.now().toString();
    const eventId = notificationEventId("complaint_reply", complaintId, eventTime);
    const claimed = await claimNotificationEvent(eventId, {
        type: "complaint_reply",
        complaintId,
        patientUid,
    });
    if (!claimed) return null;

    const message = {
        token: receiverToken,
        data: {
            schemaVersion: NOTIFICATION_SCHEMA_VERSION,
            type: "complaint_reply",
            complaintId: String(complaintId),
            patientUid: String(patientUid),
            status: String(afterData.status || ""),
            paymentId: String(afterData.paymentId || ""),
            appointmentId: String(afterData.appointmentId || ""),
            sentAt: new Date().toISOString(),
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            timestamp: Date.now().toString(),
        },
        notification: {
            title: title,
            body: body,
        },
        android: {
            priority: "high",
            ttl: "3600s",
            notification: {
                channel_id: "general_notifications",
                sound: "default",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
            },
        },
        apns: {
            headers: { "apns-priority": "10" },
            payload: {
                aps: {
                    alert: { title, body },
                    sound: "default",
                    badge: 1,
                    "content-available": 1,
                },
            },
        },
    };

    try {
        await admin.messaging().send(message);
        console.log(`[COMPLAINT_UPDATE] Sent push to patientUid=${patientUid} complaintId=${complaintId}`);
    } catch (error) {
        console.error(`[COMPLAINT_UPDATE] FCM send failed for complaintId=${complaintId}:`, error);
        if (isUnrecoverableTokenError(error)) {
            await clearStaleFcmToken(patientUid, receiverToken);
        }
    }
    return null;
});

// -----------------------------------------------------------------------------
// APPOINTMENT LIFECYCLE.
//
// Firestore has no clock: nothing happens to a confirmed appointment just
// because its slot arrived. This scheduled function is the half of the
// lifecycle that runs while the app is closed or killed; the app's own
// `AppointmentLifecycleService` is the other half for the open app.
//
//   scheduled start passed ? status becomes appointment_active, and the
//                             one-shot start alarm goes to patient and doctor
//   scheduled end passed   ? status becomes appointment_expired and the
//                             pinned chat message is unpinned, releasing the
//                             patient/doctor pair for a new booking
//
// The alarm is claimed in a transaction on `appointmentStartNotificationSent`
// *before* anything is pushed, using the same field the Dart side claims, so
// whichever of the three runs first wins and the others become no-ops. That is
// what keeps the alarm at exactly one per appointment per start instant.
//
// Only `appointment_confirmed` and `appointment_active` records are scanned:
// an unscheduled `appointment_requested` record has no slot to reach, and
// every terminal status is already past the point of changing.
// -----------------------------------------------------------------------------

const APPOINTMENT_LIFECYCLE_STATUSES = ["appointment_confirmed", "appointment_active"];
const APPOINTMENT_STATUS_ACTIVE = "appointment_active";
const APPOINTMENT_STATUS_EXPIRED = "appointment_expired";

// Mirrors AppointmentDefaults in lib/core/constants/app_constants.dart so a
// push sent from here reads exactly like one sent from the app.
const APPOINTMENT_START_TITLE = "Appointment Starting";

function appointmentStartBody(counterpartName) {
    return `Your appointment with ${counterpartName} starts now. Tap to open the chat.`;
}

// The app's schedules are Pakistani wall-clock times (the scheduler above also
// runs in Asia/Karachi), so a date label without a stored Timestamp is
// resolved against that offset rather than the instance's own timezone.
const KARACHI_OFFSET_MS = 5 * 60 * 60 * 1000;

function parseDateKey(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || "").trim());
    if (!match) return null;
    const day = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
    if (Number.isNaN(day)) return null;
    return new Date(day - KARACHI_OFFSET_MS);
}

function parseTimeLabel(value) {
    const match = /^(\d{1,2}):(\d{2})\s*(AM|PM)?$/i.exec(String(value || "").trim());
    if (!match) return null;
    let hour = Number(match[1]);
    const minute = Number(match[2]);
    const meridiem = match[3] ? match[3].toUpperCase() : null;
    if (minute > 59) return null;
    if (meridiem) {
        if (hour < 1 || hour > 12) return null;
        hour = (hour % 12) + (meridiem === "PM" ? 12 : 0);
    } else if (hour > 23) {
        return null;
    }
    return hour * 60 + minute;
}

/**
 * Absolute instant of one boundary of an appointment.
 *
 * The stored `scheduledStartDateTime` / `scheduledEndDateTime` is
 * authoritative. Records written before those keys existed fall back to the
 * date + time labels; an unreadable end label falls back to the end of the
 * scheduled day so it still expires instead of holding the pair forever, while
 * an unreadable start label resolves to null and simply never fires an alarm.
 */
function appointmentInstant(data, primary, legacy, timeKey, fallbackToNextDay) {
    const stored = data[primary] || data[legacy];
    if (stored && typeof stored.toDate === "function") return stored.toDate();

    const day = parseDateKey(data.scheduledDate);
    if (!day) return null;
    const minutes = parseTimeLabel(data[timeKey]);
    if (minutes == null) return fallbackToNextDay ? new Date(day.getTime() + 24 * 60 * 60 * 1000) : null;
    return new Date(day.getTime() + minutes * 60 * 1000);
}

/** Same chat id algorithm as `ChatController.getChatId` in the app. */
function chatIdFor(patientId, doctorId) {
    return patientId < doctorId ? `${patientId}_${doctorId}` : `${doctorId}_${patientId}`;
}

/** Takes the one-shot alarm claim, or returns false when someone already did. */
async function claimStartAlarm(ref, data) {
    if (data.appointmentStartNotificationSent === true) return false;
    // A previous pass already tried and could not reach anyone: back off rather
    // than claim/release on every tick while the window lasts.
    const retryAt = data.appointmentAlarmRetryAt;
    if (retryAt && typeof retryAt.toDate === "function" && retryAt.toDate() > new Date()) return false;
    try {
        return await admin.firestore().runTransaction(async (tx) => {
            const snap = await tx.get(ref);
            if (!snap.exists) return false;
            if (snap.data().appointmentStartNotificationSent === true) return false;
            tx.update(ref, {
                appointmentStartNotificationSent: true,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            return true;
        });
    } catch (error) {
        console.error(`[APPOINTMENT_LIFECYCLE] Claim failed for ${ref.id}:`, error);
        return false;
    }
}

/** Pushes the start alarm to both sides. True when at least one was reachable. */
async function sendStartAlarm(data, startAt) {
    const appointmentId = data.appointmentId || "";
    const patientId = data.patientId || "";
    const doctorId = data.doctorId || "";
    if (!patientId || !doctorId) return false;

    const chatId = chatIdFor(patientId, doctorId);
    const patientName = data.patientName || "your patient";
    const doctorName = data.doctorName ? `Dr. ${data.doctorName}` : "your doctor";
    const notificationId = `start:${appointmentId}:${startAt.getTime()}`;

    const recipients = [
        {token: await findFcmToken(patientId), counterpart: doctorName, role: "patient"},
        {token: await findFcmToken(doctorId), counterpart: patientName, role: "doctor"},
    ];

    let delivered = false;
    for (const recipient of recipients) {
        if (!recipient.token) continue;
        const body = appointmentStartBody(recipient.counterpart);

        const message = {
            token: recipient.token,
            data: {
                type: "appointment_start",
                appointmentId: appointmentId,
                patientId: patientId,
                patientName: patientName,
                patientImage: data.patientImage || "",
                doctorId: doctorId,
                doctorName: data.doctorName || "",
                doctorImage: data.doctorImage || "",
                chatId: chatId,
                scheduledStartAt: String(startAt.getTime()),
                title: APPOINTMENT_START_TITLE,
                body: body,
                notificationId: notificationId,
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                timestamp: Date.now().toString(),
            },
            notification: {
                title: APPOINTMENT_START_TITLE,
                body: body,
            },
            android: {
                priority: "high",
                ttl: "3600s",
                notification: {
                    channel_id: "general_notifications",
                    sound: "default",
                    click_action: "FLUTTER_NOTIFICATION_CLICK",
                },
            },
            apns: {
                headers: {"apns-priority": "10"},
                payload: {
                    aps: {
                        alert: {title: APPOINTMENT_START_TITLE, body: body},
                        sound: "default",
                        badge: 1,
                        "content-available": 1,
                    },
                },
            },
        };

        try {
            await admin.messaging().send(message);
            delivered = true;
            console.log(`[APPOINTMENT_LIFECYCLE] START_ALARM_SENT ${appointmentId} role=${recipient.role}`);
        } catch (error) {
            console.error(`[APPOINTMENT_LIFECYCLE] START_ALARM_FAILED ${appointmentId} role=${recipient.role}:`, error);
        }
    }

    return delivered;
}

/** Drops the pin so the expired appointment stops occupying the conversation. */
async function unpinAppointmentMessage(data) {
    const messageId = data.pinnedMessageId;
    if (!messageId || !data.patientId || !data.doctorId) return;
    try {
        await admin.firestore()
            .collection("chats")
            .doc(chatIdFor(data.patientId, data.doctorId))
            .collection("messages")
            .doc(messageId)
            .set({isPinned: false}, {merge: true});
    } catch (error) {
        // Unpinning is cosmetic; it must never abort the expiry itself.
        console.error(`[APPOINTMENT_LIFECYCLE] Unpin failed for ${messageId}:`, error);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lifecycle configuration, phase and outcome.
//
// A line-for-line mirror of
// lib/features/appointment/appointment_lifecycle_logic.dart: the foreground
// clock, a screen's own pass and this scheduled function must reach the same
// conclusion from the same document, or the status flip-flops and every
// notification duplicates. The numbers and the copy come from the same
// `appointment_settings/defaults` document the app reads, falling back to the
// same constants the Dart side falls back to.
// ─────────────────────────────────────────────────────────────────────────────

const APPOINTMENT_STATUS_CONFIRMED = "appointment_confirmed";
const APPOINTMENT_STATUS_NO_SHOW = "appointment_no_show";
const APPOINTMENT_STATUS_COMPLETED = "appointment_completed";

const APPOINTMENT_OPEN_STATUSES = new Set([
    "appointment_requested",
    "appointment_confirmed",
    "appointment_active",
]);

const APPOINTMENT_EVENT_TYPES = {
    reminderSent: "reminder_sent",
    doctorLate: "doctor_late",
    patientLate: "patient_late",
    graceEnding: "grace_ending",
    expired: "expired",
    completed: "completed",
    noShow: "no_show",
};

// AppointmentDefaults in lib/core/constants/app_constants.dart.
const APPOINTMENT_LIFECYCLE_DEFAULTS = {
    graceMinutes: 15,
    patientGraceMinutes: 15,
    startingSoonMinutes: 60,
    graceEndingMinutes: 5,
    cancellationWarningLimit: 2,
    freezeDurationDays: 7,
    reminderOffsetsMinutes: [10, 60, 1440],
};

function intOr(value, fallback, min, max) {
    const parsed = typeof value === "number" ? value : Number.parseInt(value, 10);
    if (!Number.isFinite(parsed)) return fallback;
    const rounded = Math.trunc(parsed);
    if (min != null && rounded < min) return min;
    if (max != null && rounded > max) return max;
    return rounded;
}

/** Ascending, positive ints only — same rule as `AppointmentConfig.fromMap`. */
function offsetsOr(value) {
    if (!Array.isArray(value)) return APPOINTMENT_LIFECYCLE_DEFAULTS.reminderOffsetsMinutes;
    const offsets = value
        .map((entry) => intOr(entry, 0, null, null))
        .filter((entry) => entry > 0);
    const unique = Array.from(new Set(offsets));
    unique.sort((a, b) => a - b);
    return unique.length > 0 ? unique : APPOINTMENT_LIFECYCLE_DEFAULTS.reminderOffsetsMinutes;
}

function sanitizeAppointmentConfig(raw) {
    const source = raw && typeof raw === "object" ? raw : {};
    const defaults = APPOINTMENT_LIFECYCLE_DEFAULTS;
    return {
        graceMinutes: intOr(source.graceMinutes, defaults.graceMinutes, 1, null),
        patientGraceMinutes: intOr(source.patientGraceMinutes, defaults.patientGraceMinutes, 1, null),
        startingSoonMinutes: intOr(source.startingSoonMinutes, defaults.startingSoonMinutes, 1, null),
        graceEndingMinutes: intOr(source.graceEndingMinutes, defaults.graceEndingMinutes, 1, null),
        cancellationWarningLimit: intOr(source.cancellationWarningLimit, defaults.cancellationWarningLimit, 1, null),
        freezeDurationDays: intOr(source.freezeDurationDays, defaults.freezeDurationDays, 1, null),
        reminderOffsetsMinutes: offsetsOr(source.reminderOffsetsMinutes),
    };
}

/** Missing or malformed admin config resolves back to the Dart defaults. */
async function loadAppointmentConfig(db) {
    try {
        const snap = await db
            .collection("appointment_settings")
            .doc("defaults")
            .get();
        return sanitizeAppointmentConfig(snap.exists ? snap.data() : {});
    } catch (error) {
        console.error("[APPOINTMENT_LIFECYCLE] Config read failed:", error);
        return sanitizeAppointmentConfig(null);
    }
}

/** Walks a dotted field path (`reminderSent.60`) instead of indexing maps. */
function readFieldPath(data, fieldPath) {
    let current = data;
    for (const part of String(fieldPath).split(".")) {
        if (!current || typeof current !== "object") return undefined;
        current = current[part];
    }
    return current;
}

/**
 * The fine-grained phase at `now` — mirrors `resolveAppointmentPhase`.
 *
 * Precedence: terminal/end → closed; no schedule → waiting; before start →
 * scheduled/starting_soon; both sides in → in_progress; end close →
 * grace_ending; otherwise the missing side's grace, measured from the
 * scheduled start.
 */
function resolveAppointmentPhase({status, startAt, endAt, data, now, config}) {
    if (!APPOINTMENT_OPEN_STATUSES.has(status)) return "closed";
    if (!startAt || !endAt) return "waiting";

    if (now < startAt) {
        const untilStart = Math.floor((startAt.getTime() - now.getTime()) / 60000);
        return untilStart <= config.startingSoonMinutes ? "starting_soon" : "scheduled";
    }
    if (!(now < endAt)) return "closed";

    const patientIn = !!data.patientJoinedAt;
    const doctorIn = !!data.doctorJoinedAt;
    if (patientIn && doctorIn) return "in_progress";

    const untilEnd = Math.floor((endAt.getTime() - now.getTime()) / 60000);
    if (untilEnd < config.graceEndingMinutes) return "grace_ending";

    const doctorLateBy = now.getTime() > startAt.getTime() + config.graceMinutes * 60000;
    const patientLateBy = now.getTime() > startAt.getTime() + config.patientGraceMinutes * 60000;

    if (patientIn && !doctorIn) return doctorLateBy ? "doctor_late" : "waiting_for_doctor";
    if (doctorIn && !patientIn) return patientLateBy ? "patient_late" : "waiting_for_patient";
    return doctorLateBy ? "doctor_late" : "waiting_for_doctor";
}

/**
 * The status an open appointment takes the moment its slot ends — mirrors
 * `resolveTerminalOutcome`: exactly one side in → no-show naming the absent
 * side, nobody in → expired, both in → completed.
 */
function resolveTerminalOutcome(data) {
    const patientIn = !!data.patientJoinedAt;
    const doctorIn = !!data.doctorJoinedAt;
    if (patientIn && !doctorIn) {
        return {status: APPOINTMENT_STATUS_NO_SHOW, noShowBy: "doctor", event: APPOINTMENT_EVENT_TYPES.noShow};
    }
    if (doctorIn && !patientIn) {
        return {status: APPOINTMENT_STATUS_NO_SHOW, noShowBy: "patient", event: APPOINTMENT_EVENT_TYPES.noShow};
    }
    if (patientIn && doctorIn) {
        return {status: APPOINTMENT_STATUS_COMPLETED, noShowBy: "", event: APPOINTMENT_EVENT_TYPES.completed};
    }
    return {status: APPOINTMENT_STATUS_EXPIRED, noShowBy: "", event: APPOINTMENT_EVENT_TYPES.expired};
}

/** Mirrors `reminderWhenLabel`: "in a day" / "in an hour" / "in 10 minutes". */
function reminderWhenLabel(offsetMinutes) {
    if (offsetMinutes >= 1440 && offsetMinutes % 1440 === 0) {
        const days = Math.trunc(offsetMinutes / 1440);
        return days === 1 ? "in a day" : `in ${days} days`;
    }
    if (offsetMinutes >= 60 && offsetMinutes % 60 === 0) {
        const hours = Math.trunc(offsetMinutes / 60);
        return hours === 1 ? "in an hour" : `in ${hours} hours`;
    }
    return `in ${offsetMinutes} minutes`;
}

/** Mirrors `isReminderDue` — the policy half; the claim handles concurrency. */
function isReminderDue({status, startAt, endAt, alreadySent, offsetMinutes, now}) {
    if (alreadySent) return false;
    if (!APPOINTMENT_OPEN_STATUSES.has(status)) return false;
    if (!startAt || !endAt) return false;
    if (offsetMinutes <= 0) return false;

    const dueAt = new Date(startAt.getTime() - offsetMinutes * 60000);
    if (now < dueAt) return false;
    if (!(now < startAt)) return false;
    if (!(now < endAt)) return false;
    return true;
}

/** Append-only audit entry — `appointments/{id}/events`, newest wins on read. */
async function appendAppointmentEvent(db, appointmentId, {type, actorId = "", actorRole = "", detail = ""}) {
    if (!appointmentId || !type) return;
    try {
        await db.collection("appointments").doc(appointmentId).collection("events").add({
            type: type,
            actorId: actorId,
            actorRole: actorRole,
            detail: detail,
            at: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (error) {
        console.error(`[APPOINTMENT_LIFECYCLE] Event write failed for ${appointmentId}:`, error);
    }
}

/** Every admin that has an FCM token — the moderation-style recipients. */
async function adminFcmTokens(db) {
    try {
        const snap = await db.collection("telemedicine_patient")
            .where("role", "==", "admin")
            .get();
        return snap.docs
            .map((doc) => doc.data().fcmToken)
            .filter((token) => typeof token === "string" && token.length > 0);
    } catch (error) {
        console.error("[APPOINTMENT_LIFECYCLE] Admin token read failed:", error);
        return [];
    }
}

/**
 * One lifecycle push, each recipient with its own rendered body but the same
 * `notificationId` — one event, one notification per device, never two. The
 * payload shape matches `FcmService.sendAppointmentLifecycleNotification`, so
 * the receiver reads a Dart-sent and a function-sent push identically.
 */
async function sendLifecyclePush(db, data, opts) {
    const appointmentId = data.appointmentId || "";
    const patientId = data.patientId || "";
    const doctorId = data.doctorId || "";
    if (!patientId || !doctorId) return false;

    const chatId = chatIdFor(patientId, doctorId);
    const recipients = [
        {token: await findFcmToken(patientId), body: opts.patientBody, role: "patient"},
        {token: await findFcmToken(doctorId), body: opts.doctorBody, role: "doctor"},
    ];
    if (opts.includeAdmins) {
        const adminBody = opts.adminBody || opts.doctorBody;
        for (const token of await adminFcmTokens(db)) {
            recipients.push({token: token, body: adminBody, role: "admin"});
        }
    }

    let delivered = false;
    for (const recipient of recipients) {
        if (!recipient.token) continue;
        const message = {
            token: recipient.token,
            data: Object.assign({
                type: opts.type,
                appointmentId: appointmentId,
                patientId: patientId,
                patientName: data.patientName || "",
                patientImage: data.patientImage || "",
                doctorId: doctorId,
                doctorName: data.doctorName || "",
                doctorImage: data.doctorImage || "",
                chatId: chatId,
                title: opts.title,
                body: recipient.body,
                notificationId: opts.notificationId,
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                timestamp: Date.now().toString(),
            }, opts.extra || {}),
            notification: {
                title: opts.title,
                body: recipient.body,
            },
            android: {
                priority: "high",
                ttl: "3600s",
                notification: {
                    channel_id: "general_notifications",
                    sound: "default",
                    click_action: "FLUTTER_NOTIFICATION_CLICK",
                },
            },
            apns: {
                headers: {"apns-priority": "10"},
                payload: {
                    aps: {
                        alert: {title: opts.title, body: recipient.body},
                        sound: "default",
                        badge: 1,
                        "content-available": 1,
                    },
                },
            },
        };
        try {
            await admin.messaging().send(message);
            delivered = true;
            console.log(`[APPOINTMENT_LIFECYCLE] ${opts.type}_SENT ${appointmentId} role=${recipient.role}`);
        } catch (error) {
            console.error(`[APPOINTMENT_LIFECYCLE] ${opts.type}_FAILED ${appointmentId} role=${recipient.role}:`, error);
        }
    }
    return delivered;
}

/**
 * Takes a boolean claim flag in a transaction, or returns false when someone
 * already did. A previous pass that could not reach anyone writes a backoff
 * timestamp first, so claim/release never becomes a write on every tick.
 */
async function claimLifecycleField(ref, data, fieldPath) {
    if (readFieldPath(data, fieldPath) === true) return false;
    const retryAt = readFieldPath(data, `noticeRetry.${fieldPath}`);
    if (retryAt && typeof retryAt.toDate === "function" && retryAt.toDate() > new Date()) return false;
    try {
        return await admin.firestore().runTransaction(async (tx) => {
            const snap = await tx.get(ref);
            if (!snap.exists) return false;
            if (readFieldPath(snap.data(), fieldPath) === true) return false;
            tx.update(ref, {
                [fieldPath]: true,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            return true;
        });
    } catch (error) {
        console.error(`[APPOINTMENT_LIFECYCLE] Claim failed for ${ref.id} (${fieldPath}):`, error);
        return false;
    }
}

/** Hands the claim back and holds the retry off for a minute. */
async function releaseLifecycleField(ref, fieldPath, now) {
    try {
        await ref.update({
            [fieldPath]: false,
            [`noticeRetry.${fieldPath}`]: new Date(now.getTime() + 60 * 1000),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (error) {
        // Leaving the claim set is the safe direction: a missing push beats a
        // duplicate one.
        console.error(`[APPOINTMENT_LIFECYCLE] Release failed for ${ref.id} (${fieldPath}):`, error);
    }
}

// AppointmentDefaults notification copy — mirrors the Dart strings exactly.
function reminderBody(counterpartName, when) {
    return `Your appointment with ${counterpartName} ${when}. Tap to open the chat.`;
}

function lateBody(absentName, minutes) {
    return `${absentName} has not joined yet (${minutes} min late). Tap to open the chat.`;
}

function lateSelfBody(counterpartName, minutes) {
    return `You have not joined your appointment with ${counterpartName} (${minutes} min late). Tap to open the chat.`;
}

function graceEndingBody(counterpartName) {
    return `Your appointment with ${counterpartName} ends in a few minutes. Tap to open the chat.`;
}

function noShowBody(absentName) {
    return `${absentName} did not join the appointment.`;
}

/**
 * The reminder / late / grace push for this appointment, or null when the
 * phase has nothing to announce. Mirrors `_pushReminder` and
 * `_pushAttendanceNotice`, copy included.
 */
function lifecycleNoticeFor({phase, data, startAt, now}) {
    const appointmentId = data.appointmentId || "";
    const patientName = data.patientName || "your patient";
    const doctorLabel = data.doctorName ? `Dr. ${data.doctorName}` : "your doctor";

    if (startAt) {
        const raw = Math.floor((now.getTime() - startAt.getTime()) / 60000);
        const minutes = raw < 0 ? 0 : (raw > 999 ? 999 : raw);
        if (phase === "doctor_late") {
            return {
                claimField: "doctorLateNoticeSent",
                type: "appointment_doctor_late",
                event: APPOINTMENT_EVENT_TYPES.doctorLate,
                notificationId: `att:${appointmentId}:doctor_late`,
                title: "Appointment Late",
                patientBody: lateBody(doctorLabel, minutes),
                doctorBody: lateSelfBody(patientName, minutes),
                extra: {phase: phase, minutes: String(minutes)},
            };
        }
        if (phase === "patient_late") {
            return {
                claimField: "patientLateNoticeSent",
                type: "appointment_patient_late",
                event: APPOINTMENT_EVENT_TYPES.patientLate,
                notificationId: `att:${appointmentId}:patient_late`,
                title: "Appointment Late",
                patientBody: lateSelfBody(doctorLabel, minutes),
                doctorBody: lateBody(patientName, minutes),
                extra: {phase: phase, minutes: String(minutes)},
            };
        }
        if (phase === "grace_ending") {
            return {
                claimField: "graceNoticeSent",
                type: "appointment_grace_ending",
                event: APPOINTMENT_EVENT_TYPES.graceEnding,
                notificationId: `att:${appointmentId}:grace_ending`,
                title: "Appointment Ending Soon",
                patientBody: graceEndingBody(doctorLabel),
                doctorBody: graceEndingBody(patientName),
                extra: {phase: phase},
            };
        }
    }
    return null;
}

exports.appointmentLifecycle = onSchedule({
    schedule: "every 1 minutes",
    timeZone: "Asia/Karachi",
    retryCount: 1,
}, async () => {
    const db = admin.firestore();
    const now = new Date();
    let activated = 0;
    let alarms = 0;
    let checked = 0;

    let snap;
    try {
        snap = await db.collection("appointments")
            .where("appointmentStatus", "in", APPOINTMENT_LIFECYCLE_STATUSES)
            .get();
    } catch (error) {
        console.error("[APPOINTMENT_LIFECYCLE] Query failed:", error);
        return null;
    }

    const config = await loadAppointmentConfig(db);
    let closed = 0;
    let phases = 0;
    let reminders = 0;
    let notices = 0;

    checked = snap.docs.length;

    for (const doc of snap.docs) {
        const data = doc.data();
        try {
            const status = data.appointmentStatus || "";

            // 1. The end is the hard deadline: an appointment that is over
            //    never gets a start alarm, however late this pass runs, and
            //    the status it lands on follows from who actually showed up.
            const endAt = appointmentInstant(
                data, "scheduledEndDateTime", "scheduledEndAt", "scheduledEndTime", true,
            );
            if (endAt && now >= endAt) {
                const outcome = resolveTerminalOutcome(data);
                const stamp = admin.firestore.FieldValue.serverTimestamp();
                const patch = {
                    appointmentStatus: outcome.status,
                    appointmentPhase: "closed",
                    updatedAt: stamp,
                };
                if (outcome.noShowBy) patch.noShowBy = outcome.noShowBy;
                if (outcome.status === APPOINTMENT_STATUS_NO_SHOW) patch.noShowAt = stamp;
                if (outcome.status === APPOINTMENT_STATUS_COMPLETED) patch.completedAt = stamp;
                await doc.ref.set(patch, {merge: true});
                await appendAppointmentEvent(db, doc.id, {
                    type: outcome.event,
                    detail: outcome.noShowBy ? `${outcome.noShowBy} did not join` : "",
                });
                await unpinAppointmentMessage(data);
                if (outcome.status === APPOINTMENT_STATUS_NO_SHOW) {
                    const absentName = outcome.noShowBy === "doctor"
                        ? `Dr. ${data.doctorName || ""}`
                        : (data.patientName || "");
                    await sendLifecyclePush(db, data, {
                        type: "appointment_no_show",
                        title: "Appointment No-Show",
                        patientBody: noShowBody(absentName),
                        doctorBody: noShowBody(absentName),
                        adminBody: noShowBody(absentName),
                        notificationId: `noshow:${doc.id}`,
                        includeAdmins: true,
                        extra: {noShowBy: outcome.noShowBy},
                    });
                }
                closed++;
                continue;
            }

            const startAt = appointmentInstant(
                data, "scheduledStartDateTime", "scheduledStartAt", "scheduledStartTime", false,
            );
            const isConfirmed = status === APPOINTMENT_STATUS_CONFIRMED
                || status === APPOINTMENT_STATUS_ACTIVE;
            const hasSchedule = !!(data.scheduledDate && String(data.scheduledDate).trim());

            // 2. The phase is the display/notification layer — written only
            //    when it actually moved; the events worth auditing (late,
            //    grace) are written by whoever pushes the notice below.
            const phase = (!isConfirmed || !hasSchedule)
                ? "waiting"
                : resolveAppointmentPhase({status, startAt, endAt, data, now, config});
            if (phase !== (data.appointmentPhase || "")) {
                await doc.ref.set({
                    appointmentPhase: phase,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, {merge: true});
                phases++;
            }

            // 3. Reminders only exist before the start; after it the start
            //    alarm owns the moment, so this loop finds nothing due.
            if (isConfirmed && hasSchedule && startAt && endAt) {
                for (const offset of config.reminderOffsetsMinutes) {
                    const claimField = `reminderSent.${offset}`;
                    const claimed = readFieldPath(data, claimField) === true;
                    if (!isReminderDue({
                        status, startAt, endAt, alreadySent: claimed, offsetMinutes: offset, now,
                    })) continue;
                    if (!await claimLifecycleField(doc.ref, data, claimField)) continue;

                    const when = reminderWhenLabel(offset);
                    const delivered = await sendLifecyclePush(db, data, {
                        type: "appointment_reminder",
                        title: "Appointment Reminder",
                        patientBody: reminderBody(`Dr. ${data.doctorName || ""}`, when),
                        doctorBody: reminderBody(data.patientName || "your patient", when),
                        notificationId: `rem:${doc.id}:${offset}`,
                        extra: {offsetMinutes: String(offset), scheduledStartAt: String(startAt.getTime())},
                    });
                    if (delivered) {
                        reminders++;
                        await appendAppointmentEvent(db, doc.id, {
                            type: APPOINTMENT_EVENT_TYPES.reminderSent,
                            detail: `offset=${offset}`,
                        });
                    } else {
                        await releaseLifecycleField(doc.ref, claimField, now);
                    }
                }
            }

            if (!startAt || now < startAt) continue;

            // 4. Activation, then the one-shot start alarm.
            if (data.appointmentStatus !== APPOINTMENT_STATUS_ACTIVE) {
                await doc.ref.update({
                    appointmentStatus: APPOINTMENT_STATUS_ACTIVE,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                data.appointmentStatus = APPOINTMENT_STATUS_ACTIVE;
                activated++;
            }

            if (await claimStartAlarm(doc.ref, data)) {
                const delivered = await sendStartAlarm(data, startAt);
                if (delivered) {
                    alarms++;
                } else {
                    // Nothing went out — hand the claim back so a later pass
                    // can still deliver the alarm inside this window, and hold
                    // the retry off so an unreachable device cannot turn the
                    // claim/release pair into a write on every tick.
                    await doc.ref.update({
                        appointmentStartNotificationSent: false,
                        appointmentAlarmRetryAt: new Date(now.getTime() + 60 * 1000),
                    });
                }
            }

            // 5. The late / grace notices — once per appointment per kind.
            const notice = lifecycleNoticeFor({phase, data, startAt, now});
            if (notice && await claimLifecycleField(doc.ref, data, notice.claimField)) {
                const delivered = await sendLifecyclePush(db, data, {
                    type: notice.type,
                    title: notice.title,
                    patientBody: notice.patientBody,
                    doctorBody: notice.doctorBody,
                    notificationId: notice.notificationId,
                    extra: notice.extra,
                });
                if (delivered) {
                    notices++;
                    await appendAppointmentEvent(db, doc.id, {
                        type: notice.event,
                        detail: notice.event === APPOINTMENT_EVENT_TYPES.graceEnding
                            ? "last call before the slot closes"
                            : "",
                    });
                } else {
                    await releaseLifecycleField(doc.ref, notice.claimField, now);
                }
            }
        } catch (error) {
            console.error(`[APPOINTMENT_LIFECYCLE] ${doc.id}:`, error);
        }
    }

    console.log(`[APPOINTMENT_LIFECYCLE] checked=${checked} closed=${closed} phases=${phases} `
        + `reminders=${reminders} notices=${notices} activated=${activated} alarms=${alarms}`);
    return null;
});

// -----------------------------------------------------------------------------
// GENERIC DISPATCHER.
//
// The app cannot send a push itself: doing so needs a Firebase Admin
// credential, and there is nowhere on a user's device to keep one — it would
// ship inside the APK and be public. (This app used to embed exactly such a
// key and post to the FCM HTTP v1 API from the client, so every push it sent
// was signed with a secret anyone could extract.)
//
// `NotificationDispatcher` in the app writes a request here instead and this
// function performs the send. Two things make that safe rather than just a
// relay:
//   • the recipient is a *user id*. It is resolved to a device token on this
//     side, so a token is never read by, or exposed to, the client.
//   • `type` is checked against an allow-list. A client can ask for one of a
//     fixed set of messages, not an arbitrary payload of its own wording.
//
// The four Firestore-triggered functions above (chat, call, password reset,
// payment proof) remain the senders for their own event types — they watch the
// documents the app already writes, so those types are intentionally absent
// from this dispatcher's allow-list and this function must never also fire for
// them.
// -----------------------------------------------------------------------------

const DISPATCHABLE_TYPES = new Set([
    "payment_proof_submitted",
    "payment_complaint",
    "complaint_reply",
    "payment_approved",
    "payment_rejected",
    "appointment_payment_submitted",
    "appointment_payment_approved",
    "appointment_payment_rejected",
    "new_appointment_request",
    "appointment_confirmed",
    "appointment_start",
    "appointment_reminder",
    "appointment_joined",
    "appointment_doctor_late",
    "appointment_patient_late",
    "appointment_grace_ending",
    "appointment_cancelled",
    "appointment_no_show",
    "booking_frozen",
    "report_shared",
]);

/** Whitelist of Android channels a client may address. Anything else falls back. */
const DISPATCHABLE_CHANNELS = new Set([
    "general_notifications",
    "chat_notifications_channel",
    "call_notifications_channel",
    "password_reset_notifications",
]);

/**
 * Old channel ids still queued by clients running a previous build. They are
 * rewritten to the current ids instead of falling back to `general`, so those
 * pushes keep their sound/importance.
 */
const CHANNEL_ALIASES = Object.freeze({
    chat_notifications: "chat_notifications_channel",
    call_notifications: "call_notifications_channel",
});

exports.dispatchNotification = onDocumentCreated("notification_outbox/{id}", async (event) => {
    const snap = event.data;
    if (!snap) return null;

    const request = snap.data();
    const id = event.params.id;
    const toUserId = request.toUserId;
    const type = request.type;

    try {
        if (!DISPATCHABLE_TYPES.has(type)) {
            console.error(`[DISPATCH] REJECTED id=${id} type=${type} (not in allow-list)`);
            await snap.ref.update({status: "rejected", error: "type not allowed"});
            return null;
        }
        if (!toUserId) {
            console.error(`[DISPATCH] REJECTED id=${id} missing toUserId`);
            await snap.ref.update({status: "rejected", error: "missing recipient"});
            return null;
        }

        const db = admin.firestore();

        // ── Server-side verification for state-dependent notifications ────────
        if (type === "payment_approved" || type === "payment_rejected") {
            const expectedStatus = type === "payment_approved" ? "approved" : "rejected";
            const patientDoc = await db.collection("telemedicine_patient").doc(toUserId).get();
            let currentStatus = patientDoc.exists ? (patientDoc.data().paymentStatus || "") : "";
            const paymentId = (request.data && (request.data.paymentId || request.data.requestId)) || "";
            if (currentStatus !== expectedStatus && paymentId) {
                const reactDoc = await db.collection("patient_reactivation_requests").doc(paymentId).get();
                if (reactDoc.exists) {
                    currentStatus = reactDoc.data().status || "";
                }
            }
            if (currentStatus !== expectedStatus) {
                console.warn(`[DISPATCH] REJECTED_STATE_MISMATCH id=${id} type=${type} currentStatus=${currentStatus} expected=${expectedStatus}`);
                await snap.ref.update({status: "rejected", error: `State mismatch: status is ${currentStatus}`});
                return null;
            }
        } else if (type === "appointment_payment_approved" || type === "appointment_payment_rejected") {
            const expectedStatus = type === "appointment_payment_approved" ? "approved" : "rejected";
            const paymentId = (request.data && request.data.paymentId) || "";
            if (paymentId) {
                const payDoc = await db.collection("appointment_payments").doc(paymentId).get();
                const currentStatus = payDoc.exists ? (payDoc.data().paymentStatus || "") : "";
                if (currentStatus && currentStatus !== expectedStatus) {
                    console.warn(`[DISPATCH] REJECTED_APPT_PAYMENT_MISMATCH id=${id} currentStatus=${currentStatus} expected=${expectedStatus}`);
                    await snap.ref.update({status: "rejected", error: `State mismatch: appointment payment status is ${currentStatus}`});
                    return null;
                }
            }
        } else if (type === "appointment_confirmed") {
            const appointmentId = (request.data && request.data.appointmentId) || "";
            if (appointmentId) {
                const apptDoc = await db.collection("appointments").doc(appointmentId).get();
                const currentStatus = apptDoc.exists ? (apptDoc.data().status || "") : "";
                if (currentStatus && currentStatus !== "confirmed" && currentStatus !== "appointment_confirmed") {
                    console.warn(`[DISPATCH] REJECTED_APPT_STATUS_MISMATCH id=${id} currentStatus=${currentStatus}`);
                    await snap.ref.update({status: "rejected", error: `State mismatch: appointment status is ${currentStatus}`});
                    return null;
                }
            }
        }

        const token = await findFcmToken(toUserId);
        if (!token) {
            // Not an error: the recipient has simply never registered a device.
            console.log(`[DISPATCH] NO_TOKEN id=${id} toUserId=${toUserId}`);
            await snap.ref.update({status: "skipped", error: "recipient has no token"});
            return null;
        }

        // Chat and call no longer reach this dispatcher (their Firestore
        // triggers own delivery), so every outbox request is a general
        // notification or the password-reset prompt.
        const requestedChannel = CHANNEL_ALIASES[request.channel] || request.channel;
        const channel = DISPATCHABLE_CHANNELS.has(requestedChannel)
            ? requestedChannel
            : "general_notifications";

        const data = {};
        for (const [key, value] of Object.entries(request.data || {})) {
            if (value === null || value === undefined) continue;
            data[key] = typeof value === "string" ? value : String(value);
        }
        data.schemaVersion = NOTIFICATION_SCHEMA_VERSION;
        data.type = type;
        data.click_action = "FLUTTER_NOTIFICATION_CLICK";
        data.sentAt = new Date().toISOString();
        data.timestamp = Date.now().toString();

        const title = String(request.title || "");
        const body = String(request.body || "");

        const androidNotification = {
            channel_id: channel,
            channelId: channel,
            icon: "ic_notification",
            sound: "default",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            clickAction: "FLUTTER_NOTIFICATION_CLICK",
            defaultSound: true,
            defaultVibrateTimings: true,
        };

        const message = {
            token: token,
            data: data,
            notification: {title: title, body: body},
            android: {
                priority: "high",
                ttl: "3600s",
                notification: androidNotification,
            },
            apns: {
                headers: {"apns-priority": "10"},
                payload: {
                    aps: {
                        alert: {title: title, body: body},
                        sound: "default",
                        badge: 1,
                        "content-available": 1,
                    },
                },
            },
        };

        const claimed = await claimNotificationEvent(notificationEventId("outbox", id), {
            type,
            requestId: id,
            recipientId: toUserId,
        });
        if (!claimed) {
            await snap.ref.update({status: "duplicate", sentAt: admin.firestore.FieldValue.serverTimestamp()});
            return null;
        }

        await admin.messaging().send(message);
        await snap.ref.update({status: "sent", sentAt: admin.firestore.FieldValue.serverTimestamp()});
        console.log(`[DISPATCH] SENT id=${id} type=${type} toUserId=${toUserId} channel=${channel}`);
    } catch (error) {
        console.error(`[DISPATCH] FAILED id=${id} type=${type}: `, error);
        if (isUnrecoverableTokenError(error) && toUserId && token) {
            try {
                await clearStaleFcmToken(toUserId, token);
            } catch (_) {}
        }
        try {
            await snap.ref.update({
                status: "failed",
                error: String(error && error.message ? error.message : error),
            });
        } catch (_) {
            // The request document is only a work record; losing the failure
            // note must not mask the original error.
        }
    }

    return null;
});

// ─────────────────────────────────────────────────────────────────────────────
// Patient FCM-OTP forgot-password (patient accounts only).
//
// Implemented as a separate module and merged into this file's exports so
// every function above stays byte-for-byte untouched. Nothing here is removed
// or renamed — `firebase deploy --only functions` adds the new callables
// alongside the existing ones:
//
//   requestPatientPasswordResetOtp (callable, asia-south1; alias: startPatientPasswordReset)
//   verifyPatientPasswordResetOtp  (callable, asia-south1)
//   resetPatientPasswordWithOtp    (callable, asia-south1; alias: resetPatientPassword)
//   sweepPasswordResetRecords      (schedule, every 6 hours)
//
// Secrets bound: OTP_PEPPER (Google Cloud Secret Manager).
// See patient_password_reset.js for full implementation.
// ─────────────────────────────────────────────────────────────────────────────
const patientPasswordReset = require("./patient_password_reset");
Object.assign(exports, patientPasswordReset);
const doctorPresence = require("./doctor_presence");
Object.assign(exports, doctorPresence);
const phoneVerification = require("./phone_verification");
Object.assign(exports, phoneVerification);
const doctorProfileHelpers = require("./doctor_profile_helpers");
exports.handleDoctorProfileUpdate = doctorProfileHelpers.handleDoctorProfileUpdate;
exports.sanitizeDoctorProfilePayload = doctorProfileHelpers.sanitizeDoctorProfilePayload;

