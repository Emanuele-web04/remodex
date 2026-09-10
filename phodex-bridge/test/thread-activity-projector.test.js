// FILE: thread-activity-projector.test.js
// Purpose: Verifies bounded Activity reduction across canonical and Desktop sources.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/thread-activity-projector

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createThreadActivityProjector,
  projectDesktopThreadActivity,
} = require("../src/thread-activity-projector");

test("canonical Activity keeps independent repository metadata and parallel turns", () => {
  const projector = createThreadActivityProjector();
  observeThread(projector, "thread-a", "/repo/a", "Alpha");
  observeThread(projector, "thread-b", "/repo/b", "Beta");

  observe(projector, "turn/started", {
    threadId: "thread-a",
    turn: { id: "turn-a", status: "inProgress", startedAt: 1_700_000_000 },
  });
  observe(projector, "turn/started", {
    threadId: "thread-a",
    turn: { id: "turn-b", status: "inProgress", startedAt: 1_700_000_001 },
  });
  const afterOlderCompletion = observe(projector, "turn/completed", {
    threadId: "thread-a",
    turn: {
      id: "turn-a",
      status: "completed",
      startedAt: 1_700_000_000,
      completedAt: 1_700_000_002,
    },
  }).entry;

  assert.equal(afterOlderCompletion.cwd, "/repo/a");
  assert.deepEqual(afterOlderCompletion.activeTurnIds, ["turn-b"]);
  assert.equal(afterOlderCompletion.runtime, "active");
  assert.deepEqual(afterOlderCompletion.lastOutcome, {
    turnId: "turn-a",
    outcome: "completed",
    startedAtMs: 1_700_000_000_000,
    completedAtMs: 1_700_000_002_000,
  });

  const secondEntry = observe(projector, "turn/started", {
    threadId: "thread-b",
    turn: { id: "turn-c", status: "inProgress" },
  }).entry;
  assert.equal(secondEntry.title, "Beta");
  assert.equal(secondEntry.cwd, "/repo/b");
});

test("canonical Activity retains a missing-turn fallback and ignores late turn-less work", () => {
  const projector = createThreadActivityProjector();
  observeThread(projector, "thread-fallback", "/repo", "Fallback");
  const running = observe(projector, "turn/started", {
    threadId: "thread-fallback",
    turn: { status: "inProgress" },
  }).entry;
  assert.equal(running.runningWithoutTurnId, true);
  assert.equal(running.runtime, "active");

  const terminal = observe(projector, "turn/completed", {
    threadId: "thread-fallback",
    turn: { status: "interrupted" },
  }).entry;
  assert.equal(terminal.runningWithoutTurnId, false);
  assert.equal(terminal.runtime, "idle");
  assert.equal(terminal.lastOutcome, undefined);

  assert.equal(observe(projector, "thread/status/changed", {
    threadId: "thread-fallback",
    status: { type: "active", activeFlags: [] },
  }), null);
  assert.equal(observe(projector, "item/started", {
    threadId: "thread-fallback",
    item: { id: "late-item", type: "reasoning", summary: ["secret"] },
  }), null);
});

test("canonical Activity resolves typed request IDs exactly without ending active work", () => {
  const projector = createThreadActivityProjector();
  observeThread(projector, "thread-actions", "/repo", "Actions");
  observe(projector, "turn/started", {
    threadId: "thread-actions",
    turn: { id: "turn-active", status: "inProgress" },
  });
  observeRequest(projector, 7, "item/commandExecution/requestApproval");
  const waiting = observeRequest(projector, "7", "item/tool/requestUserInput").entry;
  assert.equal(waiting.runtime, "active");
  assert.equal(waiting.approvalRequestCount, 1);
  assert.equal(waiting.userInputRequestCount, 1);

  const afterNumericResolution = observe(projector, "serverRequest/resolved", {
    threadId: "thread-actions",
    requestId: 7,
  }).entry;
  assert.equal(afterNumericResolution.approvalRequired, false);
  assert.equal(afterNumericResolution.userInputRequired, true);
  assert.equal(afterNumericResolution.runtime, "active");

  const afterStringResolution = observe(projector, "serverRequest/resolved", {
    threadId: "thread-actions",
    requestId: "7",
  }).entry;
  assert.equal(afterStringResolution.userInputRequired, false);
});

