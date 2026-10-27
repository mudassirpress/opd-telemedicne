"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  sanitizeDoctorProfilePayload,
  deleteExistingStorageFile,
  handleDoctorProfileUpdate,
} = require("../doctor_profile_helpers");

describe("Doctor Profile Image Deletion & Sanitization", () => {
  it("sanitizes string 'null' and 'undefined' to literal null", () => {
    const rawPayload = {
      fullname: "Dr. Gregory House",
      profile_image: "null",
      imageUrl: "null",
      image: "undefined",
    };

    const sanitized = sanitizeDoctorProfilePayload(rawPayload);
    assert.equal(sanitized.profile_image, null);
    assert.equal(sanitized.imageUrl, null);
    assert.equal(sanitized.image, null);
    assert.equal(sanitized.fullname, "Dr. Gregory House");
  });

  it("handles remove_profile_image flag from form-data (boolean, string 'true', '1')", () => {
    assert.equal(
      sanitizeDoctorProfilePayload({ remove_profile_image: true }).remove_profile_image,
      true
    );
    assert.equal(
      sanitizeDoctorProfilePayload({ remove_profile_image: "true" }).remove_profile_image,
      true
    );
    assert.equal(
      sanitizeDoctorProfilePayload({ remove_profile_image: "1" }).remove_profile_image,
      true
    );
    assert.equal(
      sanitizeDoctorProfilePayload({ remove_profile_image: false }).remove_profile_image,
      false
    );
    assert.equal(
      sanitizeDoctorProfilePayload({ remove_profile_image: "false" }).remove_profile_image,
      false
    );
  });

  it("forces image fields to null when remove_profile_image is true", () => {
    const payload = {
      remove_profile_image: true,
      imageUrl: "https://res.cloudinary.com/demo/image/upload/v1234/old.jpg",
    };

    const sanitized = sanitizeDoctorProfilePayload(payload);
    assert.equal(sanitized.profile_image, null);
    assert.equal(sanitized.imageUrl, null);
    assert.equal(sanitized.image, null);
  });

  it("unlinks existing image using storageService when remove_profile_image === true", async () => {
    let deletedUrl = null;
    const mockStorage = {
      deleteFile: async (url) => {
        deletedUrl = url;
      },
    };

    const oldUrl = "https://res.cloudinary.com/telemedicine/doctor_profiles/doctor_123.jpg";
    const res = await deleteExistingStorageFile(oldUrl, mockStorage);

    assert.equal(res, true);
    assert.equal(deletedUrl, oldUrl);
  });

  it("handleDoctorProfileUpdate deletes existing file, sets profile_image=null in DB, and returns updated doctor", async () => {
    let updatedDataInDb = null;
    let fileDeleted = null;

    const mockStorage = {
      deleteFile: async (url) => {
        fileDeleted = url;
      },
    };

    const mockDb = {
      collection: (name) => {
        assert.equal(name, "telemedicine_doctors");
        return {
          doc: (id) => ({
            get: async () => ({
              exists: true,
              id: id,
              data: () => ({
                id: "doc_999",
                fullname: "Dr. Lisa Cuddy",
                profile_image: "https://cloudinary.com/telemedicine/doctor_profiles/doc_999.png",
                imageUrl: "https://cloudinary.com/telemedicine/doctor_profiles/doc_999.png",
                specialization: "Endocrinology",
              }),
            }),
            update: async (data) => {
              updatedDataInDb = data;
            },
          }),
        };
      },
    };

    const result = await handleDoctorProfileUpdate({
      doctorId: "doc_999",
      payload: {
        remove_profile_image: true,
        highestDegree: "MD, FACP",
      },
      db: mockDb,
      storageService: mockStorage,
    });

    assert.equal(result.success, true);
    assert.equal(fileDeleted, "https://cloudinary.com/telemedicine/doctor_profiles/doc_999.png");
    assert.equal(updatedDataInDb.profile_image, null);
    assert.equal(updatedDataInDb.imageUrl, null);
    assert.equal(updatedDataInDb.image, null);
    assert.equal(result.doctor.profile_image, null);
    assert.equal(result.doctor.imageUrl, null);
    assert.equal(result.doctor.fullname, "Dr. Lisa Cuddy");
    assert.equal(result.doctor.highestDegree, "MD, FACP");
  });
});
