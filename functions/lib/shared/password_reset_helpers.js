/**
 * Pure helpers for the SendPK patient password-reset flow.
 *
 * This module must NEVER import firebase-admin / firebase-functions so it can
 * be unit-tested with plain `node --test` and so no secret is ever read at
 * module load time. Every function takes its inputs explicitly.
 */

const crypto = require("crypto");

// ─────────────────────────────────────────────────────────────────────────────
// Phone normalisation (Pakistan)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Normalises any common Pakistani mobile format to E.164 `+923XXXXXXXXX`.
 *
 * Accepted inputs (punctuation such as spaces / dashes is ignored):
 *   03XXXXXXXXX   (+92 | 92 | 0092 prefixes are expanded)
 *   923XXXXXXXXX
 *   00923XXXXXXXXX
 *   3XXXXXXXXX
 *
 * @param {*} input raw phone value from the client
 * @returns {string|null} `+923XXXXXXXXX` or null when the input is not a
 *          Pakistani mobile number.
 */
function normalizePkPhone(input) {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (trimmed.length === 0 || trimmed.length > 32) return null;
  // Strip everything except digits; remember whether a leading + was present.
  const digits = trimmed.replace(/\D/g, "");
  if (digits.length === 0 || digits.length > 15) return null;

  let national;
  if (digits.startsWith("0092")) {
    national = digits.slice(4);
  } else if (digits.startsWith("92") && digits.length >= 12) {
    national = digits.slice(2);
  } else if (digits.startsWith("0")) {
    national = digits.slice(1);
  } else {
    national = digits;
  }

  // National number must be 3XXXXXXXXX (10 digits, Pakistani mobile prefix).
  if (!/^3\d{9}$/.test(national)) return null;
  return `+92${national}`;
}

/**
 * Normalises any international or Pakistani phone number to standard E.164.
 *
 * Supported formats:
 *   - Pakistani numbers in any common format: `03001234567`, `+923001234567`, `923001234567`, `00923001234567`, `3001234567`
 *   - International E.164 numbers with leading plus: `+12025550123`, `+447911123456`
 *   - International numbers with 00 prefix: `0012025550123`, `00447911123456`
 *   - National number + explicit countryCode / dialCode (e.g. countryCode: "+1", input: "2025550123")
 *
 * @param {*} input Raw phone number string
 * @param {string} [defaultDialCode] Optional default country dialing code (e.g. "+92" or "92" or "+1")
 * @returns {string|null} E.164 format `+<country_code><subscriber_number>` or null if invalid.
 */
function normalizePhone(input, defaultDialCode) {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (trimmed.length === 0 || trimmed.length > 40) return null;

  // First, check if it's a Pakistani number in any standard format
  const pk = normalizePkPhone(trimmed);
  if (pk) return pk;

  let cleaned = trimmed.replace(/[\s\-\(\)\.]/g, "");

  // Convert 00 prefix to +
  if (cleaned.startsWith("00")) {
    cleaned = `+${cleaned.slice(2)}`;
  }

  if (cleaned.startsWith("+")) {
    const digits = cleaned.slice(1).replace(/\D/g, "");
    if (/^[1-9]\d{6,14}$/.test(digits)) {
      // If it starts with 92 and is a Pakistani mobile, verify PK format
      if (digits.startsWith("92")) {
        const pkCheck = normalizePkPhone(`+${digits}`);
        if (pkCheck) return pkCheck;
      }
      return `+${digits}`;
    }
    return null;
  }

  // If no leading plus, check defaultDialCode
  if (defaultDialCode && typeof defaultDialCode === "string") {
    const dialDigits = defaultDialCode.replace(/\D/g, "");
    let nationalDigits = cleaned.replace(/\D/g, "");
    if (dialDigits.length > 0 && nationalDigits.length > 0) {
      // Strip leading trunk zero if present (e.g. UK 07911... -> 7911...)
      if (nationalDigits.startsWith("0") && nationalDigits.length > 7) {
        nationalDigits = nationalDigits.slice(1);
      }
      // If nationalDigits already has the dialDigits prefixed (e.g. pasted without +)
      if (nationalDigits.startsWith(dialDigits) && nationalDigits.length > dialDigits.length + 5) {
        const candidate = `+${nationalDigits}`;
        if (/^\+[1-9]\d{6,14}$/.test(candidate)) return candidate;
      }
      const candidate = `+${dialDigits}${nationalDigits}`;
      if (/^\+[1-9]\d{6,14}$/.test(candidate)) {
        if (dialDigits === "92") {
          return normalizePkPhone(candidate);
        }
        return candidate;
      }
    }
  }

  // Fallback: check if raw digits without plus constitute a valid international number
  const onlyDigits = cleaned.replace(/\D/g, "");
  if (/^[1-9]\d{7,14}$/.test(onlyDigits)) {
    // If it's a Pakistani number starting with 923...
    if (onlyDigits.startsWith("923") && onlyDigits.length === 12) {
      return `+${onlyDigits}`;
    }
    // Only infer international format if at least 10 digits
    if (onlyDigits.length >= 10) {
      return `+${onlyDigits}`;
    }
  }

  return null;
}

