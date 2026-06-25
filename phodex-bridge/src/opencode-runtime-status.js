// FILE: opencode-runtime-status.js
// Purpose: Builds OpenCode runtime status snapshots for runtime/catalog and bridge-status.json.
// Layer: Bridge runtime utility
// Exports: buildOpenCodeRuntimeStatus, OPENCODE_MIN_CLI_VERSION
// Depends on: ./normalize

const { readString } = require("./normalize");

// OpenCode CLI semver from /global/health (e.g. 1.15.13). SDK v2 + `opencode serve` ship in 1.15.x.
const OPENCODE_MIN_CLI_VERSION = "1.15.12";

function parseVersionParts(version) {
  const match = readString(version).match(/(\d+)\.(\d+)\.(\d+)/);
  if (!match) {
    return null;
  }
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

function isVersionBelowMinimum(version, minimum = OPENCODE_MIN_CLI_VERSION) {
  const left = parseVersionParts(version);
  const right = parseVersionParts(minimum);
  if (!left || !right) {
    return false;
  }
  for (let index = 0; index < 3; index += 1) {
    if (left[index] < right[index]) {
      return true;
    }
    if (left[index] > right[index]) {
      return false;
    }
  }
  return false;
}

function buildOpenCodeRuntimeStatus({
  enabled = false,
  serveUrl = "",
  version = "",
  sessionCount = 0,
  lastError = "",
  command = "",
  handoffEnvEnabled = false,
  authConfigured = null,
  connectedProviders = null,
  providerDiscoveryReasonCode = null,
  providerInventory = null,
  authDiscoveryReasonCode = null,
  providerInventoryPartial = null,
} = {}) {
  const normalizedVersion = readString(version);
  const versionBelowMinimum =
    normalizedVersion.length > 0 && isVersionBelowMinimum(normalizedVersion, OPENCODE_MIN_CLI_VERSION);

  return {
    enabled: Boolean(enabled),
    serveUrl: readString(serveUrl) || null,
    version: normalizedVersion || null,
    minVersion: OPENCODE_MIN_CLI_VERSION,
    versionBelowMinimum,
    sessionCount: Number.isFinite(sessionCount) ? Math.max(0, Math.floor(sessionCount)) : 0,
    lastError: readString(lastError) || null,
    command: readString(command) || "opencode",
    handoffEnvEnabled: Boolean(handoffEnvEnabled),
    authConfigured:
      authConfigured === true || authConfigured === false ? authConfigured : null,
    connectedProviders: Array.isArray(connectedProviders) ? connectedProviders : null,
    providerDiscoveryReasonCode: readString(providerDiscoveryReasonCode) || null,
    providerInventory: Array.isArray(providerInventory) ? providerInventory : null,
    authDiscoveryReasonCode: readString(authDiscoveryReasonCode) || null,
    providerInventoryPartial:
      providerInventoryPartial === true || providerInventoryPartial === false
        ? providerInventoryPartial
        : null,
  };
}

module.exports = {
  OPENCODE_MIN_CLI_VERSION,
  buildOpenCodeRuntimeStatus,
  isVersionBelowMinimum,
};