// FILE: opencode-variant-resolve.js
// Purpose: Map composer effort strings to OpenCode session.prompt variant keys (KD-9).
// Layer: Bridge utility
// Exports: resolveOpenCodeVariantForPrompt
// Depends on: ./normalize

const { readString } = require("./normalize");

function collectVariantKeys(modelRecord) {
  if (!modelRecord || typeof modelRecord !== "object") {
    return [];
  }
  const variants = modelRecord.variants;
  if (!variants || typeof variants !== "object" || Array.isArray(variants)) {
    return [];
  }
  return Object.keys(variants).map((key) => readString(key)).filter(Boolean);
}

function resolveOpenCodeVariantForPrompt({ effort, modelRecord } = {}) {
  const normalizedEffort = readString(effort).trim();
  if (!normalizedEffort) {
    return { variant: undefined, omittedReason: null };
  }

  const keys = collectVariantKeys(modelRecord);
  if (keys.length === 0) {
    return {
      variant: undefined,
      omittedReason: "no_catalog_match",
    };
  }

  const lower = normalizedEffort.toLowerCase();
  const exact = keys.find((key) => key.toLowerCase() === lower);
  if (exact) {
    return { variant: exact, omittedReason: null };
  }

  return {
    variant: undefined,
    omittedReason: "no_catalog_match",
  };
}

module.exports = {
  resolveOpenCodeVariantForPrompt,
  collectVariantKeys,
};