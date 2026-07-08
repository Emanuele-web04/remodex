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

// Mirrors Codex's ContextualUserFragment registry. Keep this exact: arbitrary
// XML is valid user input, while these runtime-owned markers are hidden history.
const CONTEXT_MARKER_PAIRS = [
  ["<environment_context>", "</environment_context>"],
  ["<skill>", "</skill>"],
  ["<user_shell_command>", "</user_shell_command>"],
  ["<turn_aborted>", "</turn_aborted>"],
  ["<subagent_notification>", "</subagent_notification>"],
  ["<recommended_plugins>", "</recommended_plugins>"],
  ["<goal_context>", "</goal_context>"],
  // Review mode records this raw handoff in history, then emits the visible
  // review result separately. Showing it as a user bubble leaks runtime state.
  ["<user_action>", "</user_action>"],
];
const LEGACY_CONTEXT_WARNING_PREFIXES = [
  "Warning: The maximum number of unified exec processes you can keep open is",
  "Warning: Your account was flagged for potentially high-risk cyber activity",
];
const LEGACY_APPLY_PATCH_WARNING_PREFIX = "Warning: apply_patch was requested via ";
const LEGACY_APPLY_PATCH_WARNING_SUFFIX = "Use the apply_patch tool instead of exec_command.";
const AGENTS_INSTRUCTIONS_PREFIX = "# AGENTS.md instructions";
const INTERNAL_CONTEXT_PATTERN = /^<codex_internal_context\s+source=(?:"[a-z][a-z0-9_]*"|'[a-z][a-z0-9_]*')>[\s\S]*<\/codex_internal_context>$/;
const EXTERNAL_CONTEXT_PATTERN = /^<external_([a-z0-9_-]+)>[\s\S]*<\/external_\1>$/;
const PROMPT_REQUEST_BEGIN = "## My request for Codex:";
const REVIEW_PROMPT_PREFIX = "## Code review guidelines:";

