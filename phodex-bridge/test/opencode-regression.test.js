// FILE: opencode-regression.test.js
// Purpose: Verifies OpenCode disable flags, router lifecycle RPCs (command/list,
//          skills/list, desktop/continueOpenCode handoff), and Codex-only regression.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/runtime-provider-router, ./test-env (preload)

if (process.env.REMODEX_TEST !== "1") {
  throw new Error(
    "opencode-regression.test.js must run with the test harness preload.\n" +
      "  npm test\n" +
      "  node -r ./test/test-env.js --test ./test/opencode-regression.test.js\n" +
      "Without -r ./test/test-env.js, tests may spawn live opencode serve and hang.",
  );
}

const test = require("node:test");
const assert = require("node:assert/strict");
const { buildStaticSlashCommands } = require("../src/opencode-client");
const { createOpenCodeProvider } = require("../src/opencode-provider");
const {
  createRuntimeProviderRouter,
  resetOpenCodeProjectDiscoverState,
} = require("../src/runtime-provider-router");
const { handleDesktopRequest } = require("../src/desktop-handler");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");

function waitOneTick() {
  return new Promise((resolve) => setImmediate(resolve));
}

function mockOpenCodeProvider(overrides = {}) {
  return {
    id: "opencode",
    async listModels() {
      return [];
    },
    async listAgents() {
      return [{ id: "build", label: "Build" }];
    },
    async listCommands(directory) {
      return [
        { token: "/build", title: "Build", description: "Build the project", directory },
      ];
    },
    async listSkills(directory) {
      return [
        {
          name: "opencode-skill",
          description: "From OpenCode",
          path: `${directory}/.agents/skills/opencode-skill/SKILL.md`,
          scope: "project",
          enabled: true,
        },
      ];
    },
    async getHandoffContext(threadId) {
      return {
        threadId,
        sessionId: "ses_handoff",
        cwd: "/tmp/handoff-project",
        model: "openai/gpt-5.5",
        agent: "build",
        title: "Handoff thread",
      };
    },
    async selectTuiSession(sessionId) {
      assert.equal(sessionId, "ses_handoff");
      return true;
    },
    listThreads: async () => ({ data: [] }),
    ownsThread() {
      return false;
    },
    handleRequest() {},
    ...overrides,
  };
}

async function requestDesktopHandoff(request, options = {}) {
  const responses = [];
  const handled = handleDesktopRequest(JSON.stringify(request), (message) => {
    responses.push(JSON.parse(message));
  }, {
    platform: "darwin",
    executor: async () => ({ stdout: "", stderr: "" }),
    ...options,
  });
  assert.equal(handled, true, "desktop handler should handle continueOpenCode");
  await waitOneTick();
  return responses[0] ?? null;
}

function createTestRouter(overrides = {}) {
  let payload = null;
  let resolveResponse;
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse(message) {
      payload = JSON.parse(message);
      resolveResponse?.();
    },
    sendRuntimeMessage: () => {},
    logPrefix: "[test]",
    ...overrides,
  });
  return {
    router,
    async request(request, { timeoutMs = 5000 } = {}) {
      payload = null;
      let responded = false;
      const responsePromise = new Promise((resolve) => {
        resolveResponse = () => {
          responded = true;
          resolve();
        };
      });
      const timeoutPromise = new Promise((resolve) => {
        setTimeout(resolve, timeoutMs);
      });
      router.handleApplicationMessage(JSON.stringify(request));
      await Promise.race([responsePromise, timeoutPromise]);
      assert.ok(
        responded && payload,
        `router did not respond within ${timeoutMs}ms for ${request.method ?? "unknown method"}`,
      );
      return payload;
    },
  };
}

test("runtime catalog excludes opencode when flag is off", async () => {
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    sendRuntimeMessage: () => {},
    logPrefix: "[test]",
  });

  process.env.REMODEX_DISABLE_OPENCODE = "1";

  router.handleApplicationMessage(
    JSON.stringify({ id: 1, method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === 1)?.result;
  assert.ok(catalog, "runtime/catalog should produce a result");
  assert.ok(Array.isArray(catalog.runtimes), "runtimes should be an array");
  assert.ok(catalog.runtimes.some((r) => r.id === "codex"), "codex should be present");
  assert.ok(
    !catalog.runtimes.some((r) => r.id === "opencode"),
    "opencode should not be in catalog when flag is off",
  );

  delete process.env.REMODEX_DISABLE_OPENCODE;
});

