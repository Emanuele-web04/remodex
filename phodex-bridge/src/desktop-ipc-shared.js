// FILE: desktop-ipc-shared.js
// Purpose: Shared primitives for the Codex Desktop IPC modules (framing, socket path, JSON helpers).
// Layer: CLI helper
// Exports: FRAME_HEADER_BYTES, MAX_FRAME_BYTES, cloneJSON, normalizeToken, readString, readText, requestIdKey, resolveDefaultIpcSocketPath, safeParseJSON, writeFrame
// Depends on: os, path

const os = require("os");
const path = require("path");

const FRAME_HEADER_BYTES = 4;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;

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
  normalizeToken,
  readString,
  readText,
  requestIdKey,
  resolveDefaultIpcSocketPath,
  safeParseJSON,
  writeFrame,
};
