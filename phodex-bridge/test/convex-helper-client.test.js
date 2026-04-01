// FILE: convex-helper-client.test.js
// Purpose: Verifies the Convex helper client used by the local bridge.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/convex-helper-client

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  generateKeyPairSync,
  randomBytes,
  sign,
} = require("node:crypto");

const {
  createConvexHelperClient,
} = require("../src/convex-helper-client");

const { waitFor } = require("./test-utils");

const EXPECTED_CONVEX_SITE_URL = "https://determined-ladybug-18.convex.site";

test("createConvexHelperClient covers the Convex helper lifecycle", async (t) => {
  await t.test("starts with the expected default status shape", () => {
    const client = createConvexHelperClient();

    assert.deepEqual(client.currentStatus(), {
      enabled: false,
      running: false,
      available: false,
      helperPath: "",
      provider: "convex",
      siteUrl: "",
      lastError: "",
    });
  });

  await t.test("normalizes the configured site URL before exposing it in status", () => {
    const client = createConvexHelperClient({
      enabled: true,
      siteUrl: " https://example.convex.site/ ",
    });

    assert.deepEqual(client.currentStatus(), {
      enabled: true,
      running: false,
      available: false,
      helperPath: "",
      provider: "convex",
      siteUrl: "https://example.convex.site",
      lastError: "",
    });
  });

  await t.test("publishes healthy status and polls the expected outbound claim endpoint", async (t) => {
    const deviceState = makeDeviceState();
    await withDeviceState(deviceState, async () => {
      const requests = [];
      const statuses = [];
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "ok", provider: "convex" }),
        "/async/outbound/claim": ({ query }) => {
          assert.equal(query.toDeviceId, deviceState.macDeviceId);
          assert.equal(query.leaseMs, "25");
          return emptyResponse(204);
        },
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      t.after(() => {
        client?.stop();
        global.fetch = originalFetch;
      });

      client = createConvexHelperClient({
        enabled: true,
        siteUrl: ` ${EXPECTED_CONVEX_SITE_URL}/ `,
        pollIntervalMs: 50,
        leaseDurationMs: 25,
        onAsyncRequest: null,
        onStatusChange(status) {
          statuses.push({ ...status });
        },
      });

      client.start();
      await waitFor(
        () => requests.some((request) => request.path === "/async/outbound/claim"),
        5_000
      );
      assert.ok(
        statuses.some((status) => status.running && status.available && status.siteUrl === EXPECTED_CONVEX_SITE_URL)
      );
      assert.deepEqual(
        requests.map((request) => request.path),
        ["/async/health", "/async/outbound/claim"]
      );
      assert.equal(requests[0].method, "GET");
      assert.equal(requests[1].method, "GET");
      assert.deepEqual(requests[0].body, null);
      assert.deepEqual(requests[1].body, null);
      assert.equal(client.currentStatus().siteUrl, EXPECTED_CONVEX_SITE_URL);
      client.stop();
      await waitFor(() => !client.currentStatus().running, 5_000);
      assert.equal(client.currentStatus().running, false);
      assert.equal(client.currentStatus().lastError, "");
    });
  });

  await t.test("marks the helper unavailable when Convex health reports a degraded status", async () => {
    const deviceState = makeDeviceState();
    await withDeviceState(deviceState, async () => {
      const requests = [];
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "degraded", provider: "convex" }),
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      try {
        const statuses = [];
        client = createConvexHelperClient({
          enabled: true,
          siteUrl: EXPECTED_CONVEX_SITE_URL,
          pollIntervalMs: 50,
          onStatusChange(status) {
            statuses.push({ ...status });
          },
        });

        client.start();
        await waitFor(() => !client.currentStatus().running && client.currentStatus().lastError.length > 0);

        assert.deepEqual(requests.map((request) => request.path), ["/async/health"]);
        assert.equal(client.currentStatus().running, false);
        assert.equal(client.currentStatus().available, false);
        assert.equal(client.currentStatus().lastError, "Convex health check reported status \"degraded\".");
        assert.ok(
          statuses.some((status) => status.available === false && status.lastError === "Convex health check reported status \"degraded\".")
        );
      } finally {
        client?.stop();
        global.fetch = originalFetch;
      }
    });
  });

  await t.test("marks the helper unavailable when Convex health reports the wrong provider", async () => {
    const deviceState = makeDeviceState();
    await withDeviceState(deviceState, async () => {
      const requests = [];
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "ok", provider: "cloudkit" }),
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      try {
        const statuses = [];
        client = createConvexHelperClient({
          enabled: true,
          siteUrl: EXPECTED_CONVEX_SITE_URL,
          pollIntervalMs: 50,
          onStatusChange(status) {
            statuses.push({ ...status });
          },
        });

        client.start();
        await waitFor(() => !client.currentStatus().running && client.currentStatus().lastError.length > 0);

        assert.deepEqual(requests.map((request) => request.path), ["/async/health"]);
        assert.equal(client.currentStatus().running, false);
        assert.equal(client.currentStatus().available, false);
        assert.equal(client.currentStatus().lastError, "Convex health check reported provider \"cloudkit\".");
        assert.ok(
          statuses.some((status) => status.available === false && status.lastError === "Convex health check reported provider \"cloudkit\".")
        );
      } finally {
        client?.stop();
        global.fetch = originalFetch;
      }
    });
  });

  await t.test("marks the helper unavailable when the claim request reports a failure", async () => {
    const deviceState = makeDeviceState();
    await withDeviceState(deviceState, async () => {
      const requests = [];
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "ok", provider: "convex" }),
        "/async/outbound/claim": ({ query }) => {
          assert.equal(query.toDeviceId, deviceState.macDeviceId);
          assert.equal(query.leaseMs, "25");
          return jsonResponse({ ok: false, error: "Convex claim denied." });
        },
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      try {
        const statuses = [];
        client = createConvexHelperClient({
          enabled: true,
          siteUrl: EXPECTED_CONVEX_SITE_URL,
          pollIntervalMs: 50,
          leaseDurationMs: 25,
          onStatusChange(status) {
            statuses.push({ ...status });
          },
        });
        client.start();
        await waitFor(() => client.currentStatus().lastError === "Convex claim denied.");
        client.stop();
        await waitFor(() => !client.currentStatus().running);

        assert.deepEqual(
          requests.map((request) => request.path),
          ["/async/health", "/async/outbound/claim"]
        );
        assert.equal(client.currentStatus().running, false);
        assert.equal(client.currentStatus().available, false);
        assert.equal(client.currentStatus().lastError, "Convex claim denied.");
        assert.ok(
          statuses.some((status) => status.running && status.available && status.siteUrl === EXPECTED_CONVEX_SITE_URL)
        );
        assert.ok(
          statuses.some((status) => status.available === false && status.lastError === "Convex claim denied.")
        );
      } finally {
        client?.stop();
        global.fetch = originalFetch;
      }
    });
  });

  await t.test("marks the helper unavailable when the async request handler throws", async () => {
    const deviceState = makeDeviceState();
    await withDeviceState(deviceState, async () => {
      const requests = [];
      const asyncRequests = [];
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "ok", provider: "convex" }),
        "/async/outbound/claim": () =>
          jsonResponse({
            message: {
              recordName: "record-1",
              requestId: "req-1",
              payloadText: "payload",
            },
          }),
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      try {
        const statuses = [];
        client = createConvexHelperClient({
          enabled: true,
          siteUrl: EXPECTED_CONVEX_SITE_URL,
          pollIntervalMs: 50,
          leaseDurationMs: 25,
          onAsyncRequest(message) {
            asyncRequests.push({ ...message });
            throw new Error("Bridge async handler exploded.");
          },
          onStatusChange(status) {
            statuses.push({ ...status });
          },
        });
        client.start();
        await waitFor(() => client.currentStatus().lastError === "Bridge async handler exploded.");
        client.stop();
        await waitFor(() => !client.currentStatus().running);

        assert.deepEqual(
          requests.map((request) => request.path),
          ["/async/health", "/async/outbound/claim"]
        );
        assert.deepEqual(asyncRequests, [
          {
            kind: "asyncRequest",
            recordName: "record-1",
            requestId: "req-1",
            payloadText: "payload",
          },
        ]);
        assert.equal(client.currentStatus().running, false);
        assert.equal(client.currentStatus().available, false);
        assert.equal(client.currentStatus().lastError, "Bridge async handler exploded.");
        assert.ok(
          statuses.some((status) => status.available === false && status.lastError === "Bridge async handler exploded.")
        );
      } finally {
        client?.stop();
        global.fetch = originalFetch;
      }
    });
  });

  await t.test("posts encrypted response and error payloads to the Convex bridge endpoints", async () => {
    const deviceState = makeDeviceState();
    await withDeviceState(deviceState, async () => {
      const requests = [];
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "ok", provider: "convex" }),
        "/async/outbound/claim": () => emptyResponse(204),
        "/async/outbound/respond": () => emptyResponse(204),
        "/async/outbound/error": () => emptyResponse(204),
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      try {
        const statuses = [];
        const done = new Promise((resolve, reject) => {
          let triggered = false;
          client = createConvexHelperClient({
            enabled: true,
            siteUrl: EXPECTED_CONVEX_SITE_URL,
            pollIntervalMs: 50,
            leaseDurationMs: 25,
            onStatusChange(status) {
              statuses.push({ ...status });
              if (
                !triggered &&
                status.running &&
                status.available &&
                requests.some((request) => request.path === "/async/outbound/claim")
              ) {
                triggered = true;
                void (async () => {
                  try {
                    const responseResult = await client.sendResponse({
                      recordName: "record-response",
                      payloadText: "bridge payload",
                    });
                    const errorResult = await client.sendError({
                      recordName: "record-error",
                      requestId: "req-77",
                      message: "bridge failed",
                    });
                    client.stop();
                    resolve({ responseResult, errorResult });
                  } catch (error) {
                    reject(error);
                  }
                })();
              }
            },
          });
          client.start();
        });

        const { responseResult, errorResult } = await done;

        assert.equal(responseResult, true);
        assert.equal(errorResult, true);

        const responseRequest = requests.find((request) => request.path === "/async/outbound/respond");
        const errorRequest = requests.find((request) => request.path === "/async/outbound/error");

        assert.ok(responseRequest);
        assert.ok(errorRequest);
        assert.equal(responseRequest.method, "POST");
        assert.equal(errorRequest.method, "POST");
        assert.equal(responseRequest.body.recordName, "record-response");
        assert.equal(errorRequest.body.recordName, "record-error");
        assert.equal(responseRequest.body.ciphertext.length > 0, true);
        assert.equal(responseRequest.body.signature.length > 0, true);
        assert.equal(errorRequest.body.ciphertext.length > 0, true);
        assert.equal(errorRequest.body.signature.length > 0, true);

        assert.equal(
          decryptEnvelope(responseRequest.body.ciphertext, deviceState.cloudAsyncSharedSecret),
          "bridge payload"
        );
        assert.deepEqual(
          JSON.parse(decryptEnvelope(errorRequest.body.ciphertext, deviceState.cloudAsyncSharedSecret)),
          {
            id: "req-77",
            error: {
              code: -32000,
              message: "bridge failed",
            },
          }
        );
        assert.ok(
          statuses.some((status) => status.running && status.available && status.siteUrl === EXPECTED_CONVEX_SITE_URL)
        );
      } finally {
        client?.stop();
        global.fetch = originalFetch;
      }
    });
  });

  await t.test("decrypts Convex claim ciphertext using the trusted phone identity", async () => {
    const macState = makeDeviceState();
    const phone = generateKeyPairSync("ed25519");
    const phonePublicJwk = phone.publicKey.export({ format: "jwk" });
    const phonePrivateJwk = phone.privateKey.export({ format: "jwk" });
    const phoneDeviceId = `phone-${cryptoId()}`;
    const deviceState = {
      ...macState,
      trustedPhones: {
        [phoneDeviceId]: base64UrlToBase64(phonePublicJwk.x),
      },
    };

    const plaintext = JSON.stringify({
      id: "req-cipher-1",
      method: "thread/list",
      params: {},
    });
    const sharedSecret = Buffer.from(deviceState.cloudAsyncSharedSecret, "base64");
    const encrypted = encryptAesGcmPayload(Buffer.from(plaintext, "utf8"), sharedSecret);
    const phonePrivateKey = createPrivateKey({
      key: {
        crv: "Ed25519",
        d: phonePrivateJwk.d,
        kty: "OKP",
        x: phonePublicJwk.x,
      },
      format: "jwk",
    });
    const signature = sign(null, encrypted, phonePrivateKey).toString("base64");

    await withDeviceState(deviceState, async () => {
      const requests = [];
      const asyncRequests = [];
      let claimReturnedMessage = false;
      const fetchImpl = createFetchRecorder({
        "/async/health": () =>
          jsonResponse({ status: "ok", provider: "convex" }),
        "/async/outbound/claim": () => {
          if (claimReturnedMessage) {
            return emptyResponse(204);
          }
          claimReturnedMessage = true;
          return jsonResponse({
            message: {
              recordName: "convex-record-1",
              requestId: "req-cipher-1",
              fromDeviceId: phoneDeviceId,
              toDeviceId: deviceState.macDeviceId,
              ciphertext: encrypted.toString("base64"),
              signature,
            },
          });
        },
      }, requests);

      const originalFetch = global.fetch;
      global.fetch = fetchImpl;
      let client;
      try {
        client = createConvexHelperClient({
          enabled: true,
          siteUrl: EXPECTED_CONVEX_SITE_URL,
          pollIntervalMs: 50,
          leaseDurationMs: 25,
          getDeviceState: () => deviceState,
          onAsyncRequest(message) {
            asyncRequests.push({ ...message });
          },
        });
        client.start();
        await waitFor(() => asyncRequests.length > 0);
        client.stop();
        await waitFor(() => !client.currentStatus().running);

        assert.equal(asyncRequests.length, 1);
        assert.equal(asyncRequests[0].payloadText, plaintext);
        assert.equal(asyncRequests[0].recordName, "convex-record-1");
        assert.equal(asyncRequests[0].requestId, "req-cipher-1");
      } finally {
        client?.stop();
        global.fetch = originalFetch;
      }
    });
  });
});

