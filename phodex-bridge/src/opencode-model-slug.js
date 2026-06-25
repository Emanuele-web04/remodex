// FILE: opencode-model-slug.js
// Purpose: Parse OpenCode model slugs into SDK prompt model objects.
// Layer: Bridge utility
// Exports: parseOpenCodeModelSlug
// Depends on: ./normalize

const { readString } = require("./normalize");

function parseOpenCodeModelSlug(slug) {
  const trimmed = readString(slug).trim();
  if (!trimmed) {
    return null;
  }
  const separator = trimmed.indexOf("/");
  if (separator <= 0 || separator === trimmed.length - 1) {
    return null;
  }
  return {
    providerID: trimmed.slice(0, separator),
    modelID: trimmed.slice(separator + 1),
  };
}

module.exports = {
  parseOpenCodeModelSlug,
};