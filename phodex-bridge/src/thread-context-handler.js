// FILE: thread-context-handler.js
// Purpose: Serves on-demand thread context-window usage reads from local Codex rollout files.
// Layer: Bridge handler
// Exports: handleThreadContextRequest
// Depends on: ./rollout-watch

const { readLatestContextWindowUsage } = require("./rollout-watch");

function handleThreadContextRequest(rawMessage, sendResponse) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (method !== "thread/contextWindow/read") {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleThreadContextRead(params)
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
async function handleThreadContextRead(params) {
  const threadId = readString(params.threadId) || readString(params.thread_id);
  if (!threadId) {
    throw threadContextError("missing_thread_id", "thread/contextWindow/read requires a threadId.");
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
