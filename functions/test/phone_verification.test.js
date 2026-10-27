const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  isValidE164,
  normalizePhone,
  normalizePkPhone,
  phoneLookupVariants,
  maskPhone,
} = require("../phone_helpers");
const { checkPhoneAvailabilityCore } = require("../phone_verification");

describe("Phone Helper E.164 Normalization", () => {
  it("validates strict E.164 formats correctly", () => {
    assert.equal(isValidE164("+923001234567"), true);
    assert.equal(isValidE164("+12025550123"), true);
    assert.equal(isValidE164("+447911123456"), true);
    assert.equal(isValidE164("+971501234567"), true);

    // Invalid formats
    assert.equal(isValidE164("03001234567"), false);
    assert.equal(isValidE164("923001234567"), false);
    assert.equal(isValidE164("+03001234567"), false); // Leading zero after plus
    assert.equal(isValidE164("+92 300 1234567"), false); // Spaces
    assert.equal(isValidE164("+123"), false); // Too short
    assert.equal(isValidE164("invalid"), false);
    assert.equal(isValidE164(null), false);
  });

  it("normalizes diverse Pakistani mobile formats to E.164", () => {
    assert.equal(normalizePhone("03001234567"), "+923001234567");
    assert.equal(normalizePhone("0300-1234567"), "+923001234567");
    assert.equal(normalizePhone("0300 1234567"), "+923001234567");
    assert.equal(normalizePhone("+92 300 1234567"), "+923001234567");
    assert.equal(normalizePhone("923001234567"), "+923001234567");
    assert.equal(normalizePhone("00923001234567"), "+923001234567");
    assert.equal(normalizePhone("3001234567"), "+923001234567");
  });

  it("normalizes international phone numbers to E.164", () => {
    assert.equal(normalizePhone("+1 (202) 555-0123"), "+12025550123");
    assert.equal(normalizePhone("0012025550123"), "+12025550123");
    assert.equal(normalizePhone("+44 7911 123456"), "+447911123456");
    assert.equal(normalizePhone("07911123456", "+44"), "+447911123456");
  });

  it("generates complete lookup variants for database queries", () => {
    const variants = phoneLookupVariants("+923001234567");
    assert.ok(variants.includes("+923001234567"));
    assert.ok(variants.includes("03001234567"));
    assert.ok(variants.includes("923001234567"));
    assert.ok(variants.includes("3001234567"));
  });

  it("masks phone numbers safely", () => {
    assert.equal(maskPhone("+923001234567"), "+923***4567");
    assert.equal(maskPhone("03001234567"), "0300***4567");
    assert.equal(maskPhone("123"), "***");
  });
});

describe("Phone Availability Core Verification", () => {
  function createMockDb(options = {}) {
    const {
      patientDocs = [],
      doctorDocs = [],
      registeredPhoneDocs = {},
    } = options;

    return {
      collection(collName) {
        if (collName === "registered_phones") {
          return {
            doc(id) {
              const data = registeredPhoneDocs[id];
              return {
                async get() {
                  return {
                    exists: Boolean(data),
                    data: () => data || null,
                  };
                },
              };
            },
          };
        }

        if (collName === "telemedicine_patient") {
          return {
            doc(id) {
              const doc = patientDocs.find((d) => d.id === id);
              return {
                async get() {
                  return {
                    exists: Boolean(doc),
                    data: () => doc ? doc.data : null,
                  };
                },
              };
            },
            where(field, op, values) {
              return {
                limit() {
                  return {
                    async get() {
                      const matches = patientDocs.filter((d) =>
                        values.includes(d.data.phoneNumber)
                      );
                      return {
                        docs: matches.map((m) => ({
                          id: m.id,
                          data: () => m.data,
                        })),
                      };
                    },
                  };
                },
              };
            },
          };
        }

        if (collName === "telemedicine_doctors") {
          return {
            doc(id) {
              const doc = doctorDocs.find((d) => d.id === id);
              return {
                async get() {
                  return {
                    exists: Boolean(doc),
                    data: () => doc ? doc.data : null,
                  };
                },
              };
            },
            where(field, op, values) {
              return {
                limit() {
                  return {
                    async get() {
                      const matches = doctorDocs.filter((d) =>
                        values.includes(d.data.phoneNumber)
                      );
                      return {
                        docs: matches.map((m) => ({
                          id: m.id,
                          data: () => m.data,
                        })),
                      };
                    },
                  };
                },
              };
            },
          };
        }

        throw new Error(`Unexpected collection: ${collName}`);
      },
    };
  }

  it("returns available for an unregistered phone number", async () => {
    const db = createMockDb();
    const result = await checkPhoneAvailabilityCore(db, "03001234567");

    assert.equal(result.success, true);
    assert.equal(result.is_registered, false);
    assert.equal(result.normalized_phone, "+923001234567");
    assert.match(result.message, /available/i);
  });

  it("blocks and flags phone as registered if in telemedicine_patient", async () => {
    const db = createMockDb({
      patientDocs: [
        {
          id: "p1",
          data: {
            phoneNumber: "03001234567",
            fullname: "John Doe",
            role: "patient",
          },
        },
      ],
    });

    const result = await checkPhoneAvailabilityCore(db, "+923001234567");
    assert.equal(result.success, false);
    assert.equal(result.is_registered, true);
    assert.equal(result.user_id, "p1");
    assert.equal(result.role, "patient");
    assert.match(result.message, /already in use/i);
  });

  it("blocks and flags phone as registered if in telemedicine_doctors", async () => {
    const db = createMockDb({
      doctorDocs: [
        {
          id: "d1",
          data: {
            phoneNumber: "+923001234567",
            fullname: "Dr. Smith",
            role: "doctor",
          },
        },
      ],
    });

    const result = await checkPhoneAvailabilityCore(db, "03001234567");
    assert.equal(result.success, false);
    assert.equal(result.is_registered, true);
    assert.equal(result.user_id, "d1");
    assert.equal(result.role, "doctor");
  });

  it("blocks if phone is in registered_phones uniqueness index", async () => {
    const db = createMockDb({
      registeredPhoneDocs: {
        "+923001234567": {
          userId: "p2",
          role: "patient",
        },
      },
    });

    const result = await checkPhoneAvailabilityCore(db, "03001234567");
    assert.equal(result.success, false);
    assert.equal(result.is_registered, true);
    assert.equal(result.user_id, "p2");
  });

  it("allows registration if existing matching record is soft-deleted", async () => {
    const db = createMockDb({
      patientDocs: [
        {
          id: "p_del",
          data: {
            phoneNumber: "03001234567",
            isDeleted: true,
          },
        },
      ],
    });

    const result = await checkPhoneAvailabilityCore(db, "03001234567");
    assert.equal(result.success, true);
    assert.equal(result.is_registered, false);
  });

  it("rejects invalid phone numbers with error", async () => {
    const db = createMockDb();
    const result = await checkPhoneAvailabilityCore(db, "abc-not-a-phone");

    assert.equal(result.success, false);
    assert.equal(result.is_registered, false);
    assert.equal(result.error, "INVALID_PHONE_FORMAT");
  });
});