/**
 * The lookup variants stored across historical patient documents.
 * For Pakistani accounts: `03XXXXXXXXX`, `+923XXXXXXXXX`, `923XXXXXXXXX`, `3XXXXXXXXX`.
 * For International accounts: `+<country><national>`, `<country><national>`, `00<country><national>`, etc.
 *
 * @param {string} phoneE164 normalised E.164 phone number
 * @returns {string[]} distinct values to match against `phoneNumber`
 */
function phoneLookupVariants(phoneE164) {
  if (typeof phoneE164 !== "string") return [];
  const normalized = normalizePhone(phoneE164) || phoneE164.trim();

  if (normalized.startsWith("+92")) {
    const national = normalized.replace(/^\+92/, ""); // 3XXXXXXXXX
    const variants = [
      `0${national}`, // 03XXXXXXXXX — what sign-up stores
      normalized, // +923XXXXXXXXX
      `92${national}`, // 923XXXXXXXXX
      national, // 3XXXXXXXXX
    ];
    return [...new Set(variants)];
  }

  // Non-PK International numbers
  const digits = normalized.replace(/^\+/, "").replace(/\D/g, "");
  const variants = [
    normalized, // +12025550123
    digits, // 12025550123
    `00${digits}`, // 0012025550123
  ];

  // Domestic trunk variants for common formats (e.g. UK +44, UAE +971, etc.)
  if (normalized.startsWith("+44") && digits.length >= 11) {
    variants.push(`0${digits.slice(2)}`);
  } else if (normalized.startsWith("+971") && digits.length >= 11) {
    variants.push(`0${digits.slice(3)}`);
  }

  return [...new Set(variants)];
}

/**
 * The number format the SendPK API expects: `923XXXXXXXXX` (no `+`).
 * @param {string} phoneE164
 */
function sendpkMobile(phoneE164) {
  return phoneE164.replace(/^\+/, "");
}

// ─────────────────────────────────────────────────────────────────────────────
// Cryptographic helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Cryptographically secure 6-digit OTP as a zero-padded string. */
function randomOtp() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, "0");
}

/** Cryptographically secure URL-safe token (32 bytes → 43 chars). */
function randomToken() {
  return crypto.randomBytes(32).toString("base64url");
}

/** HMAC-SHA256 hex digest. Used to hash OTPs / tokens / doc keys. */
function hmacHex(pepper, data) {
  return crypto.createHmac("sha256", pepper).update(data, "utf8").digest("hex");
}

/** SHA-256 hex digest (non-keyed; used for opaque rate-limit keys). */
function sha256Hex(data) {
  return crypto.createHash("sha256").update(data, "utf8").digest("hex");
}

/**
 * Constant-time comparison of two hex digests. Returns false (never throws)
 * when the inputs are not equal-length hex strings.
 */
function timingSafeEqualHex(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length === 0 || a.length !== b.length) return false;
  if (!/^[0-9a-f]+$/i.test(a) || !/^[0-9a-f]+$/i.test(b)) return false;
  try {
    return crypto.timingSafeEqual(Buffer.from(a, "hex"), Buffer.from(b, "hex"));
  } catch (_) {
    return false;
  }
}

/**
 * The document key for a phone number: keyed hash so the raw number never
 * appears in a document id (or in any console listing of the collection).
 */
function phoneKey(pepper, phoneE164) {
  return hmacHex(pepper, `phone:${phoneE164}`);
}

