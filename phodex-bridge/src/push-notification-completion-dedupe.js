// FILE: push-notification-completion-dedupe.js
// Purpose: Persists bounded successful completion identities and guards in-flight sends.
// Layer: Bridge helper
// Exports: createPushNotificationCompletionDedupe
// Depends on: fs, os, path

const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_COMPLETION_STATE_PATH = path.join(
  os.homedir(),
  ".remodex",
  "completion-push-state.json"
);
const MAX_COMPLETION_ENTRIES = 1_000;

function createPushNotificationCompletionDedupe({
  statePath = DEFAULT_COMPLETION_STATE_PATH,
  logPrefix = "[remodex]",
} = {}) {
  const successfulKeys = loadSuccessfulKeys(statePath, logPrefix);
  const inFlightKeys = new Set();

  function hasSuccessfulNotification(dedupeKey) {
    return successfulKeys.has(readString(dedupeKey));
  }

  function beginNotification(dedupeKey) {
    const key = readString(dedupeKey);
    if (!key || successfulKeys.has(key) || inFlightKeys.has(key)) {
      return false;
    }
    inFlightKeys.add(key);
    return true;
  }

  function commitNotification(dedupeKey) {
    const key = readString(dedupeKey);
    if (!key) {
      return;
    }
    inFlightKeys.delete(key);
    successfulKeys.delete(key);
    successfulKeys.add(key);
    while (successfulKeys.size > MAX_COMPLETION_ENTRIES) {
      successfulKeys.delete(successfulKeys.values().next().value);
    }
    saveSuccessfulKeys(statePath, successfulKeys, logPrefix);
  }

  function abortNotification(dedupeKey) {
    inFlightKeys.delete(readString(dedupeKey));
  }

  return {
    abortNotification,
    beginNotification,
    commitNotification,
    hasSuccessfulNotification,
  };
}

function loadSuccessfulKeys(filePath, logPrefix) {
  if (!filePath) {
    return new Set();
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const entries = Array.isArray(parsed?.successfulCompletionKeys)
      ? parsed.successfulCompletionKeys.map(readString).filter(Boolean)
      : [];
    return new Set(entries.slice(-MAX_COMPLETION_ENTRIES));
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.error(`${logPrefix} failed to load completion push state: ${error.message}`);
    }
    return new Set();
  }
}

function saveSuccessfulKeys(filePath, successfulKeys, logPrefix) {
  if (!filePath) {
    return;
  }

  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const temporaryPath = `${filePath}.tmp`;
    fs.writeFileSync(temporaryPath, JSON.stringify({
      successfulCompletionKeys: [...successfulKeys],
    }), {
      encoding: "utf8",
      mode: 0o600,
    });
    fs.renameSync(temporaryPath, filePath);
    try {
      fs.chmodSync(filePath, 0o600);
    } catch {
      // Best effort on filesystems without POSIX modes.
    }
  } catch (error) {
    console.error(`${logPrefix} failed to save completion push state: ${error.message}`);
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  createPushNotificationCompletionDedupe,
};
