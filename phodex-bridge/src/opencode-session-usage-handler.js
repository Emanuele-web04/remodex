// FILE: opencode-session-usage-handler.js
// Purpose: Serves session/getUsageStats for OpenCode-owned threads via SDK session.get.
// Layer: Bridge handler
// Exports: handleOpenCodeSessionUsageRequest, sessionGetUsageStats
// Depends on: ./normalize, ./thread-ownership-store, ./opencode-runtime-policy

const { readString } = require("./normalize");
const { OPENCODE_PROVIDER_ID } = require("./opencode-models");
const { isOpenCodeRuntimeDisabled } = require("./opencode-runtime-policy");
const { safeParseJSON } = require("./safe-json");

function handleOpenCodeSessionUsageRequest(rawMessage, sendResponse, dependencies = {}) {
  const parsed = safeParseJSON(rawMessage);
  if (!parsed) {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (method !== "session/getUsageStats") {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  sessionGetUsageStats(params, dependencies)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "session_usage_failed";
      const message = err.userMessage || err.message || "Unable to read OpenCode session usage";
      sendResponse(
        JSON.stringify({
          id,
          error: {
            code: -32000,
            message,
            data: { errorCode },
          },
        }),
      );
    });

  return true;
}

async function sessionGetUsageStats(
  params,
  { opencodeProvider, ownershipStore, threadOwnershipStore } = {},
) {
  if (isOpenCodeRuntimeDisabled(process.env)) {
    throw sessionUsageError("opencode_disabled", "OpenCode runtime is disabled on this bridge.");
  }

  const ownership = ownershipStore || threadOwnershipStore;
  const threadId = readString(params.threadId || params.thread_id);
  if (!threadId) {
    throw sessionUsageError("missing_thread_id", "session/getUsageStats requires a threadId.");
  }

  if (ownership && !ownership.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
    throw sessionUsageError("wrong_provider", "session/getUsageStats is only available for OpenCode threads.");
  }

  if (!opencodeProvider || typeof opencodeProvider.getUsageStatsForThread !== "function") {
    throw sessionUsageError("opencode_unavailable", "OpenCode provider is not available.");
  }

  const usageResult = await opencodeProvider.getUsageStatsForThread(threadId);
  return {
    threadId,
    sessionId: usageResult?.sessionId || null,
    usage: usageResult?.usage || null,
    source: "opencode",
  };
}

function sessionUsageError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handleOpenCodeSessionUsageRequest,
  sessionGetUsageStats,
};
