// FILE: secure-device-state.test.js
// Purpose: Verifies trusted bridge pairings keep a stable relay session id across restarts.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/secure-device-state

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  rememberTrustedPhone,
  resolveBridgeRelaySession,
} = require("../src/secure-device-state");

// ─── Relay Session Persistence ───────────────────────────────

test("resolveBridgeRelaySession reuses the stored relay session for a trusted phone", () => {
  const state = makeDeviceState({
    relaySessionId: "session-trusted",
    trustedPhones: {
      "phone-1": "phone-public-key-1",
    },
  });

  const resolved = resolveBridgeRelaySession(state, { persist: false });

  assert.equal(resolved.isPersistent, true);
  assert.equal(resolved.sessionId, "session-trusted");
  assert.equal(resolved.deviceState.relaySessionId, "session-trusted");
});

test("resolveBridgeRelaySession provisions a stable relay session once trust exists", () => {
  const state = makeDeviceState({
    trustedPhones: {
      "phone-2": "phone-public-key-2",
    },
  });

  const resolved = resolveBridgeRelaySession(state, { persist: false });

  assert.equal(resolved.isPersistent, true);
  assert.ok(resolved.sessionId);
  assert.equal(resolved.deviceState.relaySessionId, resolved.sessionId);
});

test("resolveBridgeRelaySession keeps untrusted QR sessions ephemeral", () => {
  const state = makeDeviceState({
    relaySessionId: "stale-session",
    trustedPhones: {},
  });

  const resolved = resolveBridgeRelaySession(state, { persist: false });

  assert.equal(resolved.isPersistent, false);
  assert.ok(resolved.sessionId);
  assert.notEqual(resolved.sessionId, "stale-session");
  assert.equal(resolved.deviceState.relaySessionId, undefined);
});

test("rememberTrustedPhone stores the relay session id alongside the trust record", () => {
  const state = makeDeviceState();

  const nextState = rememberTrustedPhone(
    state,
    "phone-3",
    "phone-public-key-3",
    "session-persisted",
    { persist: false }
  );

  assert.deepEqual(nextState.trustedPhones, {
    "phone-3": "phone-public-key-3",
  });
  assert.equal(nextState.relaySessionId, "session-persisted");
});

function makeDeviceState(overrides = {}) {
  return {
    version: 1,
    macDeviceId: "mac-device-id",
    macIdentityPublicKey: "mac-public-key",
    macIdentityPrivateKey: "mac-private-key",
    relaySessionId: undefined,
    trustedPhones: {},
    ...overrides,
  };
}
