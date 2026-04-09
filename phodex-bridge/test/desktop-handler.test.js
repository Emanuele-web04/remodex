// FILE: desktop-handler.test.js
// Purpose: Verifies explicit Mac handoff routing and errors for desktop bridge methods.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/desktop-handler

const test = require("node:test");
const assert = require("node:assert/strict");

const { handleDesktopRequest } = require("../src/desktop-handler");

test("desktop/continueOnMac relaunches Codex for the requested thread", async () => {
  const executorCalls = [];
  const responses = [];
  let running = true;

  const handled = handleDesktopRequest(JSON.stringify({
    id: "request-1",
    method: "desktop/continueOnMac",
    params: {
      threadId: "thread-123",
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  }, {
    platform: "darwin",
    bundleId: "com.openai.codex",
    appPath: "/Applications/Codex.app",
    executor: async (...args) => {
      executorCalls.push(args);
      if (args[0] === "pkill") {
        running = false;
      }
      return { stdout: "", stderr: "" };
    },
    isAppRunning: async () => running,
    sleepFn: async () => {},
    threadMaterializeWaitMs: 0,
  });

  assert.equal(handled, true);

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(executorCalls.length, 3);
  assert.equal(executorCalls[0][0], "pkill");
  assert.deepEqual(executorCalls[0][1], [
    "-x",
    "Codex",
  ]);
  assert.equal(executorCalls[1][0], "open");
  assert.deepEqual(executorCalls[1][1], [
    "-b",
    "com.openai.codex",
  ]);
  assert.equal(executorCalls[2][0], "open");
  assert.deepEqual(executorCalls[2][1], [
    "-b",
    "com.openai.codex",
    "codex://threads/thread-123",
  ]);
  assert.deepEqual(responses, [{
    id: "request-1",
    result: {
      success: true,
      relaunched: true,
      targetUrl: "codex://threads/thread-123",
      threadId: "thread-123",
      desktopKnown: false,
    },
  }]);
});

test("desktop/continueOnMac boots Codex before deep-linking unknown threads", async () => {
  const executorCalls = [];
  const responses = [];

  handleDesktopRequest(JSON.stringify({
    id: "request-1b",
    method: "desktop/continueOnMac",
    params: {
      threadId: "thread-closed-app",
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  }, {
    platform: "darwin",
    bundleId: "com.openai.codex",
    appPath: "/Applications/Codex.app",
    executor: async (...args) => {
      executorCalls.push(args);
      return { stdout: "", stderr: "" };
    },
    isAppRunning: async () => false,
    sleepFn: async () => {},
    threadMaterializeWaitMs: 0,
  });

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(executorCalls.length, 2);
  assert.equal(executorCalls[0][0], "open");
  assert.deepEqual(executorCalls[0][1], [
    "-b",
    "com.openai.codex",
  ]);
  assert.equal(executorCalls[1][0], "open");
  assert.deepEqual(executorCalls[1][1], [
    "-b",
    "com.openai.codex",
    "codex://threads/thread-closed-app",
  ]);
  assert.equal(responses[0].result?.relaunched, false);
});

test("desktop/continueOnMac relaunches when a desktop-known thread is requested and Codex is already open", async () => {
  const executorCalls = [];
  const responses = [];
  let running = true;
  const fakeFS = {
    existsSync(targetPath) {
      return targetPath.endsWith("/sessions");
    },
    readdirSync() {
      return [{
        isDirectory: () => false,
        isFile: () => true,
        name: "rollout-2026-thread-desktop-known.jsonl",
      }];
    },
    readFileSync() {
      return JSON.stringify({
        type: "session_meta",
        payload: {
          originator: "Codex Desktop",
        },
      }) + "\n";
    },
  };

  handleDesktopRequest(JSON.stringify({
    id: "request-1c",
    method: "desktop/continueOnMac",
    params: {
      threadId: "thread-desktop-known",
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  }, {
    platform: "darwin",
    bundleId: "com.openai.codex",
    appPath: "/Applications/Codex.app",
    env: { CODEX_HOME: "/tmp/codex-home" },
    fsModule: fakeFS,
    executor: async (...args) => {
      executorCalls.push(args);
      if (args[0] === "pkill") {
        running = false;
      }
      return { stdout: "", stderr: "" };
    },
    isAppRunning: async () => running,
    sleepFn: async () => {},
  });

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(executorCalls.length, 3);
  assert.equal(executorCalls[0][0], "pkill");
  assert.deepEqual(executorCalls[0][1], [
    "-x",
    "Codex",
  ]);
  assert.equal(executorCalls[1][0], "open");
  assert.deepEqual(executorCalls[1][1], [
    "-b",
    "com.openai.codex",
  ]);
  assert.equal(executorCalls[2][0], "open");
  assert.deepEqual(executorCalls[2][1], [
    "-b",
    "com.openai.codex",
    "codex://threads/thread-desktop-known",
  ]);
  assert.equal(responses[0].result?.relaunched, true);
  assert.equal(responses[0].result?.desktopKnown, true);
});

test("desktop/continueOnMac boots Codex before deep-linking when the thread already exists locally but Codex is closed", async () => {
  const executorCalls = [];
  const responses = [];
  let running = false;
  const fakeFS = {
    existsSync(targetPath) {
      return targetPath.endsWith("/sessions");
    },
    readdirSync() {
      return [{
        isDirectory: () => false,
        isFile: () => true,
        name: "rollout-2026-thread-phone-known.jsonl",
      }];
    },
  };

  handleDesktopRequest(JSON.stringify({
    id: "request-1d",
    method: "desktop/continueOnMac",
    params: {
      threadId: "thread-phone-known",
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  }, {
    platform: "darwin",
    bundleId: "com.openai.codex",
    appPath: "/Applications/Codex.app",
    env: { CODEX_HOME: "/tmp/codex-home" },
    fsModule: fakeFS,
    executor: async (...args) => {
      executorCalls.push(args);
      return { stdout: "", stderr: "" };
    },
    isAppRunning: async () => running,
    sleepFn: async () => {},
  });

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(executorCalls.length, 2);
  assert.equal(executorCalls[0][0], "open");
  assert.deepEqual(executorCalls[0][1], [
    "-b",
    "com.openai.codex",
  ]);
  assert.equal(executorCalls[1][0], "open");
  assert.deepEqual(executorCalls[1][1], [
    "-b",
    "com.openai.codex",
    "codex://threads/thread-phone-known",
  ]);
  assert.equal(responses[0].result?.relaunched, false);
  assert.equal(responses[0].result?.desktopKnown, true);
});

test("desktop/continueOnMac returns a bridge error when thread id is missing", async () => {
  const responses = [];

  handleDesktopRequest(JSON.stringify({
    id: "request-2",
    method: "desktop/continueOnMac",
    params: {},
  }), (response) => {
    responses.push(JSON.parse(response));
  }, {
    platform: "darwin",
    executor: async () => ({ stdout: "", stderr: "" }),
  });

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(responses.length, 1);
  assert.equal(responses[0].id, "request-2");
  assert.equal(responses[0].error?.data?.errorCode, "missing_thread_id");
});

test("desktop/continueOnMac refuses non-mac platforms", async () => {
  const responses = [];

  handleDesktopRequest(JSON.stringify({
    id: "request-3",
    method: "desktop/continueOnMac",
    params: {
      threadId: "thread-456",
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  }, {
    platform: "linux",
  });

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(responses.length, 1);
  assert.equal(responses[0].id, "request-3");
  assert.equal(responses[0].error?.data?.errorCode, "unsupported_platform");
});
