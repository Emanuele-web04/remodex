// FILE: push-notification-tracker.test.js
// Purpose: Verifies lifecycle-owned completion pushes and registration ownership in the local bridge.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/push-notification-tracker, ../src/notifications-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { createPushNotificationTracker } = require("../src/push-notification-tracker");
const { createNotificationsHandler } = require("../src/notifications-handler");
const { resolveBridgeRelaySession } = require("../src/secure-device-state");

test("goal push retries failed delivery and dedupes only after success", async () => {
  let attempts = 0;
  const notifications = [];
  const tracker = createTracker({
    sessionId: "session-goal",
    async notifyCompletion(payload) {
      attempts += 1;
      if (attempts === 1) {
        throw new Error("offline");
      }
      notifications.push(payload);
      return { ok: true };
    },
  });

  emit(tracker, goalUpdate("active", 1));
  emit(tracker, goalUpdate("blocked", 2));
  emit(tracker, goalUpdate("blocked", 3));
  await settleNotifications();
  assert.equal(attempts, 1);
  emit(tracker, goalUpdate("blocked", 2));
  await settleNotifications();
  emit(tracker, goalUpdate("blocked", 2));
  await settleNotifications();

  assert.equal(attempts, 2);
  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].body, "Goal blocked — Codex needs your input");
});

test("thread statuses never create completion pushes, with or without a prior run", async () => {
  let currentTime = 0;
  const notifications = [];
  const tracker = createTracker({ notifications, now: () => currentTime });

  for (const status of ["idle", "notLoaded", "active"]) {
    emit(tracker, {
      method: "thread/status/changed",
      params: { threadId: `thread-${status}`, status },
    });
  }

  emit(tracker, turnStarted("thread-delayed", "turn-delayed"));
  emit(tracker, turnCompleted("thread-delayed", "turn-delayed", "completed"));
  await settleNotifications();
  currentTime = 31_000;
  emit(tracker, {
    method: "thread/status/changed",
    params: { threadId: "thread-delayed", status: "idle" },
  });
  await settleNotifications();

  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-delayed", "turn-delayed", "completed"],
  ]);
});

test("historical and replayed terminal events do not arm or notify", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });
  const replayedStart = turnStarted("thread-buffered", "turn-buffered");
  replayedStart.params.remodexReplayedEvent = true;
  emit(tracker, replayedStart);
  emit(tracker, turnCompleted("thread-buffered", "turn-buffered", "completed"));
  await settleNotifications();
  assert.deepEqual(notifications, []);

  const flags = ["remodexReplayedEvent", "remodexRolloutTerminalCatchUp", "remodexRolloutBootstrapReplay"];
  for (const [index, flag] of flags.entries()) {
    const threadId = `thread-${flag}`;
    emit(tracker, turnStarted(threadId, "live-turn"));
    const historicalCompletion = turnCompleted(threadId, "live-turn", "completed");
    historicalCompletion.params[flag] = true;
    emit(tracker, historicalCompletion);
    await settleNotifications();
    assert.equal(notifications.length, index, `${flag} must not notify an armed run`);
    emit(tracker, turnCompleted(threadId, "live-turn", "completed"));
    await settleNotifications();
    assert.equal(notifications.length, index + 1, "live completion must remain eligible");
  }
});

test("an active rollout bootstrap can arm a later live completion", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });
  const bootstrapStart = turnStarted("thread-bootstrap-live", "turn-bootstrap-live");
  bootstrapStart.params.remodexRolloutBootstrapReplay = true;

  emit(tracker, bootstrapStart);
  emit(tracker, turnCompleted("thread-bootstrap-live", "turn-bootstrap-live", "completed"));
  await settleNotifications();

  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-bootstrap-live", "turn-bootstrap-live", "completed"],
  ]);
});

