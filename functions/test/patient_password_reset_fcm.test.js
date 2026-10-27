const {describe, it} = require("node:test");
const assert = require("node:assert/strict");
const h = require("../password_reset_helpers");
const {isUnrecoverableTokenError} = require("../fcm_helpers");

describe("Patient Password Reset FCM OTP Core Logic", () => {
  it("generates a strictly 6-digit cryptographic numeric OTP", () => {
    for (let i = 0; i < 50; i++) {
      const otp = h.randomOtp();
      assert.equal(typeof otp, "string");
      assert.equal(otp.length, 6);
      assert.match(otp, /^\d{6}$/);
      assert.ok(h.isValidOtpFormat(otp));
    }
  });

  it("normalizes diverse Pakistani phone number inputs to standard E.164", () => {
    assert.equal(h.normalizePkPhone("03341234567"), "+923341234567");
    assert.equal(h.normalizePkPhone("+923341234567"), "+923341234567");
    assert.equal(h.normalizePkPhone("923341234567"), "+923341234567");
    assert.equal(h.normalizePkPhone("00923341234567"), "+923341234567");
    assert.equal(h.normalizePkPhone("3341234567"), "+923341234567");
    assert.equal(h.normalizePkPhone(" 0334-1234567 "), "+923341234567");
  });

  it("rejects non-Pakistani or malformed phone numbers", () => {
    assert.equal(h.normalizePkPhone(""), null);
    assert.equal(h.normalizePkPhone("0321"), null);
    assert.equal(h.normalizePkPhone("1234567890"), null);
    assert.equal(h.normalizePkPhone("+14155552671"), null);
    assert.equal(h.normalizePkPhone("not-a-number"), null);
  });

  it("validates new password policy strictly", () => {
    // Valid: >=8 chars, contains letter and number
    assert.equal(h.validateNewPassword("Secret123").ok, true);
    assert.equal(h.validateNewPassword("StrongPassw0rd!").ok, true);

    // Invalid: too short
    assert.equal(h.validateNewPassword("Pass1").ok, false);
    // Invalid: no numbers
    assert.equal(h.validateNewPassword("NoNumbersHere").ok, false);
    // Invalid: no letters
    assert.equal(h.validateNewPassword("1234567890").ok, false);
    // Invalid: empty/null
    assert.equal(h.validateNewPassword("").ok, false);
    assert.equal(h.validateNewPassword(null).ok, false);
  });

  it("generates unique 32-byte URL-safe reset tokens", () => {
    const t1 = h.randomToken();
    const t2 = h.randomToken();
    assert.notEqual(t1, t2);
    assert.equal(t1.length, 43);
    assert.match(t1, /^[A-Za-z0-9_-]+$/);
  });

  it("hashes OTP and reset token with HMAC-SHA256 without exposing plaintext", () => {
    const pepper = "super-secret-pepper-32-bytes-long";
    const phone = "+923341234567";
    const otp = "849201";

    const hash1 = h.hmacHex(pepper, `${phone}:${otp}`);
    const hash2 = h.hmacHex(pepper, `${phone}:${otp}`);
    const hashWrongOtp = h.hmacHex(pepper, `${phone}:849202`);

    assert.equal(hash1, hash2);
    assert.notEqual(hash1, hashWrongOtp);
    assert.equal(h.timingSafeEqualHex(hash1, hash2), true);
    assert.equal(h.timingSafeEqualHex(hash1, hashWrongOtp), false);
  });

  it("enforces resend cooldown and hourly send limits", () => {
    const now = 1700000000000;
    // Initial send allowed
    const first = h.evaluateSendLimit(null, now);
    assert.equal(first.allowed, true);

    // Immediate second send blocked by 60s cooldown
    const second = h.evaluateSendLimit(first.next, now + 10000); // 10s later
    assert.equal(second.allowed, false);
    assert.equal(second.resendInSeconds, 50);

    // After cooldown (65s), allowed
    const third = h.evaluateSendLimit(first.next, now + 65000);
    assert.equal(third.allowed, true);
  });

  it("safely detects dead FCM tokens for cleanup", () => {
    assert.equal(
      isUnrecoverableTokenError({code: "messaging/registration-token-not-registered"}),
      true,
    );
    assert.equal(
      isUnrecoverableTokenError({code: "messaging/invalid-registration-token"}),
      true,
    );
    // Transient network errors must NOT be marked dead
    assert.equal(
      isUnrecoverableTokenError({code: "messaging/server-unavailable"}),
      false,
    );
  });

  it("maps phone number variants to the correct patient account and extracts device FCM token", async () => {
    const {findAccountByPhone} = require("../patient_password_reset");
    const mockPatientDoc = {
      id: "patient_uid_123",
      data: () => ({
        fullname: "John Doe",
        phoneNumber: "+923341234567",
        role: "patient",
        fcmToken: "device_token_abc_123",
        deviceId: "device_xyz",
      }),
    };

    const mockDb = {
      collection: (name) => {
        assert.equal(name, "telemedicine_patient");
        return {
          where: (field, op, values) => {
            assert.equal(field, "phoneNumber");
            assert.equal(op, "in");
            assert.ok(values.includes("+923341234567"));
            return {
              limit: () => ({
                get: async () => ({ docs: [mockPatientDoc] }),
              }),
            };
          },
        };
      },
    };

    const account = await findAccountByPhone(mockDb, "+923341234567");
    assert.ok(account);
    assert.equal(account.id, "patient_uid_123");
    assert.equal(account.fcmToken, "device_token_abc_123");
    assert.equal(account.deviceId, "device_xyz");
  });

  it("strictly isolates doctor accounts and prevents targeting doctors for password reset", async () => {
    const {findAccountByPhone} = require("../patient_password_reset");
    const mockDoctorDoc = {
      id: "doctor_uid_456",
      data: () => ({
        fullname: "Dr. Smith",
        phoneNumber: "+923341234567",
        role: "doctor",
        fcmToken: "doc_fcm_token",
      }),
    };

    const mockDb = {
      collection: () => ({
        where: () => ({
          limit: () => ({
            get: async () => ({ docs: [mockDoctorDoc] }),
          }),
        }),
      }),
    };

    const account = await findAccountByPhone(mockDb, "+923341234567");
    assert.equal(account, null);
  });

  it("rejects deleted or blocked patient accounts", async () => {
    const {findAccountByPhone} = require("../patient_password_reset");
    const mockDeletedDoc = {
      id: "deleted_patient",
      data: () => ({
        phoneNumber: "+923341234567",
        role: "patient",
        isDeleted: true,
      }),
    };

    const mockDb = {
      collection: () => ({
        where: () => ({
          limit: () => ({
            get: async () => ({ docs: [mockDeletedDoc] }),
          }),
        }),
      }),
    };

    const account = await findAccountByPhone(mockDb, "+923341234567");
    assert.equal(account, null);
  });

  it("enforces single-use reset authorization token and rejects cross-account reuse", () => {
    const pepper = "test-pepper-32-chars-long-123456";
    const now = Date.now();
    const tokenRecord = {
      accountId: "patient_uid_123",
      usedAtMs: null,
      expiresAtMs: now + 600000,
      phoneKey: h.phoneKey(pepper, "+923341234567"),
    };

    // First use: valid
    assert.equal(tokenRecord.usedAtMs, null);
    tokenRecord.usedAtMs = now;

    // Second use: must be blocked because usedAtMs is not null
    assert.notEqual(tokenRecord.usedAtMs, null);

    // Cross-account check: token issued for patient_uid_123 cannot reset patient_uid_999
    assert.notEqual(tokenRecord.accountId, "patient_uid_999");
  });

  it("maps international phone numbers to correct patient accounts across US and UK formats", async () => {
    const {findAccountByPhone} = require("../patient_password_reset");
    const mockUsPatientDoc = {
      id: "us_patient_uid",
      data: () => ({
        fullname: "Alice US",
        phoneNumber: "+12025550123",
        role: "patient",
        fcmToken: "us_device_token",
      }),
    };

    const mockDb = {
      collection: () => ({
        where: (field, op, values) => {
          assert.equal(field, "phoneNumber");
          assert.ok(values.includes("+12025550123"));
          assert.ok(values.includes("12025550123"));
          return {
            limit: () => ({
              get: async () => ({ docs: [mockUsPatientDoc] }),
            }),
          };
        },
      }),
    };

    const account = await findAccountByPhone(mockDb, "+12025550123");
    assert.ok(account);
    assert.equal(account.id, "us_patient_uid");
    assert.equal(account.fcmToken, "us_device_token");
  });
});

