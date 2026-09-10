// FILE: thread-activity-store.test.js
// Purpose: Verifies opt-in Activity snapshots, deltas, coalescing, and retention.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/thread-activity-store

const test = require("node:test");
const assert = require("node:assert/strict");

const { createThreadActivityStore } = require("../src/thread-activity-store");

test("Activity stays silent until subscribed and after unsubscribe", () => {
  const outbound = [];
  const store = createStore(outbound);
  store.upsert(entry("thread-a", { title: "Before" }));
  assert.deepEqual(outbound, []);

  assert.equal(store.handleRequest({
    id: 41,
    method: "remodex/activity/subscribe",
    params: { schemaVersion: 1 },
  }), true);
  assert.equal(outbound[0].id, 41);
  assert.equal(outbound[0].result.epoch, "activity-epoch");
  assert.equal(outbound[0].result.coverage, "observedThreads");
  assert.equal(outbound[0].result.entries[0].title, "Before");

  store.handleRequest({
    id: "unsubscribe-id",
    method: "remodex/activity/unsubscribe",
  });
  const messagesAfterUnsubscribe = outbound.length;
  store.upsert(entry("thread-a", { runtime: "active", activeTurnIds: ["turn-a"] }));
  assert.equal(outbound.length, messagesAfterUnsubscribe);
});

test("snapshot watermark is followed by contiguous deltas and repeat subscribe drops old batches", () => {
  const outbound = [];
  const timers = createFakeTimers();
  const store = createStore(outbound, timers.options);
  store.upsert(entry("thread-a"));
  store.handleRequest({ id: "first", method: "remodex/activity/subscribe" });
  const snapshotRevision = outbound[0].result.revision;

  store.upsert(entry("thread-a", { title: "Coalesced title" }));
  assert.equal(timers.pending(), 1);
  store.upsert(entry("thread-a", {
    title: "Coalesced title",
    runtime: "active",
    activeTurnIds: ["turn-a"],
  }));
  const firstDelta = outbound.at(-1);
  assert.equal(firstDelta.method, "remodex/activity/updated");
  assert.equal(firstDelta.params.baseRevision, snapshotRevision);
  assert.equal(firstDelta.params.revision, snapshotRevision + 2);

  store.upsert(entry("thread-a", {
    title: "Pending older batch",
    runtime: "active",
    activeTurnIds: ["turn-a"],
  }));
  assert.equal(timers.pending(), 1);
  store.handleRequest({ id: "repeat", method: "remodex/activity/subscribe" });
  const repeatedSnapshot = outbound.at(-1);
  assert.equal(repeatedSnapshot.id, "repeat");
  assert.equal(repeatedSnapshot.result.entries[0].title, "Pending older batch");
  timers.runAll();
  assert.equal(outbound.at(-1).id, "repeat");

  store.upsert(entry("thread-a", {
    title: "After repeat",
    runtime: "active",
    activeTurnIds: ["turn-a"],
  }));
  timers.runAll();
  const postRepeatDelta = outbound.at(-1);
  assert.equal(postRepeatDelta.params.baseRevision, repeatedSnapshot.result.revision);
  assert.equal(postRepeatDelta.params.revision, repeatedSnapshot.result.revision + 1);
});

test("unchanged entries are dropped and metadata changes coalesce", () => {
  const outbound = [];
  const timers = createFakeTimers();
  const store = createStore(outbound, timers.options);
  store.handleRequest({ id: 1, method: "remodex/activity/subscribe" });
  store.upsert(entry("thread-a", { runtime: "active", activeTurnIds: ["turn-a"] }));
  const afterUrgent = outbound.length;

  assert.equal(store.upsert(entry("thread-a", {
    runtime: "active",
    activeTurnIds: ["turn-a"],
  })), false);
  assert.equal(outbound.length, afterUrgent);
  store.upsert(entry("thread-a", {
    runtime: "active",
    activeTurnIds: ["turn-a"],
    latestItem: { itemId: "item-a", kind: "thinking", label: "Thinking" },
  }));
  store.upsert(entry("thread-a", {
    runtime: "active",
    activeTurnIds: ["turn-a"],
    latestItem: { itemId: "item-b", kind: "tool", label: "Using a tool" },
  }));
  assert.equal(outbound.length, afterUrgent);
  timers.runAll();
  assert.equal(outbound.length, afterUrgent + 1);
  assert.equal(outbound.at(-1).params.upserts[0].latestItem.itemId, "item-b");
});

