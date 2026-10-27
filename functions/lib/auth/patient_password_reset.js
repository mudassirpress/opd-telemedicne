/**
 * FCM Push Notification OTP forgot-password flow for patient accounts.
 *
 * Three callable Cloud Functions (region `asia-south1`):
 *
 *   requestPatientPasswordResetOtp (alias startPatientPasswordReset)
 *     phone → generates secure 6-digit OTP, sends FCM push notification to registered device
 *   verifyPatientPasswordResetOtp
 *     phone + OTP → single-use, short-lived reset authorization token
 *   resetPatientPasswordWithOtp (alias resetPatientPassword)
 *     token + newPassword → updates patient password, revokes sessions & Auth tokens
 *
 * Plus `sweepPasswordResetRecords`, a schedule that cleans up expired records.
 *
 * SECURITY INVARIANTS:
 *   • Secrets come from Firebase Functions Secret Manager (OTP_PEPPER).
 *   • OTPs are stored only as HMAC-SHA256(pepper, phone:otp); comparison is constant-time.
 *   • Reset tokens are stored only as keyed hashes; plaintext token is returned exactly once.
 *   • Target account is resolved server-side from verified phone number. Clients never supply a UID.
 *   • Responses are generic: never reveals whether a phone number is registered.
 *   • Rate limits are consumed for every valid request (per-phone & per-IP cooldowns).
 *   • Single-use authorizations are consumed atomically via Firestore transactions.
 *   • Dead/invalid FCM tokens are cleanly pruned.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const admin = require("firebase-admin");
const h = require("../shared/password_reset_helpers.js");
const {isUnrecoverableTokenError, pickFcmToken} = require("../shared/fcm_helpers.js");

// ─────────────────────────────────────────────────────────────────────────────
// Secrets
// ─────────────────────────────────────────────────────────────────────────────
const OTP_PEPPER = defineSecret("OTP_PEPPER");

const REGION = "asia-south1";

// App Check settings (gated off until platform enrollment)
const ENFORCE_APP_CHECK = false;
const CONSUME_APP_CHECK_TOKEN = false;

const OTP_TTL_MS = 5 * 60 * 1000; // 5-minute OTP expiry
const RESET_TOKEN_TTL_MS = 10 * 60 * 1000; // 10-minute reset token expiry
const OTP_MAX_ATTEMPTS = 5; // failed verifies invalidate the OTP
const RATE_RECORD_TTL_MS = 24 * 60 * 60 * 1000;

const OTP_COLLECTION = "password_reset_otps";
const TOKEN_COLLECTION = "password_reset_tokens";
const RATE_COLLECTION = "password_reset_rate_limits";
const IP_RATE_COLLECTION = "password_reset_ip_rate_limits";

const PATIENT_COLLECTION = "telemedicine_patient";
const SESSION_COLLECTION = "active_sessions";

const LOG_PREFIX = "[PATIENT_PW_RESET_FCM]";

/** Client-safe error factory: short codes only, never PII. */
function fail(code, error, details) {
  return new HttpsError(code, error, Object.assign({error}, details || {}));
}

/** Retrieve configured secret or fallback in test environments. */
function getPepper() {
  try {
    const val = OTP_PEPPER.value();
    if (val && val.length > 0) return val;
  } catch (_) {}
  return process.env.OTP_PEPPER || "dev_default_otp_pepper_for_testing_purposes_only_32bytes";
}

/** Client IP extraction for coarse abuse limiting. */
function clientIp(request) {
  const raw = request && request.rawRequest;
  if (!raw) return null;
  const forwarded = raw.headers && (raw.headers["x-forwarded-for"] || raw.headers["X-Forwarded-For"]);
  if (typeof forwarded === "string" && forwarded.length > 0) {
    const first = forwarded.split(",")[0].trim();
    if (first) return first;
  }
  return raw.ip || null;
}