test("known live runs notify for genuine success and terminal failure", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });

  emit(tracker, {
    method: "thread/started",
    params: { thread: { id: "thread-success", title: "Fix auth bug" } },
  });
  emit(tracker, turnStarted("thread-success", "turn-success"));
  emit(tracker, {
    method: "item/completed",
    params: {
      threadId: "thread-success",
      turnId: "turn-success",
      item: { type: "agent_message", role: "assistant", text: "Ready." },
    },
  });
  emit(tracker, turnCompleted("thread-success", "turn-success"));

  emit(tracker, turnStarted("thread-failure", "turn-failure"));
  emit(tracker, {
    method: "turn/failed",
    params: {
      threadId: "thread-failure",
      turnId: "turn-failure",
      message: "Tests failed on CI.",
    },
  });
  await settleNotifications();

  assert.equal(notifications.length, 2);
  assert.deepEqual(completionIdentity(notifications[0]), [
    "thread-success", "turn-success", "completed",
  ]);
  assert.equal(notifications[0].title, "Fix auth bug");
  assert.equal(notifications[0].body, "Response ready");
  assert.deepEqual(completionIdentity(notifications[1]), [
    "thread-failure", "turn-failure", "failed",
  ]);
  assert.equal(notifications[1].body, "Tests failed on CI.");
});

test("unknown terminals and non-notifiable terminal statuses stay silent", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });

  emit(tracker, turnCompleted("thread-old", "turn-old"));
  for (const status of ["stopped", "interrupted", "cancelled", "active", "mystery"]) {
    const threadId = `thread-${status}`;
    const turnId = `turn-${status}`;
    emit(tracker, turnStarted(threadId, turnId));
    emit(tracker, turnCompleted(threadId, turnId, status));
    emit(tracker, turnCompleted(threadId, turnId));
  }
  await settleNotifications();

  assert.deepEqual(notifications, []);
});

test("ID-less starts promote safely and identified overlapping runs remain distinct", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });

  emit(tracker, turnStarted("thread-promoted"));
  emit(tracker, turnCompleted("thread-promoted", "turn-canonical"));

  emit(tracker, turnStarted("thread-overlap", "turn-a"));
  emit(tracker, turnStarted("thread-overlap", "turn-b"));
  emit(tracker, turnCompleted("thread-overlap", "turn-unrelated"));
  emit(tracker, turnCompleted("thread-overlap", "turn-b"));
  emit(tracker, turnCompleted("thread-overlap", "turn-a", "failed", "A failed"));
  await settleNotifications();

  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-promoted", "turn-canonical", "completed"],
    ["thread-overlap", "turn-b", "completed"],
    ["thread-overlap", "turn-a", "failed"],
  ]);
});

test("a distinct subsequent run on the same thread sends its own completion", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });

  emit(tracker, turnStarted("thread-sequential", "turn-first"));
  emit(tracker, turnCompleted("thread-sequential", "turn-first"));
  await settleNotifications();
  emit(tracker, turnStarted("thread-sequential", "turn-second"));
  emit(tracker, turnCompleted("thread-sequential", "turn-second"));
  await settleNotifications();

  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-sequential", "turn-first", "completed"],
    ["thread-sequential", "turn-second", "completed"],
  ]);
});

test("successful completion receipts survive real session rotation without suppressing distinct runs or Macs", async (t) => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-completion-state-"));
  const completionStatePath = path.join(tempDir, "completion-state.json");
  t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const notifications = [];

  const firstSession = resolveBridgeRelaySession({}).sessionId;
  const nextSession = resolveBridgeRelaySession({}).sessionId;
  assert.notEqual(firstSession, nextSession);
  const firstTracker = createTracker({ notifications, completionStatePath, sessionId: firstSession });
  emit(firstTracker, turnStarted("thread-restart", "turn-restart"));
  emit(firstTracker, turnCompleted("thread-restart", "turn-restart", "completed"));
  await settleNotifications();

  const restartedTracker = createTracker({ notifications, completionStatePath, sessionId: nextSession });
  emit(restartedTracker, turnStarted("thread-restart", "turn-restart"));
  emit(restartedTracker, turnCompleted(
    "thread-restart", "turn-restart", "failed", "Late failure snapshot"
  ));
  await settleNotifications();

  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-restart", "turn-restart", "completed"],
  ]);

  emit(restartedTracker, turnStarted("thread-restart", "turn-new"));
  emit(restartedTracker, turnCompleted("thread-restart", "turn-new", "completed"));
  emit(restartedTracker, turnStarted("other-thread", "turn-restart"));
  emit(restartedTracker, turnCompleted("other-thread", "turn-restart", "completed"));
  const otherMac = createTracker({
    notifications,
    sessionId: resolveBridgeRelaySession({}).sessionId,
    completionStatePath: path.join(tempDir, "other-mac.json"),
  });
  emit(otherMac, turnStarted("thread-restart", "turn-restart"));
  emit(otherMac, turnCompleted("thread-restart", "turn-restart", "completed"));
  await settleNotifications();
  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-restart", "turn-restart", "completed"],
    ["thread-restart", "turn-new", "completed"],
    ["other-thread", "turn-restart", "completed"],
    ["thread-restart", "turn-restart", "completed"],
  ]);
  assert.equal(new Set(notifications.map((notification) => notification.dedupeKey)).size, 4);
});

