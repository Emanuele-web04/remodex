// FILE: desktop-ipc-shared.js
// Purpose: Shared primitives for the Codex Desktop IPC modules (framing, socket path, JSON helpers).
// Layer: CLI helper
// Exports: FRAME_HEADER_BYTES, MAX_FRAME_BYTES, cloneJSON, normalizeToken, readString, readText, requestIdKey, resolveDefaultIpcSocketPath, safeParseJSON, writeFrame
// Depends on: os, path

const os = require("os");
const path = require("path");

const FRAME_HEADER_BYTES = 4;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;

// Codex injects project/context instructions as plain text fragments inside the
// turn input. Desktop hides them via these exact markers (see codex-rs
// memories/write phase1 and tui ide_context/prompt.rs); mirrored user bubbles
// must apply the same rules or the phone renders instruction walls as prompts.
const CONTEXT_FRAGMENT_MARKERS = [
  { start: "# AGENTS.md instructions for ", end: "</INSTRUCTIONS>" },
  { start: "<user_instructions>", end: "</user_instructions>" },
  { start: "<environment_context>", end: "</environment_context>" },
];
const PROMPT_REQUEST_BEGIN = "## My request for Codex:";

function isContextualUserText(text) {
  const trimmed = typeof text === "string" ? text.trim() : "";
  if (!trimmed) {
    return false;
  }
  return CONTEXT_FRAGMENT_MARKERS.some(({ start, end }) => (
    trimmed.startsWith(start) && trimmed.endsWith(end)
  ));
}

// Mirrors Desktop's extract_prompt_request: IDE-context prompts embed the real
// request after the last "## My request for Codex:" delimiter.
function visibleUserPromptText(text) {
  if (typeof text !== "string" || !text) {
    return "";
  }
  if (isContextualUserText(text)) {
    return "";
  }
  const requestIndex = text.lastIndexOf(PROMPT_REQUEST_BEGIN);
  if (requestIndex < 0) {
    return text;
  }
  return text.slice(requestIndex + PROMPT_REQUEST_BEGIN.length).trim();
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function readText(value) {
  return typeof value === "string" ? value : "";
}

function normalizeToken(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[_-\s]+/g, "")
    : "";
}

function cloneJSON(value) {
  if (value == null) {
    return value;
  }
  return JSON.parse(JSON.stringify(value));
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function requestIdKey(value) {
  if (typeof value === "string" && value) {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  return "";
}

function writeFrame(socket, payload, callback) {
  const body = Buffer.from(payload, "utf8");
  const header = Buffer.alloc(FRAME_HEADER_BYTES);
  header.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([header, body]), callback);
}

function resolveDefaultIpcSocketPath() {
  if (process.platform === "win32") {
    return "\\\\.\\pipe\\codex-ipc";
  }

  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  return path.join(os.tmpdir(), "codex-ipc", `ipc-${uid}.sock`);
}

module.exports = {
  FRAME_HEADER_BYTES,
  MAX_FRAME_BYTES,
  cloneJSON,
  isContextualUserText,
  normalizeToken,
  readString,
  readText,
  requestIdKey,
  resolveDefaultIpcSocketPath,
  safeParseJSON,
  visibleUserPromptText,
  writeFrame,
};
