// FILE: codex-desktop-refresher.test.js
// Purpose: Verifies desktop refresh defaults, failure hardening, and rollout-based throttling.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/codex-desktop-refresher, ../src/rollout-watch

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  CodexDesktopRefresher,
  readBridgeConfig,
} = require("../src/codex-desktop-refresher");
const { createThreadRolloutActivityWatcher } = require("../src/rollout-watch");

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("readBridgeConfig keeps safe defaults and explicit overrides", () => {
  const macConfig = readBridgeConfig({ env: {}, platform: "darwin" });
  const macEndpointConfig = readBridgeConfig({
    env: { REMODEX_CODEX_ENDPOINT: "ws://localhost:8080" },
    platform: "darwin",
  });
  const linuxConfig = readBridgeConfig({ env: {}, platform: "linux" });
  const linuxCommandConfig = readBridgeConfig({
    env: { REMODEX_REFRESH_COMMAND: "echo refresh" },
    platform: "linux",
  });
  const explicitOnConfig = readBridgeConfig({
    env: {
      REMODEX_CODEX_ENDPOINT: "ws://localhost:8080",
      REMODEX_REFRESH_ENABLED: "true",
    },
    platform: "darwin",
  });
  const explicitOffConfig = readBridgeConfig({
    env: {
      REMODEX_REFRESH_COMMAND: "echo refresh",
      REMODEX_REFRESH_ENABLED: "false",
    },
    platform: "darwin",
  });

  assert.equal(macConfig.refreshEnabled, false);
  assert.equal(macEndpointConfig.refreshEnabled, false);
  assert.equal(linuxConfig.refreshEnabled, false);
  assert.equal(linuxCommandConfig.refreshEnabled, false);
  assert.equal(explicitOnConfig.refreshEnabled, true);
  assert.equal(explicitOffConfig.refreshEnabled, false);
});

test("thread/start falls back once to the new-thread route when thread id is still unknown", async () => {
  const refreshCalls = [];
  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    fallbackNewThreadMs: 15,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
  });

  refresher.handleInbound(JSON.stringify({
    method: "thread/start",
    params: {},
  }));

  await wait(40);

  assert.deepEqual(refreshCalls, ["codex://threads/new"]);
  refresher.handleTransportReset();
});

test("thread/started cancels the fallback and refreshes the concrete thread route", async () => {
  const refreshCalls = [];
  const watchedThreads = [];
  let stopCount = 0;
  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    fallbackNewThreadMs: 40,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
    watchThreadRolloutFactory: ({ threadId }) => {
      watchedThreads.push(threadId);
      return {
        stop() {
          stopCount += 1;
        },
      };
    },
  });

  refresher.handleInbound(JSON.stringify({
    method: "thread/start",
    params: {},
  }));
  await wait(10);
  refresher.handleOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-123",
      },
    },
  }));

  await wait(25);

  assert.deepEqual(refreshCalls, ["codex://threads/thread-123"]);
  assert.deepEqual(watchedThreads, ["thread-123"]);

  await wait(30);
  assert.deepEqual(refreshCalls, ["codex://threads/thread-123"]);

  refresher.handleTransportReset();
  assert.equal(stopCount, 1);
});

test("rollout growth refreshes are throttled during long runs", async () => {
  const refreshCalls = [];
  let watcherHooks = null;
  let currentTime = 0;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    midRunRefreshThrottleMs: 3_000,
    now: () => currentTime,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
    watchThreadRolloutFactory: (hooks) => {
      watcherHooks = hooks;
      return { stop() {} };
    },
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-456",
    },
  }));
  await wait(10);
  refreshCalls.length = 0;

  currentTime = 1_000;
  watcherHooks.onEvent({
    reason: "growth",
    threadId: "thread-456",
    size: 10,
  });
  await wait(10);
  assert.deepEqual(refreshCalls, ["codex://threads/thread-456"]);

  refreshCalls.length = 0;
  currentTime = 2_000;
  watcherHooks.onEvent({
    reason: "growth",
    threadId: "thread-456",
    size: 15,
  });
  await wait(10);
  assert.deepEqual(refreshCalls, []);

  currentTime = 4_500;
  watcherHooks.onEvent({
    reason: "growth",
    threadId: "thread-456",
    size: 20,
  });
  await wait(10);
  assert.deepEqual(refreshCalls, ["codex://threads/thread-456"]);
});

test("turn/completed bypasses duplicate-target dedupe and still stops the watcher", async () => {
  const refreshCalls = [];
  let stopCount = 0;
  let currentTime = 3_000;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    now: () => currentTime,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
    watchThreadRolloutFactory: () => ({
      stop() {
        stopCount += 1;
      },
    }),
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-789",
    },
  }));
  await wait(10);

  currentTime = 4_500;
  refresher.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-789",
      turnId: "turn-789",
    },
  }));
  await wait(10);

  currentTime = 4_700;
  refresher.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-789",
      turnId: "turn-789",
    },
  }));
  await wait(10);

  assert.deepEqual(refreshCalls, [
    "codex://threads/thread-789",
    "codex://threads/thread-789",
  ]);
  assert.equal(stopCount, 1);
});

test("turn/completed is retried after a slow in-flight refresh finishes", async () => {
  const refreshCalls = [];
  let releaseSlowRefresh = null;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
      if (refreshCalls.length === 1) {
        await new Promise((resolve) => {
          releaseSlowRefresh = resolve;
        });
      }
    },
    watchThreadRolloutFactory: () => ({ stop() {} }),
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-slow",
    },
  }));
  await wait(10);

  refresher.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-slow",
      turnId: "turn-slow",
    },
  }));
  await wait(10);

  assert.equal(refreshCalls.length, 1);

  releaseSlowRefresh?.();
  await wait(20);

  assert.deepEqual(refreshCalls, [
    "codex://threads/thread-slow",
    "codex://threads/thread-slow",
  ]);
});

