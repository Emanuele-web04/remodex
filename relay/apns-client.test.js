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
        on() {},
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

test("a session-level error rejects sendNotification instead of crashing the process", async () => {
  const { privateKey } = crypto.generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });

  const client = createAPNsClient({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    bundleId: "com.example.remodex",
    privateKey: privateKey.export({ type: "pkcs8", format: "pem" }),
    http2Connect() {
      const session = new EventEmitter();
      session.request = () => {
        const request = new EventEmitter();
        request.setEncoding = () => {};
        request.end = () => {
          process.nextTick(() => {
            session.emit("error", new Error("ECONNREFUSED"));
          });
        };
        return request;
      };
      session.close = () => {};
      return session;
    },
  });

  await assert.rejects(
    client.sendNotification({
      deviceToken: "aa bb cc",
      apnsEnvironment: "development",
      title: "Ready",
      body: "Response ready",
    }),
    (error) => {
      assert.equal(error.code, "apns_session_error");
      return true;
    }
  );
});

test("sendNotification settles only once when a session error and a request error both fire", async () => {
  const { privateKey } = crypto.generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  let requestErrorHandler = null;

  const client = createAPNsClient({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    bundleId: "com.example.remodex",
    privateKey: privateKey.export({ type: "pkcs8", format: "pem" }),
    http2Connect() {
      const session = new EventEmitter();
      session.request = () => {
        const request = new EventEmitter();
        request.setEncoding = () => {};
        const originalOn = request.on.bind(request);
        request.on = (event, handler) => {
          if (event === "error") {
            requestErrorHandler = handler;
          }
          return originalOn(event, handler);
        };
        request.end = () => {
          process.nextTick(() => {
            session.emit("error", new Error("session down"));
            requestErrorHandler(new Error("stream reset"));
          });
        };
        return request;
      };
      session.close = () => {};
      return session;
    },
  });

  let rejectionCount = 0;
  try {
    await client.sendNotification({
      deviceToken: "aa bb cc",
      apnsEnvironment: "development",
      title: "Ready",
      body: "Response ready",
    });
  } catch (error) {
    rejectionCount += 1;
    assert.equal(error.code, "apns_session_error");
  }

  assert.equal(rejectionCount, 1);
});

function decodeBase64URL(value) {
  const normalized = String(value || "")
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(padded, "base64");
}