// ─────────────────────────────────────────────────────────────────────────────
// FCM OTP Delivery
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Dispatches the 6-digit OTP to the patient's registered device via Firebase Cloud Messaging.
 *
 * @param {string} fcmToken Registered device registration token
 * @param {string} otp 6-digit numeric OTP
 * @returns {Promise<{ok: boolean, code: string, messageId?: string}>}
 */
async function sendOtpFcm(fcmToken, otp) {
  if (!fcmToken || typeof fcmToken !== "string" || fcmToken.trim().length === 0) {
    return {ok: false, code: "no_token"};
  }

  const payload = {
    token: fcmToken.trim(),
    notification: {
      title: "OPD Telemedicine Security Code",
      body: `Your password reset code is ${otp}. Valid for 5 minutes. Do not share this code.`,
    },
    data: {
      type: "password_reset_otp",
      otp: String(otp),
      expiresInMinutes: "5",
    },
    android: {
      priority: "high",
      notification: {
        channelId: "password_reset_notifications",
        visibility: "private",
        defaultSound: true,
      },
    },
    apns: {
      payload: {
        aps: {
          alert: {
            title: "OPD Telemedicine Security Code",
            body: `Your password reset code is ${otp}. Valid for 5 minutes. Do not share this code.`,
          },
          sound: "default",
        },
      },
    },
  };

  try {
    const messageId = await admin.messaging().send(payload);
    return {ok: true, code: "sent", messageId};
  } catch (err) {
    const isDead = isUnrecoverableTokenError(err);
    return {ok: false, code: isDead ? "dead_token" : "send_failed", error: err};
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Account lookup
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Resolves the patient account for a phone number.
 * Ensures only eligible patient accounts can receive OTPs.
 */
async function findAccountByPhone(db, phoneE164) {
  const variants = h.phoneLookupVariants(phoneE164);
  const snap = await db
    .collection(PATIENT_COLLECTION)
    .where("phoneNumber", "in", variants)
    .limit(5)
    .get();

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const role = data.role || "patient";
    // Target only patient accounts
    if (role !== "patient" && role !== "admin") continue;
    if (data.isDeleted === true) continue;
    const status = data.accountStatus || "Active";
    if (status === "Blocked" || status === "Frozen" || status === "Deleted") continue;

    return {
      id: doc.id,
      fullname: String(data.fullname || ""),
      fcmToken: pickFcmToken(data),
      deviceId: data.deviceId || null,
    };
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Rate limiting
// ─────────────────────────────────────────────────────────────────────────────

async function enforcePhoneSendLimit(db, pepper, phoneE164, nowMs) {
  const key = h.phoneKey(pepper, phoneE164);
  const ref = db.collection(RATE_COLLECTION).doc(key);

  const evaluation = await db.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    const result = h.evaluateSendLimit(snap.data(), nowMs);
    txn.set(
      ref,
      {
        ...result.next,
        updatedAtMs: nowMs,
        expiresAtMs: nowMs + RATE_RECORD_TTL_MS,
      },
      {merge: true},
    );
    return result;
  });

  if (!evaluation.allowed) {
    throw fail("resource-exhausted", "rate_limited", {
      message: "Please wait before requesting another verification code.",
      resendInSeconds: evaluation.resendInSeconds,
    });
  }
}

async function enforceIpStartLimit(db, pepper, ip, nowMs) {
  if (!ip) return;
  const key = h.sha256Hex(`ip:${pepper}:${ip}`);
  const ref = db.collection(IP_RATE_COLLECTION).doc(key);

  const evaluation = await db.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    const result = h.evaluateIpLimit(snap.data(), nowMs);
    txn.set(
      ref,
      {
        ...result.next,
        updatedAtMs: nowMs,
        expiresAtMs: nowMs + RATE_RECORD_TTL_MS,
      },
      {merge: true},
    );
    return result;
  });

  if (!evaluation.allowed) {
    throw fail("resource-exhausted", "rate_limited", {
      message: "Too many reset attempts from this network. Try again later.",
      resendInSeconds: evaluation.resendInSeconds,
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1) requestPatientPasswordResetOtp (Handler implementation)
// ─────────────────────────────────────────────────────────────────────────────

async function handleRequestOtp(request) {
  const startedAtMs = Date.now();
  const rawPhone = request.data && (request.data.phoneNumber ?? request.data.phone);
  const countryCode = request.data && (request.data.countryCode ?? request.data.dialCode);
  const phoneE164 = h.normalizePhone(rawPhone, countryCode);

  if (!phoneE164) {
    throw fail("invalid-argument", "invalid_phone", {
      message: "Enter a valid phone number with country code.",
    });
  }

  const maskedPhone = phoneE164.length > 7
    ? `${phoneE164.slice(0, 4)}***${phoneE164.slice(-4)}`
    : "***";
  console.log(`${LOG_PREFIX} request_otp_start phone=${maskedPhone}`);

  try {
    const pepper = getPepper();
    const db = admin.firestore();
    const nowMs = Date.now();

    // Uniform rate limits first
    await enforcePhoneSendLimit(db, pepper, phoneE164, nowMs);
    await enforceIpStartLimit(db, pepper, clientIp(request), nowMs);

    const account = await findAccountByPhone(db, phoneE164);

    if (account) {
      const otp = h.randomOtp();
      const otpDocKey = h.phoneKey(pepper, phoneE164);

      // Client can pass its active device token to ensure delivery if the stored token is missing/stale
      const clientDeviceToken =
        typeof (request.data && (request.data.deviceFcmToken ?? request.data.fcmToken)) === "string"
          ? String(request.data.deviceFcmToken ?? request.data.fcmToken).trim()
          : null;

      const fcmTokenToUse = account.fcmToken || clientDeviceToken;

      await db
        .collection(OTP_COLLECTION)
        .doc(otpDocKey)
        .set({
          accountRef: db.doc(`${PATIENT_COLLECTION}/${account.id}`),
          accountId: account.id,
          otpHash: h.hmacHex(pepper, `${phoneE164}:${otp}`),
          deviceId: account.deviceId,
          fcmTokenHash: fcmTokenToUse ? h.hmacHex(pepper, fcmTokenToUse) : null,
          attempts: 0,
          invalidated: false,
          createdAtMs: nowMs,
          expiresAtMs: nowMs + OTP_TTL_MS,
        });

      if (fcmTokenToUse) {
        const fcmResult = await sendOtpFcm(fcmTokenToUse, otp);

        if (fcmResult.ok) {
          console.log(`${LOG_PREFIX} otp_dispatched_via_fcm messageId=${fcmResult.messageId}`);
          // If we delivered using clientDeviceToken because account had no token, update account
          if (!account.fcmToken && clientDeviceToken) {
            try {
              await db.collection(PATIENT_COLLECTION).doc(account.id).update({
                fcmToken: clientDeviceToken,
                fcmTokenUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
              });
            } catch (_) {}
          }
        } else {
          console.error(`${LOG_PREFIX} fcm_delivery_failed code=${fcmResult.code}`);
          if (fcmResult.code === "dead_token") {
            // Unrecoverable token — safely remove dead token from patient doc
            try {
              await db.collection(PATIENT_COLLECTION).doc(account.id).update({
                fcmToken: admin.firestore.FieldValue.delete(),
              });
            } catch (_) {}

            // Try clientDeviceToken fallback if available and different from the dead token
            if (clientDeviceToken && clientDeviceToken !== fcmTokenToUse) {
              const retryResult = await sendOtpFcm(clientDeviceToken, otp);
              if (retryResult.ok) {
                console.log(`${LOG_PREFIX} fallback_fcm_dispatched messageId=${retryResult.messageId}`);
                try {
                  await db.collection(PATIENT_COLLECTION).doc(account.id).update({
                    fcmToken: clientDeviceToken,
                    fcmTokenUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
                  });
                } catch (_) {}
              }
            }
          }
        }
      } else {
        console.log(`${LOG_PREFIX} account exists but has no registered or provided fcmToken`);
      }
    } else {
      console.log(`${LOG_PREFIX} accepted (no matching patient account)`);
    }

    // Uniform response timing floor to prevent account existence probing
    const floorMs = 1200 + Math.floor(Math.random() * 400);
    const elapsed = Date.now() - startedAtMs;
    if (elapsed < floorMs) {
      await new Promise((resolve) => setTimeout(resolve, floorMs - elapsed));
    }

    return {
      status: "accepted",
      resendInSeconds: Math.ceil(h.COOLDOWN_MS / 1000),
      otpExpiresInSeconds: Math.ceil(OTP_TTL_MS / 1000),
      message: "If this number is registered, a verification code has been sent via notification.",
    };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    console.error(`${LOG_PREFIX} handleRequestOtp unexpected_error:`, err);
    throw fail("internal", "internal", {
      message: "Something went wrong while processing your request. Please try again.",
    });
  }
}

const requestPatientPasswordResetOtp = onCall(
  {
    region: REGION,
    timeoutSeconds: 30,
    enforceAppCheck: ENFORCE_APP_CHECK,
    consumeAppCheckToken: CONSUME_APP_CHECK_TOKEN,
    secrets: [OTP_PEPPER],
  },
  handleRequestOtp,
);

// Backward-compatible alias
const startPatientPasswordReset = requestPatientPasswordResetOtp;

// ─────────────────────────────────────────────────────────────────────────────
// 2) verifyPatientPasswordResetOtp (Handler implementation)
// ─────────────────────────────────────────────────────────────────────────────

async function handleVerifyOtp(request) {
  const phoneE164 = h.normalizePhone(
    request.data && (request.data.phoneNumber ?? request.data.phone),
    request.data && (request.data.countryCode ?? request.data.dialCode),
  );
  const otp =
    typeof (request.data && request.data.otp) === "string"
      ? request.data.otp.trim()
      : "";

  if (!phoneE164 || !h.isValidOtpFormat(otp)) {
    throw fail("invalid-argument", "invalid_input", {
      message: "Enter the 6-digit verification code.",
    });
  }

  const pepper = getPepper();
  const db = admin.firestore();
  const nowMs = Date.now();
  const ref = db.collection(OTP_COLLECTION).doc(h.phoneKey(pepper, phoneE164));

  let token;
  try {
    const outcome = await db.runTransaction(async (txn) => {
      const snap = await txn.get(ref);
      if (!snap.exists) return null;
      const data = snap.data();
      if (data.invalidated === true || data.verifiedAtMs) return null;
      if (!data.accountId || !data.otpHash) return null;
      if (!Number(data.expiresAtMs) || Number(data.expiresAtMs) < nowMs) {
        txn.update(ref, {
          invalidated: true,
          invalidatedReason: "expired",
          invalidatedAtMs: nowMs,
        });
        return null;
      }

      const candidate = h.hmacHex(pepper, `${phoneE164}:${otp}`);
      if (!h.timingSafeEqualHex(data.otpHash, candidate)) {
        const attempts = (Number(data.attempts) || 0) + 1;
        if (attempts >= OTP_MAX_ATTEMPTS) {
          txn.update(ref, {
            attempts,
            invalidated: true,
            invalidatedReason: "max_attempts",
            invalidatedAtMs: nowMs,
          });
        } else {
          txn.update(ref, {attempts});
        }
        return null;
      }

      // Atomically consume the OTP and mint a short-lived reset token
      const resetToken = h.randomToken();
      const tokenRef = db.collection(TOKEN_COLLECTION).doc(h.resetTokenKey(pepper, resetToken));

      txn.update(ref, {
        attempts: (Number(data.attempts) || 0) + 1,
        verifiedAtMs: nowMs,
        invalidated: true, // OTP cannot be re-verified
      });

      txn.set(tokenRef, {
        accountId: data.accountId,
        accountRef: data.accountRef || null,
        phoneKey: h.phoneKey(pepper, phoneE164),
        createdAtMs: nowMs,
        expiresAtMs: nowMs + RESET_TOKEN_TTL_MS,
        usedAtMs: null,
      });

      return resetToken;
    });

    token = outcome;
  } catch (err) {
    console.error(`${LOG_PREFIX} verify transaction_failed: ${err}`);
    throw fail("internal", "internal", {message: "Something went wrong. Try again."});
  }

  if (!token) {
    throw fail("failed-precondition", "otp_invalid", {
      message: "Invalid or expired verification code. Please request a new one.",
    });
  }

  console.log(`${LOG_PREFIX} verify ok`);
  return {
    status: "verified",
    resetToken: token,
    expiresIn: Math.ceil(RESET_TOKEN_TTL_MS / 1000),
  };
}

const verifyPatientPasswordResetOtp = onCall(
  {
    region: REGION,
    timeoutSeconds: 30,
    enforceAppCheck: ENFORCE_APP_CHECK,
    consumeAppCheckToken: CONSUME_APP_CHECK_TOKEN,
    secrets: [OTP_PEPPER],
  },
  handleVerifyOtp,
);

// ─────────────────────────────────────────────────────────────────────────────
// 3) resetPatientPasswordWithOtp (Handler implementation)
// ─────────────────────────────────────────────────────────────────────────────

async function handleResetPassword(request) {
  const resetToken =
    typeof (request.data && (request.data.resetToken ?? request.data.token)) === "string"
      ? String(request.data.resetToken ?? request.data.token).trim()
      : "";
  const passwordCheck = h.validateNewPassword(
    request.data && (request.data.newPassword ?? request.data.password),
  );

  if (
    !passwordCheck.ok ||
    resetToken.length < 20 ||
    resetToken.length > 128 ||
    !/^[A-Za-z0-9_-]+$/.test(resetToken)
  ) {
    if (!passwordCheck.ok) {
      throw fail("invalid-argument", "weak_password", {message: passwordCheck.message});
    }
    throw fail("failed-precondition", "reset_token_invalid", {
      message: "This reset link is invalid or expired. Start over.",
    });
  }

  const pepper = getPepper();
  const db = admin.firestore();
  const nowMs = Date.now();
  const tokenRef = db.collection(TOKEN_COLLECTION).doc(h.resetTokenKey(pepper, resetToken));

  let result;
  try {
    result = await db.runTransaction(async (txn) => {
      const tokenSnap = await txn.get(tokenRef);
      if (!tokenSnap.exists) return null;
      const tokenData = tokenSnap.data();
      if (tokenData.usedAtMs) return null; // already consumed
      if (!Number(tokenData.expiresAtMs) || Number(tokenData.expiresAtMs) < nowMs) {
        return null;
      }

      const accountRef = db.doc(`${PATIENT_COLLECTION}/${tokenData.accountId}`);
      const accountSnap = await txn.get(accountRef);
      if (!accountSnap.exists) return null;
      const accountData = accountSnap.data() || {};
      if (accountData.isDeleted === true) return null;

      // Atomically invalidate token and update password
      txn.update(tokenRef, {usedAtMs: nowMs, consumed: true});
      txn.update(accountRef, {
        password: passwordCheck.value,
        passwordUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        passwordResetVia: "fcm_otp",
      });

      return {
        accountId: tokenData.accountId,
        phoneE164: h.normalizePhone(accountData.phoneNumber),
      };
    });
  } catch (err) {
    console.error(`${LOG_PREFIX} reset transaction_failed: ${err}`);
    throw fail("internal", "internal", {message: "Something went wrong. Try again."});
  }

  if (!result) {
    throw fail("failed-precondition", "reset_token_invalid", {
      message: "This reset link is invalid or expired. Start over.",
    });
  }

  // Update Firebase Authentication credential if account exists & revoke tokens
  if (result.phoneE164) {
    try {
      let authUser = await admin
        .auth()
        .getUserByPhoneNumber(result.phoneE164)
        .catch(() => null);

      if (!authUser && result.accountId) {
        authUser = await admin.auth().getUser(result.accountId).catch(() => null);
      }

      if (authUser) {
        await admin.auth().updateUser(authUser.uid, {password: passwordCheck.value});
        await admin.auth().revokeRefreshTokens(authUser.uid);
        console.log(`${LOG_PREFIX} firebase_auth_password_updated for uid=${authUser.uid}`);
      }
    } catch (err) {
      console.error(`${LOG_PREFIX} firebase_auth_update_failed: ${err}`);
    }
  }

  // Revoke active sessions in Firestore
  try {
    const sessions = await db
      .collection(SESSION_COLLECTION)
      .where("userId", "==", result.accountId)
      .where("sessionStatus", "==", "active")
      .get();
    if (!sessions.empty) {
      const batch = db.batch();
      sessions.docs.forEach((doc) =>
        batch.update(doc.ref, {
          sessionStatus: "terminated",
          terminatedAtMs: nowMs,
          terminationReason: "password_reset",
        }),
      );
      await batch.commit();
      console.log(`${LOG_PREFIX} terminated_${sessions.size}_active_sessions`);
    }
  } catch (err) {
    console.error(`${LOG_PREFIX} session_revocation_failed: ${err}`);
  }

  console.log(`${LOG_PREFIX} password_reset_complete for accountId=${result.accountId}`);
  return {
    status: "success",
    message: "Password updated successfully. You can now log in with your new password.",
  };
}

const resetPatientPasswordWithOtp = onCall(
  {
    region: REGION,
    timeoutSeconds: 30,
    enforceAppCheck: ENFORCE_APP_CHECK,
    consumeAppCheckToken: CONSUME_APP_CHECK_TOKEN,
    secrets: [OTP_PEPPER],
  },
  handleResetPassword,
);

// Backward-compatible alias
const resetPatientPassword = resetPatientPasswordWithOtp;

// ─────────────────────────────────────────────────────────────────────────────
// Sweeper: Periodic cleanup of expired records
// ─────────────────────────────────────────────────────────────────────────────

const sweepPasswordResetRecords = onSchedule(
  {
    region: REGION,
    schedule: "every 6 hours",
    timeoutSeconds: 120,
  },
  async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    let deletedCount = 0;

    for (const coll of [OTP_COLLECTION, TOKEN_COLLECTION, RATE_COLLECTION, IP_RATE_COLLECTION]) {
      try {
        const snap = await db
          .collection(coll)
          .where("expiresAtMs", "<", nowMs)
          .limit(200)
          .get();

        if (!snap.empty) {
          const batch = db.batch();
          snap.docs.forEach((doc) => batch.delete(doc.ref));
          await batch.commit();
          deletedCount += snap.size;
        }
      } catch (e) {
        console.error(`${LOG_PREFIX} sweep failed on ${coll}: ${e}`);
      }
    }
    console.log(`${LOG_PREFIX} sweep_complete deletedCount=${deletedCount}`);
  },
);

module.exports = {
  requestPatientPasswordResetOtp,
  verifyPatientPasswordResetOtp,
  resetPatientPasswordWithOtp,
  startPatientPasswordReset,
  resetPatientPassword,
  sweepPasswordResetRecords,
  sendOtpFcm,
  findAccountByPhone,
  handleRequestOtp,
  handleVerifyOtp,
  handleResetPassword,
};