test("new ID-less runs stay independent of an older completion delivery", async (t) => {
  for (const previousID of [null, "previous-turn"]) {
    for (const nextID of [null, "next-turn"]) {
      for (const deliveryOrder of ["before", "after", "failed"]) {
        await t.test(`${previousID ?? "anonymous"} -> ${nextID ?? "anonymous"}, delivery ${deliveryOrder}`, async () => {
          const sends = [];
          const tracker = createTracker({
            readThread: async () => ({ thread: { id: "thread", turns: [
              { id: "previous-turn", status: "completed" },
              { id: nextID, status: "completed" },
            ] } }),
            notifyCompletion(payload) {
              return new Promise((resolve, reject) => sends.push({ payload, resolve, reject }));
            },
          });
          emit(tracker, turnStarted("thread", previousID));
          emit(tracker, turnCompleted("thread", previousID, "completed"));
          emit(tracker, turnStarted("thread"));
          // Re-announcing the new run while it is still active is not another run.
          emit(tracker, turnStarted("thread"));
          assert.equal(sends.length, 1);
          if (deliveryOrder === "before") sends[0].resolve({ ok: true });
          if (deliveryOrder === "failed") sends[0].reject(new Error("offline"));
          await settleNotifications();

          emit(tracker, turnCompleted("thread", nextID, "completed"));
          await settleNotifications();
          assert.equal(sends.length, 2);
          assert.deepEqual(sends.map(({ payload }) => completionIdentity(payload)), [
            ["thread", previousID, "completed"],
            ["thread", nextID, "completed"],
          ]);
          assert.notEqual(sends[0].payload.dedupeKey, sends[1].payload.dedupeKey);
          emit(tracker, turnCompleted("thread", nextID, "completed"));
          assert.equal(sends.length, 2);

          sends[1].resolve({ ok: true });
          if (deliveryOrder === "after") sends[0].resolve({ ok: true });
          await settleNotifications();
          // An identified older failure can still retry without consuming the new run.
          if (deliveryOrder === "failed" && previousID) {
            emit(tracker, turnCompleted("thread", previousID, "completed"));
            assert.equal(sends.length, 3);
            assert.equal(sends[2].payload.dedupeKey, sends[0].payload.dedupeKey);
            sends[2].resolve({ ok: true });
            await settleNotifications();
          }
        });
      }
    }
  }
});

test("failed delivery keeps the matching live run available for retry", async () => {
  let attempts = 0;
  const notifications = [];
  const tracker = createTracker({
    async notifyCompletion(payload) {
      attempts += 1;
      if (attempts === 1) {
        throw new Error("relay unavailable");
      }
      notifications.push(payload);
      return { ok: true };
    },
  });

  emit(tracker, turnStarted("thread-retry", "turn-retry"));
  emit(tracker, {
    method: "turn/failed",
    params: {
      threadId: "thread-retry",
      turnId: "turn-retry",
      message: "Transient stream error",
      willRetry: true,
    },
  });
  await settleNotifications();
  assert.equal(attempts, 0);
  emit(tracker, turnCompleted("thread-retry", "turn-retry", "failed", "Build failed"));
  await settleNotifications();
  emit(tracker, turnCompleted("thread-retry", "turn-retry", "failed", "Build failed"));
  await settleNotifications();

  assert.equal(attempts, 2);
  assert.deepEqual(notifications.map(completionIdentity), [
    ["thread-retry", "turn-retry", "failed"],
  ]);
});

