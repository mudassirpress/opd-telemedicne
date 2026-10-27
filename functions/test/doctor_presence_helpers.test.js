const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
    DEFAULT_HEARTBEAT_TIMEOUT_MS,
    parseTimestampMillis,
    isHeartbeatFresh,
    evaluateDoctorEligibility,
    computeEffectiveStatus,
    buildProbePushPayload,
} = require("../lib/presence/doctor_presence_helpers.js");

describe("Doctor Presence Helpers", () => {
    it("parseTimestampMillis parses numbers, Dates, Firestore Timestamps and ISO strings", () => {
        const now = 1700000000000;
        assert.equal(parseTimestampMillis(now), now);
        assert.equal(parseTimestampMillis(new Date(now)), now);
        assert.equal(parseTimestampMillis({ toMillis: () => now }), now);
        assert.equal(parseTimestampMillis({ toDate: () => new Date(now) }), now);
        assert.equal(parseTimestampMillis(new Date(now).toISOString()), now);
        assert.equal(parseTimestampMillis(null), null);
        assert.equal(parseTimestampMillis("invalid-date"), null);
    });

    it("isHeartbeatFresh accurately calculates freshness within timeout window", () => {
        const now = 1700000000000;
        const fresh = now - 30 * 1000; // 30s ago
        const stale = now - 70 * 1000; // 70s ago

        assert.equal(isHeartbeatFresh(fresh, now, 60 * 1000), true);
        assert.equal(isHeartbeatFresh(stale, now, 60 * 1000), false);
        assert.equal(isHeartbeatFresh(null, now, 60 * 1000), false);
    });

    it("evaluateDoctorEligibility enforces the manual/account rules strictly", () => {
        const now = 1700000000000;
        const freshHeartbeat = now - 15 * 1000;

        const baseDoctor = {
            manualAvailability: true,
            isActive: true,
            isDeleted: false,
            isSuspended: false,
            accountStatus: "Active",
            lastHeartbeat: freshHeartbeat,
        };

        // 1. All valid -> Eligible
        assert.deepEqual(evaluateDoctorEligibility(baseDoctor, now), { eligible: true, reason: null });

        // 2. Manual toggle OFF -> Ineligible
        assert.equal(evaluateDoctorEligibility({ ...baseDoctor, manualAvailability: false }, now).eligible, false);

        // 3. Inactive account -> Ineligible
        assert.equal(evaluateDoctorEligibility({ ...baseDoctor, isActive: false }, now).eligible, false);

        // 4. Soft-deleted account -> Ineligible
        assert.equal(evaluateDoctorEligibility({ ...baseDoctor, isDeleted: true }, now).eligible, false);

        // 5. Suspended account -> Ineligible
        assert.equal(evaluateDoctorEligibility({ ...baseDoctor, isSuspended: true }, now).eligible, false);

        // 6. Suspended accountStatus -> Ineligible
        assert.equal(evaluateDoctorEligibility({ ...baseDoctor, accountStatus: "Suspended" }, now).eligible, false);

        // 7. Heartbeat age MUST NOT cancel manual ONLINE duty. A backgrounded
        // app stops sending heartbeats; reachability is proven by FCM instead.
        const staleHeartbeat = now - 75 * 1000;
        assert.deepEqual(
            evaluateDoctorEligibility({ ...baseDoctor, lastHeartbeat: staleHeartbeat }, now),
            { eligible: true, reason: null }
        );
        assert.deepEqual(
            evaluateDoctorEligibility({ ...baseDoctor, lastHeartbeat: null, lastSeen: null }, now),
            { eligible: true, reason: null }
        );
    });

    it("computeEffectiveStatus returns BUSY when active call exists", () => {
        const now = 1700000000000;
        const doctor = {
            manualAvailability: true,
            isActive: true,
            accountStatus: "Active",
            lastHeartbeat: now - 10 * 1000,
            activeCallId: "call_active_123",
        };
        assert.equal(computeEffectiveStatus(doctor, now), "BUSY");
    });

    it("computeEffectiveStatus returns ONLINE only when all criteria pass", () => {
        const now = 1700000000000;
        const onlineDoctor = {
            manualAvailability: true,
            isActive: true,
            accountStatus: "Active",
            lastHeartbeat: now - 10 * 1000,
        };
        assert.equal(computeEffectiveStatus(onlineDoctor, now), "ONLINE");

        const offlineDoctor = {
            ...onlineDoctor,
            manualAvailability: false,
        };
        assert.equal(computeEffectiveStatus(offlineDoctor, now), "OFFLINE");
    });

    it("buildProbePushPayload creates compliant High-Priority short-TTL message", () => {
        const payload = buildProbePushPayload({
            token: "fcm_test_token_123",
            callId: "call_abc",
            probeId: "probe_xyz",
            callerId: "patient_1",
            callerName: "Jane Doe",
            callType: "video",
            channelId: "room_call_abc",
        });

        assert.equal(payload.token, "fcm_test_token_123");
        assert.equal(payload.data.type, "call_probe");
        assert.equal(payload.data.probeId, "probe_xyz");
        assert.equal(payload.data.callId, "call_abc");
        assert.equal(payload.android.priority, "high");
        assert.equal(payload.android.ttl, "5s");
        assert.equal(payload.apns.headers["apns-priority"], "10");
        assert.equal(payload.apns.payload.aps["content-available"], 1);
        // Ensure no notification block that would trigger OS heads-up banner during probe
        assert.equal(payload.notification, undefined);
    });
});
