// FILE: rollout-watch.test.js
// Purpose: Verifies rollout token parsing prefers last-turn usage over cumulative session totals.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/rollout-watch

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");
const { setTimeout: wait } = require("node:timers/promises");

const {
  contextUsageFromTokenCountPayload,
  createThreadRolloutActivityWatcher,
  readLatestContextWindowUsage,
} = require("../src/rollout-watch");

test("contextUsageFromTokenCountPayload prefers last_token_usage totals", () => {
  const usage = contextUsageFromTokenCountPayload({
    info: {
      total_token_usage: {
        total_tokens: 123_884_753,
      },
      last_token_usage: {
        total_tokens: 200_930,
      },
      model_context_window: 258_400,
    },
  });

  assert.deepEqual(usage, {
    tokensUsed: 200_930,
    tokenLimit: 258_400,
  });
});

test("watcher falls back to the thread-scoped rollout when turn id is unavailable", async (t) => {
  const { homeDir, threadDir } = makeTemporarySessionsHome();
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  writeRolloutFile(path.join(threadDir, "rollout-2026-03-05T13-23-27-thread-a.jsonl"), {
    turnId: "turn-a",
    tokensUsed: 111,
    tokenLimit: 1_000,
  });
  writeRolloutFile(path.join(threadDir, "rollout-2026-03-05T13-25-27-thread-b.jsonl"), {
    turnId: "turn-b",
    tokensUsed: 999,
    tokenLimit: 1_000,
  });

  const usages = [];
  const watcher = createThreadRolloutActivityWatcher({
    threadId: "thread-a",
    intervalMs: 5,
    lookupTimeoutMs: 100,
    idleTimeoutMs: 100,
    onUsage: ({ usage }) => usages.push(usage),
  });

  await wait(30);
  watcher.stop();

  assert.deepEqual(usages[0], {
    tokensUsed: 111,
    tokenLimit: 1_000,
  });
});

test("readLatestContextWindowUsage prefers the thread-scoped rollout over newer unrelated files", (t) => {
  const { homeDir, threadDir } = makeTemporarySessionsHome();
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  writeRolloutFile(path.join(threadDir, "rollout-2026-03-05T13-23-27-thread-a.jsonl"), {
    turnId: "turn-a",
    tokensUsed: 222,
    tokenLimit: 1_000,
  });
  writeRolloutFile(path.join(threadDir, "rollout-2026-03-05T13-25-27-thread-b.jsonl"), {
    turnId: "turn-b",
    tokensUsed: 999,
    tokenLimit: 1_000,
  });

  const result = readLatestContextWindowUsage({ threadId: "thread-a" });
  assert.deepEqual(result?.usage, {
    tokensUsed: 222,
    tokenLimit: 1_000,
  });
  assert.match(result?.rolloutPath ?? "", /thread-a\.jsonl$/);
});

test("readLatestContextWindowUsage returns null when no rollout matches the requested thread", (t) => {
  const { homeDir, threadDir } = makeTemporarySessionsHome();
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  writeRolloutFile(path.join(threadDir, "rollout-2026-03-05T13-25-27-thread-b.jsonl"), {
    turnId: "turn-b",
    tokensUsed: 999,
    tokenLimit: 1_000,
  });

  const result = readLatestContextWindowUsage({ threadId: "missing-thread" });
  assert.equal(result, null);
});

function makeTemporarySessionsHome() {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "rollout-watch-"));
  const threadDir = path.join(homeDir, "sessions", "2026", "03", "12");
  fs.mkdirSync(threadDir, { recursive: true });
  return { homeDir, threadDir };
}

function writeRolloutFile(filePath, { turnId, tokensUsed, tokenLimit }) {
  const lines = [
    JSON.stringify({
      timestamp: "2026-03-05T13:23:27.971Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: turnId,
        model_context_window: tokenLimit,
      },
    }),
    JSON.stringify({
      timestamp: "2026-03-05T13:23:29.357Z",
      type: "event_msg",
      payload: {
        type: "token_count",
        info: {
          last_token_usage: {
            total_tokens: tokensUsed,
          },
          model_context_window: tokenLimit,
        },
      },
    }),
    "",
  ];
  fs.writeFileSync(filePath, lines.join("\n"));
}

function restoreCodexHome(previousCodexHome) {
  if (previousCodexHome == null) {
    delete process.env.CODEX_HOME;
    return;
  }
  process.env.CODEX_HOME = previousCodexHome;
}
