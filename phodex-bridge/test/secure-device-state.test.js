// FILE: secure-device-state.test.js
// Purpose: Verifies canonical bridge-state persistence, migration, and reset behavior.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/secure-device-state

const fs = require("fs");
const os = require("os");
const path = require("path");
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  loadOrCreateBridgeDeviceState,
  readBridgeDeviceState,
  rememberLastSeenPhoneAppVersion,
  rememberTrustedPhone,
  resetBridgeDeviceState,
  resolveBridgeRelaySession,
} = require("../src/secure-device-state");

// ─── Relay Session Resolution ───────────────────────────────

test("resolveBridgeRelaySession always creates a fresh relay session", () => {
  const state = makeDeviceState({
    trustedPhones: {
      "phone-1": "phone-public-key-1",
    },
  });

  const resolved = resolveBridgeRelaySession(state, { persist: false });

  assert.equal(resolved.isPersistent, false);
  assert.ok(resolved.sessionId);
  assert.deepEqual(resolved.deviceState, state);
});

test("rememberTrustedPhone stores the trusted phone identity", () => {
  const state = makeDeviceState();

  const nextState = rememberTrustedPhone(
    state,
    "phone-3",
    "phone-public-key-3",
    { persist: false }
  );

  assert.deepEqual(nextState.trustedPhones, {
    "phone-3": "phone-public-key-3",
  });
});

test("rememberLastSeenPhoneAppVersion stores the latest App Store version", () => {
  const state = makeDeviceState();

  const nextState = rememberLastSeenPhoneAppVersion(
    state,
    "1.0",
    { persist: false }
  );

  assert.equal(nextState.lastSeenPhoneAppVersion, "1.0");
});

test("loadOrCreateBridgeDeviceState writes and reloads the canonical file state", () => {
  withTempDeviceStateEnv(() => {
    const firstState = loadOrCreateBridgeDeviceState();
    const secondState = loadOrCreateBridgeDeviceState();

    assert.deepEqual(secondState, firstState);
    assert.deepEqual(readCanonicalStateFromDisk(), stripUndefined(firstState));
  });
});

test("readBridgeDeviceState returns null before the first pairing state exists", () => {
  withTempDeviceStateEnv(() => {
    assert.equal(readBridgeDeviceState(), null);
  });
});

test("loadOrCreateBridgeDeviceState migrates a valid Keychain mirror into the canonical file", () => {
  withTempDeviceStateEnv(({ keychainMirrorFile, canonicalStateFile }) => {
    const migratedState = makeDeviceState({
      trustedPhones: {
        "phone-4": "phone-public-key-4",
      },
    });
    fs.writeFileSync(keychainMirrorFile, JSON.stringify(migratedState, null, 2));

    const loadedState = loadOrCreateBridgeDeviceState();

    assert.deepEqual(loadedState, migratedState);
    assert.deepEqual(readCanonicalStateFromDisk(), migratedState);
    assert.equal(fs.existsSync(canonicalStateFile), true);
  });
});

test("loadOrCreateBridgeDeviceState replaces a corrupted legacy Keychain mirror with a fresh canonical state", () => {
  withTempDeviceStateEnv(({ keychainMirrorFile, canonicalStateFile }) => {
    fs.writeFileSync(keychainMirrorFile, "{ definitely-not-json", "utf8");

    const loadedState = loadOrCreateBridgeDeviceState();

    assert.equal(loadedState.version, 1);
    assert.ok(loadedState.macDeviceId);
    assert.ok(loadedState.macIdentityPublicKey);
    assert.ok(loadedState.macIdentityPrivateKey);
    assert.deepEqual(loadedState.trustedPhones, {});
    assert.deepEqual(readCanonicalStateFromDisk(), stripUndefined(loadedState));
    assert.deepEqual(
      JSON.parse(fs.readFileSync(keychainMirrorFile, "utf8")),
      stripUndefined(loadedState)
    );
    assert.equal(fs.existsSync(canonicalStateFile), true);
  });
});

