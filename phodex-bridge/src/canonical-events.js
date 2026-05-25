// FILE: canonical-events.js
// Purpose: Builds and validates Remodex runtime-neutral event envelopes.
// Layer: Bridge core
// Exports: canonical event constants, builders, validators

const CANONICAL_SCHEMA_VERSION = 1;
const CANONICAL_METHOD_PREFIX = "remodex/event/";

const CANONICAL_EVENT_TYPES = Object.freeze({
  THREAD_STARTED: "thread_started",
  TURN_STARTED: "turn_started",
  USER_MESSAGE: "user_message",
  ASSISTANT_DELTA: "assistant_delta",
  ASSISTANT_COMPLETED: "assistant_completed",
  TOOL_STARTED: "tool_started",
  TOOL_DELTA: "tool_delta",
  TOOL_COMPLETED: "tool_completed",
  DIFF_UPDATED: "diff_updated",
  TURN_COMPLETED: "turn_completed",
  ERROR: "error",
});

function canonicalMethodForType(type) {
  const normalizedType = readString(type);
  return normalizedType ? `${CANONICAL_METHOD_PREFIX}${normalizedType}` : "";
}

function createCanonicalEvent({
  type,
  agentRuntime = "codex",
  threadId,
  agentSessionId,
  turnId,
  itemId,
  createdAt = new Date().toISOString(),
  payload = {},
} = {}) {
  const method = canonicalMethodForType(type);
  if (!method) {
    throw new Error("Canonical event type is required.");
  }

  const params = omitEmpty({
    schemaVersion: CANONICAL_SCHEMA_VERSION,
    agentRuntime: readString(agentRuntime) || "codex",
    threadId: readString(threadId),
    agentSessionId: readString(agentSessionId),
    turnId: readString(turnId),
    itemId: readString(itemId),
    createdAt: readString(createdAt) || new Date().toISOString(),
    payload: payload && typeof payload === "object" ? payload : {},
  });

  return {
    jsonrpc: "2.0",
    method,
    params,
  };
}

function isCanonicalEvent(message) {
  return typeof message?.method === "string"
    && message.method.startsWith(CANONICAL_METHOD_PREFIX)
    && message.params?.schemaVersion === CANONICAL_SCHEMA_VERSION;
}

function validateCanonicalEvent(message) {
  if (!isCanonicalEvent(message)) {
    return { valid: false, reason: "not_canonical_event" };
  }
  const params = message.params || {};
  if (!readString(params.agentRuntime)) {
    return { valid: false, reason: "missing_agent_runtime" };
  }
  if (!readString(params.createdAt)) {
    return { valid: false, reason: "missing_created_at" };
  }
  if (!params.payload || typeof params.payload !== "object" || Array.isArray(params.payload)) {
    return { valid: false, reason: "invalid_payload" };
  }
  return { valid: true };
}

function omitEmpty(value) {
  const next = {};
  for (const [key, entry] of Object.entries(value)) {
    if (entry === "" || entry === undefined || entry === null) {
      continue;
    }
    next[key] = entry;
  }
  return next;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  CANONICAL_EVENT_TYPES,
  CANONICAL_METHOD_PREFIX,
  CANONICAL_SCHEMA_VERSION,
  canonicalMethodForType,
  createCanonicalEvent,
  isCanonicalEvent,
  validateCanonicalEvent,
};
