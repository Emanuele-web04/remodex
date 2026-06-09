// FILE: push-notification-service-client.js
// Purpose: Sends push registration and completion requests from the local Mac bridge to the configured notification service.
// Layer: Bridge helper
// Exports: createPushNotificationServiceClient
// Depends on: global fetch

const { safeParseJSON } = require("./safe-json");

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
  retryLimit = DEFAULT_PUSH_SERVICE_RETRY_LIMIT,
  retryBaseDelayMs = DEFAULT_PUSH_SERVICE_RETRY_BASE_DELAY_MS,
  sleepImpl = sleep,
} = {}) {
  const normalizedBaseUrl = normalizeBaseUrl(baseUrl);
  const safeRetryLimit = normalizeNonNegativeInteger(retryLimit, DEFAULT_PUSH_SERVICE_RETRY_LIMIT);
  const safeRetryBaseDelayMs = normalizeNonNegativeInteger(
    retryBaseDelayMs,
    DEFAULT_PUSH_SERVICE_RETRY_BASE_DELAY_MS
  );

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

  async function notifyPermissionNeeded({
    threadId,
    turnId,
    title,
    body,
    dedupeKey,
  } = {}) {
    return postJSON("/v1/push/session/notify-permission", {
      sessionId,
      notificationSecret,
      threadId,
      turnId,
      title,
      body,
      dedupeKey,
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
    for (let attempt = 0; attempt <= safeRetryLimit; attempt += 1) {
      if (attempt > 0) {
        const delayMs = safeRetryBaseDelayMs * Math.pow(2, attempt - 1);
        if (delayMs > 0) {
          await sleepImpl(delayMs);
        }
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
        if (response.status >= 500 && attempt < safeRetryLimit) {
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
    notifyPermissionNeeded,
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

  const normalized = trimmed.replace(/\/+$/, "");
  
  // Security: Validate URL against whitelist
  validatePushServiceUrl(normalized);
  
  return normalized;
}

function validatePushServiceUrl(url) {
  try {
    const parsedUrl = new URL(url);

    // Require HTTP or HTTPS protocol for all URLs
    if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
      throw new Error(
        `Push service URL must use HTTP or HTTPS protocol. URL: ${url}`
      );
    }

    // Allow localhost and loopback for testing.
    const hostname = parsedUrl.hostname.toLowerCase();
    if (
      hostname === 'localhost' ||
      hostname === '127.0.0.1' ||
      hostname === '::1' ||
      hostname === '[::1]'
    ) {
      // Allow HTTP for local loopback targets.
      return;
    }

    // Require HTTPS for non-localhost
    if (parsedUrl.protocol !== 'https:') {
      throw new Error(
        `Push service URL must use HTTPS for non-localhost domains. URL: ${url}`
      );
    }

    // Whitelist of allowed push service domains
    // Add production/staging domains here as needed
    const allowedDomains = [
      // Example: 'push.remodex.dev',
      // Example: 'push-staging.remodex.dev',
    ];

    // Reject non-localhost domains when whitelist is empty
    if (allowedDomains.length === 0) {
      throw new Error(
        `Push service URL whitelist is empty - non-localhost domains not allowed. Hostname: ${hostname}`
      );
    }

    const isAllowed = allowedDomains.some(domain =>
      hostname === domain || hostname.endsWith(`.${domain}`)
    );

    if (!isAllowed) {
      console.error(
        `Push service URL hostname not in whitelist: ${hostname}. ` +
        `Allowed: ${allowedDomains.join(', ')}`
      );
      throw new Error(
        `Push service URL hostname not allowed: ${hostname}`
      );
    }

  } catch (error) {
    if (error.message.includes('Push service URL')) {
      throw error;
    }
    throw new Error(`Invalid push service URL format: ${url} - ${error.message}`);
  }
}

function createTimeoutAbortError(timeoutMs) {
  const error = new Error(`Push service request timed out after ${timeoutMs}ms`);
  error.name = "AbortError";
  error.code = "push_request_timeout";
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

function normalizeNonNegativeInteger(value, fallback) {
  return Number.isInteger(value) && value >= 0 ? value : fallback;
}

function sleep(delayMs) {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}


module.exports = {
  createPushNotificationServiceClient,
};