test("loadOrCreateBridgeDeviceState recovers a corrupted canonical file from a valid Keychain mirror", () => {
  withTempDeviceStateEnv(({ canonicalStateFile, keychainMirrorFile }) => {
    const mirroredState = makeDeviceState({
      trustedPhones: {
        "phone-7": "phone-public-key-7",
      },
    });
    fs.mkdirSync(path.dirname(canonicalStateFile), { recursive: true });
    fs.writeFileSync(canonicalStateFile, "{ definitely-not-json", "utf8");
    fs.writeFileSync(keychainMirrorFile, JSON.stringify(mirroredState, null, 2));

    const loadedState = loadOrCreateBridgeDeviceState();

    assert.deepEqual(loadedState, mirroredState);
    assert.deepEqual(readCanonicalStateFromDisk(), mirroredState);
  });
});

test("loadOrCreateBridgeDeviceState throws when the canonical file is corrupted and no fallback exists", () => {
  withTempDeviceStateEnv(({ canonicalStateFile }) => {
    fs.mkdirSync(path.dirname(canonicalStateFile), { recursive: true });
    fs.writeFileSync(canonicalStateFile, "{ definitely-not-json", "utf8");

    assert.throws(
      () => loadOrCreateBridgeDeviceState(),
      /saved Remodex pairing state in device-state\.json is unreadable/i
    );
  });
});

test("resolveBridgeRelaySession does not persist the fresh launch session id", () => {
  withTempDeviceStateEnv(() => {
    const trustedState = rememberTrustedPhone(
      makeDeviceState(),
      "phone-5",
      "phone-public-key-5",
      { persist: true }
    );

    const resolved = resolveBridgeRelaySession(trustedState);
    const reloaded = loadOrCreateBridgeDeviceState();

    assert.equal(resolved.isPersistent, false);
    assert.equal(reloaded.macDeviceId, trustedState.macDeviceId);
    assert.deepEqual(reloaded.trustedPhones, {
      "phone-5": "phone-public-key-5",
    });
  });
});

test("rememberLastSeenPhoneAppVersion persists across reloads", () => {
  withTempDeviceStateEnv(() => {
    rememberLastSeenPhoneAppVersion(
      makeDeviceState(),
      "1.1",
      { persist: true }
    );

    const reloaded = loadOrCreateBridgeDeviceState();
    assert.equal(reloaded.lastSeenPhoneAppVersion, "1.1");
  });
});

test("resetBridgeDeviceState removes both canonical and mirrored pairing state", () => {
  withTempDeviceStateEnv(({ keychainMirrorFile, canonicalStateFile }) => {
    const state = makeDeviceState({
      trustedPhones: {
        "phone-6": "phone-public-key-6",
      },
    });
    fs.mkdirSync(path.dirname(canonicalStateFile), { recursive: true });
    fs.writeFileSync(canonicalStateFile, JSON.stringify(state, null, 2));
    fs.writeFileSync(keychainMirrorFile, JSON.stringify(state, null, 2));

    const result = resetBridgeDeviceState();

    assert.equal(result.hadState, true);
    assert.equal(fs.existsSync(canonicalStateFile), false);
    assert.equal(fs.existsSync(keychainMirrorFile), false);
  });
});

function makeDeviceState(overrides = {}) {
  return {
    version: 1,
    macDeviceId: "mac-device-id",
    macIdentityPublicKey: "mac-public-key",
    macIdentityPrivateKey: "mac-private-key",
    trustedPhones: {},
    lastSeenPhoneAppVersion: null,
    ...overrides,
  };
}

function withTempDeviceStateEnv(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const previousMirror = process.env.REMODEX_DEVICE_STATE_KEYCHAIN_MOCK_FILE;
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-device-state-"));
  const canonicalStateFile = path.join(tempRoot, "device-state.json");
  const keychainMirrorFile = path.join(tempRoot, "keychain-device-state.json");

  process.env.REMODEX_DEVICE_STATE_DIR = tempRoot;
  process.env.REMODEX_DEVICE_STATE_KEYCHAIN_MOCK_FILE = keychainMirrorFile;

  try {
    return run({ canonicalStateFile, keychainMirrorFile });
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }

    if (previousMirror === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_KEYCHAIN_MOCK_FILE;
    } else {
      process.env.REMODEX_DEVICE_STATE_KEYCHAIN_MOCK_FILE = previousMirror;
    }

    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function readCanonicalStateFromDisk() {
  const canonicalStateFile = path.join(process.env.REMODEX_DEVICE_STATE_DIR, "device-state.json");
  return JSON.parse(fs.readFileSync(canonicalStateFile, "utf8"));
}

function stripUndefined(value) {
  return JSON.parse(JSON.stringify(value));
}
