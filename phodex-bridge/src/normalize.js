// FILE: normalize.js
// Purpose: Shared normalization helpers used across the bridge.
// Layer: Bridge shared utility
// Exports: readString, readStringOrNull, resolvedParam
// Depends on: (none)

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function readStringOrNull(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function resolvedParam(params, ...keys) {
  for (const key of keys) {
    const value = readString(params?.[key]);
    if (value) return value;
  }
  return "";
}

module.exports = { readString, readStringOrNull, resolvedParam };
