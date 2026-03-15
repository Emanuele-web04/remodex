// FILE: push-notification-service-client.js
// Purpose: Sends push registration and completion requests from the local Mac bridge to the configured notification service.
// Layer: Bridge helper
// Exports: createPushNotificationServiceClient
// Depends on: global fetch

const DEFAULT_PUSH_SERVICE_TIMEOUT_MS = 10_000;

function createPushNotificationServiceClient({
  baseUrl = "",
  sessionId,
  notificationSecret,
  fetchImpl = globalThis.fetch,
  logPrefix = "[remodex]",
  requestTimeoutMs = DEFAULT_PUSH_SERVICE_TIMEOUT_MS,
} = {}) {
  const normalizedBaseUrl = normalizeBaseUrl(baseUrl);

  async function registerDevice({
    deviceToken,
    alertsEnabled,
    apnsEnvironment,
  } = {}) {
    return postJSON("/v1/push/session/register-device", {
      sessionId,
      notificationSecret,
      deviceToken,
      alertsEnabled,
      apnsEnvironment,
    });
  }

  async function notifyCompletion({
    threadId,
    turnId,
    result,
    title,
    body,
    dedupeKey,
  } = {}) {
    return postJSON("/v1/push/session/notify-completion", {
      sessionId,
      notificationSecret,
      threadId,
      turnId,
      result,
      title,
      body,
      dedupeKey,
    });
  }

  async function postJSON(pathname, payload) {
    if (!normalizedBaseUrl || typeof fetchImpl !== "function") {
      return { ok: false, skipped: true };
    }

    const controller = typeof AbortController === "function" && requestTimeoutMs > 0
      ? new AbortController()
      : null;
    const timeoutID = controller
      ? setTimeout(() => {
        controller.abort(createTimeoutAbortError(requestTimeoutMs));
      }, requestTimeoutMs)
      : null;

    let response;
    try {
      response = await fetchImpl(`${normalizedBaseUrl}${pathname}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: controller?.signal,
      });
    } catch (error) {
      if (isAbortError(error)) {
        const timeoutError = new Error(`Push service request timed out after ${requestTimeoutMs}ms`);
        timeoutError.code = "push_request_timeout";
        throw timeoutError;
      }
      throw error;
    } finally {
      if (timeoutID) {
        clearTimeout(timeoutID);
      }
    }

    const responseText = await response.text();
    const parsed = safeParseJSON(responseText);
    if (!response.ok) {
      const message = parsed?.error || parsed?.message || responseText || `HTTP ${response.status}`;
      const error = new Error(message);
      error.status = response.status;
      throw error;
    }

    return parsed ?? { ok: true };
  }

  return {
    hasConfiguredBaseUrl: Boolean(normalizedBaseUrl),
    registerDevice,
    notifyCompletion,
    logUnavailable() {
      if (!normalizedBaseUrl) {
        console.log(`${logPrefix} push notifications disabled: no push service URL configured`);
      }
    },
  };
}

function normalizeBaseUrl(value) {
  if (typeof value !== "string") {
    return "";
  }

  const trimmed = value.trim();
  if (!trimmed) {
    return "";
  }

  return trimmed.replace(/\/+$/, "");
}

function createTimeoutAbortError(timeoutMs) {
  const error = new Error(`Push service request timed out after ${timeoutMs}ms`);
  error.name = "AbortError";
  return error;
}

function isAbortError(error) {
  return error?.name === "AbortError" || error?.code === "ABORT_ERR";
}

function safeParseJSON(value) {
  if (!value || typeof value !== "string") {
    return null;
  }

  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

module.exports = {
  createPushNotificationServiceClient,
};