function encryptAesGcmPayload(plaintext, sharedSecret) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", sharedSecret, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, encrypted, tag]);
}

function createFetchRecorder(responders, requests) {
  return async (input, options = {}) => {
    const url = new URL(input);
    const rawBody = typeof options.body === "string" ? options.body : "";
    const body = rawBody ? JSON.parse(rawBody) : null;
    requests.push({
      path: url.pathname,
      method: options.method || "GET",
      query: Object.fromEntries(url.searchParams.entries()),
      body,
      rawBody,
    });

    const responder = responders[url.pathname];
    if (!responder) {
      throw new Error(`Unexpected Convex helper request: ${url.pathname}`);
    }

    return responder({ url, options, body, query: Object.fromEntries(url.searchParams.entries()) });
  };
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
    },
  });
}

function emptyResponse(status = 204) {
  return new Response(null, { status });
}

function decryptEnvelope(ciphertextBase64, sharedSecretBase64) {
  const ciphertext = Buffer.from(ciphertextBase64, "base64");
  const iv = ciphertext.subarray(0, 12);
  const tag = ciphertext.subarray(ciphertext.length - 16);
  const payload = ciphertext.subarray(12, ciphertext.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", Buffer.from(sharedSecretBase64, "base64"), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(payload), decipher.final()]).toString("utf8");
}

function makeDeviceState() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicJwk = publicKey.export({ format: "jwk" });
  const privateJwk = privateKey.export({ format: "jwk" });

  return {
    macDeviceId: `mac-${cryptoId()}`,
    macIdentityPublicKey: base64UrlToBase64(publicJwk.x),
    macIdentityPrivateKey: base64UrlToBase64(privateJwk.d),
    cloudAsyncSharedSecret: randomBytes(32).toString("base64"),
  };
}

async function withDeviceState(deviceState, fn) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "convex-helper-client-"));
  fs.writeFileSync(
    path.join(tempDir, "device-state.json"),
    JSON.stringify(deviceState, null, 2),
    "utf8"
  );

  process.env.REMODEX_DEVICE_STATE_DIR = tempDir;
  try {
    return await fn();
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}


function base64UrlToBase64(value) {
  const normalized = String(value).replace(/-/g, "+").replace(/_/g, "/");
  const padding = (4 - (normalized.length % 4)) % 4;
  return normalized + "=".repeat(padding);
}

function cryptoId() {
  return randomBytes(8).toString("hex");
}
