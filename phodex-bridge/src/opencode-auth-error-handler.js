// FILE: opencode-auth-error-handler.js
// Purpose: Detects OpenCode ProviderAuthError payloads and emits runtime/auth/error to iOS.
// Layer: Bridge handler
// Exports: createOpenCodeAuthErrorNotifier, extractOpenCodeAuthError
// Depends on: ./normalize, ./opencode-usage-mapper

const { readString } = require("./normalize");
const { isProviderAuthErrorPayload } = require("./opencode-usage-mapper");

function createOpenCodeAuthErrorNotifier({ sendApplicationMessage, logPrefix = "[remodex]" } = {}) {
  const recentByKey = new Map();
  const DEDUPE_TTL_MS = 15_000;

  function notifyAuthError(payload = {}) {
    const normalized = extractOpenCodeAuthError(payload);
    if (!normalized) {
      return false;
    }

    const dedupeKey = `${normalized.providerID || "unknown"}|${normalized.message}`;
    const now = Date.now();
    const lastSentAt = recentByKey.get(dedupeKey) || 0;
    if (now - lastSentAt < DEDUPE_TTL_MS) {
      return false;
    }
    recentByKey.set(dedupeKey, now);

    if (typeof sendApplicationMessage !== "function") {
      return false;
    }

    console.log(
      JSON.stringify({
        event: "opencode_auth_error_forward",
        providerID: normalized.providerID || null,
        threadId: normalized.threadId || null,
        turnId: normalized.turnId || null,
      }),
    );

    sendApplicationMessage(
      JSON.stringify({
        method: "runtime/auth/error",
        params: normalized,
      }),
    );
    return true;
  }

  function inspectTurnFailure({ threadId, turnId, message, error } = {}) {
    return notifyAuthError({
      threadId,
      turnId,
      message,
      error,
      source: "turn_failed",
    });
  }

  return {
    notifyAuthError,
    inspectTurnFailure,
    _logPrefix: logPrefix,
  };
}

function extractOpenCodeAuthError(payload = {}) {
  const errorObject = payload.error && typeof payload.error === "object" ? payload.error : payload;
  if (!isProviderAuthErrorPayload(errorObject) && !isProviderAuthErrorPayload(payload)) {
    return null;
  }

  const providerID = readString(
    payload.providerID ||
      payload.providerId ||
      payload.authProvider ||
      errorObject?.providerID ||
      errorObject?.providerId ||
      errorObject?.authProvider ||
      errorObject?.data?.providerID ||
      errorObject?.data?.providerId ||
      errorObject?.data?.authProvider,
  );
  const message =
    readString(errorObject?.message || payload.message) ||
    "OpenCode provider authentication failed. Re-authenticate on your Mac.";

  return {
    providerID: providerID || null,
    providerId: providerID || null,
    threadId: readString(payload.threadId || payload.thread_id) || null,
    turnId: readString(payload.turnId || payload.turn_id || payload.turnID) || null,
    message,
    errorCode: "provider_auth_error",
    source: readString(payload.source) || "opencode",
  };
}

module.exports = {
  createOpenCodeAuthErrorNotifier,
  extractOpenCodeAuthError,
};