test("stale, removals, and inactive retention preserve actionable entries", () => {
  const outbound = [];
  const evicted = [];
  const store = createStore(outbound, {
    maxInactiveEntries: 1,
    onEvict(threadId, source) {
      evicted.push([threadId, source]);
    },
  });
  store.handleRequest({ id: 1, method: "remodex/activity/subscribe" });
  store.upsert(entry("active", { runtime: "active", activeTurnIds: ["turn-active"] }));
  store.upsert(entry("idle-old"));
  store.upsert(entry("idle-new"));
  assert.deepEqual(evicted, [["idle-old", "desktop-ipc"]]);
  assert.deepEqual(store.snapshot().entries.map((value) => value.threadId), ["active", "idle-new"]);

  store.markSourceStale("desktop-ipc", 1);
  assert.equal(store.snapshot().entries.every((value) => value.freshness === "stale"), true);
  assert.equal(store.remove("active", { source: "app-server" }), false);
  assert.equal(store.remove("active", { source: "desktop-ipc" }), true);
  assert.equal(outbound.at(-1).params.removedThreadIds.includes("active"), true);
});

test("new authenticated session reset requires a new subscription", () => {
  const outbound = [];
  const store = createStore(outbound);
  store.handleRequest({ id: 1, method: "remodex/activity/subscribe" });
  store.resetSubscriber();
  store.upsert(entry("thread-a", { runtime: "active", activeTurnIds: ["turn-a"] }));
  assert.equal(outbound.length, 1);

  store.handleRequest({ id: 2, method: "remodex/activity/subscribe" });
  assert.equal(outbound.at(-1).result.entries[0].threadId, "thread-a");
});

test("invalid Activity schema is intercepted with the original request ID type", () => {
  const outbound = [];
  const store = createStore(outbound);
  store.handleRequest({
    id: 17,
    method: "remodex/activity/subscribe",
    params: { schemaVersion: 2 },
  });
  assert.equal(outbound[0].id, 17);
  assert.equal(outbound[0].error.code, -32602);
});

test("flag-only attention is urgent and disposed stores stay empty", () => {
  const outbound = [];
  const timers = createFakeTimers();
  const store = createStore(outbound, timers.options);
  store.upsert(entry("flags", { runtime: "active" }));
  store.handleRequest({ id: "subscribe", method: "remodex/activity/subscribe" });
  store.upsert(entry("flags", { runtime: "active", approvalRequired: true }));
  assert.equal(outbound.at(-1).method, "remodex/activity/updated");
  assert.equal(timers.pending(), 0);
  store.dispose();
  assert.equal(store.upsert(entry("late")), false);
  assert.deepEqual(store.snapshot().entries, []);
});

function createStore(outbound, overrides = {}) {
  return createThreadActivityStore({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    createEpoch: () => "activity-epoch",
    ...overrides,
  });
}

function entry(threadId, overrides = {}) {
  return {
    threadId,
    source: "desktop-ipc",
    runtime: "idle",
    activeTurnIds: [],
    runningWithoutTurnId: false,
    approvalRequired: false,
    approvalRequestCount: 0,
    userInputRequired: false,
    userInputRequestCount: 0,
    freshness: "current",
    sourceGeneration: 1,
    ...overrides,
  };
}

function createFakeTimers() {
  const callbacks = new Map();
  let nextId = 1;
  return {
    options: {
      setTimeoutFn(callback) {
        const id = nextId++;
        callbacks.set(id, callback);
        return { id, unref() {} };
      },
      clearTimeoutFn(timer) {
        callbacks.delete(timer.id);
      },
    },
    pending() {
      return callbacks.size;
    },
    runAll() {
      const queued = [...callbacks.values()];
      callbacks.clear();
      for (const callback of queued) {
        callback();
      }
    },
  };
}
