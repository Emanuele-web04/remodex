// FILE: opencode-auth-providers.js
// Purpose: Read authenticated OpenCode provider IDs from Mac auth.json (keys only).
// Layer: Bridge utility
// Exports: readAuthProviderIds
// Depends on: fs, path, os, ./normalize

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { readString } = require("./normalize");

const MAX_AUTH_FILE_BYTES = 256 * 1024;

function defaultAuthPath() {
  return path.join(os.homedir(), ".local", "share", "opencode", "auth.json");
}

function readAuthProviderIds(options = {}) {
  const authPath = readString(options.authPath) || defaultAuthPath();
  try {
    const stat = fs.lstatSync(authPath);
    if (!stat.isFile()) {
      return { ids: [], authDiscoveryReasonCode: "auth_file_unreadable" };
    }
    if (stat.size > MAX_AUTH_FILE_BYTES) {
      return { ids: [], authDiscoveryReasonCode: "auth_file_unreadable" };
    }
    const raw = fs.readFileSync(authPath, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { ids: [], authDiscoveryReasonCode: "auth_file_unreadable" };
    }
    const ids = Object.keys(parsed)
      .map((key) => readString(key))
      .filter(Boolean);
    return { ids, authDiscoveryReasonCode: "ok" };
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return { ids: [], authDiscoveryReasonCode: "auth_unavailable" };
    }
    return { ids: [], authDiscoveryReasonCode: "auth_file_unreadable" };
  }
}

function authProviderIdsFromProbe(response) {
  const payload =
    response && typeof response === "object" && response.data && typeof response.data === "object"
      ? response.data
      : response;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return [];
  }
  return Object.keys(payload)
    .filter((key) => key !== "data")
    .map((key) => readString(key))
    .filter(Boolean);
}

module.exports = {
  readAuthProviderIds,
  authProviderIdsFromProbe,
  defaultAuthPath,
};