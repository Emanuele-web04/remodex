// FILE: thread-agent-state.test.js
// Purpose: Verifies persisted per-thread agent runtime metadata and fork inheritance.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/thread-agent-state

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  createThreadAgentStateStore,
  normalizeThreadRecord,
} = require("../src/thread-agent-state");

test("thread agent state upserts and reloads runtime metadata", async () => {
  await withTempStateDir(async ({ stateStore }) => {
    const record = stateStore.upsert("thread-a", {
      agentRuntime: "opencode",
      agentSessionId: "ses-a",
      cwd: "/repo",
      opencodeBuildAgentName: "build",
      opencodePlanAgentName: "plan",
      runtimeLocked: true,
    });

    assert.equal(record.agentRuntime, "opencode");
    assert.equal(record.runtimeLocked, true);
    assert.equal(stateStore.get("thread-a")?.agentSessionId, "ses-a");
  });
});

test("inherit copies runtime metadata from source thread to forked thread", async () => {
  await withTempStateDir(async ({ stateStore }) => {
    stateStore.upsert("thread-source", {
      agentRuntime: "cursor",
      agentSessionId: "cur-source",
      cwd: "/repo",
      opencodeBuildAgentName: "build",
      opencodePlanAgentName: "plan",
      runtimeLocked: true,
    });

    const inherited = stateStore.inherit("thread-source", "thread-fork", {
      agentSessionId: "thread-fork",
    });

    assert.equal(inherited.agentRuntime, "cursor");
    assert.equal(inherited.agentSessionId, "thread-fork");
    assert.equal(inherited.cwd, "/repo");
    assert.equal(inherited.runtimeLocked, true);
    assert.equal(stateStore.get("thread-fork")?.agentRuntime, "cursor");
  });
});

test("normalizeThreadRecord defaults missing OpenCode agent names", () => {
  const record = normalizeThreadRecord("thread-default", {
    agentRuntime: "opencode",
    agentSessionId: "ses-1",
  });
  assert.equal(record.opencodeBuildAgentName, "build");
  assert.equal(record.opencodePlanAgentName, "plan");
});

async function withTempStateDir(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-thread-agent-state-"));
  process.env.REMODEX_DEVICE_STATE_DIR = stateDir;
  try {
    await run({ stateStore: createThreadAgentStateStore() });
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
}
