// FILE: opencode-discovery-policy.js
// Purpose: Resolves OpenCode external discovery from Remodex app RPC params with env overrides.
// Layer: Bridge policy
// Exports: resolveDiscoverSessionsEnabled, resolveDiscoverProjectsEnabled, readClientDiscoverFlag
// Depends on: ./normalize, ./opencode-runtime-policy

const { readString } = require("./normalize");
const { isOpenCodeRuntimeDisabled } = require("./opencode-runtime-policy");

function readClientDiscoverFlag(params = {}, keys = []) {
  if (!params || typeof params !== "object") {
    return null;
  }

  for (const key of keys) {
    if (params[key] === true) {
      return true;
    }
    if (params[key] === false) {
      return false;
    }
  }
  return null;
}

function readEnvDiscoverFlag(env = process.env, envKey = "") {
  const raw = readString(env?.[envKey]).toLowerCase();
  if (raw === "0" || raw === "false") {
    return false;
  }
  if (raw === "1" || raw === "true") {
    return true;
  }
  return null;
}

function resolveDiscoverSessionsEnabled(env = process.env, params = {}) {
  if (isOpenCodeRuntimeDisabled(env)) {
    return false;
  }

  const envFlag = readEnvDiscoverFlag(env, "REMODEX_OPENCODE_DISCOVER_SESSIONS");
  if (envFlag === false) {
    return false;
  }
  if (envFlag === true) {
    return true;
  }

  const clientFlag = readClientDiscoverFlag(params, [
    "discoverOpenCodeSessions",
    "discover_open_code_sessions",
  ]);
  return clientFlag === true;
}

function resolveDiscoverProjectsEnabled(env = process.env, params = {}) {
  if (isOpenCodeRuntimeDisabled(env)) {
    return false;
  }

  const envFlag = readEnvDiscoverFlag(env, "REMODEX_OPENCODE_DISCOVER_PROJECTS");
  if (envFlag === false) {
    return false;
  }
  if (envFlag === true) {
    return true;
  }

  const clientFlag = readClientDiscoverFlag(params, [
    "discoverOpenCodeProjects",
    "discover_open_code_projects",
  ]);
  return clientFlag === true;
}

module.exports = {
  readClientDiscoverFlag,
  resolveDiscoverProjectsEnabled,
  resolveDiscoverSessionsEnabled,
};