test("late canonical events cannot consume a newer anonymous run", async (t) => {
  for (const deliveryOrder of ["before", "after", "failed"]) {
    for (const reannounceStart of [false, true]) {
      await t.test(`${deliveryOrder}, late start ${reannounceStart}`, async () => {
        const sends = [];
        let resolveRead;
        const tracker = createTracker({
          readThread: () => new Promise((resolve) => { resolveRead = resolve; }),
          notifyCompletion: (payload) => new Promise((resolve, reject) => {
            sends.push({ payload, resolve, reject });
          }),
        });
        emit(tracker, turnStarted("thread"));
        emit(tracker, turnCompleted("thread", null, "completed"));
        if (deliveryOrder === "before") sends[0].resolve({ ok: true });
        if (deliveryOrder === "failed") sends[0].reject(new Error("offline"));
        await settleNotifications();
        emit(tracker, turnStarted("thread"));
        if (reannounceStart) emit(tracker, turnStarted("thread", "previous-turn"));
        emit(tracker, turnCompleted("thread", "previous-turn", "completed"));
        emit(tracker, turnCompleted("thread", "next-turn", "completed"));
        assert.equal(sends.length, 1, "ambiguous IDs must wait for the runtime");
        resolveRead({ thread: { id: "thread", turns: [
          { id: "previous-turn", status: "completed" },
          { id: "next-turn", status: "completed" },
        ] } });
        await settleNotifications();
        assert.deepEqual(sends.map(({ payload }) => payload.turnId), [null, "next-turn"]);
        sends[1].resolve({ ok: true });
        if (deliveryOrder === "after") sends[0].resolve({ ok: true });
        await settleNotifications();
        emit(tracker, turnStarted("thread", "previous-turn"));
        emit(tracker, turnCompleted("thread", "previous-turn", "completed"));
        emit(tracker, turnCompleted("thread", "next-turn", "completed"));
        await settleNotifications();
        assert.equal(sends.length, 2, "replays cannot create an extra alert");
      });
    }
  }
});

test("ambiguous identity reads fail closed and a later live event can retry", async () => {
  const notifications = [];
  const reads = [
    new Error("runtime unavailable"),
    { thread: { id: "other-thread", turns: [{ id: "next-turn" }] } },
    { thread: { id: "thread", turns: [] } },
    { thread: { id: "thread", turns: [
      { id: "previous-turn", status: "completed" },
      { id: "next-turn", status: "completed" },
    ] } },
  ];
  const tracker = createTracker({ notifications, async readThread() {
    const snapshot = reads.shift();
    if (snapshot instanceof Error) throw snapshot;
    return snapshot;
  } });
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", null, "completed"));
  await settleNotifications();
  emit(tracker, turnStarted("thread"));
  for (let attempt = 0; attempt < 3; attempt += 1) {
    emit(tracker, turnCompleted("thread", "next-turn", "completed"));
    await settleNotifications();
    assert.equal(notifications.length, 1);
  }
  emit(tracker, turnCompleted("thread", "next-turn", "completed"));
  await settleNotifications();
  assert.deepEqual(notifications.map((notification) => notification.turnId), [null, "next-turn"]);
});

test("a subsequent identified start is not suppressed by an anonymous receipt", async () => {
  const notifications = [];
  let latestTurn = "second-turn";
  const tracker = createTracker({ notifications, readThread: async () => ({ thread: {
    id: "thread", turns: [{ id: "first-turn", status: "completed" }, { id: latestTurn }],
  } }) });
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", null, "completed"));
  await settleNotifications();
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", "second-turn", "completed"));
  await settleNotifications();
  latestTurn = "third-turn";
  emit(tracker, turnStarted("thread", "third-turn"));
  emit(tracker, turnCompleted("thread", "third-turn", "completed"));
  await settleNotifications();
  assert.deepEqual(notifications.map((notification) => notification.turnId), [null, "second-turn", "third-turn"]);
});

test("identity recovery preserves a tracked parallel completion", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications, readThread: async () => ({ thread: {
    id: "thread", turns: [
      { id: "previous-turn", status: "completed" },
      { id: "parallel-turn", status: "completed" },
      { id: "next-turn", status: "completed" },
    ],
  } }) });
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", null, "completed"));
  await settleNotifications();
  emit(tracker, turnStarted("thread", "parallel-turn"));
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", "next-turn", "completed"));
  await settleNotifications();
  emit(tracker, turnCompleted("thread", "parallel-turn", "completed"));
  await settleNotifications();
  assert.deepEqual(notifications.map((notification) => notification.turnId), [null, "next-turn", "parallel-turn"]);
});

