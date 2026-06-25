// FILE: push-notification-completion-dedupe.test.js
// Purpose: Verifies the small helper that bounds completion dedupe state and thread-status suppression.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/push-notification-completion-dedupe

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  COMPLETION_DEDUPE_STORE_KEY,
  createPushNotificationCompletionDedupe,
} = require("../src/push-notification-completion-dedupe");

function makeTempHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-dedupe-test-"));
}

function makeDedupe(tempHome, opts = {}) {
  return createPushNotificationCompletionDedupe({
    homeDir: tempHome,
    fsImpl: fs,
    ...opts,
  });
}

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
  const tmpHome = makeTempHome();
  try {
  let currentTime = 0;
  const dedupe = makeDedupe(tmpHome, {
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
  } finally {
    fs.rmSync(tmpHome, { recursive: true, force: true });
  }
});

test("dedupe persists across restart in isolated home", async () => {
  const tmpHome = makeTempHome();
  try {
    let currentTime = 10_000;
    const dedupe = makeDedupe(tmpHome, { now: () => currentTime });

    dedupe.beginNotification({
      dedupeKey: "done-persist|thread-p|turn-persist-x|completed",
      threadId: "thread-p",
      turnId: "turn-persist-x",
      result: "completed",
    });
    dedupe.commitNotification({
      dedupeKey: "done-persist|thread-p|turn-persist-x|completed",
      threadId: "thread-p",
      turnId: "turn-persist-x",
      result: "completed",
    });
    await new Promise((resolve) => setImmediate(resolve));

    const persistPath = path.join(tmpHome, ".remodex", "turn-completed-dedupe.json");
    const onDisk = JSON.parse(fs.readFileSync(persistPath, "utf8"));
    assert.ok(onDisk[COMPLETION_DEDUPE_STORE_KEY]);
    assert.equal(Array.isArray(onDisk[COMPLETION_DEDUPE_STORE_KEY].completedTurns), true);
    assert.equal(onDisk[COMPLETION_DEDUPE_STORE_KEY].completedTurns[0].turnId, "turn-persist-x");
    assert.equal(onDisk.undefined, undefined);

    const dedupe2 = makeDedupe(tmpHome, { now: () => currentTime });
    assert.equal(dedupe2.hasActiveDedupeKey("foo|bar|turn-persist-x|completed"), true);
    assert.equal(dedupe2.debugState().persistedCompletedTurns, 1);
  } finally {
    fs.rmSync(tmpHome, { recursive: true, force: true });
  }
});

test("persisted dedupe expires after restart when TTL elapses", async () => {
  const tmpHome = makeTempHome();
  try {
    let currentTime = 0;
    const dedupe = makeDedupe(tmpHome, { now: () => currentTime });
    dedupe.commitNotification({
      dedupeKey: "sess|thread-ttl|turn-ttl|completed",
      threadId: "thread-ttl",
      turnId: "turn-ttl",
      result: "completed",
    });
    await new Promise((resolve) => setImmediate(resolve));
    await new Promise((resolve) => setImmediate(resolve));

    const dedupeAfterRestart = makeDedupe(tmpHome, { now: () => currentTime });
    assert.equal(dedupeAfterRestart.hasActiveDedupeKey("sess|thread-ttl|turn-ttl|completed"), true);

    currentTime = 24 * 60 * 60 * 1000 + 1;
    const dedupeAfterTtl = makeDedupe(tmpHome, { now: () => currentTime });
    assert.equal(dedupeAfterTtl.hasActiveDedupeKey("sess|thread-ttl|turn-ttl|completed"), false);
    assert.equal(dedupeAfterTtl.debugState().persistedCompletedTurns, 0);
  } finally {
    fs.rmSync(tmpHome, { recursive: true, force: true });
  }
});

test("loads legacy undefined-key persisted dedupe once", () => {
  const tmpHome = makeTempHome();
  try {
    const persistPath = path.join(tmpHome, ".remodex", "turn-completed-dedupe.json");
    fs.mkdirSync(path.dirname(persistPath), { recursive: true });
    const legacyCompletedAt = new Date(5_000).toISOString();
    fs.writeFileSync(
      persistPath,
      JSON.stringify({
        undefined: {
          completedTurnIds: ["turn-legacy-1"],
          lastPruned: legacyCompletedAt,
        },
      }),
      "utf8",
    );

    const dedupe = makeDedupe(tmpHome, { now: () => 10_000 });
    assert.equal(dedupe.hasActiveDedupeKey("x|y|turn-legacy-1|completed"), true);
  } finally {
    fs.rmSync(tmpHome, { recursive: true, force: true });
  }
});