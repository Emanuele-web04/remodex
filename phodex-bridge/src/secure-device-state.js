// FILE: secure-device-state.js
// Purpose: Persists the bridge device identity and trusted phone registry for E2EE pairing.
// Layer: CLI helper
// Exports: loadOrCreateBridgeDeviceState, rememberTrustedPhone, getTrustedPhonePublicKey
// Depends on: fs, os, path, crypto, child_process

const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomUUID, generateKeyPairSync } = require("crypto");
const { execFileSync } = require("child_process");

const STORE_DIR = path.join(os.homedir(), ".remodex");
const STORE_FILE = path.join(STORE_DIR, "device-state.json");
const KEYCHAIN_SERVICE = "com.remodex.bridge.device-state";
const KEYCHAIN_ACCOUNT = "default";

function loadOrCreateBridgeDeviceState() {
  const existingState = readBridgeDeviceState();
  if (existingState) {
    return existingState;
  }

  const nextState = createBridgeDeviceState();
  writeBridgeDeviceState(nextState);
  return nextState;
}

function rememberTrustedPhone(state, phoneDeviceId, phoneIdentityPublicKey) {
  const normalizedDeviceId = normalizeNonEmptyString(phoneDeviceId);
  const normalizedPublicKey = normalizeNonEmptyString(phoneIdentityPublicKey);
  if (!normalizedDeviceId || !normalizedPublicKey) {
    return state;
  }

  // Remodex supports one trusted iPhone per Mac, so a new trust record replaces old ones.
  const nextState = {
    ...state,
    trustedPhones: {
      [normalizedDeviceId]: normalizedPublicKey,
    },
  };
  writeBridgeDeviceState(nextState);
  return nextState;
}

function getTrustedPhonePublicKey(state, phoneDeviceId) {
  const normalizedDeviceId = normalizeNonEmptyString(phoneDeviceId);
  if (!normalizedDeviceId) {
    return null;
  }
  return state.trustedPhones?.[normalizedDeviceId] || null;
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

function readBridgeDeviceState() {
  const rawState = readStoredDeviceStateString();
  if (!rawState) {
    return null;
  }

  try {
    return normalizeBridgeDeviceState(JSON.parse(rawState));
  } catch {
    return null;
  }
}

function writeBridgeDeviceState(state) {
  const serialized = JSON.stringify(state, null, 2);
  if (process.platform === "darwin" && writeKeychainStateString(serialized)) {
    return;
  }

  fs.mkdirSync(STORE_DIR, { recursive: true });
  fs.writeFileSync(STORE_FILE, serialized, { mode: 0o600 });
  try {
    fs.chmodSync(STORE_FILE, 0o600);
  } catch {
    // Best-effort only on filesystems that support POSIX modes.
  }
}

function readStoredDeviceStateString() {
  if (process.platform === "darwin") {
    const keychainValue = readKeychainStateString();
    if (keychainValue) {
      return keychainValue;
    }
  }

  if (!fs.existsSync(STORE_FILE)) {
    return null;
  }

  try {
    return fs.readFileSync(STORE_FILE, "utf8");
  } catch {
    return null;
  }
}

function readKeychainStateString() {
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

function normalizeNonEmptyString(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim();
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
};