// Attachments ride as input_image entries framed by "<image>"/"</image>" text
// entries, so an image-only item's joined text is exactly an empty tag pair.
// That incidentally matches the context shape, but it is NOT injected context:
// classifying it as such would drop image-only user messages (the image entries
// live in the same item the callers discard). Strip the placeholders before
// classifying, and never surface them as visible bubble text.
const IMAGE_PLACEHOLDER_PAIR = /<image>\s*<\/image>/gi;
const IMAGE_PLACEHOLDER_TOKEN = /^<\/?image>$/i;
const RUNTIME_IMAGE_OPENING_TAG = /<image\s+name=\[Image #\d+\]\s+path=(?:"[^"\r\n]+"|'[^'\r\n]+'|[^\s<>]+)\s*>/gi;

function stripImagePlaceholders(text) {
  let sawRuntimeImageOpeningTag = false;
  const withoutRuntimeOpeners = text.replace(RUNTIME_IMAGE_OPENING_TAG, () => {
    sawRuntimeImageOpeningTag = true;
    return "";
  });
  const withoutPairs = withoutRuntimeOpeners.replace(IMAGE_PLACEHOLDER_PAIR, "");
  if (sawRuntimeImageOpeningTag) {
    return withoutPairs.replace(/<\/image>/gi, "");
  }
  return IMAGE_PLACEHOLDER_TOKEN.test(withoutPairs.trim()) ? "" : withoutPairs;
}

function isContextualUserText(text) {
  const raw = typeof text === "string" ? text : "";
  const trimmed = stripImagePlaceholders(raw).trim();
  if (!trimmed) {
    return false;
  }
  // Review envelopes contain a real request after the delimiter and are never
  // wholly contextual, even when that request itself contains reserved markup.
  if (trimmed.startsWith(REVIEW_PROMPT_PREFIX) && trimmed.includes(PROMPT_REQUEST_BEGIN)) {
    return false;
  }
  const normalized = trimmed.toLowerCase();
  if (normalized.startsWith(AGENTS_INSTRUCTIONS_PREFIX.toLowerCase())) {
    // Runtime context can concatenate AGENTS.md with any registered hidden
    // fragment. Only classify the whole item as hidden when its final fragment
    // is also runtime-owned; a following real user request must stay visible.
    return normalized.endsWith("</instructions>")
      || CONTEXT_MARKER_PAIRS.some(([, end]) => normalized.endsWith(end));
  }
  if (CONTEXT_MARKER_PAIRS.some(([start, end]) => (
    normalized.startsWith(start) && normalized.endsWith(end)
  ))) {
    return true;
  }
  if (INTERNAL_CONTEXT_PATTERN.test(trimmed) || EXTERNAL_CONTEXT_PATTERN.test(trimmed)) {
    return true;
  }
  if (LEGACY_CONTEXT_WARNING_PREFIXES.some((prefix) => trimmed.startsWith(prefix))) {
    return true;
  }
  return trimmed.startsWith(LEGACY_APPLY_PATCH_WARNING_PREFIX)
    && trimmed.endsWith(LEGACY_APPLY_PATCH_WARNING_SUFFIX);
}

function decodeXmlText(text) {
  return text.replace(/&(lt|gt|quot|apos|amp);/g, (match, entity) => ({
    lt: "<",
    gt: ">",
    quot: "\"",
    apos: "'",
    amp: "&",
  })[entity] || match);
}

function extractNestedRuntimeText(text, outerTag, innerTag) {
  const outerPattern = new RegExp(`^<${outerTag}>[\\s\\S]*<\\/${outerTag}>$`, "i");
  if (!outerPattern.test(text.trim())) {
    return null;
  }
  const innerPattern = new RegExp(`<${innerTag}>([\\s\\S]*?)<\\/${innerTag}>`, "i");
  const match = innerPattern.exec(text);
  return match ? decodeXmlText(match[1]).trim() : null;
}

// Some runtime wrappers are visible triggers, not hidden context. Codex.app
// presents only their human-facing payload and keeps transport metadata private.
function extractVisibleRuntimeEnvelope(text) {
  const trimmed = text.trim();
  const envelopePairs = [
    ["heartbeat", "instructions"],
    ["codex_delegation", "input"],
    ["realtime_delegation", "input"],
    ["sidechat_boundary", "latest_user_message"],
  ];
  for (const [outerTag, innerTag] of envelopePairs) {
    const extracted = extractNestedRuntimeText(trimmed, outerTag, innerTag);
    if (extracted != null) {
      return extracted;
    }
  }

  const hookPrompt = /^<hook_prompt\s+hook_run_id=(?:"[^"]+"|'[^']+')>([\s\S]*?)<\/hook_prompt>$/i.exec(trimmed);
  return hookPrompt ? decodeXmlText(hookPrompt[1]).trim() : null;
}

// Mirrors Desktop's extract_prompt_request: IDE-context prompts embed the real
// request after the last "## My request for Codex:" delimiter.
function visibleUserPromptText(text) {
  if (typeof text !== "string" || !text) {
    return "";
  }
  const cleaned = stripImagePlaceholders(text);
  // Context bodies can contain the request delimiter as ordinary text. Classify
  // the complete fragment first so the delimiter cannot reveal hidden content.
  if (isContextualUserText(cleaned)) {
    return "";
  }
  const requestIndex = cleaned.lastIndexOf(PROMPT_REQUEST_BEGIN);
  if (requestIndex >= 0) {
    return cleaned.slice(requestIndex + PROMPT_REQUEST_BEGIN.length).trim();
  }
  const envelopeText = extractVisibleRuntimeEnvelope(cleaned);
  if (envelopeText != null) {
    return envelopeText;
  }
  return cleaned;
}

// Sanitizes text fragments independently so a hidden fragment cannot cause a
// sibling prompt or image attachment in the same user item to be discarded.
function sanitizeUserInputEntries(entries) {
  if (!Array.isArray(entries)) {
    return [];
  }
  const sanitized = [];
  for (const entry of entries) {
    if (typeof entry === "string") {
      const visible = visibleUserPromptText(entry);
      if (visible) {
        sanitized.push(visible);
      }
      continue;
    }
    if (!entry || typeof entry !== "object") {
      continue;
    }
    const textKey = ["text", "message", "content"].find((key) => typeof entry[key] === "string");
    if (!textKey) {
      sanitized.push(entry);
      continue;
    }
    const visible = visibleUserPromptText(entry[textKey]);
    if (!visible) {
      continue;
    }
    sanitized.push(visible === entry[textKey] ? entry : { ...entry, [textKey]: visible });
  }
  return sanitized;
}

function sanitizeUserRoleItem(item) {
  if (!isUserRoleItem(item)) {
    return item;
  }
  let sanitized = item;
  let changed = false;

  if (Array.isArray(item.content)) {
    const content = sanitizeUserInputEntries(item.content);
    changed = content.length !== item.content.length
      || content.some((entry, index) => entry !== item.content[index]);
    if (changed) {
      sanitized = { ...sanitized, content };
    }
  }

  for (const key of ["text", "message"]) {
    if (typeof sanitized[key] !== "string") {
      continue;
    }
    const visible = visibleUserPromptText(sanitized[key]);
    if (!visible && !Array.isArray(sanitized.content)) {
      return null;
    }
    if (visible !== sanitized[key]) {
      sanitized = { ...sanitized, [key]: visible };
      changed = true;
    }
  }

  const hasContent = Array.isArray(sanitized.content) && sanitized.content.length > 0;
  const hasDirectText = ["text", "message"].some((key) => (
    typeof sanitized[key] === "string" && sanitized[key].trim()
  ));
  if (Array.isArray(sanitized.content) && !hasContent && !hasDirectText) {
    return null;
  }

  return changed ? sanitized : item;
}

// Extracts the visible human prompt from turn-start input entries while dropping
// injected context fragments. Used by Desktop IPC and rollout mirrors.
function visibleUserPromptFromInputEntries(input) {
  const entries = Array.isArray(input) ? input : [input];
  return entries
    .map(readInputEntryText)
    .map((text) => visibleUserPromptText(text).trim())
    .filter(Boolean)
    .join("\n")
    .trim();
}

function readInputEntryText(entry) {
  if (typeof entry === "string") {
    return entry;
  }
  if (!entry || typeof entry !== "object") {
    return "";
  }
  if (typeof entry.text === "string") {
    return entry.text;
  }
  if (typeof entry.message === "string") {
    return entry.message;
  }
  if (typeof entry.content === "string") {
    return entry.content;
  }
  const content = Array.isArray(entry.content) ? entry.content : [];
  return content
    .map(readInputEntryText)
    .filter(Boolean)
    .join("\n");
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
// weaker claims: strong enough to take over an idle thread, but never one the
// local app-server is still running.
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
  sanitizeUserInputEntries,
  sanitizeUserRoleItem,
  visibleUserPromptText,
  visibleUserPromptFromInputEntries,
  writeFrame,
};
