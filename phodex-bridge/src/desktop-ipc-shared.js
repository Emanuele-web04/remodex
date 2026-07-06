// FILE: desktop-ipc-shared.js
// Purpose: Shared primitives for the Codex Desktop IPC modules (framing, socket path, JSON helpers).
// Layer: CLI helper
// Exports: FRAME_HEADER_BYTES, MAX_FRAME_BYTES, cloneJSON, normalizeToken, readString, readText, requestIdKey, resolveDefaultIpcSocketPath, safeParseJSON, writeFrame
// Depends on: os, path

const os = require("os");
const path = require("path");

const FRAME_HEADER_BYTES = 4;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;

const CLIENT_STATUS_CHANGED = "client-status-changed";

// Single source of truth for Codex Desktop's IPC method versions. Desktop's
// bundled map validates versions on both requests and broadcasts, and this
// table already drifted once while it lived in two modules.
const DESKTOP_IPC_METHOD_VERSIONS = new Map([
  ["initialize", 1],
  [CLIENT_STATUS_CHANGED, 1],
  // Desktop pins thread-stream-state-changed at version 8 and drops mismatches.
  ["thread-stream-state-changed", 8],
  ["thread-archived", 2],
  ["thread-unarchived", 1],
  ["thread-read-state-changed", 1],
  ["thread-queued-followups-changed", 1],
  ["thread-follower-start-turn", 1],
  ["thread-follower-load-complete-history", 1],
  ["thread-follower-update-thread-settings", 1],
  ["thread-follower-compact-thread", 1],
  ["thread-follower-steer-turn", 1],
  ["thread-follower-interrupt-turn", 2],
  ["thread-follower-set-model-and-reasoning", 1],
  ["thread-follower-set-collaboration-mode", 1],
  ["thread-follower-edit-last-user-turn", 2],
  ["thread-follower-command-approval-decision", 1],
  ["thread-follower-file-approval-decision", 1],
  ["thread-follower-permissions-request-approval-response", 1],
  ["thread-follower-submit-user-input", 1],
  ["thread-follower-submit-mcp-server-elicitation-response", 1],
  ["thread-follower-set-queued-follow-ups-state", 1],
]);

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

function isPlainJSONObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

// Single predicate for "this timeline item is a user message", shared by the
// relay sanitizer, the JSONL history parser, and the Desktop-bound adapter so
// context filters can never drift apart across paths again.
function isUserRoleItem(item) {
  const type = normalizeToken(item?.type);
  if (type === "usermessage") {
    return true;
  }
  return type === "message" && normalizeToken(item?.role) === "user";
}

function readUserItemText(item) {
  const direct = readString(item?.text) || readString(item?.message);
  if (direct) {
    return direct;
  }
  const content = Array.isArray(item?.content) ? item.content : [];
  return content
    .map((entry) => {
      if (typeof entry === "string") {
        return entry;
      }
      if (!entry || typeof entry !== "object") {
        return "";
      }
      return typeof entry.text === "string" ? entry.text : "";
    })
    .filter(Boolean)
    .join("\n");
}

// A stream snapshot that carries an actively running turn is evidence the
// sender's runtime is executing the conversation. Idle snapshots also arrive
// for threads a peer merely viewed or re-broadcast on reconnect, so they are
// not an ownership claim.
function conversationSnapshotShowsActiveTurn(change) {
  const conversationState = change?.conversationState || change?.conversation_state;
  const turns = Array.isArray(conversationState?.turns) ? conversationState.turns : [];
  return turns.some((turn) => {
    const status = normalizeToken(turn?.status);
    return status === "inprogress" || status === "running" || status === "active";
  });
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
  CLIENT_STATUS_CHANGED,
  DESKTOP_IPC_METHOD_VERSIONS,
  FRAME_HEADER_BYTES,
  MAX_FRAME_BYTES,
  cloneJSON,
  conversationSnapshotShowsActiveTurn,
  isContextualUserText,
  isPlainJSONObject,
  isUserRoleItem,
  normalizeToken,
  readString,
  readText,
  readUserItemText,
  requestIdKey,
  resolveDefaultIpcSocketPath,
  safeParseJSON,
  visibleUserPromptText,
  writeFrame,
};
