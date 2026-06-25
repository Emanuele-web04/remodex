// FILE: opencode-usage-mapper.js
// Purpose: Maps OpenCode session token counters into Remodex context-window usage
//          shape, and detects provider auth-error payloads for the auth-error notifier.
// Layer: Bridge helper
// Exports: mapOpenCodeSessionToContextUsage, resolveOpenCodeSessionPayload, isProviderAuthErrorPayload
// Depends on: ./normalize

const { readString } = require("./normalize");

function resolveOpenCodeSessionPayload(response) {
  if (!response || typeof response !== "object") {
    return null;
  }
  if (response.data && typeof response.data === "object" && !Array.isArray(response.data)) {
    return response.data;
  }
  return response;
}

function readTokenCount(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 0;
}

// Converts OpenCode session token counters into the iOS ContextWindowUsage wire shape.
function mapOpenCodeSessionToContextUsage(session, { tokenLimit = 0 } = {}) {
  const payload = resolveOpenCodeSessionPayload(session);
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const tokens = payload.tokens && typeof payload.tokens === "object" ? payload.tokens : {};
  const cache = tokens.cache && typeof tokens.cache === "object" ? tokens.cache : {};
  const tokensUsed =
    readTokenCount(tokens.total) ||
    readTokenCount(tokens.input) +
      readTokenCount(tokens.output) +
      readTokenCount(tokens.reasoning) +
      readTokenCount(cache.read) +
      readTokenCount(cache.write);

  const resolvedLimit =
    readTokenCount(tokenLimit) ||
    readTokenCount(payload.contextWindow) ||
    readTokenCount(payload.context_window) ||
    readTokenCount(payload.modelContextWindow) ||
    readTokenCount(payload.model_context_window);

  if (!resolvedLimit) {
    return null;
  }

  return {
    tokensUsed: Math.min(tokensUsed, resolvedLimit),
    tokenLimit: resolvedLimit,
  };
}

const PROVIDER_AUTH_ERROR_CODES = new Set([
  "provider_auth_error",
  "providerautherror",
  "authentication_failed",
  "auth_error",
  "invalid_api_key",
  "api_key_invalid",
]);

function readStructuredErrorCode(error) {
  return readString(
    error?.errorCode ||
      error?.code ||
      error?.data?.errorCode ||
      error?.data?.code,
  ).toLowerCase();
}

function readStructuredProviderId(error) {
  return readString(
    error?.providerID ||
      error?.providerId ||
      error?.data?.providerID ||
      error?.data?.providerId ||
      error?.authProvider ||
      error?.data?.authProvider,
  );
}

function readStructuredHttpStatus(error) {
  const status = Number(error?.status ?? error?.statusCode ?? error?.response?.status);
  return Number.isFinite(status) ? status : null;
}

function isProviderAuthErrorPayload(error) {
  if (!error || typeof error !== "object") {
    return false;
  }

  const name = readString(error.name || error.type).toLowerCase();
  if (name === "providerautherror") {
    return true;
  }

  const errorCode = readStructuredErrorCode(error);
  if (PROVIDER_AUTH_ERROR_CODES.has(errorCode)) {
    return true;
  }

  const providerID = readStructuredProviderId(error);
  const status = readStructuredHttpStatus(error);
  if (providerID && (status === 401 || status === 403)) {
    return true;
  }

  if (providerID && (errorCode === "unauthorized" || errorCode === "forbidden")) {
    return true;
  }

  return false;
}

module.exports = {
  mapOpenCodeSessionToContextUsage,
  resolveOpenCodeSessionPayload,
  isProviderAuthErrorPayload,
};
