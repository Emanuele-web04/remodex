// FILE: push-notification-completion-dedupe.test.js
// Purpose: Verifies the small helper that bounds completion dedupe state and thread-status suppression.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/push-notification-completion-dedupe

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createPushNotificationCompletionDedupe,
} = require("../src/push-notification-completion-dedupe");

test("completion dedupe suppresses thread-status fallback until a new run starts", () => {
  let currentTime = 0;
  const dedupe = createPushNotificationCompletionDedupe({
    now: () => currentTime,
  });

  dedupe.beginNotification({
    dedupeKey: "done-a",
    threadId: "thread-1",
    turnId: "turn-a",
    result: "completed",
  });
  dedupe.commitNotification({
    dedupeKey: "done-a",
    threadId: "thread-1",
    turnId: "turn-a",
    result: "completed",
  });

  currentTime = 1_000;
  assert.equal(
    dedupe.shouldSuppressThreadStatusFallback({
      threadId: "thread-1",
      result: "completed",
    }),
    true
  );

  dedupe.clearForNewRun("thread-1");
  assert.equal(
    dedupe.shouldSuppressThreadStatusFallback({
      threadId: "thread-1",
      result: "completed",
    }),
    false
  );
});

test("completion dedupe removes pending suppression if the send fails", () => {
  const dedupe = createPushNotificationCompletionDedupe();

  dedupe.beginNotification({
    dedupeKey: "done-b",
    threadId: "thread-2",
    turnId: "turn-b",
    result: "failed",
  });

  assert.equal(
    dedupe.shouldSuppressThreadStatusFallback({
      threadId: "thread-2",
      result: "failed",
    }),
    true
  );

  dedupe.abortNotification({
    dedupeKey: "done-b",
    threadId: "thread-2",
    turnId: "turn-b",
    result: "failed",
  });

  assert.equal(
    dedupe.shouldSuppressThreadStatusFallback({
      threadId: "thread-2",
      result: "failed",
    }),
    false
  );
});

test("completion dedupe expires sent keys so state stays bounded", () => {
  let currentTime = 0;
  const dedupe = createPushNotificationCompletionDedupe({
    now: () => currentTime,
  });

  dedupe.beginNotification({
    dedupeKey: "done-c",
    threadId: "thread-3",
    turnId: "turn-c",
    result: "completed",
  });
  dedupe.commitNotification({
    dedupeKey: "done-c",
    threadId: "thread-3",
    turnId: "turn-c",
    result: "completed",
  });

  assert.equal(dedupe.hasActiveDedupeKey("done-c"), true);
  assert.equal(dedupe.debugState().sentDedupeKeys, 1);

  currentTime = 24 * 60 * 60 * 1000 + 1;

  assert.equal(dedupe.hasActiveDedupeKey("done-c"), false);
  assert.equal(dedupe.debugState().sentDedupeKeys, 0);
});