/** The document key for a reset token: only the hash is ever stored. */
function resetTokenKey(pepper, resetToken) {
  return hmacHex(pepper, `reset:${resetToken}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// OTP / password validation
// ─────────────────────────────────────────────────────────────────────────────

/** True when the value is exactly six digits. */
function isValidOtpFormat(otp) {
  return typeof otp === "string" && /^\d{6}$/.test(otp);
}

/**
 * Password policy for the reset flow. Mirrors (and tightens) the sign-up
 * rules: 8–64 characters after trimming, at least one letter and one digit.
 *
 * @returns {{ok: boolean, value?: string, message?: string}}
 */
function validateNewPassword(rawPassword) {
  if (typeof rawPassword !== "string") {
    return {ok: false, message: "Password is required"};
  }
  const value = rawPassword.trim();
  if (value.length === 0) {
    return {ok: false, message: "Password is required"};
  }
  if (value.length < 8) {
    return {ok: false, message: "Password must be at least 8 characters"};
  }
  if (value.length > 64) {
    return {ok: false, message: "Password must be at most 64 characters"};
  }
  if (!/[A-Za-z]/.test(value)) {
    return {ok: false, message: "Password must contain at least one letter"};
  }
  if (!/\d/.test(value)) {
    return {ok: false, message: "Password must contain at least one number"};
  }
  if (/^\s+$/.test(value)) {
    return {ok: false, message: "Password cannot be only spaces"};
  }
  return {ok: true, value};
}

// ─────────────────────────────────────────────────────────────────────────────
// SendPK request building / response parsing
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Builds the `message` JSON payload for an approved Fixed-SMS/OTP template.
 *
 * `template` is the entry returned by `fetch_all_fixed_templates.php`
 * (`{id, name, message, variables: [...]}`) or null when discovery failed —
 * in which case the common `{"otp": …, "name": …}` shape is assumed.
 *
 * Variable matching is deliberately fuzzy because each account's approved
 * template wording (and therefore its placeholder names) is unique.
 *
 * @param {{variables?: string[]}|null} template
 * @param {{otp: string, name?: string, phoneE164?: string, minutes?: number}} values
 */
function buildTemplateVariables(template, values) {
  const otp = values.otp || "";
  const name = values.name || "";
  const minutes = String(values.minutes == null ? 5 : values.minutes);
  const phone = values.phoneE164 || "";
  const maskedPhone =
    phone.length >= 4 ? `****${phone.slice(-4)}` : phone;

  if (!template || !Array.isArray(template.variables) || template.variables.length === 0) {
    // Template unknown → send the two most common OTP placeholder names.
    return {otp, name};
  }

  const vars = {};
  for (const raw of template.variables) {
    const variable = String(raw).toLowerCase();
    if (/otp|code|pin|passcode|token/.test(variable)) {
      vars[raw] = otp;
    } else if (/name|user|customer|receiver|recipient|member|account/.test(variable)) {
      vars[raw] = name;
    } else if (/minute|min\b|expir|valid|duration|time|ttl/.test(variable)) {
      vars[raw] = minutes;
    } else if (/phone|mobile|number/.test(variable)) {
      vars[raw] = maskedPhone;
    } else {
      // Unknown placeholder: empty string keeps the message sendable without
      // inventing content the template owner never approved.
      vars[raw] = "";
    }
  }
  if (!("otp" in vars) && Object.keys(vars).length === 0) {
    vars.otp = otp;
  }
  return vars;
}

/**
 * Parses the plain-text (default) SendPK `sms.php` response.
 *
 * Success:  `OK` or `OK ID:29346`
 * Failure:  a numeric status code (`1`, `2`, `4`, `5`, `6`, `7`, `8`, `9`, `12`)
 *
 * @returns {{ok: boolean, id?: string, code?: string}}
 */
function parseSendPkResponse(text) {
  if (typeof text !== "string") return {ok: false, code: "unknown"};
  const trimmed = text.trim();
  if (trimmed.length === 0) return {ok: false, code: "empty"};
  if (/^OK\b/i.test(trimmed)) {
    const idMatch = trimmed.match(/ID:\s*(\d+)/i);
    return idMatch ? {ok: true, id: idMatch[1]} : {ok: true};
  }
  // Some configurations answer JSON — accept {"status":"OK"…} too.
  if (trimmed.startsWith("{")) {
    try {
      const parsed = JSON.parse(trimmed);
      const status = String(parsed.status ?? parsed.result ?? "").toUpperCase();
      if (status === "OK" || status === "SUCCESS" || parsed.success === true || parsed.success === "true") {
        const id = parsed.id ?? parsed.smsid ?? parsed.message_id;
        return id != null ? {ok: true, id: String(id)} : {ok: true};
      }
      const code = parsed.code ?? parsed.error_code ?? parsed.status ?? "";
      return {ok: false, code: String(code)};
    } catch (_) {
      // fall through to code extraction
    }
  }
  const codeMatch = trimmed.match(/\b(\d{1,3})\b/);
  return {ok: false, code: codeMatch ? codeMatch[1] : "unknown"};
}

// ─────────────────────────────────────────────────────────────────────────────
// Rate-limit arithmetic (pure — persistence lives in the callable module)
// ─────────────────────────────────────────────────────────────────────────────

const COOLDOWN_MS = 60 * 1000;
const HOURLY_WINDOW_MS = 60 * 60 * 1000;
const MAX_SENDS_PER_HOUR = 5;

/**
 * Evaluates resend eligibility for a per-phone rate-limit record.
 *
 * The record shape is:
 *   {lastSmsAtMs: number, windowStartMs: number, sendsInWindow: number}
 *
 * Deliberately evaluated for EVERY `start` request — registered number or not
 * — so the response can never be used to probe which numbers have accounts.
 *
 * @returns {{allowed: boolean, resendInSeconds: number, next: object}} `next`
 *          is the record to persist when `allowed` is true.
 */
function evaluateSendLimit(record, nowMs) {
  const lastSmsAtMs = Number(record && record.lastSmsAtMs) || 0;
  const windowStartMs = Number(record && record.windowStartMs) || 0;
  let sendsInWindow = Number(record && record.sendsInWindow) || 0;

  if (lastSmsAtMs > 0 && nowMs - lastSmsAtMs < COOLDOWN_MS) {
    return {
      allowed: false,
      resendInSeconds: Math.ceil((lastSmsAtMs + COOLDOWN_MS - nowMs) / 1000),
      next: {lastSmsAtMs, windowStartMs, sendsInWindow},
    };
  }

  const inWindow = windowStartMs > 0 && nowMs - windowStartMs < HOURLY_WINDOW_MS;
  if (inWindow && sendsInWindow >= MAX_SENDS_PER_HOUR) {
    return {
      allowed: false,
      resendInSeconds: Math.ceil((windowStartMs + HOURLY_WINDOW_MS - nowMs) / 1000),
      next: {lastSmsAtMs, windowStartMs, sendsInWindow},
    };
  }

  return {
    allowed: true,
    resendInSeconds: Math.ceil(COOLDOWN_MS / 1000),
    next: {
      lastSmsAtMs: nowMs,
      windowStartMs: inWindow ? windowStartMs : nowMs,
      sendsInWindow: inWindow ? sendsInWindow + 1 : 1,
    },
  };
}

/**
 * Per-IP start limit (shared NATs need headroom, so this is generous and
 * coarse — it only exists to stop scripted enumeration floods).
 */
const IP_MAX_STARTS_PER_HOUR = 30;

function evaluateIpLimit(record, nowMs) {
  const windowStartMs = Number(record && record.windowStartMs) || 0;
  let startsInWindow = Number(record && record.startsInWindow) || 0;
  const inWindow = windowStartMs > 0 && nowMs - windowStartMs < HOURLY_WINDOW_MS;
  if (inWindow && startsInWindow >= IP_MAX_STARTS_PER_HOUR) {
    return {
      allowed: false,
      resendInSeconds: Math.ceil((windowStartMs + HOURLY_WINDOW_MS - nowMs) / 1000),
      next: {windowStartMs, startsInWindow},
    };
  }
  return {
    allowed: true,
    resendInSeconds: Math.ceil(COOLDOWN_MS / 1000),
    next: {
      windowStartMs: inWindow ? windowStartMs : nowMs,
      startsInWindow: inWindow ? startsInWindow + 1 : 1,
    },
  };
}

module.exports = {
  normalizePkPhone,
  normalizePhone,
  phoneLookupVariants,
  sendpkMobile,
  randomOtp,
  randomToken,
  hmacHex,
  sha256Hex,
  timingSafeEqualHex,
  phoneKey,
  resetTokenKey,
  isValidOtpFormat,
  validateNewPassword,
  buildTemplateVariables,
  parseSendPkResponse,
  evaluateSendLimit,
  evaluateIpLimit,
  COOLDOWN_MS,
  HOURLY_WINDOW_MS,
  MAX_SENDS_PER_HOUR,
  IP_MAX_STARTS_PER_HOUR,
};