test("completion refresh keeps its own thread target even if another thread queues behind it", async () => {
  const refreshCalls = [];
  let stopCount = 0;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 1_200,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
    watchThreadRolloutFactory: ({ threadId }) => ({
      stop() {
        if (threadId === "thread-a") {
          stopCount += 1;
        }
      },
    }),
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-a" },
  }));
  await wait(10);
  refreshCalls.length = 0;
  refresher.clearRefreshTimer();

  refresher.handleOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-a",
      turnId: "turn-a",
    },
  }));
  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-b" },
  }));
  refresher.clearRefreshTimer();
  await refresher.runPendingRefresh();
  await refresher.runPendingRefresh();

  assert.deepEqual(refreshCalls, [
    "codex://threads/thread-a",
    "codex://threads/thread-b",
  ]);
  assert.equal(stopCount, 1);
});

test("handleTransportReset cancels pending refreshes and clears watcher state", async () => {
  const refreshCalls = [];
  let stopCount = 0;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 30,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
    watchThreadRolloutFactory: () => ({
      stop() {
        stopCount += 1;
      },
    }),
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-reset",
    },
  }));
  refresher.handleTransportReset();
  await wait(50);

  assert.deepEqual(refreshCalls, []);
  assert.equal(stopCount, 1);
});

test("handleTransportReset clears duplicate-target memory so the next refresh can run", async () => {
  const refreshCalls = [];
  let currentTime = 5_000;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 1_200,
    now: () => currentTime,
    refreshExecutor: async (targetUrl) => {
      refreshCalls.push(targetUrl);
    },
    watchThreadRolloutFactory: () => ({ stop() {} }),
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-reset-dedupe" },
  }));
  await wait(10);

  refresher.handleTransportReset();

  currentTime = 5_100;
  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-reset-dedupe" },
  }));
  await wait(10);

  assert.deepEqual(refreshCalls, [
    "codex://threads/thread-reset-dedupe",
    "codex://threads/thread-reset-dedupe",
  ]);
});

test("desktop refresh disables itself after a desktop-unavailable AppleScript failure", async () => {
  let attempts = 0;
  let stopCount = 0;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    refreshBackend: "applescript",
    refreshExecutor: async () => {
      attempts += 1;
      throw new Error("Unable to find application named Codex");
    },
    watchThreadRolloutFactory: () => ({
      stop() {
        stopCount += 1;
      },
    }),
  });

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-disable-1",
    },
  }));
  await wait(10);

  refresher.handleInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-disable-2",
    },
  }));
  await wait(10);

  assert.equal(attempts, 1);
  assert.equal(stopCount, 1);
  assert.equal(refresher.runtimeRefreshAvailable, false);
});

test("custom refresh commands only disable after repeated failures", async () => {
  let attempts = 0;

  const refresher = new CodexDesktopRefresher({
    enabled: true,
    debounceMs: 0,
    refreshBackend: "command",
    customRefreshFailureThreshold: 3,
    refreshExecutor: async () => {
      attempts += 1;
      throw new Error("command failed");
    },
  });

  for (const threadId of ["thread-cmd-1", "thread-cmd-2", "thread-cmd-3", "thread-cmd-4"]) {
    refresher.handleInbound(JSON.stringify({
      method: "turn/start",
      params: { threadId },
    }));
    await wait(10);
  }

  assert.equal(attempts, 3);
  assert.equal(refresher.runtimeRefreshAvailable, false);
});

test("rollout watcher retries transient filesystem errors before succeeding", async () => {
  const events = [];
  const errors = [];
  let readdirCalls = 0;

  const watcher = createThreadRolloutActivityWatcher({
    threadId: "thread-watch-ok",
    intervalMs: 5,
    lookupTimeoutMs: 100,
    idleTimeoutMs: 100,
    transientErrorRetryLimit: 2,
    fsModule: {
      existsSync: () => true,
      readdirSync: () => {
        readdirCalls += 1;
        if (readdirCalls === 1) {
          const error = new Error("temporary missing dir");
          error.code = "ENOENT";
          throw error;
        }

        return [{
          name: "rollout-thread-watch-ok.jsonl",
          isDirectory: () => false,
          isFile: () => true,
        }];
      },
      statSync: () => ({ size: 12, mtimeMs: Date.now() }),
      openSync: () => 1,
      readSync: (_fd, buffer) => {
        buffer.write('{"x":1}\n', 0, "utf8");
        return 8;
      },
      closeSync: () => {},
    },
    onEvent: (event) => events.push(event),
    onError: (error) => errors.push(error),
  });

  await wait(25);
  watcher.stop();

  assert.equal(errors.length, 0);
  assert.equal(events[0]?.reason, "materialized");
});

test("rollout watcher stops after repeated transient filesystem failures", async () => {
  const errors = [];
  let currentTime = 0;

  const watcher = createThreadRolloutActivityWatcher({
    threadId: "thread-watch-fail",
    intervalMs: 5,
    lookupTimeoutMs: 100,
    idleTimeoutMs: 100,
    transientErrorRetryLimit: 1,
    now: () => {
      currentTime += 5;
      return currentTime;
    },
    fsModule: {
      existsSync: () => true,
      readdirSync: () => {
        const error = new Error("still missing");
        error.code = "ENOENT";
        throw error;
      },
    },
    onError: (error) => errors.push(error),
  });

  await wait(25);
  watcher.stop();

  assert.equal(errors.length, 1);
});
