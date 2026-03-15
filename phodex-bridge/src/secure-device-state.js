// FILE: secure-device-state.js
// Purpose: Persists canonical bridge identity and trusted-phone state for local QR pairing.
// Layer: CLI helper
// Exports: loadOrCreateBridgeDeviceState, resetBridgeDeviceState, rememberTrustedPhone, getTrustedPhonePublicKey, resolveBridgeRelaySession
// Depends on: fs, os, path, crypto, child_process

const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomUUID, generateKeyPairSync } = require("crypto");
const { execFileSync } = require("child_process");

const DEFAULT_STORE_DIR = path.join(os.homedir(), ".remodex");
const DEFAULT_STORE_FILE = path.join(DEFAULT_STORE_DIR, "device-state.json");
const KEYCHAIN_SERVICE = "com.remodex.bridge.device-state";
const KEYCHAIN_ACCOUNT = "default";
let hasLoggedKeychainMismatch = false;

// Loads the canonical bridge state or bootstraps a fresh one when no trusted state exists yet.
function loadOrCreateBridgeDeviceState() {
  const fileRecord = readCanonicalFileStateRecord();
  if (fileRecord.error) {
    throw corruptedStateError("device-state.json", fileRecord.error);
  }

  const keychainRecord = readKeychainStateRecord();

  if (fileRecord.state) {
    reconcileLegacyKeychainMirror(fileRecord.state, keychainRecord);
    return fileRecord.state;
  }

  if (keychainRecord.error) {
    throw corruptedStateError("legacy Keychain bridge state", keychainRecord.error);
  }

  if (keychainRecord.state) {
    writeBridgeDeviceState(keychainRecord.state);
    return keychainRecord.state;
  }

  const nextState = createBridgeDeviceState();
  writeBridgeDeviceState(nextState);
  return nextState;
}

// Removes the saved bridge identity/trust state so the next `remodex up` requires a fresh QR pairing.
function resetBridgeDeviceState() {
  const removedCanonicalFile = deleteCanonicalFileState();
  const removedKeychainMirror = deleteKeychainStateString();
  return {
    hadState: removedCanonicalFile || removedKeychainMirror,
    removedCanonicalFile,
    removedKeychainMirror,
  };
}

// Generates a fresh relay session for every bridge launch so QR pairing stays explicit per-run.
function resolveBridgeRelaySession(state, { persist = true } = {}) {
  return {
    deviceState: state,
    isPersistent: false,
    sessionId: randomUUID(),
  };
}

// Persists the trusted iPhone identity so reconnects can be authenticated during the current pairing flow.
function rememberTrustedPhone(state, phoneDeviceId, phoneIdentityPublicKey, { persist = true } = {}) {
  const normalizedDeviceId = normalizeNonEmptyString(phoneDeviceId);
  const normalizedPublicKey = normalizeNonEmptyString(phoneIdentityPublicKey);
  if (!normalizedDeviceId || !normalizedPublicKey) {
    return state;
  }

  // Remodex supports one trusted iPhone per Mac, so a new trust record replaces old ones.
  const nextState = normalizeBridgeDeviceState({
    ...state,
    trustedPhones: {
      [normalizedDeviceId]: normalizedPublicKey,
    },
  });
  if (persist) {
    writeBridgeDeviceState(nextState);
  }
  return nextState;
}

function getTrustedPhonePublicKey(state, phoneDeviceId) {
  const normalizedDeviceId = normalizeNonEmptyString(phoneDeviceId);
  if (!normalizedDeviceId) {
    return null;
  }
  return state.trustedPhones?.[normalizedDeviceId] || null;
}

function hasTrustedPhones(state) {
  return Object.keys(state?.trustedPhones || {}).length > 0;
}

