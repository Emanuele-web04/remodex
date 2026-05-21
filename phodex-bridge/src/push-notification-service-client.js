// FILE: push-notification-service-client.js
// Purpose: Sends push registration and completion requests from the local Mac bridge to the configured notification service.
// Layer: Bridge helper
// Exports: createPushNotificationServiceClient
// Depends on: global fetch

const DEFAULT_PUSH_SERVICE_TIMEOUT_MS = 10_000;
const DEFAULT_PUSH_SERVICE_RETRY_LIMIT = 2;
const DEFAULT_PUSH_SERVICE_RETRY_BASE_DELAY_MS = 500;

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

    const bodyJSON = JSON.stringify(payload);
    let lastError = null;
    for (let attempt = 0; attempt <= DEFAULT_PUSH_SERVICE_RETRY_LIMIT; attempt += 1) {
      if (attempt > 0) {
        const delayMs = DEFAULT_PUSH_SERVICE_RETRY_BASE_DELAY_MS * Math.pow(2, attempt - 1);
        await new Promise((resolve) => setTimeout(resolve, delayMs));
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
          body: bodyJSON,
          signal: controller?.signal,
        });
      } catch (error) {
        lastError = error;
        if (isAbortError(error)) {
          continue;
        }
        if (isRetryableNetworkError(error)) {
          continue;
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
        if (response.status >= 500 && attempt < DEFAULT_PUSH_SERVICE_RETRY_LIMIT) {
          lastError = error;
          continue;
        }
        throw error;
      }

      return parsed ?? { ok: true };
    }

    if (lastError) {
      throw lastError;
    }
    return { ok: false };
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

function isRetryableNetworkError(error) {
  const code = error?.code ?? "";
  return code === "ECONNRESET" || code === "ECONNREFUSED" || code === "ETIMEDOUT"
    || code === "ENETUNREACH" || code === "EHOSTUNREACH" || code === "ENOTFOUND"
    || error?.message?.includes("fetch failed");
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
