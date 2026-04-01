// FILE: convex-helper-client.js
// Purpose: Polls the Convex HTTP-action backend for async bridge requests.
// Layer: CLI helper
// Exports: createConvexHelperClient
// Depends on: fs, os, path

const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  createPublicKey,
  randomBytes,
  sign,
  verify,
} = require("crypto");
const { getTrustedPhonePublicKey } = require("./secure-device-state");

const DEFAULT_POLL_INTERVAL_MS = 2000;
const DEFAULT_LEASE_DURATION_MS = 15000;
const DEFAULT_PROVIDER = "convex";
const DEFAULT_LOG_PREFIX = "[remodex]";

function createConvexHelperClient({
  enabled = false,
  siteUrl = "",
  logPrefix = DEFAULT_LOG_PREFIX,
  onAsyncRequest = null,
  onStatusChange = null,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  leaseDurationMs = DEFAULT_LEASE_DURATION_MS,
  getDeviceState = null,
} = {}) {
  const normalizedEnabled = Boolean(enabled);
  const normalizedSiteUrl = normalizeSiteUrl(siteUrl);
  const normalizedPollIntervalMs = toPositiveInteger(pollIntervalMs, DEFAULT_POLL_INTERVAL_MS);
  const normalizedLeaseDurationMs = toPositiveInteger(leaseDurationMs, DEFAULT_LEASE_DURATION_MS);
  void logPrefix;

  let currentStatus = {
    enabled: normalizedEnabled,
    running: false,
    available: false,
    helperPath: "",
    provider: DEFAULT_PROVIDER,
    siteUrl: normalizedSiteUrl,
    lastError: "",
  };
  let activeRunId = 0;
  let activeController = null;
  let starting = false;

  function publishStatus(nextStatus) {
    currentStatus = {
      ...currentStatus,
      ...nextStatus,
    };

    if (typeof onStatusChange === "function") {
      try {
        onStatusChange(currentStatus);
      } catch {
        // Keep the helper alive if the observer fails.
      }
    }
  }

  function currentHelperStatus() {
    return currentStatus;
  }

  function isCurrentRun(runId, controller) {
    return activeRunId === runId && activeController === controller && !controller.signal.aborted;
  }

  function readMacDeviceId() {
    const filePath = resolveDeviceStateFilePath();
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      const trimmed = raw.replace(/^\uFEFF/, "").trim();
      if (!trimmed) {
        return "";
      }
      const parsed = JSON.parse(trimmed);
      return normalizeString(parsed?.macDeviceId);
    } catch {
      return "";
    }
  }

  async function fetchJson({ endpointPath, method, query = null, body = undefined, signal, label }) {
    const url = buildUrl(currentStatus.siteUrl, endpointPath, query);
    const response = await fetch(url, {
      method,
      signal,
      headers: {
        accept: "application/json",
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const raw = await response.text();
    if (!response.ok) {
      throw new Error(buildHttpError(label, response.status, raw));
    }
    const trimmed = raw.trim();
    if (!trimmed) {
      return null;
    }
    try {
      return JSON.parse(trimmed);
    } catch {
      throw new Error(`${label} returned invalid JSON.`);
    }
  }

  async function validateHealth(controller, runId, site) {
    const responseBody = await fetchJson({
      endpointPath: "/remodex/health",
      method: "GET",
      signal: controller.signal,
      label: "Convex health check",
    });

    if (!isCurrentRun(runId, controller)) {
      return;
    }

    if (isPlainObject(responseBody)) {
      const okValue = responseBody.ok;
      if (okValue === false) {
        throw new Error(normalizeErrorMessage(responseBody.error, "Convex health check reported failure."));
      }

      const statusValue = normalizeString(responseBody.status).toLowerCase();
      if (statusValue && statusValue !== "ok") {
        throw new Error(`Convex health check reported status "${statusValue}".`);
      }

      const providerValue = normalizeString(responseBody.provider).toLowerCase();
      if (providerValue && providerValue !== DEFAULT_PROVIDER) {
        throw new Error(`Convex health check reported provider "${providerValue}".`);
      }
    }

    publishStatus({
      available: true,
      lastError: "",
      siteUrl: site,
    });
  }

  async function claimNextMessage(controller, runId, macDeviceId) {
    const responseBody = await fetchJson({
      endpointPath: "/remodex/messages/outbound/claim",
      method: "GET",
      signal: controller.signal,
      label: "Convex claim request",
      query: {
        toDeviceId: macDeviceId,
        leaseMs: normalizedLeaseDurationMs,
      },
    });

    if (!isCurrentRun(runId, controller)) {
      return null;
    }

    if (isPlainObject(responseBody) && responseBody.ok === false) {
      throw new Error(normalizeErrorMessage(responseBody.error, "Convex claim request reported failure."));
    }

    const message = unwrapMessage(responseBody, getDeviceState);
    if (!message) {
      return null;
    }

    return message;
  }

  async function pollLoop(controller, runId, macDeviceId, site) {
    while (isCurrentRun(runId, controller)) {
      let message = null;
      try {
        message = await claimNextMessage(controller, runId, macDeviceId);
      } catch (error) {
        if (!isCurrentRun(runId, controller)) {
          return;
        }
        publishStatus({
          available: false,
          lastError: describeError(error, "Convex claim request failed."),
        });
        await sleep(normalizedPollIntervalMs, controller.signal);
        continue;
      }

      if (!isCurrentRun(runId, controller)) {
        return;
      }

      publishStatus({
        available: true,
        lastError: "",
        siteUrl: site,
      });

      if (!message) {
        await sleep(normalizedPollIntervalMs, controller.signal);
        continue;
      }

      try {
        if (typeof onAsyncRequest === "function") {
          await Promise.resolve(onAsyncRequest({
            kind: "asyncRequest",
            recordName: message.recordName,
            requestId: message.requestId,
            payloadText: message.payloadText,
          }));
        }
      } catch (error) {
        if (!isCurrentRun(runId, controller)) {
          return;
        }
        publishStatus({
          available: false,
          lastError: describeError(error, "Convex async request handler failed."),
        });
        await sleep(normalizedPollIntervalMs, controller.signal);
      }
    }
  }

  async function postReply(endpointPath, body, fallbackError) {
    if (!currentStatus.running) {
      return false;
    }

    if (!body.recordName) {
      return false;
    }

    try {
      const response = await fetch(buildUrl(currentStatus.siteUrl, endpointPath), {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });
      const raw = await response.text();
      if (!response.ok) {
        throw new Error(buildHttpError("Convex request", response.status, raw));
      }
      publishStatus({
        available: true,
        lastError: "",
      });
      return true;
    } catch (error) {
      publishStatus({
        available: false,
        lastError: describeError(error, fallbackError),
      });
      return false;
    }
  }

  function start() {
    if (!normalizedEnabled || currentStatus.running || starting) {
      return;
    }

    if (!normalizedSiteUrl) {
      publishStatus({
        available: false,
        lastError: "No Convex site URL was configured.",
      });
      return;
    }

    if (!isHttpUrl(normalizedSiteUrl)) {
      publishStatus({
        available: false,
        lastError: "Convex site URL must be an http or https URL.",
      });
      return;
    }

    if (typeof fetch !== "function") {
      publishStatus({
        available: false,
        lastError: "Global fetch is not available in this runtime.",
      });
      return;
    }

    const macDeviceId = readMacDeviceId();
    if (!macDeviceId) {
      publishStatus({
        available: false,
        lastError: "Unable to read macDeviceId from device-state.json.",
      });
      return;
    }

    starting = true;
    const controller = new AbortController();
    const runId = ++activeRunId;
    activeController = controller;
    const site = normalizedSiteUrl;

    publishStatus({
      enabled: true,
      available: false,
      siteUrl: site,
      lastError: "",
    });

    void (async () => {
      try {
        await validateHealth(controller, runId, site);
        if (!isCurrentRun(runId, controller)) {
          return;
        }

        publishStatus({
          running: true,
          available: true,
          siteUrl: site,
          lastError: "",
        });

        await pollLoop(controller, runId, macDeviceId, site);
      } catch (error) {
        if (!isCurrentRun(runId, controller)) {
          return;
        }
        publishStatus({
          running: false,
          available: false,
          lastError: describeError(error, "Convex helper failed to start."),
        });
      } finally {
        if (activeController === controller) {
          activeController = null;
        }
        if (activeRunId === runId) {
          starting = false;
        }
      }
    })();
  }

  function stop() {
    activeRunId += 1;
    starting = false;
    if (activeController) {
      activeController.abort();
      activeController = null;
    }
    publishStatus({
      running: false,
    });
  }

  async function sendResponse({ recordName, payloadText, requestId } = {}) {
    try {
      const body = buildResponseBody(recordName, payloadText);
      if (!body) {
        return false;
      }
      return await postReply(
        "/remodex/messages/outbound/respond",
        body,
        "Convex response request failed."
      );
    } catch (error) {
      publishStatus({
        available: false,
        lastError: describeError(error, "Convex response request failed."),
      });
      return false;
    }
  }

  async function sendError({ recordName, requestId, message } = {}) {
    try {
      const body = buildErrorBody(recordName, requestId, message);
      if (!body) {
        return false;
      }
      return await postReply(
        "/remodex/messages/outbound/error",
        body,
        "Convex error request failed."
      );
    } catch (error) {
      publishStatus({
        available: false,
        lastError: describeError(error, "Convex error request failed."),
      });
      return false;
    }
  }

  return {
    currentStatus: currentHelperStatus,
    start,
    stop,
    sendResponse,
    sendError,
  };
}

function unwrapMessage(value, getDeviceState) {
  if (!isPlainObject(value)) {
    return null;
  }

  const candidates = [
    value.message,
    value.record,
    value.data,
    value.result,
    value,
  ];

  for (const candidate of candidates) {
    if (!isPlainObject(candidate)) {
      continue;
    }

    const recordName = normalizeString(candidate.recordName);
    if (!recordName) {
      continue;
    }

    const payloadText = resolveClaimedPayloadText(candidate, getDeviceState);
    if (!normalizeString(payloadText)) {
      continue;
    }

    return {
      recordName,
      requestId: normalizeString(candidate.requestId),
      payloadText,
    };
  }

  return null;
}

function resolveDeviceStateForAsyncClaim(getDeviceState) {
  if (typeof getDeviceState === "function") {
    try {
      const state = getDeviceState();
      if (state && isPlainObject(state)) {
        return state;
      }
    } catch {
      // Fall back to on-disk state when the live snapshot is unavailable.
    }
  }
  return readDeviceState();
}

function readOptionalConvexString(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  return trimmed ? trimmed : "";
}

function resolveClaimedPayloadText(candidate, getDeviceState) {
  const inlinePayload = stringOrEmpty(candidate.payloadText);
  const ciphertext = readOptionalConvexString(candidate.ciphertext);
  const signature = readOptionalConvexString(candidate.signature);
  const fromDeviceId = normalizeString(candidate.fromDeviceId);

  if (ciphertext && signature && fromDeviceId) {
    const deviceState = resolveDeviceStateForAsyncClaim(getDeviceState);
    if (!deviceState) {
      throw new Error("Convex async claim could not load bridge device state for decryption.");
    }

    const phonePublicKey = getTrustedPhonePublicKey(deviceState, fromDeviceId);
    if (!phonePublicKey) {
      throw new Error(
        `Convex async claim is from an unknown phone device (${fromDeviceId}); refusing ciphertext.`
      );
    }

    const cipherBuffer = Buffer.from(ciphertext, "base64");
    if (!cipherBuffer.length) {
      throw new Error("Convex async claim ciphertext was empty after decoding.");
    }

    if (!verifyPhonePayloadSignature(cipherBuffer, signature, phonePublicKey)) {
      throw new Error("Convex async claim signature verification failed for the trusted phone.");
    }

    const sharedSecret = readSharedSecret(deviceState);
    const plaintext = decryptAesGcmCombined(cipherBuffer, sharedSecret);
    return plaintext.toString("utf8");
  }

  return inlinePayload;
}

function decryptAesGcmCombined(ciphertextBuffer, sharedSecret) {
  if (ciphertextBuffer.length < 12 + 16) {
    throw new Error("Convex ciphertext was too short to decrypt.");
  }

  const iv = ciphertextBuffer.subarray(0, 12);
  const authTag = ciphertextBuffer.subarray(ciphertextBuffer.length - 16);
  const encrypted = ciphertextBuffer.subarray(12, ciphertextBuffer.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", sharedSecret, iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

function verifyPhonePayloadSignature(ciphertextBuffer, signatureBase64, phonePublicKeyBase64) {
  let publicKey;
  try {
    publicKey = createPublicKey({
      key: {
        crv: "Ed25519",
        x: base64ToBase64Url(phonePublicKeyBase64),
        kty: "OKP",
      },
      format: "jwk",
    });
  } catch {
    return false;
  }

  const signature = Buffer.from(normalizeString(signatureBase64), "base64");
  if (!signature.length) {
    return false;
  }

  try {
    return verify(null, ciphertextBuffer, publicKey, signature);
  } catch {
    return false;
  }
}

function buildResponseBody(recordName, payloadText) {
  const normalizedRecordName = normalizeString(recordName);
  if (!normalizedRecordName) {
    return null;
  }

  const normalizedPayloadText = stringOrEmpty(payloadText);
  if (!normalizedPayloadText) {
    return { recordName: normalizedRecordName };
  }

  const deviceState = readDeviceState();
  const sharedSecret = readSharedSecret(deviceState);
  const encryptedPayload = encryptPayload(Buffer.from(normalizedPayloadText, "utf8"), sharedSecret);
  return {
    recordName: normalizedRecordName,
    ciphertext: encryptedPayload.toString("base64"),
    signature: signPayload(encryptedPayload, deviceState),
  };
}

function buildErrorBody(recordName, requestId, message) {
  const normalizedRecordName = normalizeString(recordName);
  if (!normalizedRecordName) {
    return null;
  }

  const normalizedRequestId = normalizeString(requestId);
  if (!normalizedRequestId) {
    return { recordName: normalizedRecordName };
  }

  const errorMessage = normalizeErrorMessage(message, "Bridge request failed.");
  const responsePayload = JSON.stringify({
    id: normalizedRequestId,
    error: {
      code: -32000,
      message: errorMessage,
    },
  });
  const deviceState = readDeviceState();
  const sharedSecret = readSharedSecret(deviceState);
  const encryptedPayload = encryptPayload(Buffer.from(responsePayload, "utf8"), sharedSecret);
  return {
    recordName: normalizedRecordName,
    ciphertext: encryptedPayload.toString("base64"),
    signature: signPayload(encryptedPayload, deviceState),
  };
}

function resolveDeviceStateFilePath() {
  const configuredDir = normalizeString(process.env.REMODEX_DEVICE_STATE_DIR);
  const rootDir = configuredDir || path.join(os.homedir(), ".remodex");
  return path.join(rootDir, "device-state.json");
}

function readDeviceState() {
  const filePath = resolveDeviceStateFilePath();
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    const trimmed = raw.replace(/^\uFEFF/, "").trim();
    if (!trimmed) {
      return null;
    }
    const parsed = JSON.parse(trimmed);
    if (!isPlainObject(parsed)) {
      return null;
    }
    return {
      macDeviceId: normalizeString(parsed.macDeviceId),
      macIdentityPublicKey: normalizeString(parsed.macIdentityPublicKey),
      macIdentityPrivateKey: normalizeString(parsed.macIdentityPrivateKey),
      cloudAsyncSharedSecret: normalizeString(parsed.cloudAsyncSharedSecret),
    };
  } catch {
    return null;
  }
}

function readSharedSecret(deviceState) {
  const sharedSecret = Buffer.from(normalizeString(deviceState?.cloudAsyncSharedSecret), "base64");
  if (sharedSecret.length !== 32) {
    throw new Error("Convex async shared secret is missing or invalid.");
  }
  return sharedSecret;
}

function encryptPayload(plaintext, sharedSecret) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", sharedSecret, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, encrypted, tag]);
}

function signPayload(payload, deviceState) {
  const privateKey = createPrivateKey({
    key: {
      crv: "Ed25519",
      d: base64ToBase64Url(normalizeString(deviceState?.macIdentityPrivateKey)),
      kty: "OKP",
      x: base64ToBase64Url(normalizeString(deviceState?.macIdentityPublicKey)),
    },
    format: "jwk",
  });
  return sign(null, payload, privateKey).toString("base64");
}

function buildUrl(baseUrl, endpointPath, query = null) {
  const url = new URL(endpointPath, baseUrl);
  if (query && isPlainObject(query)) {
    for (const [key, value] of Object.entries(query)) {
      if (value === undefined || value === null || value === "") {
        continue;
      }
      url.searchParams.set(key, String(value));
    }
  }
  return url;
}

function buildHttpError(label, status, rawBody) {
  const suffix = normalizeString(rawBody);
  return suffix ? `${label} failed with HTTP ${status}: ${suffix}` : `${label} failed with HTTP ${status}.`;
}

function describeError(error, fallback) {
  if (typeof error === "string") {
    const normalized = normalizeString(error);
    return normalized || fallback;
  }

  if (isPlainObject(error) && typeof error.message === "string") {
    const normalized = normalizeString(error.message);
    return normalized || fallback;
  }

  return fallback;
}

function normalizeErrorMessage(value, fallback) {
  if (typeof value === "string") {
    const normalized = normalizeString(value);
    if (normalized) {
      return normalized;
    }
  }

  if (isPlainObject(value) && typeof value.message === "string") {
    const normalized = normalizeString(value.message);
    if (normalized) {
      return normalized;
    }
  }

  return fallback;
}

function normalizeSiteUrl(value) {
  const normalized = normalizeString(value);
  return normalized ? normalized.replace(/\/+$/, "") : "";
}

function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function stringOrEmpty(value) {
  return typeof value === "string" ? value : "";
}

function base64ToBase64Url(value) {
  return normalizeString(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function toNonNegativeInteger(value, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }
  return Math.max(0, Math.trunc(numeric));
}

function toPositiveInteger(value, fallback) {
  const numeric = toNonNegativeInteger(value, fallback);
  return numeric > 0 ? numeric : fallback;
}

function isHttpUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

async function sleep(ms, signal) {
  const delay = Math.max(0, Number(ms) || 0);
  if (delay === 0) {
    return;
  }

  await new Promise((resolve) => {
    if (signal?.aborted) {
      resolve();
      return;
    }

    let timeoutId = null;
    const cleanup = () => {
      if (timeoutId !== null) {
        clearTimeout(timeoutId);
        timeoutId = null;
      }
      signal?.removeEventListener("abort", onAbort);
    };
    const onAbort = () => {
      cleanup();
      resolve();
    };

    timeoutId = setTimeout(() => {
      cleanup();
      resolve();
    }, delay);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

module.exports = {
  createConvexHelperClient,
};
