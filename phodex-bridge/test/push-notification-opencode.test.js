// FILE: push-notification-opencode.test.js
// Purpose: Verifies OpenCode-shaped outbound messages use the same push tracker as Codex turns.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/push-notification-tracker

const test = require("node:test");
const assert = require("node:assert/strict");
const { createPushNotificationTracker } = require("../src/push-notification-tracker");

test("OpenCode turn/completed triggers push tracker completion preview", async () => {
  const notifications = [];
  const tracker = createPushNotificationTracker({
    sessionId: "session-opencode",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
    previewMaxChars: 120,
  });

  const threadId = "opencode-thread-abc";
  const turnId = "opencode-turn-xyz";

  tracker.handleOutbound(
    JSON.stringify({
      method: "thread/started",
      params: {
        thread: { id: threadId, title: "OpenCode auth fix" },
      },
    }),
  );
  tracker.handleOutbound(
    JSON.stringify({
      method: "turn/started",
      params: { threadId, turnId },
    }),
  );
  tracker.handleOutbound(
    JSON.stringify({
      method: "item/agentMessage/delta",
      params: {
        threadId,
        turnId,
        delta: "Refactoring the auth module on OpenCode.",
      },
    }),
  );
  tracker.handleOutbound(
    JSON.stringify({
      method: "turn/completed",
      params: {
        threadId,
        turnId,
        status: "completed",
        model: "opencode/gpt-5.5",
      },
    }),
  );

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].threadId, threadId);
  assert.equal(notifications[0].turnId, turnId);
  assert.equal(notifications[0].result, "completed");
  assert.equal(notifications[0].title, "OpenCode auth fix");
  assert.equal(notifications[0].body, "Response ready");
});

test("OpenCode turn/completed does not call push client when base URL is unconfigured (T-09)", async () => {
  const notifications = [];
  const tracker = createPushNotificationTracker({
    sessionId: "session-opencode-unconfigured",
    pushServiceClient: {
      hasConfiguredBaseUrl: false,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
  });

  const threadId = "opencode-thread-unconfigured";
  const turnId = "opencode-turn-unconfigured";

  tracker.handleOutbound(
    JSON.stringify({
      method: "thread/started",
      params: {
        thread: { id: threadId, title: "Silent push" },
      },
    }),
  );
  tracker.handleOutbound(
    JSON.stringify({
      method: "turn/completed",
      params: {
        threadId,
        turnId,
        status: "completed",
      },
    }),
  );

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 0);
});