// FILE: opencode-handoff.test.js
// Purpose: Verifies OpenCode desktop handoff payload building, env gate, and TUI fallback behavior.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-handoff

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildHandoffPayload,
  continueOpenCodeHandoff,
  detectOpenCodeApp,
  isOpenCodeHandoffEnabled,
} = require("../src/opencode-handoff");

function fakeOwnership(providerId = "opencode") {
  return {
    getOwnership(threadId) {
      return threadId === "opencode-thread-1" ? providerId : null;
    },
  };
}

function fakeProvider({
  context = {
    threadId: "opencode-thread-1",
    sessionId: "ses_abc",
    cwd: "/Users/dev/project",
    model: "anthropic/claude-sonnet-4-5",
    agent: "build",
    title: "Mobile thread",
  },
  tuiSelected = true,
} = {}) {
  return {
    id: "opencode",
    async getHandoffContext() {
      return { ...context };
    },
    async selectTuiSession(sessionId) {
      assert.equal(sessionId, context.sessionId);
      return tuiSelected;
    },
  };
}

test("isOpenCodeHandoffEnabled respects production defaults and explicit overrides", () => {
  assert.equal(isOpenCodeHandoffEnabled({}), true);
  assert.equal(isOpenCodeHandoffEnabled({ REMODEX_PROFILE: "dev" }), false);
  assert.equal(isOpenCodeHandoffEnabled({ NODE_ENV: "development" }), false);
  assert.equal(isOpenCodeHandoffEnabled({ REMODEX_OPENCODE_HANDOFF: "0" }), false);
  assert.equal(isOpenCodeHandoffEnabled({ REMODEX_OPENCODE_HANDOFF: "1" }), true);
  assert.equal(isOpenCodeHandoffEnabled({ REMODEX_OPENCODE_HANDOFF: "true" }), true);
});

test("buildHandoffPayload returns session metadata fields", () => {
  assert.deepEqual(
    buildHandoffPayload({
      threadId: "opencode-thread-1",
      sessionId: "ses_abc",
      cwd: "/tmp/proj",
      model: "openai/gpt-5.5",
      agent: "plan",
      title: "Fix tests",
    }),
    {
      threadId: "opencode-thread-1",
      sessionId: "ses_abc",
      cwd: "/tmp/proj",
      model: "openai/gpt-5.5",
      agent: "plan",
      title: "Fix tests",
    },
  );
});

test("continueOpenCodeHandoff rejects whitespace-only thread id", async () => {
  await assert.rejects(
    () =>
      continueOpenCodeHandoff(
        { threadId: "   " },
        {
          env: { REMODEX_OPENCODE_HANDOFF: "1" },
          platform: "darwin",
          ownershipStore: fakeOwnership(),
          opencodeProvider: fakeProvider(),
        },
      ),
    (error) => {
      assert.equal(error.errorCode, "missing_thread_id");
      return true;
    },
  );
});

test("continueOpenCodeHandoff rejects missing thread id", async () => {
  await assert.rejects(
    () =>
      continueOpenCodeHandoff(
        {},
        {
          env: { REMODEX_OPENCODE_HANDOFF: "1" },
          platform: "darwin",
          ownershipStore: fakeOwnership(),
          opencodeProvider: fakeProvider(),
        },
      ),
    (error) => {
      assert.equal(error.errorCode, "missing_thread_id");
      return true;
    },
  );
});

test("continueOpenCodeHandoff rejects wrong provider ownership", async () => {
  const codexOwnedStore = {
    getOwnership(threadId) {
      return threadId === "codex-thread-99" ? "codex" : null;
    },
  };

  await assert.rejects(
    () =>
      continueOpenCodeHandoff(
        { threadId: "codex-thread-99" },
        {
          env: { REMODEX_OPENCODE_HANDOFF: "1" },
          platform: "darwin",
          ownershipStore: codexOwnedStore,
          opencodeProvider: fakeProvider(),
        },
      ),
    (error) => {
      assert.equal(error.errorCode, "wrong_provider");
      return true;
    },
  );
});

