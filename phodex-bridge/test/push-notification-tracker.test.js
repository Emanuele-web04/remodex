// FILE: push-notification-tracker.test.js
// Purpose: Verifies managed push registration routing and completion preview tracking in the local bridge.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/push-notification-tracker, ../src/notifications-handler

const test = require("node:test");
const assert = require("node:assert/strict");

const { createPushNotificationTracker } = require("../src/push-notification-tracker");
const { createNotificationsHandler } = require("../src/notifications-handler");

test("push tracker sends one completion push with a stable ready body", async () => {
  const notifications = [];
  const tracker = createPushNotificationTracker({
    sessionId: "session-1",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
    previewMaxChars: 80,
  });

  tracker.handleOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-1",
        title: "Fix auth bug",
      },
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "item/agentMessage/delta",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
      delta: "Looking at the login flow.",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
      item: {
        type: "agent_message",
        role: "assistant",
        text: "The login fix is ready to review.",
      },
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].threadId, "thread-1");
  assert.equal(notifications[0].turnId, "turn-1");
  assert.equal(notifications[0].result, "completed");
  assert.equal(notifications[0].title, "Fix auth bug");
  assert.equal(notifications[0].body, "Response ready");
});

test("push tracker ignores non-assistant item completions when a turn finishes", async () => {
  const notifications = [];
  const tracker = createPushNotificationTracker({
    sessionId: "session-tools",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
  });

  tracker.handleOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-tools",
      turnId: "turn-tools",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-tools",
      turnId: "turn-tools",
      item: {
        type: "commandExecution",
        status: "completed",
        command: "/bin/zsh -lc \"echo one\"",
      },
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-tools",
      turnId: "turn-tools",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].body, "Response ready");
});

test("push tracker uses failure previews for failed turns", async () => {
  const notifications = [];
  const tracker = createPushNotificationTracker({
    sessionId: "session-2",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
  });

  tracker.handleOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-2",
      turnId: "turn-2",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "turn/failed",
    params: {
      threadId: "thread-2",
      turnId: "turn-2",
      message: "Tests failed on CI.",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-2",
      turnId: "turn-2",
      turn: {
        status: "failed",
      },
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].result, "failed");
  assert.equal(notifications[0].body, "Tests failed on CI.");
});

test("push tracker sends a failed push for terminal error events", async () => {
  const notifications = [];
  const tracker = createPushNotificationTracker({
    sessionId: "session-error",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
  });

  tracker.handleOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-error",
      turnId: "turn-error",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "error",
    params: {
      threadId: "thread-error",
      turnId: "turn-error",
      message: "Connection dropped while applying the patch.",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].result, "failed");
  assert.equal(notifications[0].body, "Connection dropped while applying the patch.");
});

test("push tracker dedupes turnless terminal thread statuses per time bucket", async () => {
  const notifications = [];
  let currentTime = 0;
  const tracker = createPushNotificationTracker({
    sessionId: "session-status",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
    now: () => currentTime,
  });

  tracker.handleOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-status",
        title: "Status-only runtime",
      },
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "thread/status/changed",
    params: {
      threadId: "thread-status",
      status: "completed",
    },
  }));
  tracker.handleOutbound(JSON.stringify({
    method: "thread/status/changed",
    params: {
      threadId: "thread-status",
      status: "completed",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  currentTime = 31_000;
  tracker.handleOutbound(JSON.stringify({
    method: "thread/status/changed",
    params: {
      threadId: "thread-status",
      status: "completed",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 2);
  assert.equal(notifications[0].threadId, "thread-status");
  assert.equal(notifications[0].result, "completed");
  assert.equal(notifications[0].body, "Response ready");
  assert.equal(notifications[1].result, "completed");
});

test("push tracker ignores thread-status fallback after a turn completion already notified", async () => {
  const notifications = [];
  let currentTime = 0;
  const tracker = createPushNotificationTracker({
    sessionId: "session-mixed-runtime",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
    now: () => currentTime,
  });

  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-mixed-runtime",
      turnId: "turn-mixed-runtime",
    },
  }));

  currentTime = 1_000;
  tracker.handleOutbound(JSON.stringify({
    method: "thread/status/changed",
    params: {
      threadId: "thread-mixed-runtime",
      status: "completed",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].turnId, "turn-mixed-runtime");
  assert.equal(notifications[0].result, "completed");
});

test("push tracker clears fallback suppression when a new turn starts", async () => {
  const notifications = [];
  let currentTime = 0;
  const tracker = createPushNotificationTracker({
    sessionId: "session-queued-runtime",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
    now: () => currentTime,
  });

  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-queued-runtime",
      turnId: "turn-a",
    },
  }));

  currentTime = 1_000;
  tracker.handleOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-queued-runtime",
      turnId: "turn-b",
    },
  }));

  currentTime = 2_000;
  tracker.handleOutbound(JSON.stringify({
    method: "thread/status/changed",
    params: {
      threadId: "thread-queued-runtime",
      status: "completed",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(notifications.length, 2);
  assert.equal(notifications[0].turnId, "turn-a");
  assert.equal(notifications[1].threadId, "thread-queued-runtime");
  assert.equal(notifications[1].result, "completed");
});

test("push tracker expires old sent dedupe keys", async () => {
  const notifications = [];
  let currentTime = 0;
  const tracker = createPushNotificationTracker({
    sessionId: "session-expiry",
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async notifyCompletion(payload) {
        notifications.push(payload);
        return { ok: true };
      },
    },
    now: () => currentTime,
  });

  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-expiry",
      turnId: "turn-expiry",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(notifications.length, 1);

  currentTime = 24 * 60 * 60 * 1000 + 1;
  tracker.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-expiry",
      turnId: "turn-expiry",
    },
  }));

  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(notifications.length, 2);
});

test("notifications handler forwards device registration to the push service client", async () => {
  const registrations = [];
  const handler = createNotificationsHandler({
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async registerDevice(payload) {
        registrations.push(payload);
        return { ok: true };
      },
    },
  });

  const responses = [];
  const handled = handler.handleNotificationsRequest(JSON.stringify({
    id: "request-1",
    method: "notifications/push/register",
    params: {
      deviceToken: "aabbcc",
      alertsEnabled: true,
      authorizationStatus: "authorized",
      appEnvironment: "development",
    },
  }), (message) => {
    responses.push(JSON.parse(message));
  });

  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(handled, true);
  assert.deepEqual(registrations, [{
    deviceToken: "aabbcc",
    alertsEnabled: true,
    apnsEnvironment: "development",
  }]);
  assert.equal(responses[0]?.result?.ok, true);
});
