// FILE: apns-client.js
// Purpose: Sends APNs alert pushes for relay-hosted Remodex notifications using token-based auth.
// Layer: Hosted service helper
// Exports: createAPNsClient
// Depends on: crypto, http2

const crypto = require("crypto");
const http2 = require("http2");

const APNS_TOKEN_TTL_SECONDS = 50 * 60;

function createAPNsClient({
  teamId = "",
  keyId = "",
  bundleId = "",
  privateKey = "",
  now = () => Date.now(),
  http2Connect = http2.connect,
} = {}) {
  let cachedToken = null;

  function isConfigured() {
    return Boolean(teamId && keyId && bundleId && privateKey);
  }

  async function sendNotification({
    deviceToken,
    apnsEnvironment = "production",
    title,
    body,
    payload = {},
  } = {}) {
    if (!isConfigured()) {
      throw apnsError("apns_not_configured", "APNs credentials are not configured.", 503);
    }

    const normalizedDeviceToken = normalizeDeviceToken(deviceToken);
    if (!normalizedDeviceToken) {
      throw apnsError("invalid_device_token", "A valid APNs device token is required.", 400);
    }

    const authority = apnsEnvironment === "development"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";
    const client = http2Connect(authority);

    try {
      const response = await sendRequest(client, {
        ":method": "POST",
        ":path": `/3/device/${normalizedDeviceToken}`,
        authorization: `bearer ${authorizationToken()}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      }, JSON.stringify({
        aps: {
          alert: {
            title: normalizeString(title) || "Remodex",
            body: normalizeString(body) || "Response ready",
          },
          sound: "default",
        },
        ...payload,
      }));

      if (response.status >= 400) {
        throw apnsError(
          "apns_request_failed",
          response.body?.reason || `APNs request failed with HTTP ${response.status}.`,
          response.status
        );
      }

      return { ok: true };
    } finally {
      client.close();
    }
  }

  function authorizationToken() {
    const issuedAt = Math.floor(now() / 1000);
    if (cachedToken && cachedToken.expiresAt > issuedAt + 30) {
      return cachedToken.value;
    }

    const header = base64UrlJSON({ alg: "ES256", kid: keyId });
    const claims = base64UrlJSON({ iss: teamId, iat: issuedAt });
    const signingInput = `${header}.${claims}`;
    const signature = crypto.sign("sha256", Buffer.from(signingInput), {
      key: privateKey,
      dsaEncoding: "ieee-p1363",
    });
    const token = `${signingInput}.${base64Url(signature)}`;

    cachedToken = {
      value: token,
      expiresAt: issuedAt + APNS_TOKEN_TTL_SECONDS,
    };
    return token;
  }

  return {
    isConfigured,
    sendNotification,
  };
}

function sendRequest(client, headers, body) {
  return new Promise((resolve, reject) => {
    const request = client.request(headers);
    const chunks = [];
    let responseHeaders = null;

    request.setEncoding("utf8");
    request.on("response", (headers) => {
      responseHeaders = headers;
    });
    request.on("data", (chunk) => {
      chunks.push(chunk);
    });
    request.on("end", () => {
      resolve({
        status: Number(responseHeaders?.[":status"] || 0),
        body: safeParseJSON(chunks.join("")),
      });
    });
    request.on("error", reject);
    request.end(body);
  });
}

function safeParseJSON(value) {
  if (!value) {
    return null;
  }

  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function base64UrlJSON(value) {
  return base64Url(Buffer.from(JSON.stringify(value)));
}

function base64Url(value) {
  return Buffer.from(value)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function normalizeDeviceToken(value) {
  const normalized = normalizeString(value);
  if (!normalized) {
    return "";
  }

  return normalized.replace(/[^a-fA-F0-9]/g, "").toLowerCase();
}

function normalizeString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function apnsError(code, message, status) {
  const error = new Error(message);
  error.code = code;
  error.status = status;
  return error;
}

module.exports = {
  createAPNsClient,
};
