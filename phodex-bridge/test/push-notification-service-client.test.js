// FILE: push-notification-service-client.test.js
// Purpose: Verifies timeout behavior for push-service HTTP calls from the local bridge.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/push-notification-service-client

const test = require("node:test");
const assert = require("node:assert/strict");

const { createPushNotificationServiceClient } = require("../src/push-notification-service-client");

test("push service client aborts stalled requests with a timeout error", async () => {
  const client = createPushNotificationServiceClient({
    baseUrl: "https://push.example.test",
    sessionId: "session-timeout",
    notificationSecret: "secret-timeout",
    requestTimeoutMs: 20,
    fetchImpl: async (_url, options) => new Promise((_, reject) => {
      options.signal.addEventListener("abort", () => {
        reject(options.signal.reason);
      }, { once: true });
    }),
  });

  await assert.rejects(
    client.registerDevice({
      deviceToken: "aabbcc",
      alertsEnabled: true,
      apnsEnvironment: "development",
    }),
    /timed out after 20ms/
  );
});
