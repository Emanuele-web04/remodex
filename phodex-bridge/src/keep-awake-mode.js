// FILE: keep-awake-mode.js
// Purpose: Normalizes persisted and wire-level Mac wake preferences.
// Layer: Bridge helper
// Exports: wake mode constants plus normalization and caffeinate flag helpers

const KEEP_AWAKE_MODE_OFF = "off";
const KEEP_AWAKE_MODE_AC_POWER = "ac-power";
const KEEP_AWAKE_MODE_ALWAYS = "always";

function normalizeKeepAwakeMode(value, fallback = null) {
  if (typeof value !== "string") {
    return fallback;
  }

  switch (value.trim().toLowerCase().replace(/[_\s]+/g, "-")) {
    case "off":
    case "disabled":
    case "false":
      return KEEP_AWAKE_MODE_OFF;
    case "ac":
    case "ac-power":
    case "plugged-in":
    case "charging":
      return KEEP_AWAKE_MODE_AC_POWER;
    case "always":
    case "on":
    case "enabled":
    case "true":
      return KEEP_AWAKE_MODE_ALWAYS;
    default:
      return fallback;
  }
}

function resolveKeepAwakeMode({ mode, enabled, fallback = KEEP_AWAKE_MODE_OFF } = {}) {
  const normalizedMode = normalizeKeepAwakeMode(mode);
  if (normalizedMode) {
    return normalizedMode;
  }
  if (typeof enabled === "boolean") {
    return enabled ? KEEP_AWAKE_MODE_ALWAYS : KEEP_AWAKE_MODE_OFF;
  }
  if (fallback === null) {
    return null;
  }
  return normalizeKeepAwakeMode(fallback, KEEP_AWAKE_MODE_OFF);
}

function caffeinateFlagForKeepAwakeMode(mode) {
  switch (normalizeKeepAwakeMode(mode, KEEP_AWAKE_MODE_OFF)) {
    case KEEP_AWAKE_MODE_AC_POWER:
      return "-s";
    case KEEP_AWAKE_MODE_ALWAYS:
      return "-i";
    default:
      return null;
  }
}

module.exports = {
  KEEP_AWAKE_MODE_AC_POWER,
  KEEP_AWAKE_MODE_ALWAYS,
  KEEP_AWAKE_MODE_OFF,
  caffeinateFlagForKeepAwakeMode,
  normalizeKeepAwakeMode,
  resolveKeepAwakeMode,
};
