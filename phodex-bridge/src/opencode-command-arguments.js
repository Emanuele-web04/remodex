// FILE: opencode-command-arguments.js
// Purpose: Derives slash-command argument requirements and serializes structured
//          argumentFields into the single OpenCode SDK arguments string (PM-1).
// Layer: Domain helper
// Exports: deriveRequiresArguments, extractNumericPlaceholderKeys,
//          usesArgumentsOnlyPlaceholder, normalizeArgumentFields,
//          serializeCommandArguments
// Depends on: ./normalize (readString)

const { readString } = require("./normalize");

const PLACEHOLDER_DERIVATION_REGEX = /\$ARGUMENTS|\$\d+/;
const NUMERIC_PLACEHOLDER_REGEX = /\$(\d+)/g;

function deriveRequiresArguments(template, hints = []) {
  const hintList = Array.isArray(hints)
    ? hints.map((entry) => readString(entry)).filter(Boolean)
    : [];
  if (hintList.length > 0) {
    return true;
  }
  const normalizedTemplate = readString(template);
  return PLACEHOLDER_DERIVATION_REGEX.test(normalizedTemplate);
}

function extractNumericPlaceholderKeys(template) {
  const normalizedTemplate = readString(template);
  const matches = normalizedTemplate.match(/\$\d+/g) || [];
  const unique = [...new Set(matches)];
  unique.sort((left, right) => Number(left.slice(1)) - Number(right.slice(1)));
  return unique;
}

function usesArgumentsOnlyPlaceholder(template, hints = []) {
  const normalizedTemplate = readString(template);
  if (!normalizedTemplate.includes("$ARGUMENTS")) {
    return false;
  }
  if (extractNumericPlaceholderKeys(normalizedTemplate).length > 0) {
    return false;
  }
  const hintList = Array.isArray(hints)
    ? hints.map((entry) => readString(entry)).filter(Boolean)
    : [];
  if (hintList.length === 0) {
    return true;
  }
  return hintList.every((hint) => hint === "$ARGUMENTS");
}

function normalizeArgumentFields(raw) {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.map((entry) => {
    if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      return {
        key: readString(entry.key),
        value: readString(entry.value),
      };
    }
    return { key: "", value: readString(entry) };
  });
}

function argumentFieldValues(fields) {
  const normalized = normalizeArgumentFields(fields);
  return normalized.map((entry) => readString(entry.value));
}

function quoteArgForArgsRegex(value) {
  const normalized = readString(value);
  if (!normalized) {
    return "";
  }
  if (/[\s"'\\]/.test(normalized)) {
    return `"${normalized.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return normalized;
}

function serializeCommandArguments({ template = "", hints = [], fields = [] } = {}) {
  const normalizedTemplate = readString(template);
  const hintList = Array.isArray(hints)
    ? hints.map((entry) => readString(entry)).filter(Boolean)
    : [];
  const values = argumentFieldValues(fields);

  if (usesArgumentsOnlyPlaceholder(normalizedTemplate, hintList)) {
    return readString(values[0]).trim();
  }

  const numericKeys = extractNumericPlaceholderKeys(normalizedTemplate);
  if (numericKeys.length > 0) {
    return values.map(quoteArgForArgsRegex).filter(Boolean).join(" ");
  }

  if (hintList.length > 0) {
    return values.map(quoteArgForArgsRegex).filter(Boolean).join(" ");
  }

  return values
    .map((value) => readString(value).trim())
    .filter(Boolean)
    .join(" ")
    .trim();
}

function mapSdkCommandToBridge(command) {
  const name = readString(command?.name || command?.token);
  const token = name.startsWith("/") ? name : `/${name}`;
  const template = readString(command?.template);
  const hints = Array.isArray(command?.hints)
    ? command.hints.map((entry) => readString(entry)).filter(Boolean)
    : [];
  const mapped = {
    token,
    title: readString(command?.title || command?.displayName || name),
    description: readString(command?.description) || "",
    requiresArguments: deriveRequiresArguments(template, hints),
  };
  if (template) {
    mapped.template = template;
  }
  if (hints.length > 0) {
    mapped.hints = hints;
  }
  const agent = readString(command?.agent);
  if (agent) {
    mapped.agent = agent;
  }
  const model = readString(command?.model);
  if (model) {
    mapped.model = model;
  }
  const source = readString(command?.source);
  if (source) {
    mapped.source = source;
  }
  return mapped;
}

module.exports = {
  deriveRequiresArguments,
  extractNumericPlaceholderKeys,
  usesArgumentsOnlyPlaceholder,
  normalizeArgumentFields,
  serializeCommandArguments,
  mapSdkCommandToBridge,
};