test("canonical Activity emits only generic item metadata", () => {
  const projector = createThreadActivityProjector();
  observeThread(projector, "thread-items", "/repo", "Items");
  observe(projector, "turn/started", {
    threadId: "thread-items",
    turn: { id: "turn-items", status: "inProgress" },
  });
  const result = observe(projector, "item/started", {
    threadId: "thread-items",
    turnId: "turn-items",
    startedAtMs: 1_700_000_000_123,
    item: {
      id: "command-item",
      type: "commandExecution",
      command: "print a secret",
      aggregatedOutput: "private output",
    },
  });

  assert.deepEqual(result.entry.latestItem, {
    itemId: "command-item",
    turnId: "turn-items",
    kind: "command",
    label: "Running command",
    startedAtMs: 1_700_000_000_123,
  });
  const payload = JSON.stringify(result.entry);
  assert.equal(payload.includes("print a secret"), false);
  assert.equal(payload.includes("private output"), false);
});

test("Desktop Activity preserves millisecond timing, unread state, and unknown runtime", () => {
  const active = projectDesktopThreadActivity("desktop-active", {
    title: "Desktop",
    cwd: "/repo/desktop",
    hasUnreadTurn: true,
    unreadMessageCount: 3,
    threadRuntimeStatus: { type: "active", activeFlags: [] },
    requests: [{
      id: "approval",
      method: "item/fileChange/requestApproval",
      params: { changes: ["not retained"] },
    }],
    turns: [{
      id: "turn-desktop",
      status: "inProgress",
      turnStartedAtMs: 1_700_000_000_456,
      items: [{
        id: "file-item",
        type: "fileChange",
        changes: [{ path: "private.txt", diff: "secret" }],
      }],
    }],
  }, 4);
  assert.equal(active.runtime, "active");
  assert.deepEqual(active.activeTurnIds, ["turn-desktop"]);
  assert.deepEqual(active.desktopUnread, { hasUnreadTurn: true, unreadMessageCount: 3 });
  assert.deepEqual(active.latestItem, {
    itemId: "file-item",
    turnId: "turn-desktop",
    kind: "fileChange",
    label: "Editing files",
  });
  assert.equal(active.sourceGeneration, 4);
  assert.equal(JSON.stringify(active).includes("private.txt"), false);

  const unknown = projectDesktopThreadActivity("desktop-unknown", {
    turns: [],
    requests: [],
  }, 5);
  assert.equal(unknown.runtime, "unknown");
  assert.equal(unknown.lastOutcome, undefined);
});

test("Desktop terminal timing is not rescaled from milliseconds", () => {
  const entry = projectDesktopThreadActivity("desktop-terminal", {
    threadRuntimeStatus: { type: "idle" },
    requests: [],
    turns: [{
      id: "turn-terminal",
      status: "failed",
      turnStartedAtMs: 1_700_000_000_100,
      turnCompletedAtMs: 1_700_000_000_900,
      error: { message: "not retained" },
      items: [],
    }],
  }, 2);
  assert.deepEqual(entry.lastOutcome, {
    turnId: "turn-terminal",
    outcome: "failed",
    startedAtMs: 1_700_000_000_100,
    completedAtMs: 1_700_000_000_900,
  });
  assert.equal(JSON.stringify(entry).includes("not retained"), false);
});

test("completion can supply the first turn ID and retain the canonical start time", () => {
  const projector = createThreadActivityProjector();
  const running = observe(projector, "turn/started", {
    threadId: "fallback", turn: { startedAt: 100 },
  }).entry;
  assert.equal(running.runningStartedAtMs, 100_000);
  const terminal = observe(projector, "turn/completed", {
    threadId: "fallback", turn: { id: "real-turn", status: "completed", completedAt: 110 },
  }).entry;
  assert.equal(terminal.runtime, "idle");
  assert.equal(terminal.runningWithoutTurnId, false);
  assert.deepEqual(terminal.lastOutcome, {
    turnId: "real-turn", outcome: "completed", startedAtMs: 100_000, completedAtMs: 110_000,
  });
});

test("parallel completion clears only that turn's pending requests", () => {
  const projector = createThreadActivityProjector();
  for (const id of ["one", "two"]) {
    observe(projector, "turn/started", { threadId: "parallel", turn: { id, startedAt: 5 } });
    projector.observeAppServer({
      id, method: "item/commandExecution/requestApproval", params: { threadId: "parallel", turnId: id },
    });
  }
  let entry = observe(projector, "turn/completed", {
    threadId: "parallel", turn: { id: "one", status: "completed" },
  }).entry;
  assert.equal(entry.approvalRequestCount, 1);
  assert.equal(entry.runtime, "active");
  assert.deepEqual(entry.activeTurns, [{ turnId: "two", startedAtMs: 5_000 }]);
  entry = observe(projector, "turn/completed", {
    threadId: "parallel", turn: { id: "two", status: "interrupted" },
  }).entry;
  assert.equal(entry.approvalRequired, false);
  assert.equal(entry.lastOutcome.startedAtMs, 5_000);
});