test("continueOpenCodeHandoff rejects when env gate is off", async () => {
  await assert.rejects(
    () =>
      continueOpenCodeHandoff(
        { threadId: "opencode-thread-1" },
        {
          env: { REMODEX_OPENCODE_HANDOFF: "0" },
          platform: "darwin",
          ownershipStore: fakeOwnership(),
          opencodeProvider: fakeProvider(),
        },
      ),
    (error) => {
      assert.equal(error.errorCode, "opencode_handoff_disabled");
      return true;
    },
  );
});

test("continueOpenCodeHandoff returns payload with TUI selection", async () => {
  const result = await continueOpenCodeHandoff(
    {
      threadId: "opencode-thread-1",
      sessionId: "ses_abc",
      directory: "/Users/dev/project",
    },
    {
      env: { REMODEX_OPENCODE_HANDOFF: "1" },
      platform: "darwin",
      ownershipStore: fakeOwnership(),
      opencodeProvider: fakeProvider(),
      executor: async () => ({ stdout: "", stderr: "" }),
      fsModule: { existsSync: () => false },
    },
  );

  assert.equal(result.success, true);
  assert.equal(result.sessionId, "ses_abc");
  assert.equal(result.cwd, "/Users/dev/project");
  assert.equal(result.model, "anthropic/claude-sonnet-4-5");
  assert.equal(result.agent, "build");
  assert.equal(result.title, "Mobile thread");
  assert.equal(result.handoffMode, "tui");
  assert.equal(result.sessionSelected, true);
});

test("continueOpenCodeHandoff uses desktop_app + TUI fallback when no deep link", async () => {
  const executorCalls = [];
  const result = await continueOpenCodeHandoff(
    {
      threadId: "opencode-thread-1",
      preferDesktopApp: true,
    },
    {
      env: { REMODEX_OPENCODE_HANDOFF: "1" },
      platform: "darwin",
      ownershipStore: fakeOwnership(),
      opencodeProvider: fakeProvider({ tuiSelected: false }),
      executor: async (...args) => {
        executorCalls.push(args);
        return { stdout: "", stderr: "" };
      },
      fsModule: {
        existsSync(path) {
          return path === "/Applications/OpenCode.app";
        },
      },
    },
  );

  assert.equal(executorCalls.length, 1);
  assert.deepEqual(executorCalls[0][0], "open");
  assert.equal(result.handoffMode, "desktop_app");
  assert.equal(result.sessionSelected, false);
  assert.equal(result.desktopAppInstalled, true);
  assert.match(result.instructions, /Terminal|session picker/i);
});

test("continueOpenCodeHandoff returns tui_only when desktop app is missing", async () => {
  const result = await continueOpenCodeHandoff(
    { threadId: "opencode-thread-1" },
    {
      env: { REMODEX_OPENCODE_HANDOFF: "1" },
      platform: "darwin",
      ownershipStore: fakeOwnership(),
      opencodeProvider: fakeProvider({ tuiSelected: false }),
      executor: async () => {
        throw new Error("should not launch desktop");
      },
      fsModule: { existsSync: () => false },
    },
  );

  assert.equal(result.handoffMode, "tui_only");
  assert.equal(result.sessionSelected, false);
  assert.equal(result.desktopAppInstalled, false);
});

test("detectOpenCodeApp reports installed app path from filesystem", async () => {
  const detection = await detectOpenCodeApp({
    fsModule: {
      existsSync(path) {
        return path === "/Applications/OpenCode.app";
      },
    },
    executor: async () => {
      throw new Error("mdfind should not run when app path exists");
    },
    env: { platform: "darwin" },
  });

  assert.equal(detection.installed, true);
  assert.equal(detection.bundleId, "ai.opencode.desktop");
  assert.equal(detection.appPath, "/Applications/OpenCode.app");
});
