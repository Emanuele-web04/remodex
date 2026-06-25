// FILE: opencode-usage-rpc.test.js
// Purpose: Verifies OpenCode project/discover, session/getUsageStats, and auth error RPC helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-*-handler, ../src/opencode-usage-mapper

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  handleOpenCodeProjectDiscoverRequest,
  projectDiscoverFromOpenCode,
} = require("../src/opencode-project-discover-handler");
const {
  handleOpenCodeSessionUsageRequest,
  sessionGetUsageStats,
} = require("../src/opencode-session-usage-handler");
const {
  createOpenCodeAuthErrorNotifier,
  extractOpenCodeAuthError,
} = require("../src/opencode-auth-error-handler");
const {
  mapOpenCodeSessionToContextUsage,
  isProviderAuthErrorPayload,
} = require("../src/opencode-usage-mapper");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-usage-rpc-"));
}

async function withOpenCodeEnabled(run) {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;
  try {
    return await run();
  } finally {
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
}

function makeOwnershipStore(tempDir) {
  const store = createThreadOwnershipStore({
    storagePath: path.join(tempDir, "thread-ownership.json"),
    fsImpl: fs,
  });
  store.setOwnership("thread-oc", "opencode");
  store.setOwnership("thread-codex", "codex");
  return store;
}

test("mapOpenCodeSessionToContextUsage sums token counters into context window shape", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    {
      tokens: { input: 1200, output: 300, reasoning: 50, cache: { read: 100, write: 0 } },
      contextWindow: 128000,
    },
    {},
  );

  assert.deepEqual(usage, { tokensUsed: 1650, tokenLimit: 128000 });
});

test("project/discover registers OpenCode projects in the bridge registry", async () => {
  await withOpenCodeEnabled(async () => {
    const homeDir = makeTempDir();
    const allowedDir = path.join(homeDir, "workspace", "demo-app");
    fs.mkdirSync(allowedDir, { recursive: true });
    const remembered = [];
    const opencodeProvider = {
      discoverProjects: async () => [
        { id: "proj-1", path: allowedDir, name: "Demo App" },
        { id: "proj-evil", path: "/etc/passwd", name: "Blocked" },
      ],
    };
    const projectRegistry = {
      rememberProjectPath: (projectPath, meta) => {
        remembered.push({ projectPath, meta });
      },
    };

    try {
      const result = await projectDiscoverFromOpenCode(
        {},
        { homeDir, opencodeProvider, projectRegistry },
      );

      assert.equal(result.source, "opencode");
      assert.equal(result.count, 1);
      assert.equal(result.projects.length, 1);
      assert.equal(remembered.length, 1);
      assert.equal(remembered[0].projectPath, fs.realpathSync(allowedDir));
      assert.equal(remembered[0].meta.provider, "opencode");
    } finally {
      fs.rmSync(homeDir, { recursive: true });
    }
  });
});

test("project/discover rejects disallowed directory params before calling OpenCode", async () => {
  await withOpenCodeEnabled(async () => {
    const homeDir = makeTempDir();
    try {
      let discoverCalled = false;
      const opencodeProvider = {
        discoverProjects: async () => {
          discoverCalled = true;
          return [];
        },
      };

      await assert.rejects(
        () =>
          projectDiscoverFromOpenCode(
            { directory: "/etc" },
            { homeDir, opencodeProvider, projectRegistry: null },
          ),
        (err) => err.errorCode === "path_not_allowed",
      );
      assert.equal(discoverCalled, false);
    } finally {
      fs.rmSync(homeDir, { recursive: true });
    }
  });
});

test("project/discover rejects symlink directories that resolve outside home", async () => {
  await withOpenCodeEnabled(async () => {
    const homeDir = makeTempDir();
    const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-discover-outside-"));
    const linkPath = path.join(homeDir, "outside-link");
    fs.symlinkSync(outsideDir, linkPath, "dir");

    try {
      let discoverCalled = false;
      const opencodeProvider = {
        discoverProjects: async () => {
          discoverCalled = true;
          return [];
        },
      };

      await assert.rejects(
        () =>
          projectDiscoverFromOpenCode(
            { directory: linkPath },
            { homeDir, opencodeProvider, projectRegistry: null },
          ),
        (err) => err.errorCode === "path_not_allowed",
      );
      assert.equal(discoverCalled, false);
    } finally {
      fs.rmSync(homeDir, { recursive: true });
      fs.rmSync(outsideDir, { recursive: true });
    }
  });
});

