// FILE: opencode-runtime-policy.js
// Purpose: Centralizes when the OpenCode runtime is registered, enabled, and advertised to iOS.
// Layer: Bridge policy
// Exports: isOpenCodeRuntimeDisabled, isOpenCodeRuntimeEnabled, resolveDefaultOpenCodeAgent
// Depends on: ./normalize

const { readString } = require("./normalize");

// Opt-out flags for Codex-only regression runs and explicit operator disable.
function isOpenCodeRuntimeDisabled(env = process.env) {
  const disableFlag = readString(env.REMODEX_DISABLE_OPENCODE);
  if (disableFlag === "1" || disableFlag === "true") {
    return true;
  }
  const legacyEnableFlag = readString(env.REMODEX_ENABLE_OPENCODE);
  if (legacyEnableFlag === "0" || legacyEnableFlag === "false") {
    return true;
  }
  return false;
}

function isOpenCodeRuntimeEnabled(env = process.env) {
  return !isOpenCodeRuntimeDisabled(env);
}

// Operator override for the default OpenCode agent used when a request omits one.
function resolveDefaultOpenCodeAgent(env = process.env) {
  return readString(env?.REMODEX_OPENCODE_DEFAULT_AGENT) || "build";
}

module.exports = {
  isOpenCodeRuntimeDisabled,
  isOpenCodeRuntimeEnabled,
  resolveDefaultOpenCodeAgent,
};
