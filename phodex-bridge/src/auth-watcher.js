// FILE: auth-watcher.js
// Purpose: Watches ~/.codex/auth.json for credential changes and triggers a callback when the content hash changes.
// Layer: CLI helper
// Exports: createAuthWatcher
// Depends on: fs, path, crypto, os

const fs = require("fs");
const path = require("path");
const { createHash } = require("crypto");
const os = require("os");

const AUTH_FILE = path.join(os.homedir(), ".codex", "auth.json");
const DEBOUNCE_MS = 1500;

function hashFileContents(filePath) {
  try {
    const data = fs.readFileSync(filePath, "utf8");
    return createHash("sha256").update(data).digest("hex");
  } catch {
    return null;
  }
}

function createAuthWatcher({ onAuthChanged, logPrefix = "[remodex]" } = {}) {
  if (typeof onAuthChanged !== "function") {
    throw new Error("createAuthWatcher requires an onAuthChanged callback.");
  }

  let lastHash = hashFileContents(AUTH_FILE);
  let debounceTimer = null;
  let watcher = null;
  let isReloading = false;

  function handleChange() {
    if (debounceTimer) {
      clearTimeout(debounceTimer);
    }

    debounceTimer = setTimeout(async () => {
      debounceTimer = null;
      const currentHash = hashFileContents(AUTH_FILE);
      if (currentHash === lastHash) {
        return;
      }

      if (currentHash === null) {
        console.log(`${logPrefix} auth.json was removed; skipping reload.`);
        return;
      }

      if (isReloading) {
        console.log(`${logPrefix} auth reload already in progress; skipping.`);
        return;
      }

      lastHash = currentHash;
      isReloading = true;
      console.log(`${logPrefix} auth.json changed — reloading Codex transport...`);
      try {
        await onAuthChanged();
        console.log(`${logPrefix} Codex transport reloaded successfully.`);
      } catch (error) {
        console.error(`${logPrefix} Failed to reload Codex transport:`, error?.message || error);
      } finally {
        isReloading = false;
      }
    }, DEBOUNCE_MS);
  }

  // Ensure the directory exists before watching
  const authDir = path.dirname(AUTH_FILE);
  try {
    fs.mkdirSync(authDir, { recursive: true });
  } catch {
    // ignore
  }

  try {
    watcher = fs.watch(authDir, (eventType, filename) => {
      if (filename === "auth.json" || filename === null) {
        handleChange();
      }
    });
    console.log(`${logPrefix} Watching ${AUTH_FILE} for credential changes.`);
  } catch (error) {
    console.warn(`${logPrefix} Could not watch ${AUTH_FILE}: ${error?.message || error}`);
    console.warn(`${logPrefix} Auth hot-reload is disabled. Use \`remodex reload\` for manual reload.`);
  }

  return function teardown() {
    if (debounceTimer) {
      clearTimeout(debounceTimer);
      debounceTimer = null;
    }
    if (watcher) {
      watcher.close();
      watcher = null;
    }
  };
}

module.exports = { createAuthWatcher };