test("starting an identified parallel run does not supersede an active anonymous run", async () => {
  const notifications = [];
  const tracker = createTracker({ notifications });
  emit(tracker, turnStarted("thread", "first-parallel"));
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnStarted("thread", "second-parallel"));
  emit(tracker, turnCompleted("thread", "first-parallel", "completed"));
  emit(tracker, turnCompleted("thread", "second-parallel", "completed"));
  await settleNotifications();
  emit(tracker, turnCompleted("thread", "anonymous-canonical", "completed"));
  await settleNotifications();
  assert.deepEqual(notifications.map((notification) => notification.turnId), [
    "first-parallel", "second-parallel", "anonymous-canonical",
  ]);
});

test("a delayed identity response cannot consume the next anonymous run", async () => {
  const notifications = [];
  const reads = [];
  const tracker = createTracker({ notifications, readThread: () => new Promise((resolve) => reads.push(resolve)) });
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", null, "completed"));
  await settleNotifications();
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", "second-turn", "completed"));
  emit(tracker, turnCompleted("thread", null, "completed"));
  await settleNotifications();
  emit(tracker, turnStarted("thread"));
  emit(tracker, turnCompleted("thread", "third-turn", "completed"));
  reads[0]({ thread: { id: "thread", turns: [{ id: "second-turn", status: "completed" }] } });
  await settleNotifications();
  assert.equal(notifications.length, 2);
  reads[1]({ thread: { id: "thread", turns: [{ id: "third-turn", status: "completed" }] } });
  await settleNotifications();
  assert.deepEqual(notifications.map((notification) => notification.turnId), [null, null, "third-turn"]);
});

test("ID-less runs stay distinct across restart and promotion cannot double-send in flight", async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-idless-push-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const completionStatePath = path.join(directory, "state.json");
  const notifications = [];
  for (let restart = 0; restart < 2; restart += 1) {
    const tracker = createTracker({ notifications, completionStatePath });
    emit(tracker, turnStarted("idless"));
    emit(tracker, turnCompleted("idless", null, "completed"));
    await settleNotifications();
  }
  assert.equal(notifications.length, 2);

  const pending = [];
  const tracker = createTracker({ completionStatePath, notifyCompletion(payload) {
    notifications.push(payload);
    return new Promise((resolve) => pending.push(resolve));
  } });
  emit(tracker, turnStarted("promoted"));
  emit(tracker, turnCompleted("promoted", null, "completed"));
  emit(tracker, turnStarted("promoted", "canonical"));
  emit(tracker, turnCompleted("promoted", "canonical", "completed"));
  pending.forEach((resolve) => resolve({ ok: true }));
  await settleNotifications();
  const restarted = createTracker({ notifications, completionStatePath });
  emit(restarted, turnStarted("promoted", "canonical"));
  emit(restarted, turnCompleted("promoted", "canonical", "completed"));
  await settleNotifications();
  assert.equal(notifications.length, 3);
});

test("old explicit completion timestamps and expired failed-send retries stay silent", async () => {
  let currentTime = 1_800_000_000_000;
  const notifications = [];
  const tracker = createTracker({ notifications, now: () => currentTime });
  for (const wrapped of [false, true]) {
    const threadId = `old-${wrapped}`;
    emit(tracker, turnStarted(threadId, "old-turn"));
    const turn = { id: "old-turn", status: "completed", completedAt: currentTime / 1000 - 86_400 };
    emit(tracker, { method: "turn/completed", params: {
      threadId, turnId: "old-turn", ...(wrapped ? { event: { turn } } : { turn }),
    } });
  }
  await settleNotifications();
  assert.equal(notifications.length, 0);
  let attempts = 0;
  const retrying = createTracker({ now: () => currentTime, async notifyCompletion() {
    attempts += 1;
    throw new Error("offline");
  } });
  emit(retrying, turnStarted("retry", "turn"));
  emit(retrying, turnCompleted("retry", "turn", "completed"));
  await settleNotifications();
  currentTime += 301_000;
  emit(retrying, turnCompleted("retry", "turn", "completed"));
  await settleNotifications();
  assert.equal(attempts, 1);
});