function createBridgeDeviceState() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const privateJwk = privateKey.export({ format: "jwk" });
  const publicJwk = publicKey.export({ format: "jwk" });

  return {
    version: 1,
    macDeviceId: randomUUID(),
    macIdentityPublicKey: base64UrlToBase64(publicJwk.x),
    macIdentityPrivateKey: base64UrlToBase64(privateJwk.d),
    trustedPhones: {},
  };
}

// Reads the canonical file-backed state and distinguishes "missing" from "corrupted".
function readCanonicalFileStateRecord() {
  const storeFile = resolveStoreFile();
  if (!fs.existsSync(storeFile)) {
    return { state: null, error: null };
  }

  try {
    return {
      state: normalizeBridgeDeviceState(JSON.parse(fs.readFileSync(storeFile, "utf8"))),
      error: null,
    };
  } catch (error) {
    return { state: null, error };
  }
}

// Reads the legacy Keychain mirror so old installs can be migrated into the canonical file.
function readKeychainStateRecord() {
  const rawState = readKeychainStateString();
  if (!rawState) {
    return { state: null, error: null };
  }

  try {
    return {
      state: normalizeBridgeDeviceState(JSON.parse(rawState)),
      error: null,
    };
  } catch (error) {
    return { state: null, error };
  }
}

function writeBridgeDeviceState(state) {
  const serialized = JSON.stringify(state, null, 2);
  writeCanonicalFileStateString(serialized);
  writeKeychainStateString(serialized);
}

// Keeps the canonical file updated even when the optional Keychain mirror is unavailable.
function writeCanonicalFileStateString(serialized) {
  const storeDir = resolveStoreDir();
  const storeFile = resolveStoreFile();
  fs.mkdirSync(storeDir, { recursive: true });
  fs.writeFileSync(storeFile, serialized, { mode: 0o600 });
  try {
    fs.chmodSync(storeFile, 0o600);
  } catch {
    // Best-effort only on filesystems that support POSIX modes.
  }
}

function resolveStoreDir() {
  return normalizeNonEmptyString(process.env.REMODEX_DEVICE_STATE_DIR) || DEFAULT_STORE_DIR;
}

function resolveStoreFile() {
  return normalizeNonEmptyString(process.env.REMODEX_DEVICE_STATE_FILE)
    || path.join(resolveStoreDir(), "device-state.json");
}

function resolveKeychainMirrorFile() {
  return normalizeNonEmptyString(process.env.REMODEX_DEVICE_STATE_KEYCHAIN_MOCK_FILE);
}