test("runtime catalog includes opencode by default", async () => {
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    sendRuntimeMessage: () => {},
    providers: [],
    logPrefix: "[test]",
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  const previousEnable = process.env.REMODEX_ENABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_ENABLE_OPENCODE;

  router.handleApplicationMessage(
    JSON.stringify({ id: 3, method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === 3)?.result;
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.ok(opencodeRuntime, "opencode should be advertised by default");
  assert.equal(opencodeRuntime.enabled, false);
  assert.equal(opencodeRuntime.reasonCode, "opencode_not_enabled");

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
  if (previousEnable === undefined) {
    delete process.env.REMODEX_ENABLE_OPENCODE;
  } else {
    process.env.REMODEX_ENABLE_OPENCODE = previousEnable;
  }
});

test("runtime catalog exposes showsBetaLabel on opencode runtime", async () => {
  const responses = [];
  const mockOpenCodeProvider = {
    id: "opencode",
    listAgents: async () => [{ id: "build", label: "Build" }],
  };
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    sendRuntimeMessage: () => {},
    providers: [mockOpenCodeProvider],
    logPrefix: "[test]",
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;

  router.handleApplicationMessage(
    JSON.stringify({ id: 2, method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === 2)?.result;
  const codexRuntime = catalog.runtimes.find((runtime) => runtime.id === "codex");
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.equal(codexRuntime.showsBetaLabel, false);
  assert.equal(opencodeRuntime.showsBetaLabel, true);

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
});

test("runtime catalog advertises OpenCode supportsDesktopHandoff after PR8 sign-off", async () => {
  const responses = [];
  const mockOpenCodeProvider = {
    id: "opencode",
    listAgents: async () => [{ id: "build", label: "Build" }],
  };
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    sendRuntimeMessage: () => {},
    providers: [mockOpenCodeProvider],
    logPrefix: "[test]",
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  const previousHandoff = process.env.REMODEX_OPENCODE_HANDOFF;
  delete process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_OPENCODE_HANDOFF;

  router.handleApplicationMessage(
    JSON.stringify({ id: "catalog-handoff-cap", method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === "catalog-handoff-cap")?.result;
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.equal(opencodeRuntime.capabilities.supportsDesktopHandoff, true);

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
  if (previousHandoff === undefined) {
    delete process.env.REMODEX_OPENCODE_HANDOFF;
  } else {
    process.env.REMODEX_OPENCODE_HANDOFF = previousHandoff;
  }
});

test("provider is not created when OpenCode is explicitly disabled", () => {
  process.env.REMODEX_DISABLE_OPENCODE = "1";
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: () => {},
    sendRuntimeMessage: () => {},
    logPrefix: "[test]",
  });
  delete process.env.REMODEX_DISABLE_OPENCODE;

  assert.equal(router.providers.length, 0, "no providers should be created when OpenCode is disabled");
});

test("provider is created by default", async (t) => {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  const previousEnable = process.env.REMODEX_ENABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_ENABLE_OPENCODE;

  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: () => {},
    sendRuntimeMessage: () => {},
    logPrefix: "[test]",
  });

  t.after(async () => {
    const provider = router.providers.find((entry) => entry.id === "opencode");
    if (provider && typeof provider.shutdown === "function") {
      await provider.shutdown();
    }
  });

  assert.equal(router.providers.length, 1, "OpenCode provider should register by default");
  assert.equal(router.providers[0].id, "opencode");

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
  if (previousEnable === undefined) {
    delete process.env.REMODEX_ENABLE_OPENCODE;
  } else {
    process.env.REMODEX_ENABLE_OPENCODE = previousEnable;
  }
});

test("command/list returns empty when OpenCode provider is absent", async () => {
  const { request } = createTestRouter({ providers: [] });
  const response = await request({
    id: "cmd-off",
    method: "command/list",
    params: { directory: "/tmp/repo" },
  });

  assert.equal(response.id, "cmd-off");
  assert.deepEqual(response.result.commands, []);
});

test("command/list returns OpenCode slash commands when provider is registered", async () => {
  const { request } = createTestRouter({ providers: [mockOpenCodeProvider()] });
  const response = await request({
    id: "cmd-on",
    method: "command/list",
    params: { directory: "/tmp/repo" },
  });

  assert.equal(response.id, "cmd-on");
  assert.equal(response.result.commands.length, 1);
  assert.equal(response.result.commands[0].token, "/build");
});

test("command/list returns >= 15 static builtins when OpenCode server cannot start", async () => {
  const provider = createOpenCodeProvider({
    sendApplicationMessage: () => {},
    env: { REMODEX_ENABLE_OPENCODE: "1" },
    serverFactory: () => ({
      get baseUrl() {
        return "";
      },
      get isRunning() {
        return false;
      },
      start: async () => {
        throw new Error("OpenCode server unavailable in test");
      },
      stop: async () => {},
    }),
  });
  const { request } = createTestRouter({ providers: [provider] });
  const response = await request({
    id: "cmd-degraded-builtins",
    method: "command/list",
    params: { directory: "/tmp/repo" },
  });

  assert.equal(response.id, "cmd-degraded-builtins");
  assert.equal(response.result.commands.length, buildStaticSlashCommands().length);
  const tokens = response.result.commands.map((command) => command.token);
  assert.ok(tokens.includes("/undo"), "includes /undo builtin");
  assert.ok(tokens.includes("/compact"), "includes /compact builtin");
  assert.deepEqual(tokens.slice(0, buildStaticSlashCommands().length), buildStaticSlashCommands().map((c) => c.token));
});

test("command/execute returns opencode_unavailable when OpenCode provider is absent", async () => {
  const { request } = createTestRouter({ providers: [] });
  const response = await request({
    id: "cmd-exec-off",
    method: "command/execute",
    params: {
      threadId: "opencode-thread-test",
      command: "/skills",
    },
  });

  assert.equal(response.id, "cmd-exec-off");
  assert.deepEqual(response.result, { ok: false, errorCode: "opencode_unavailable" });
});

test("command/execute returns opencode_unavailable when OpenCode is disabled", async () => {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  process.env.REMODEX_DISABLE_OPENCODE = "1";
  try {
    const { request } = createTestRouter({});
    const response = await request({
      id: "cmd-exec-disable",
      method: "command/execute",
      params: {
        threadId: "opencode-thread-test",
        command: "/skills",
      },
    });

    assert.equal(response.id, "cmd-exec-disable");
    assert.deepEqual(response.result, { ok: false, errorCode: "opencode_unavailable" });
  } finally {
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
});

// opencode-regression.test.js for DISABLE=1 command paths parity
test("command/list under default DISABLE=1 (via test-env) has no opencode provider (codex command paths unaffected)", async () => {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  process.env.REMODEX_DISABLE_OPENCODE = "1";
  try {
    // no providers passed => resolveProviders sees REMODEX_DISABLE_OPENCODE=1, returns []
    const { request } = createTestRouter({});
    const response = await request({
      id: "cmd-disable-parity",
      method: "command/list",
      params: { directory: "/tmp/repo" },
    });

    assert.equal(response.id, "cmd-disable-parity");
    assert.deepEqual(response.result.commands, []);
  } finally {
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
});

test("skills/list omits OpenCode skills when provider is absent", async () => {
  const { request } = createTestRouter({
    providers: [],
    sendCodexRequest: async () => ({
      data: [
        {
          cwd: "/tmp/repo",
          skills: [
            {
              name: "codex-skill",
              description: "From Codex",
              path: "/tmp/repo/.agents/skills/codex-skill/SKILL.md",
              scope: "project",
              enabled: true,
            },
          ],
        },
      ],
    }),
  });
  const response = await request({
    id: "skills-off",
    method: "skills/list",
    params: { cwds: ["/tmp/repo"] },
  });

  const bucket = response.result.data.find((entry) => entry.cwd === "/tmp/repo");
  assert.deepEqual(bucket.skills.map((skill) => skill.name), ["codex-skill"]);
});

test("skills/list merges OpenCode skills when provider is registered", async () => {
  const { request } = createTestRouter({
    providers: [mockOpenCodeProvider()],
    sendCodexRequest: async () => ({
      data: [
        {
          cwd: "/tmp/repo",
          skills: [
            {
              name: "codex-skill",
              description: "From Codex",
              path: "/tmp/repo/.agents/skills/codex-skill/SKILL.md",
              scope: "project",
              enabled: true,
            },
          ],
        },
      ],
    }),
  });
  const response = await request({
    id: "skills-on",
    method: "skills/list",
    params: { cwds: ["/tmp/repo"] },
  });

  const bucket = response.result.data.find((entry) => entry.cwd === "/tmp/repo");
  assert.deepEqual(bucket.skills.map((skill) => skill.name).sort(), [
    "codex-skill",
    "opencode-skill",
  ]);
});

test("desktop/continueOpenCode returns opencode_handoff_disabled when env gate is off", async () => {
  const ownershipStore = createThreadOwnershipStore({
    storagePath: "/tmp/opencode-handoff-disabled-ownership.json",
    fsImpl: {
      readFileSync() {
        throw new Error("ENOENT");
      },
      writeFileSync() {},
      renameSync() {},
      mkdirSync() {},
    },
  });
  ownershipStore.setOwnership("opencode-thread-handoff", "opencode");

  const previousHandoff = process.env.REMODEX_OPENCODE_HANDOFF;
  process.env.REMODEX_OPENCODE_HANDOFF = "0";

  const response = await requestDesktopHandoff(
    {
      id: "handoff-off",
      method: "desktop/continueOpenCode",
      params: { threadId: "opencode-thread-handoff" },
    },
    {
      env: { REMODEX_OPENCODE_HANDOFF: "0" },
      ownershipStore,
      opencodeProvider: mockOpenCodeProvider(),
    },
  );

  assert.equal(response.id, "handoff-off");
  assert.equal(response.error.data.errorCode, "opencode_handoff_disabled");

  if (previousHandoff === undefined) {
    delete process.env.REMODEX_OPENCODE_HANDOFF;
  } else {
    process.env.REMODEX_OPENCODE_HANDOFF = previousHandoff;
  }
});

test("desktop/continueOpenCode succeeds with production-default handoff when env unset", async () => {
  const ownershipStore = createThreadOwnershipStore({
    storagePath: "/tmp/opencode-handoff-default-ownership.json",
    fsImpl: {
      readFileSync() {
        throw new Error("ENOENT");
      },
      writeFileSync() {},
      renameSync() {},
      mkdirSync() {},
    },
  });
  ownershipStore.setOwnership("opencode-thread-handoff", "opencode");

  const response = await requestDesktopHandoff(
    {
      id: "handoff-default",
      method: "desktop/continueOpenCode",
      params: { threadId: "opencode-thread-handoff" },
    },
    {
      env: {},
      ownershipStore,
      opencodeProvider: mockOpenCodeProvider(),
    },
  );

  assert.equal(response.id, "handoff-default");
  assert.equal(response.result.success, true);
  assert.equal(response.result.sessionId, "ses_handoff");
});

test("desktop/continueOpenCode succeeds when handoff env gate is on", async () => {
  const ownershipStore = createThreadOwnershipStore({
    storagePath: "/tmp/opencode-handoff-enabled-ownership.json",
    fsImpl: {
      readFileSync() {
        throw new Error("ENOENT");
      },
      writeFileSync() {},
      renameSync() {},
      mkdirSync() {},
    },
  });
  ownershipStore.setOwnership("opencode-thread-handoff", "opencode");

  const previousHandoff = process.env.REMODEX_OPENCODE_HANDOFF;
  process.env.REMODEX_OPENCODE_HANDOFF = "1";

  const response = await requestDesktopHandoff(
    {
      id: "handoff-on",
      method: "desktop/continueOpenCode",
      params: { threadId: "opencode-thread-handoff" },
    },
    {
      ownershipStore,
      opencodeProvider: mockOpenCodeProvider(),
    },
  );

  assert.equal(response.id, "handoff-on");
  assert.equal(response.result.success, true);
  assert.equal(response.result.sessionId, "ses_handoff");
  assert.equal(response.result.handoffMode, "tui");
  assert.equal(response.result.sessionSelected, true);

  if (previousHandoff === undefined) {
    delete process.env.REMODEX_OPENCODE_HANDOFF;
  } else {
    process.env.REMODEX_OPENCODE_HANDOFF = previousHandoff;
  }
});

test("DISABLE_OPENCODE=1 thread/list does not hot-path discover OpenCode projects", async () => {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  const previousDiscover = process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS;
  process.env.REMODEX_DISABLE_OPENCODE = "1";
  process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS = "1";
  resetOpenCodeProjectDiscoverState();

  try {
    let discoverCalls = 0;
    const { request } = createTestRouter({
      providers: [
        mockOpenCodeProvider({
          async discoverProjects() {
            discoverCalls += 1;
            return [{ id: "proj-1", path: "/tmp/demo", name: "Demo" }];
          },
        }),
      ],
      sendCodexRequest: async () => ({
        data: [{ id: "codex-thread", cwd: "/tmp/codex", provider: "codex" }],
      }),
      projectRegistry: { rememberProjectsFromThreads() {} },
    });

    const response = await request({
      id: "thread-list-disable-discover",
      method: "thread/list",
      params: {
        discoverOpenCodeSessions: true,
        discoverOpenCodeProjects: true,
      },
    });
    await waitOneTick();

    assert.equal(response.id, "thread-list-disable-discover");
    assert.equal(response.result.data.length, 1);
    assert.equal(discoverCalls, 0);
  } finally {
    resetOpenCodeProjectDiscoverState();
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
    if (previousDiscover === undefined) {
      delete process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS;
    } else {
      process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS = previousDiscover;
    }
  }
});

test("thread/list with REMODEX_DISABLE_OPENCODE=1 returns Codex-only threads", async () => {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  process.env.REMODEX_DISABLE_OPENCODE = "1";
  try {
    const { request } = createTestRouter({
      sendCodexRequest: async () => ({
        data: [
          {
            id: "codex-thread-only",
            cwd: "/Users/me/work/codex",
            provider: "codex",
          },
        ],
      }),
    });
    const response = await request({
      id: "thread-list-disable",
      method: "thread/list",
      params: {
        discoverOpenCodeSessions: true,
        discoverOpenCodeProjects: true,
      },
    });

    assert.equal(response.id, "thread-list-disable");
    assert.equal(response.result.data.length, 1);
    assert.equal(response.result.data[0].id, "codex-thread-only");
  } finally {
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
});

// MSG-3: DISABLE=1 regression for router/notify paths (late guard, dedup, buffer not affect codex passthrough)
test("DISABLE_OPENCODE=1 keeps codex router catalog codex-only (no OC provider leakage)", async () => {
  const previous = process.env.REMODEX_DISABLE_OPENCODE;
  process.env.REMODEX_DISABLE_OPENCODE = "1";
  try {
    const responses = [];
    const runtimeMessages = [];
    const router = createRuntimeProviderRouter({
      sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
      sendCodexRequest: async () => ({ items: [] }),
      sendRuntimeMessage: (msg) => runtimeMessages.push(JSON.parse(msg)),
      projectRegistry: { getOrCreateForCwd() { return { id: "p" }; } },
      ownershipStore: { ownsThread() { return false; }, setOwnership() {}, getOwner() { return null; } },
    });

    router.handleApplicationMessage(
      JSON.stringify({ id: "catalog-disabled-msg3", method: "runtime/catalog", params: {} }),
    );
    await waitOneTick();

    const catalog = responses.find((response) => response.id === "catalog-disabled-msg3")?.result;
    assert.ok(catalog);
    const codexRuntime = catalog.runtimes.find((runtime) => runtime.id === "codex");
    const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
    assert.ok(codexRuntime);
    assert.equal(opencodeRuntime, undefined);

    const codexNotify = {
      method: "turn/completed",
      params: { threadId: "c1", turnId: "t1", status: "completed" },
    };
    router.handleApplicationMessage(JSON.stringify(codexNotify));
    await waitOneTick();

    const lateSuppressed = runtimeMessages.filter(
      (message) => message.event === "bridge_late_delta_suppressed",
    );
    assert.equal(lateSuppressed.length, 0);
  } finally {
    if (previous === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previous;
    }
  }
});