test("goal snapshots after restart or same-status updates do not renotify", async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-goal-push-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const goalPushStatePath = path.join(directory, "goals.json");
  fs.writeFileSync(goalPushStatePath, JSON.stringify({ "thread-goal": { status: "active", updatedAt: 1 } }));
  const notifications = [];
  const tracker = createTracker({ notifications, goalPushStatePath });
  emit(tracker, goalUpdate("complete", 2));
  await settleNotifications();
  assert.equal(notifications.length, 0);
  emit(tracker, goalUpdate("active", 3));
  emit(tracker, goalUpdate("complete", 4));
  emit(tracker, goalUpdate("complete", 5));
  await settleNotifications();
  emit(tracker, goalUpdate("complete", 6));
  await settleNotifications();
  assert.equal(notifications.length, 1);

  emit(tracker, goalUpdate("active", 7));
  emit(tracker, goalUpdate("complete", 8));
  emit(tracker, goalUpdate("active", 9));
  await settleNotifications();
  emit(tracker, goalUpdate("complete", 10));
  await settleNotifications();
  assert.equal(notifications.length, 3);
});

test("registration claims remote completion ownership only from an enabled capable relay", async () => {
  const registrations = [];
  const capableHandler = createNotificationsHandler({
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async registerDevice(payload) {
        registrations.push(payload);
        return { ok: true, skipped: false, pushEnabled: true };
      },
    },
  });
  const capable = await register(capableHandler, { alertsEnabled: true });

  const olderRelay = await register(createNotificationsHandler({
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async registerDevice() {
        return { ok: true };
      },
    },
  }), { alertsEnabled: true });

  const rejectedRegistration = await register(createNotificationsHandler({
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      async registerDevice() {
        return { ok: false, skipped: false, pushEnabled: true };
      },
    },
  }), { alertsEnabled: true });

  const disabledAlerts = await register(capableHandler, { alertsEnabled: false });
  const noService = await register(createNotificationsHandler({
    pushServiceClient: { hasConfiguredBaseUrl: false },
  }), { alertsEnabled: true });

  assert.deepEqual(registrations, [
    { deviceToken: "aabbcc", alertsEnabled: true, apnsEnvironment: "development" },
    { deviceToken: "aabbcc", alertsEnabled: false, apnsEnvironment: "development" },
  ]);
  assert.equal(capable.result.ok, true);
  assert.equal(capable.result.completionPushEnabled, true);
  assert.equal(olderRelay.result.completionPushEnabled, false);
  assert.equal(rejectedRegistration.result.ok, false);
  assert.equal(rejectedRegistration.result.completionPushEnabled, false);
  assert.equal(disabledAlerts.result.completionPushEnabled, false);
  assert.equal(noService.result.ok, false);
  assert.equal(noService.result.skipped, true);
  assert.equal(noService.result.completionPushEnabled, false);
});

function createTracker({
  notifications = [],
  notifyCompletion,
  sessionId = "session-test",
  now,
  completionStatePath = null,
  goalPushStatePath = null,
  readThread,
} = {}) {
  return createPushNotificationTracker({
    sessionId,
    completionStatePath,
    goalPushStatePath,
    readThread,
    ...(now ? { now } : {}),
    pushServiceClient: {
      hasConfiguredBaseUrl: true,
      notifyCompletion: notifyCompletion || (async (payload) => {
        notifications.push(payload);
        return { ok: true };
      }),
    },
  });
}

function emit(tracker, message) {
  tracker.handleOutbound(JSON.stringify(message), message);
}

function turnStarted(threadId, turnId = null) {
  return {
    method: "turn/started",
    params: {
      threadId,
      ...(turnId ? { turnId, turn: { id: turnId, status: "inProgress" } } : {}),
    },
  };
}

function turnCompleted(threadId, turnId, status, message) {
  return {
    method: "turn/completed",
    params: {
      threadId,
      ...(turnId ? { turnId } : {}),
      ...(status ? { status, turn: { id: turnId, status } } : {}),
      ...(message ? { message, error: { message } } : {}),
    },
  };
}

function goalUpdate(status, updatedAt) {
  return {
    method: "thread/goal/updated",
    params: {
      threadId: "thread-goal",
      goal: { threadId: "thread-goal", objective: "Ship", status, updatedAt },
    },
  };
}

function completionIdentity(notification) {
  return [notification.threadId, notification.turnId, notification.result];
}

async function register(handler, { alertsEnabled }) {
  return new Promise((resolve) => {
    const handled = handler.handleNotificationsRequest(JSON.stringify({
      id: "request-register",
      method: "notifications/push/register",
      params: {
        deviceToken: "aabbcc",
        alertsEnabled,
        appEnvironment: "development",
      },
    }), (rawResponse) => resolve(JSON.parse(rawResponse)));
    assert.equal(handled, true);
  });
}

async function settleNotifications() {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
}
