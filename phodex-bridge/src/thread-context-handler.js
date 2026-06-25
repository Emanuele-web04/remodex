// FILE: thread-context-handler.js
// Purpose: Serves on-demand thread context-window usage reads from local Codex rollout files.
// Layer: Bridge handler
// Exports: handleThreadContextRequest
// Depends on: ./rollout-watch

const { readLatestContextWindowUsage } = require("./rollout-watch");
const { OPENCODE_PROVIDER_ID } = require("./opencode-models");
const { sessionGetUsageStats } = require("./opencode-session-usage-handler");
const { safeParseJSON } = require("./safe-json");

function handleThreadContextRequest(rawMessage, sendResponse, dependencies = {}) {
  const parsed = safeParseJSON(rawMessage);
  if (!parsed) {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (method !== "thread/contextWindow/read") {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleThreadContextRead(params, dependencies)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "thread_context_error";
      const message = err.userMessage || err.message || "Unknown thread context error";
      sendResponse(
        JSON.stringify({
          id,
          error: {
            code: -32000,
            message,
            data: { errorCode },
          },
        })
      );
    });

  return true;
}

// Reads the newest rollout-backed usage snapshot and returns it in the app-facing shape.
async function handleThreadContextRead(params, { ownershipStore, opencodeProvider } = {}) {
  const threadId = readString(params.threadId) || readString(params.thread_id);
  if (!threadId) {
    throw threadContextError("missing_thread_id", "thread/contextWindow/read requires a threadId.");
  }

  if (ownershipStore?.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
    const openCodeUsage = await sessionGetUsageStats(params, {
      ownershipStore,
      opencodeProvider,
    });
    return {
      threadId,
      usage: openCodeUsage?.usage ?? null,
      source: "opencode",
      sessionId: openCodeUsage?.sessionId ?? null,
    };
  }

  const turnId = readString(params.turnId) || readString(params.turn_id);
  const result = readLatestContextWindowUsage({
    threadId,
    turnId,
  });

  return {
    threadId,
    usage: result?.usage ?? null,
    rolloutPath: result?.rolloutPath ?? null,
    source: "codex_rollout",
  };
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function threadContextError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handleThreadContextRequest,
};
