/**
 * Unit tests for the pure password-reset helpers.
 *
 * Run from `functions/`:
 *   npm test        (node --test test/)
 *
 * These need no Firebase project, no emulator and no secrets — the helpers
 * module deliberately has zero Firebase imports.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const h = require("../lib/shared/password_reset_helpers.js");

const PEPPER = "test-pepper-not-a-real-secret";

test("normalizePkPhone accepts every common Pakistani format", () => {
  const expected = "+923451234567";
  assert.equal(h.normalizePkPhone("03451234567"), expected);
  assert.equal(h.normalizePkPhone("+923451234567"), expected);
  assert.equal(h.normalizePkPhone("923451234567"), expected);
  assert.equal(h.normalizePkPhone("00923451234567"), expected);
  assert.equal(h.normalizePkPhone("3451234567"), expected);
  assert.equal(h.normalizePkPhone("0345 1234567"), expected);
  assert.equal(h.normalizePkPhone(" 0345-123-4567 "), expected);
  assert.equal(h.normalizePkPhone("(0345)1234567"), expected);
});

test("normalizePkPhone accepts all valid PK prefixes (0300–0349 range)", () => {
  assert.equal(h.normalizePkPhone("03001234567"), "+923001234567");
  assert.equal(h.normalizePkPhone("03356975643"), "+923356975643");
  assert.equal(h.normalizePkPhone("03491234567"), "+923491234567");
});

test("normalizePkPhone rejects everything that is not a PK mobile", () => {
  assert.equal(h.normalizePkPhone(""), null);
  assert.equal(h.normalizePkPhone("   "), null);
  assert.equal(h.normalizePkPhone(null), null);
  assert.equal(h.normalizePkPhone(undefined), null);
  assert.equal(h.normalizePkPhone(12345), null);
  assert.equal(h.normalizePkPhone("0345123456"), null); // 10 digits
  assert.equal(h.normalizePkPhone("034512345678"), null); // 12 digits
  assert.equal(h.normalizePkPhone("02131234567"), null); // landline
  assert.equal(h.normalizePkPhone("+15551234567"), null); // US
  assert.equal(h.normalizePkPhone("abc"), null);
  assert.equal(h.normalizePkPhone("03451234567".repeat(5)), null); // too long
});

test("phoneLookupVariants returns the four stored formats", () => {
  const variants = h.phoneLookupVariants("+923451234567");
  assert.deepEqual(variants, [
    "03451234567",
    "+923451234567",
    "923451234567",
    "3451234567",
  ]);
});

test("sendpkMobile strips the leading plus", () => {
  assert.equal(h.sendpkMobile("+923451234567"), "923451234567");
});

test("randomOtp is a 6-digit zero-padded string", () => {
  for (let i = 0; i < 200; i++) {
    const otp = h.randomOtp();
    assert.match(otp, /^\d{6}$/);
  }
});

test("randomToken is URL-safe and 43 chars (32 bytes)", () => {
  const token = h.randomToken();
  assert.match(token, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(token, h.randomToken());
});

test("hmacHex is deterministic per pepper and distinct across peppers", () => {
  const a1 = h.hmacHex(PEPPER, "phone:+923451234567");
  const a2 = h.hmacHex(PEPPER, "phone:+923451234567");
  const b = h.hmacHex("other-pepper", "phone:+923451234567");
  assert.equal(a1, a2);
  assert.notEqual(a1, b);
  assert.match(a1, /^[0-9a-f]{64}$/);
});

test("timingSafeEqualHex compares safely and never throws", () => {
  const digest = h.hmacHex(PEPPER, "x");
  assert.equal(h.timingSafeEqualHex(digest, digest), true);
  assert.equal(h.timingSafeEqualHex(digest, h.hmacHex(PEPPER, "y")), false);
  assert.equal(h.timingSafeEqualHex(digest, digest.slice(0, 10)), false); // length
  assert.equal(h.timingSafeEqualHex("", ""), false); // empty
  assert.equal(h.timingSafeEqualHex(digest, "zz".repeat(32)), false); // non-hex
  assert.equal(h.timingSafeEqualHex(null, digest), false);
  assert.equal(h.timingSafeEqualHex(digest, undefined), false);
});

test("phoneKey / resetTokenKey never contain the plaintext input", () => {
  const otpDocKey = h.phoneKey(PEPPER, "+923451234567");
  assert.match(otpDocKey, /^[0-9a-f]{64}$/);
  assert.ok(!otpDocKey.includes("923451234567"));

  const token = h.randomToken();
  const tokenKey = h.resetTokenKey(PEPPER, token);
  assert.match(tokenKey, /^[0-9a-f]{64}$/);
  assert.ok(!tokenKey.includes(token));
  assert.equal(tokenKey, h.resetTokenKey(PEPPER, token));
});

test("isValidOtpFormat accepts exactly six digits", () => {
  assert.equal(h.isValidOtpFormat("123456"), true);
  assert.equal(h.isValidOtpFormat("000000"), true);
  assert.equal(h.isValidOtpFormat("12345"), false);
  assert.equal(h.isValidOtpFormat("1234567"), false);
  assert.equal(h.isValidOtpFormat("abcdef"), false);
  assert.equal(h.isValidOtpFormat("12 456"), false);
  assert.equal(h.isValidOtpFormat(""), false);
  assert.equal(h.isValidOtpFormat(null), false);
  assert.equal(h.isValidOtpFormat(123456), false);
});

test("validateNewPassword enforces strength and limits", () => {
  assert.equal(h.validateNewPassword("Password1").ok, true);
  assert.equal(h.validateNewPassword("  Password1  ").value, "Password1"); // trimmed
  assert.equal(h.validateNewPassword("abcdefgh").ok, false); // no digit
  assert.equal(h.validateNewPassword("12345678").ok, false); // no letter
  assert.equal(h.validateNewPassword("Ab1").ok, false); // too short
  assert.equal(h.validateNewPassword(`A1${"a".repeat(70)}`).ok, false); // too long
  assert.equal(h.validateNewPassword("        ").ok, false); // spaces only
  assert.equal(h.validateNewPassword("").ok, false);
  assert.equal(h.validateNewPassword(null).ok, false);
  assert.equal(h.validateNewPassword(12345678).ok, false);
  const message = h.validateNewPassword("abc").message;
  assert.ok(typeof message === "string" && message.length > 0);
});

test("buildTemplateVariables falls back to {otp, name} when template unknown", () => {
  assert.deepEqual(h.buildTemplateVariables(null, {otp: "123456", name: "Ali"}), {
    otp: "123456",
    name: "Ali",
  });
  assert.deepEqual(
    h.buildTemplateVariables({variables: []}, {otp: "123456", name: "Ali"}),
    {otp: "123456", name: "Ali"},
  );
});

test("buildTemplateVariables maps approved-template placeholders", () => {
  const vars = h.buildTemplateVariables(
    {variables: ["name", "otp", "minutes_left", "phone", "brand_extra"]},
    {otp: "123456", name: "Ali Khan", phoneE164: "+923451234567", minutes: 5},
  );
  assert.equal(vars.name, "Ali Khan");
  assert.equal(vars.otp, "123456");
  assert.equal(vars.minutes_left, "5");
  assert.equal(vars.phone, "****4567");
  assert.equal(vars.brand_extra, ""); // unknown placeholder is empty, not invented
  // The full phone number must never be emitted — only the masked form.
  assert.ok(!Object.values(vars).includes("+923451234567"));
  assert.ok(!Object.values(vars).includes("923451234567"));
});

test("buildTemplateVariables matches fuzzy variable names", () => {
  const vars = h.buildTemplateVariables(
    {variables: ["user_name", "verification_code", "expiry_time"]},
    {otp: "654321", name: "Sara", minutes: 5},
  );
  assert.equal(vars.user_name, "Sara");
  assert.equal(vars.verification_code, "654321");
  assert.equal(vars.expiry_time, "5");
});

test("parseSendPkResponse handles plain-text OK and numeric errors", () => {
  assert.deepEqual(h.parseSendPkResponse("OK ID:29346"), {ok: true, id: "29346"});
  assert.deepEqual(h.parseSendPkResponse("OK"), {ok: true});
  assert.deepEqual(h.parseSendPkResponse("OK ID:29346\n"), {ok: true, id: "29346"});
  assert.deepEqual(h.parseSendPkResponse("8"), {ok: false, code: "8"});
  assert.deepEqual(h.parseSendPkResponse("12"), {ok: false, code: "12"});
  assert.deepEqual(h.parseSendPkResponse("1"), {ok: false, code: "1"});
  assert.equal(h.parseSendPkResponse("").ok, false);
  assert.equal(h.parseSendPkResponse(null).ok, false);
});

test("parseSendPkResponse handles JSON responses", () => {
  assert.deepEqual(h.parseSendPkResponse('{"status":"OK","id":42}'), {
    ok: true,
    id: "42",
  });
  assert.equal(h.parseSendPkResponse('{"success":"true","results":[]}').ok, true);
  assert.equal(h.parseSendPkResponse('{"code":"8"}').code, "8");
});

test("evaluateSendLimit enforces the 60-second cooldown", () => {
  const now = 1_700_000_000_000;

  // Fresh record → allowed.
  const fresh = h.evaluateSendLimit(null, now);
  assert.equal(fresh.allowed, true);
  assert.equal(fresh.resendInSeconds, 60);
  assert.equal(fresh.next.sendsInWindow, 1);

  // 10s after a send → blocked with ~50s remaining.
  const blocked = h.evaluateSendLimit({lastSmsAtMs: now - 10_000, windowStartMs: now - 10_000, sendsInWindow: 1}, now);
  assert.equal(blocked.allowed, false);
  assert.ok(blocked.resendInSeconds > 40 && blocked.resendInSeconds <= 50);

  // Cooldown elapsed → allowed again.
  const afterCooldown = h.evaluateSendLimit(
    {lastSmsAtMs: now - 61_000, windowStartMs: now - 61_000, sendsInWindow: 1},
    now,
  );
  assert.equal(afterCooldown.allowed, true);
  assert.equal(afterCooldown.next.sendsInWindow, 2);
});

test("evaluateSendLimit enforces five sends per hour", () => {
  const now = 1_700_000_000_000;
  const fiveSends = {
    lastSmsAtMs: now - 120_000,
    windowStartMs: now - 120_000,
    sendsInWindow: 5,
  };
  const blocked = h.evaluateSendLimit(fiveSends, now);
  assert.equal(blocked.allowed, false);
  assert.ok(blocked.resendInSeconds > 3000 && blocked.resendInSeconds <= 3600);

  // Window rolled past the hour → allowed, counter resets.
  const rolled = h.evaluateSendLimit(
    {lastSmsAtMs: now - 120_000, windowStartMs: now - 3_600_001, sendsInWindow: 5},
    now,
  );
  assert.equal(rolled.allowed, true);
  assert.equal(rolled.next.sendsInWindow, 1);
  assert.equal(rolled.next.windowStartMs, now);
});

test("evaluateSendLimit four sends in-window plus elapsed cooldown allows the fifth", () => {
  const now = 1_700_000_000_000;
  const decision = h.evaluateSendLimit(
    {lastSmsAtMs: now - 61_000, windowStartMs: now - 3_000_000, sendsInWindow: 4},
    now,
  );
  assert.equal(decision.allowed, true);
  assert.equal(decision.next.sendsInWindow, 5);
});

test("evaluateIpLimit allows headroom then blocks", () => {
  const now = 1_700_000_000_000;
  const ok = h.evaluateIpLimit({windowStartMs: now - 1000, startsInWindow: 29}, now);
  assert.equal(ok.allowed, true);
  assert.equal(ok.next.startsInWindow, 30);

  const blocked = h.evaluateIpLimit({windowStartMs: now - 1000, startsInWindow: 30}, now);
  assert.equal(blocked.allowed, false);
  assert.ok(blocked.resendInSeconds > 3000);

  const rolled = h.evaluateIpLimit({windowStartMs: now - 3_600_001, startsInWindow: 99}, now);
  assert.equal(rolled.allowed, true);
  assert.equal(rolled.next.startsInWindow, 1);
});

test("normalizePhone normalizes international numbers (US, UK, UAE, etc.) to canonical E.164", () => {
  // US numbers
  assert.equal(h.normalizePhone("+12025550123"), "+12025550123");
  assert.equal(h.normalizePhone("0012025550123"), "+12025550123");
  assert.equal(h.normalizePhone("+1 (202) 555-0123"), "+12025550123");
  assert.equal(h.normalizePhone("2025550123", "+1"), "+12025550123");

  // UK numbers
  assert.equal(h.normalizePhone("+447911123456"), "+447911123456");
  assert.equal(h.normalizePhone("00447911123456"), "+447911123456");
  assert.equal(h.normalizePhone("07911123456", "+44"), "+447911123456");

  // UAE numbers
  assert.equal(h.normalizePhone("+971501234567"), "+971501234567");
  assert.equal(h.normalizePhone("0501234567", "+971"), "+971501234567");

  // Pakistan backward compatibility
  assert.equal(h.normalizePhone("03451234567"), "+923451234567");
  assert.equal(h.normalizePhone("+923451234567"), "+923451234567");
  assert.equal(h.normalizePhone("3451234567", "+92"), "+923451234567");
});

test("normalizePhone rejects invalid or malformed numbers", () => {
  assert.equal(h.normalizePhone(""), null);
  assert.equal(h.normalizePhone("   "), null);
  assert.equal(h.normalizePhone(null), null);
  assert.equal(h.normalizePhone("123"), null); // too short
  assert.equal(h.normalizePhone("+0123456789"), null); // invalid leading 0 in country code
  assert.equal(h.normalizePhone("abcdefgh"), null);
});

test("phoneLookupVariants supports international accounts while preserving PK variants", () => {
  // US variants
  const usVariants = h.phoneLookupVariants("+12025550123");
  assert.ok(usVariants.includes("+12025550123"));
  assert.ok(usVariants.includes("12025550123"));
  assert.ok(usVariants.includes("0012025550123"));

  // UK variants (includes domestic 0 trunk)
  const ukVariants = h.phoneLookupVariants("+447911123456");
  assert.ok(ukVariants.includes("+447911123456"));
  assert.ok(ukVariants.includes("447911123456"));
  assert.ok(ukVariants.includes("07911123456"));

  // PK variants
  const pkVariants = h.phoneLookupVariants("+923451234567");
  assert.ok(pkVariants.includes("03451234567"));
  assert.ok(pkVariants.includes("+923451234567"));
  assert.ok(pkVariants.includes("923451234567"));
  assert.ok(pkVariants.includes("3451234567"));
});