test("handleOpenCodeProjectDiscoverRequest responds to project/discover RPC", async () => {
  await withOpenCodeEnabled(async () => {
    const homeDir = makeTempDir();
    const repoDir = path.join(homeDir, "workspace", "repo");
    fs.mkdirSync(repoDir, { recursive: true });
    const opencodeProvider = {
      discoverProjects: async () => [{ id: "p1", path: repoDir, name: "Repo" }],
    };
    try {
      const response = await new Promise((resolve) => {
        const handled = handleOpenCodeProjectDiscoverRequest(
          JSON.stringify({ id: 7, method: "project/discover", params: {} }),
          (payload) => resolve(JSON.parse(payload)),
          { homeDir, opencodeProvider, projectRegistry: null },
        );
        assert.equal(handled, true);
      });

      assert.equal(response.id, 7);
      assert.equal(response.result.source, "opencode");
      assert.equal(response.result.count, 1);
    } finally {
      fs.rmSync(homeDir, { recursive: true });
    }
  });
});

test("session/getUsageStats returns OpenCode usage for owned threads", async () => {
  await withOpenCodeEnabled(async () => {
    const tempDir = makeTempDir();
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      const opencodeProvider = {
        getUsageStatsForThread: async (threadId) => ({
          sessionId: "sess-1",
          usage: { tokensUsed: 900, tokenLimit: 200000 },
        }),
      };

      const result = await sessionGetUsageStats(
        { threadId: "thread-oc" },
        { ownershipStore, opencodeProvider },
      );

      assert.equal(result.threadId, "thread-oc");
      assert.equal(result.sessionId, "sess-1");
      assert.deepEqual(result.usage, { tokensUsed: 900, tokenLimit: 200000 });
      assert.equal(result.source, "opencode");
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("session/getUsageStats rejects non-OpenCode threads", async () => {
  await withOpenCodeEnabled(async () => {
    const tempDir = makeTempDir();
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      await assert.rejects(
        () =>
          sessionGetUsageStats(
            { threadId: "thread-codex" },
            { ownershipStore, opencodeProvider: { getUsageStatsForThread: async () => ({}) } },
          ),
        (error) => error.errorCode === "wrong_provider",
      );
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("handleOpenCodeSessionUsageRequest responds to session/getUsageStats RPC", async () => {
  await withOpenCodeEnabled(async () => {
    const tempDir = makeTempDir();
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      const opencodeProvider = {
        getUsageStatsForThread: async () => ({
          sessionId: "sess-42",
          usage: { tokensUsed: 42, tokenLimit: 1000 },
        }),
      };

      const response = await new Promise((resolve) => {
        const handled = handleOpenCodeSessionUsageRequest(
          JSON.stringify({ id: 9, method: "session/getUsageStats", params: { threadId: "thread-oc" } }),
          (payload) => resolve(JSON.parse(payload)),
          { ownershipStore, opencodeProvider },
        );
        assert.equal(handled, true);
      });

      assert.equal(response.id, 9);
      assert.equal(response.result.sessionId, "sess-42");
      assert.deepEqual(response.result.usage, { tokensUsed: 42, tokenLimit: 1000 });
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("auth error notifier emits runtime/auth/error for ProviderAuthError payloads", () => {
  const outbound = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => outbound.push(JSON.parse(payload)),
  });

  const sent = notifier.inspectTurnFailure({
    threadId: "thread-oc",
    turnId: "turn-1",
    message: "Provider authentication failed",
    error: { name: "ProviderAuthError", providerID: "anthropic" },
  });

  assert.equal(sent, true);
  assert.equal(outbound.length, 1);
  assert.equal(outbound[0].method, "runtime/auth/error");
  assert.equal(outbound[0].params.errorCode, "provider_auth_error");
  assert.equal(outbound[0].params.providerID, "anthropic");
});

test("extractOpenCodeAuthError ignores non-auth failures", () => {
  assert.equal(
    extractOpenCodeAuthError({ message: "tool execution timed out", error: { name: "TimeoutError" } }),
    null,
  );
  assert.equal(
    extractOpenCodeAuthError({
      message: "unauthorized workspace access",
      error: { message: "unauthorized workspace access" },
    }),
    null,
  );
});

test("isProviderAuthErrorPayload matches structured auth signals", () => {
  assert.equal(
    isProviderAuthErrorPayload({ name: "ProviderAuthError", providerID: "anthropic" }),
    true,
  );
  assert.equal(
    isProviderAuthErrorPayload({ errorCode: "provider_auth_error", providerId: "openai" }),
    true,
  );
  assert.equal(
    isProviderAuthErrorPayload({ status: 401, providerID: "google" }),
    true,
  );
  assert.equal(
    isProviderAuthErrorPayload({ data: { errorCode: "invalid_api_key", providerID: "xai" } }),
    true,
  );
});

test("isProviderAuthErrorPayload ignores message-only unauthorized substrings", () => {
  assert.equal(isProviderAuthErrorPayload({ message: "unauthorized" }), false);
  assert.equal(
    isProviderAuthErrorPayload({ message: "authentication failed for tool execution" }),
    false,
  );
  assert.equal(isProviderAuthErrorPayload({ message: "invalid api key in prompt" }), false);
});
