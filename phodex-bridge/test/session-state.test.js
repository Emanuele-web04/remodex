// FILE: session-state.test.js
// Purpose: Verifies last-thread persistence for Mac handoff reopen flows.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/session-state

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  rememberActiveThread,
  readLastActiveThread,
  resolveLastThreadPath,
  resolveRemodexStateDir,
} = require("../src/session-state");

test("session-state persists and reads the latest active thread", () => {
  withTempSessionEnv(({ rootDir }) => {
    assert.equal(rememberActiveThread("thread-1", "bridge"), true);
    assert.equal(resolveRemodexStateDir(), rootDir);
    assert.equal(readLastActiveThread()?.threadId, "thread-1");
    assert.equal(readLastActiveThread()?.source, "bridge");
    assert.equal(fs.existsSync(resolveLastThreadPath()), true);
  });
});

test("session-state rejects invalid thread ids", () => {
  withTempSessionEnv(() => {
    assert.equal(rememberActiveThread("", "bridge"), false);
    assert.equal(rememberActiveThread(null, "bridge"), false);
    assert.equal(readLastActiveThread(), null);
  });
});

test("session-state returns null for missing or corrupt state files", () => {
  withTempSessionEnv(({ rootDir }) => {
    assert.equal(readLastActiveThread(), null);

    const stateFile = resolveLastThreadPath();
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.writeFileSync(stateFile, "{not-json", "utf8");
    assert.equal(readLastActiveThread(), null);
    assert.equal(fs.existsSync(stateFile), true);
    assert.equal(path.dirname(stateFile), rootDir);
  });
});

function withTempSessionEnv(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-session-state-"));
  process.env.REMODEX_DEVICE_STATE_DIR = rootDir;

  try {
    run({ rootDir });
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    fs.rmSync(rootDir, { recursive: true, force: true });
  }
}
