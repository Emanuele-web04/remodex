// FILE: apns-client.test.js
// Purpose: Verifies APNs JWT generation uses the JOSE ES256 signature format that APNs expects.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, node:crypto, node:events, ./apns-client

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { EventEmitter } = require("node:events");

const { createAPNsClient } = require("./apns-client");

test("APNs authorization tokens use a 64-byte JOSE ES256 signature", async () => {
  const { privateKey } = crypto.generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  let capturedAuthorizationHeader = null;

  const client = createAPNsClient({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    bundleId: "com.example.remodex",
    privateKey: privateKey.export({ type: "pkcs8", format: "pem" }),
    http2Connect() {
      return {
        request(headers) {
          capturedAuthorizationHeader = headers.authorization;
          const request = new EventEmitter();
          request.setEncoding = () => {};
          request.end = () => {
            process.nextTick(() => {
              request.emit("response", { ":status": 200 });
              request.emit("data", "{}");
              request.emit("end");
            });
          };
          return request;
        },
        close() {},
      };
    },
  });

  await client.sendNotification({
    deviceToken: "aa bb cc",
    apnsEnvironment: "development",
    title: "Ready",
    body: "Response ready",
  });

  const token = String(capturedAuthorizationHeader || "").replace(/^bearer\s+/i, "");
  const [, , encodedSignature] = token.split(".");
  const signature = decodeBase64URL(encodedSignature);

  assert.equal(signature.length, 64);
});

function decodeBase64URL(value) {
  const normalized = String(value || "")
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(padded, "base64");
}
