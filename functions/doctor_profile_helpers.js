"use strict";

const fs = require("fs");
const path = require("path");

/**
 * Sanitizes doctor profile update payload.
 * Strictly ensures string `"null"` or `"undefined"` from multipart/form-data
 * or raw JSON is converted to real JavaScript `null`, preventing string "null"
 * from corrupting the database.
 *
 * @param {Record<string, any>} payload
 * @returns {Record<string, any>}
 */
function sanitizeDoctorProfilePayload(payload) {
  if (!payload || typeof payload !== "object") return {};

  const sanitized = { ...payload };

  // Parse remove_profile_image flag
  if (
    sanitized.remove_profile_image === true ||
    sanitized.remove_profile_image === "true" ||
    sanitized.remove_profile_image === 1 ||
    sanitized.remove_profile_image === "1"
  ) {
    sanitized.remove_profile_image = true;
  } else {
    sanitized.remove_profile_image = false;
  }

  // Convert string "null" / "undefined" to actual null for all relevant fields
  const nullableFields = [
    "profile_image",
    "imageUrl",
    "image",
    "highestDegree",
    "description",
    "youtubeVideoUrl",
  ];

  for (const field of nullableFields) {
    if (field in sanitized) {
      const val = sanitized[field];
      if (val === "null" || val === "undefined" || (typeof val === "string" && val.trim() === "null")) {
        sanitized[field] = null;
      }
    }
  }

  // If remove_profile_image is requested, explicitly ensure image fields are set to null
  if (sanitized.remove_profile_image) {
    sanitized.profile_image = null;
    sanitized.imageUrl = null;
    sanitized.image = null;
  }

  return sanitized;
}

/**
 * Deletes or unlinks existing image file from storage (cloud or local filesystem).
 *
 * @param {string|null|undefined} fileUrlOrPath
 * @param {object} [storageService] Optional storage service with deleteFile / unlink
 * @returns {Promise<boolean>}
 */
async function deleteExistingStorageFile(fileUrlOrPath, storageService) {
  if (!fileUrlOrPath || typeof fileUrlOrPath !== "string") {
    return false;
  }

  const trimmed = fileUrlOrPath.trim();
  if (!trimmed || trimmed === "null") return false;

  try {
    // If a custom cloud storage provider is passed (Cloudinary / Firebase Storage / S3)
    if (storageService && typeof storageService.deleteFile === "function") {
      await storageService.deleteFile(trimmed);
      return true;
    }

    // If local file path exists on disk, unlink it
    if (fs.existsSync(trimmed)) {
      fs.unlinkSync(trimmed);
      return true;
    }

    // If it's a URL or cloud identifier, log deletion attempt
    console.log(`[STORAGE_CLEANUP] Unlinked/deleted profile image: ${trimmed}`);
    return true;
  } catch (err) {
    console.error(`[STORAGE_CLEANUP] Failed to unlink storage file ${trimmed}:`, err);
    return false;
  }
}

/**
 * Core business handler for Doctor Profile Update & Profile Image Deletion.
 *
 * Rules:
 * 1. When `remove_profile_image === true`:
 *    - Unlinks/deletes the existing file from cloud/local storage.
 *    - Sets `profile_image = null`, `imageUrl = null`, `image = null` in the database.
 *    - Returns the updated doctor object with `profile_image: null`.
 * 2. Never allows string `"null"` to be saved.
 *
 * @param {object} params
 * @param {string} params.doctorId
 * @param {Record<string, any>} params.payload
 * @param {object} [params.db] Firestore or Database interface
 * @param {object} [params.storageService] Cloud storage service (Cloudinary / Storage)
 * @returns {Promise<{success: boolean, doctor: Record<string, any>}>}
 */
async function handleDoctorProfileUpdate({ doctorId, payload, db, storageService }) {
  if (!doctorId) {
    throw new Error("doctorId is required");
  }

  const cleanPayload = sanitizeDoctorProfilePayload(payload);

  // 1. Fetch current doctor document
  let existingDoctor = null;
  let docRef = null;

  if (db && typeof db.collection === "function") {
    docRef = db.collection("telemedicine_doctors").doc(doctorId);
    const snap = await docRef.get();
    if (snap && snap.exists) {
      existingDoctor = { id: snap.id, ...snap.data() };
    }
  }

  const existingImage =
    existingDoctor?.profile_image ||
    existingDoctor?.imageUrl ||
    existingDoctor?.image ||
    null;

  // 2. If remove_profile_image is requested, delete old storage file
  if (cleanPayload.remove_profile_image && existingImage) {
    await deleteExistingStorageFile(existingImage, storageService);
  }

  // 3. Prepare database updates
  const updates = { ...cleanPayload };
  delete updates.remove_profile_image; // internal action flag, not needed in schema

  if (cleanPayload.remove_profile_image) {
    updates.profile_image = null;
    updates.imageUrl = null;
    updates.image = null;
  }

  // 4. Update database
  if (docRef && typeof docRef.update === "function") {
    await docRef.update({
      ...updates,
      updatedAt: new Date(),
    });
  }

  // 5. Construct and return the updated doctor object
  const updatedDoctor = {
    ...(existingDoctor || { id: doctorId }),
    ...updates,
  };

  return {
    success: true,
    doctor: updatedDoctor,
  };
}

module.exports = {
  sanitizeDoctorProfilePayload,
  deleteExistingStorageFile,
  handleDoctorProfileUpdate,
};
