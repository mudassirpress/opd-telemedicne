/**
 * E.164 Phone Normalization and Validation Helpers.
 *
 * Implements strict E.164 normalization, international format detection,
 * database lookup variants for backward compatibility, and validation.
 *
 * This module is pure (no external dependencies) and unit-tested via `node --test`.
 */

const {
  normalizePkPhone,
  normalizePhone: baseNormalizePhone,
  phoneLookupVariants: basePhoneLookupVariants,
} = require("./password_reset_helpers.js");

/**
 * Validates whether a given string is in strict E.164 format:
 * `+` followed by country code and subscriber number (8 to 15 digits total, no leading zero after +).
 *
 * @param {string} phone
 * @returns {boolean}
 */
function isValidE164(phone) {
  if (typeof phone !== "string") return false;
  return /^\+[1-9]\d{7,14}$/.test(phone.trim());
}

/**
 * Normalizes any domestic or international phone number to canonical E.164 format.
 *
 * Examples:
 *   "03001234567"       -> "+923001234567"
 *   "0300-1234567"      -> "+923001234567"
 *   "923001234567"      -> "+923001234567"
 *   "+92 300 1234567"   -> "+923001234567"
 *   "00923001234567"    -> "+923001234567"
 *   "+1 (202) 555-0123" -> "+12025550123"
 *   "07911123456", "+44"-> "+447911123456"
 *
 * @param {string} input Raw phone string
 * @param {string} [defaultDialCode="+92"] Default dial code if missing
 * @returns {string|null} Normalized E.164 or null if invalid
 */
function normalizePhone(input, defaultDialCode = "+92") {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (trimmed.length === 0 || trimmed.length > 40) return null;

  return baseNormalizePhone(trimmed, defaultDialCode);
}

/**
 * Returns all potential string representations of a phone number as stored
 * across historical Firestore documents, ensuring complete backward compatibility.
 *
 * @param {string} input Raw or normalized phone string
 * @param {string} [defaultDialCode="+92"]
 * @returns {string[]} Array of unique lookup variants
 */
function phoneLookupVariants(input, defaultDialCode = "+92") {
  return basePhoneLookupVariants(input, defaultDialCode);
}

/**
 * Masks a phone number for secure logging and UI display.
 * Example: "+923001234567" -> "+923***4567"
 *
 * @param {string} phone
 * @returns {string}
 */
function maskPhone(phone) {
  if (typeof phone !== "string" || phone.length <= 6) return "***";
  const start = phone.length > 8 ? 4 : 2;
  return `${phone.substring(0, start)}***${phone.substring(phone.length - 4)}`;
}

module.exports = {
  isValidE164,
  normalizePhone,
  normalizePkPhone,
  phoneLookupVariants,
  maskPhone,
};