function readKeychainStateString() {
  const keychainMirrorFile = resolveKeychainMirrorFile();
  if (keychainMirrorFile) {
    try {
      return fs.readFileSync(keychainMirrorFile, "utf8");
    } catch {
      return null;
    }
  }

  if (process.platform !== "darwin") {
    return null;
  }

  try {
    return execFileSync(
      "security",
      [
        "find-generic-password",
        "-s",
        KEYCHAIN_SERVICE,
        "-a",
        KEYCHAIN_ACCOUNT,
        "-w",
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
  } catch {
    return null;
  }
}

function writeKeychainStateString(value) {
  const keychainMirrorFile = resolveKeychainMirrorFile();
  if (keychainMirrorFile) {
    try {
      fs.mkdirSync(path.dirname(keychainMirrorFile), { recursive: true });
      fs.writeFileSync(keychainMirrorFile, value, { mode: 0o600 });
      return true;
    } catch {
      return false;
    }
  }

  if (process.platform !== "darwin") {
    return false;
  }

  try {
    execFileSync(
      "security",
      [
        "add-generic-password",
        "-U",
        "-s",
        KEYCHAIN_SERVICE,
        "-a",
        KEYCHAIN_ACCOUNT,
        "-w",
        value,
      ],
      { stdio: ["ignore", "ignore", "ignore"] }
    );
    return true;
  } catch {
    return false;
  }
}

function deleteKeychainStateString() {
  const keychainMirrorFile = resolveKeychainMirrorFile();
  if (keychainMirrorFile) {
    const existed = fs.existsSync(keychainMirrorFile);
    try {
      fs.rmSync(keychainMirrorFile, { force: true });
      return existed;
    } catch {
      return false;
    }
  }

  if (process.platform !== "darwin") {
    return false;
  }

  try {
    execFileSync(
      "security",
      [
        "delete-generic-password",
        "-s",
        KEYCHAIN_SERVICE,
        "-a",
        KEYCHAIN_ACCOUNT,
      ],
      { stdio: ["ignore", "ignore", "ignore"] }
    );
    return true;
  } catch {
    return false;
  }
}

function deleteCanonicalFileState() {
  const storeFile = resolveStoreFile();
  const existed = fs.existsSync(storeFile);
  try {
    fs.rmSync(storeFile, { force: true });
    return existed;
  } catch {
    return false;
  }
}

// Prefers the canonical file, but repairs or warns about stale legacy Keychain mirrors.
function reconcileLegacyKeychainMirror(canonicalState, keychainRecord) {
  if (keychainRecord.error) {
    warnOnce("[remodex] Ignoring unreadable legacy Keychain pairing mirror; using canonical device-state.json.");
    return;
  }

  if (!keychainRecord.state) {
    writeKeychainStateString(JSON.stringify(canonicalState, null, 2));
    return;
  }

  if (bridgeStatesEqual(canonicalState, keychainRecord.state)) {
    return;
  }

  warnOnce("[remodex] Canonical bridge pairing state differs from the legacy Keychain mirror; using device-state.json.");
  writeKeychainStateString(JSON.stringify(canonicalState, null, 2));
}

function normalizeBridgeDeviceState(rawState) {
  const macDeviceId = normalizeNonEmptyString(rawState?.macDeviceId);
  const macIdentityPublicKey = normalizeNonEmptyString(rawState?.macIdentityPublicKey);
  const macIdentityPrivateKey = normalizeNonEmptyString(rawState?.macIdentityPrivateKey);

  if (!macDeviceId || !macIdentityPublicKey || !macIdentityPrivateKey) {
    throw new Error("Bridge device state is incomplete");
  }

  const trustedPhones = {};
  if (rawState?.trustedPhones && typeof rawState.trustedPhones === "object") {
    for (const [deviceId, publicKey] of Object.entries(rawState.trustedPhones)) {
      const normalizedDeviceId = normalizeNonEmptyString(deviceId);
      const normalizedPublicKey = normalizeNonEmptyString(publicKey);
      if (!normalizedDeviceId || !normalizedPublicKey) {
        continue;
      }
      trustedPhones[normalizedDeviceId] = normalizedPublicKey;
    }
  }

  return {
    version: 1,
    macDeviceId,
    macIdentityPublicKey,
    macIdentityPrivateKey,
    trustedPhones,
  };
}

function bridgeStatesEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function normalizeNonEmptyString(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim();
}

function corruptedStateError(source, error) {
  const detail = normalizeNonEmptyString(error?.message);
  return new Error(
    `The saved Remodex pairing state in ${source} is unreadable. `
      + "Run `remodex reset-pairing` to start fresh."
      + (detail ? ` (${detail})` : "")
  );
}

function warnOnce(message) {
  if (hasLoggedKeychainMismatch) {
    return;
  }
  hasLoggedKeychainMismatch = true;
  console.warn(message);
}

function base64UrlToBase64(value) {
  if (typeof value !== "string" || value.length === 0) {
    return "";
  }

  const padded = `${value}${"=".repeat((4 - (value.length % 4 || 4)) % 4)}`;
  return padded.replace(/-/g, "+").replace(/_/g, "/");
}

module.exports = {
  getTrustedPhonePublicKey,
  loadOrCreateBridgeDeviceState,
  rememberTrustedPhone,
  resetBridgeDeviceState,
  resolveBridgeRelaySession,
};
