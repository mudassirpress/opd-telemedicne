/**
 * Phone Number Duplication Verification & Availability Checks.
 *
 * Implements strict backend validation for Sign-up and Patient Card flows:
 *   1. Normalizes incoming phone to canonical E.164.
 *   2. Checks both `telemedicine_patient` and `telemedicine_doctors` collections
 *      against all possible phone lookup variants.
 *   3. Enforces atomic database uniqueness via `registered_phones/{e164}` collection.
 *   4. Exposes both HTTP REST endpoint (`/api/auth/check-phone-availability`)
 *      and Firebase 2nd Gen Callable (`checkPhoneAvailability`).
 */

const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const {normalizePhone, phoneLookupVariants, maskPhone, isValidE164} = require("./phone_helpers");

const PATIENT_COLLECTION = "telemedicine_patient";
const DOCTOR_COLLECTION = "telemedicine_doctors";
const REGISTERED_PHONES_COLLECTION = "registered_phones";

/**
 * Core availability check function (shared by HTTP and Callable handlers).
 *
 * @param {admin.firestore.Firestore} db
 * @param {string} rawPhone Raw or international phone string
 * @param {string} [role="patient"] Role context ("patient" or "doctor")
 * @param {string} [countryCode="+92"] Default dial code if missing in raw input
 * @returns {Promise<{
 *   success: boolean,
 *   is_registered: boolean,
 *   message: string,
 *   normalized_phone: string,
 *   user_id?: string,
 *   role?: string,
 *   has_patient_id?: boolean,
 *   is_active?: boolean,
 *   error?: string
 * }>}
 */
async function checkPhoneAvailabilityCore(db, rawPhone, role = "patient", countryCode = "+92") {
  if (!rawPhone || typeof rawPhone !== "string") {
    return {
      success: false,
      is_registered: false,
      message: "Phone number is required.",
      error: "INVALID_PHONE_INPUT",
      normalized_phone: "",
    };
  }

  const normalized = normalizePhone(rawPhone, countryCode);
  if (!normalized || !isValidE164(normalized)) {
    return {
      success: false,
      is_registered: false,
      message: "Invalid phone number format. Please provide a valid phone number with country code.",
      error: "INVALID_PHONE_FORMAT",
      normalized_phone: rawPhone.trim(),
    };
  }

  const variants = phoneLookupVariants(normalized, countryCode);

  // 1. Check uniqueness lock document first (O(1) read)
  const phoneDocRef = db.collection(REGISTERED_PHONES_COLLECTION).doc(normalized);
  const phoneDoc = await phoneDocRef.get();
  if (phoneDoc.exists) {
    const data = phoneDoc.data() || {};
    const existingUserId = data.userId || "";
    const existingRole = data.role || "patient";

    // Verify target account is not soft-deleted
    const targetColl = existingRole === "doctor" ? DOCTOR_COLLECTION : PATIENT_COLLECTION;
    let isActive = true;
    if (existingUserId) {
      const userSnap = await db.collection(targetColl).doc(existingUserId).get();
      if (userSnap.exists) {
        const userData = userSnap.data() || {};
        if (userData.isDeleted === true) {
          isActive = false;
        }
      }
    }

    if (isActive) {
      console.log(`[PHONE_CHECK] Phone ${maskPhone(normalized)} already registered via unique index`);
      return {
        success: false,
        is_registered: true,
        message: "Phone number already in use.",
        normalized_phone: normalized,
        role: existingRole,
        user_id: existingUserId,
        has_patient_id: Boolean(data.patientId),
        is_active: true,
      };
    }
  }

  // 2. Query patient collection with all lookup variants
  const patientSnap = await db
    .collection(PATIENT_COLLECTION)
    .where("phoneNumber", "whereIn", variants)
    .limit(5)
    .get();

  for (const doc of patientSnap.docs) {
    const data = doc.data() || {};
    // Exclude soft-deleted patients
    if (data.isDeleted === true) continue;

    console.log(`[PHONE_CHECK] Phone ${maskPhone(normalized)} found in patient collection: docId=${doc.id}`);
    return {
      success: false,
      is_registered: true,
      message: "Phone number already in use.",
      normalized_phone: normalized,
      role: "patient",
      user_id: doc.id,
      has_patient_id: Boolean(data.patientId && String(data.patientId).trim().length > 0),
      is_active: true,
    };
  }

  // 3. Query doctor collection with all lookup variants
  const doctorSnap = await db
    .collection(DOCTOR_COLLECTION)
    .where("phoneNumber", "whereIn", variants)
    .limit(5)
    .get();

  for (const doc of doctorSnap.docs) {
    const data = doc.data() || {};
    if (data.isDeleted === true) continue;

    console.log(`[PHONE_CHECK] Phone ${maskPhone(normalized)} found in doctor collection: docId=${doc.id}`);
    return {
      success: false,
      is_registered: true,
      message: "Phone number already in use.",
      normalized_phone: normalized,
      role: "doctor",
      user_id: doc.id,
      has_patient_id: false,
      is_active: true,
    };
  }

  // Phone is completely available
  console.log(`[PHONE_CHECK] Phone ${maskPhone(normalized)} is available for registration`);
  return {
    success: true,
    is_registered: false,
    message: "Phone number is available.",
    normalized_phone: normalized,
  };
}

/**
 * Cloud Function (Callable): `checkPhoneAvailability`
 *
 * Payload:
 *   { phone: "+923001234567", role?: "patient", countryCode?: "+92" }
 */
const checkPhoneAvailability = onCall(
  {
    region: "asia-south1",
    cors: true,
  },
  async (request) => {
    const data = request.data || {};
    const rawPhone = data.phone || data.phoneNumber;
    const role = data.role || "patient";
    const countryCode = data.countryCode || "+92";

    const db = admin.firestore();
    const result = await checkPhoneAvailabilityCore(db, rawPhone, role, countryCode);

    return result;
  }
);

/**
 * Cloud Function (HTTP): `checkPhoneAvailabilityHttp`
 *
 * Accessible via `POST /api/auth/check-phone-availability` or `POST /api/auth/send-otp-register`.
 * Headers: Content-Type: application/json
 * Body:
 *   { "phone": "+923001234567", "role": "patient" }
 */
const checkPhoneAvailabilityHttp = onRequest(
  {
    region: "asia-south1",
    cors: true,
  },
  async (req, res) => {
    // Only accept POST
    if (req.method !== "POST") {
      res.set("Allow", "POST");
      return res.status(405).json({
        success: false,
        error: "Method Not Allowed. Use POST.",
      });
    }

    try {
      const data = req.body || {};
      const rawPhone = data.phone || data.phoneNumber;
      const role = data.role || "patient";
      const countryCode = data.countryCode || "+92";

      const db = admin.firestore();
      const result = await checkPhoneAvailabilityCore(db, rawPhone, role, countryCode);

      // Return 200 with result payload
      return res.status(200).json(result);
    } catch (err) {
      console.error("[PHONE_CHECK_HTTP_ERROR]", err);
      return res.status(500).json({
        success: false,
        error: "Internal Server Error checking phone availability.",
      });
    }
  }
);

module.exports = {
  checkPhoneAvailabilityCore,
  checkPhoneAvailability,
  checkPhoneAvailabilityHttp,
  REGISTERED_PHONES_COLLECTION,
};