test("runtime flags indicate attention without inventing actionable requests", () => {
  const projector = createThreadActivityProjector();
  const status = { type: "active", activeFlags: ["waitingOnApproval", "waitingOnUserInput"] };
  const canonical = observe(projector, "thread/status/changed", { threadId: "flags", status }).entry;
  const desktop = projectDesktopThreadActivity("flags", { threadRuntimeStatus: status }, 1);
  for (const entry of [canonical, desktop]) {
    assert.equal(entry.runtime, "active");
    assert.equal(entry.runningWithoutTurnId, true);
    assert.equal(entry.approvalRequired, true);
    assert.equal(entry.userInputRequired, true);
    assert.equal(entry.approvalRequestCount, 0);
    assert.equal(entry.userInputRequestCount, 0);
  }
});

test("long cwd stays exact and runtime unload retains the last outcome as stale", () => {
  const projector = createThreadActivityProjector();
  const cwd = "/tmp/" + "directory/".repeat(25);
  assert.equal(observeThread(projector, "closed", cwd, "Long path").entry.cwd, cwd);
  observe(projector, "turn/completed", { threadId: "closed", turn: { id: "done", status: "failed" } });
  const closed = observe(projector, "thread/closed", { threadId: "closed" }).entry;
  assert.equal(closed.freshness, "stale");
  assert.equal(closed.lastOutcome.outcome, "failed");
});

test("late items cannot replace a newer item or a terminal turn", () => {
  const projector = createThreadActivityProjector();
  observe(projector, "turn/started", { threadId: "items", turn: { id: "run" } });
  for (const id of ["older", "newer"]) {
    observe(projector, "item/started", {
      threadId: "items", turnId: "run", item: { id, type: "commandExecution" },
    });
  }
  assert.equal(observe(projector, "item/completed", {
    threadId: "items", turnId: "run", item: { id: "older", type: "commandExecution" },
  }), null);
  observe(projector, "turn/completed", { threadId: "items", turn: { id: "run", status: "completed" } });
  assert.equal(observe(projector, "item/started", {
    threadId: "items", turnId: "run", item: { id: "late", type: "reasoning" },
  }), null);
  const next = observe(projector, "turn/started", { threadId: "items", turn: { id: "next" } }).entry;
  assert.equal(next.latestItem, undefined);
});

test("Desktop seconds are converted by field and idle does not synthesize an outcome", () => {
  const terminal = projectDesktopThreadActivity("seconds", {
    turns: [{ id: "done", status: "completed", startedAt: 100, completedAt: 120 }],
  }, 1);
  assert.equal(terminal.lastOutcome.startedAtMs, 100_000);
  assert.equal(terminal.lastOutcome.completedAtMs, 120_000);
  const unknown = projectDesktopThreadActivity("idle", {
    threadRuntimeStatus: { type: "idle" },
    turns: [{ id: "stale", status: "inProgress", startedAt: null }],
  }, 1);
  assert.equal(unknown.runtime, "idle");
  assert.deepEqual(unknown.activeTurnIds, []);
  assert.equal(unknown.lastOutcome, undefined);
});

test("a new Desktop turn does not inherit an older turn's activity label", () => {
  const entry = projectDesktopThreadActivity("new-turn", {
    turns: [
      { id: "old", status: "completed", items: [{ id: "old-command", type: "commandExecution" }] },
      { id: "new", status: "inProgress", items: [] },
    ],
  }, 1);
  assert.equal(entry.runtime, "active");
  assert.equal(entry.latestItem, undefined);
});

function observeThread(projector, threadId, cwd, name) {
  return observe(projector, "thread/started", {
    thread: {
      id: threadId,
      cwd,
      name,
      status: { type: "idle" },
    },
  });
}

function observeRequest(projector, id, method) {
  return projector.observeAppServer({
    id,
    method,
    params: {
      threadId: "thread-actions",
      turnId: "turn-active",
      itemId: `item-${String(id)}`,
      questions: [{ question: "Private question" }],
      isBlocking: false,
    },
  });
}

function observe(projector, method, params) {
  return projector.observeAppServer({ method, params });
}
