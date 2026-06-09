// FILE: bridge-operator-profile.js
// Purpose: Resolves operator vs dev bridge profiles for production-default feature gates.
// Layer: Bridge policy
// Exports: resolveBridgeProfile, resolveOpenCodeHandoffEnabled, isDevBridgeProfile
// Depends on: none

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function readOptionalBooleanEnv(keys, env = process.env) {
  const truthy = new Set(["1", "true", "yes", "on"]);
  const falsy = new Set(["0", "false", "no", "off"]);

  for (const key of keys) {
    const rawValue = env?.[key];
    if (typeof rawValue !== "string" || !rawValue.trim()) {
      continue;
    }
    const normalizedValue = rawValue.trim().toLowerCase();
    if (truthy.has(normalizedValue)) {
      return true;
    }
    if (falsy.has(normalizedValue)) {
      return false;
    }
  }

  return null;
}

function readFirstDefinedEnv(keys, fallback = "", env = process.env) {
  for (const key of keys) {
    const value = readString(env?.[key]);
    if (value) {
      return value;
    }
  }
  return fallback;
}

function resolveBridgeProfile(env = process.env) {
  const explicitProfile = readString(env.REMODEX_PROFILE || env.PHODEX_PROFILE).toLowerCase();
  if (explicitProfile === "dev") {
    return "dev";
  }
  if (explicitProfile === "managed-relay" || explicitProfile === "managed") {
    return "managed-relay";
  }
  if (explicitProfile === "self-hosted" || explicitProfile === "selfhost") {
    return "self-hosted";
  }

  const nodeEnv = readString(env.NODE_ENV).toLowerCase();
  if (nodeEnv === "development" || nodeEnv === "test") {
    return "dev";
  }

  if (readFirstDefinedEnv(["REMODEX_PUSH_SERVICE_URL", "PHODEX_PUSH_SERVICE_URL"], "", env)) {
    return "managed-relay";
  }

  if (readFirstDefinedEnv(["REMODEX_RELAY", "PHODEX_RELAY"], "", env)) {
    return "self-hosted";
  }

  return "operator";
}

function isDevBridgeProfile(env = process.env) {
  return resolveBridgeProfile(env) === "dev";
}

function resolveOpenCodeHandoffEnabled(env = process.env) {
  const explicit = readOptionalBooleanEnv(["REMODEX_OPENCODE_HANDOFF"], env);
  if (explicit !== null) {
    return explicit;
  }

  return !isDevBridgeProfile(env);
}

module.exports = {
  isDevBridgeProfile,
  resolveBridgeProfile,
  resolveOpenCodeHandoffEnabled,
};