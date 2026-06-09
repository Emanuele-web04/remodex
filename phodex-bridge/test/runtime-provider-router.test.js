// FILE: runtime-provider-router.test.js
// Purpose: Verifies bridge routing semantics for provider-aware model/thread RPCs.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/runtime-provider-router

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createProjectRegistry } = require("../src/project-registry");
const {
  CODEX_THREAD_LIST_BUDGET_MS,
  DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS,
  DEFAULT_OPENCODE_THREAD_LIST_BUDGET_MS,
  MODEL_LIST_PROVIDER_BUDGET_MS,
  buildCatalogOpenCodeRuntime,
  capOpenCodeModelsForMobileList,
  codexThreadListBudgetMs,
  computeCatalogFingerprint,
  computeCatalogRevision,
  createRuntimeProviderRouter,
  isOpenCodeDiscoverProjectsEnabled,
  listProviderThreadsForThreadList,
  mergeModelListResult,
  mergeSkillsAcrossProviders,
  mergeThreadListResult,
  opencodeModelListBudgetMs,
  opencodeThreadListBudgetMs,
  providerForRequest,
  providerModelsForModelList,
  readDiscoverProjectTtlMs,
  resetCatalogPushState,
  resetOpenCodeProjectDiscoverState,
  resetThreadListInFlightState,
  THREAD_LIST_BUDGET_CEILING_MS,
  resolvePrimaryProvider,
  shouldWarmProviderInventory,
  stripRuntimeProviderFieldsForCodex,
} = require("../src/runtime-provider-router");

test.afterEach(() => {
  resetThreadListInFlightState();
});

function makeProvider(ownedThreadIds = []) {
  const owned = new Set(ownedThreadIds);
  return {
    id: "opencode",
    ownsThread(threadId) {
      return owned.has(threadId);
    },
  };
}

// Small helper (per review suggestion on Issue 9 capture hygiene): centralizes save/restore
// for muting console during direct providerForRequest calls (used by the explicit-routes test).
// Other tests that need the emitted logs (e.g. audit/decision) use their own collecting pattern.
function withMutedConsole(fn) {
  const originalLog = console.log;
  console.log = () => {};
  try {
    fn();
  } finally {
    console.log = originalLog;
  }
}

test("providerModelsForModelList adds placeholder only when OpenCode is disabled and empty", () => {
  const realModel = {
    id: "anthropic/claude-sonnet-4",
    model: "anthropic/claude-sonnet-4",
    modelProvider: "opencode",
    upstreamProviderId: "anthropic",
  };

  const enabledCatalog = { id: "opencode", enabled: true };
  const disabledCatalog = { id: "opencode", enabled: false };

  assert.deepEqual(
    providerModelsForModelList([realModel], enabledCatalog).map((model) => model.id),
    ["anthropic/claude-sonnet-4"],
  );
  assert.deepEqual(
    providerModelsForModelList([], disabledCatalog).map((model) => model.id),
    ["opencode/gpt-5.5"],
  );
  assert.deepEqual(providerModelsForModelList([realModel], disabledCatalog).map((model) => model.id), [
    "anthropic/claude-sonnet-4",
  ]);
});

test("capOpenCodeModelsForMobileList limits total and per-upstream models", () => {
  const models = [];
  for (let index = 0; index < 40; index += 1) {
    models.push({
      id: `openai/gpt-${index}`,
      model: `openai/gpt-${index}`,
      modelProvider: "opencode",
      upstreamProviderId: "openai",
    });
  }
  for (let index = 0; index < 40; index += 1) {
    models.push({
      id: `anthropic/claude-${index}`,
      model: `anthropic/claude-${index}`,
      modelProvider: "opencode",
      upstreamProviderId: "anthropic",
    });
  }

  const capped = capOpenCodeModelsForMobileList(models, {
    REMODEX_MODEL_LIST_OPENCODE_MAX: "50",
    REMODEX_MODEL_LIST_OPENCODE_PER_UPSTREAM: "10",
  });

  assert.ok(capped.length <= 50);
  const openaiCount = capped.filter((model) => model.upstreamProviderId === "openai").length;
  const anthropicCount = capped.filter((model) => model.upstreamProviderId === "anthropic").length;
  assert.ok(openaiCount <= 10);
  assert.ok(anthropicCount <= 10);
  assert.ok(capped.every((model) => model.contextWindow === undefined));
});

test("capOpenCodeModelsForMobileList preserves logoProviderId", () => {
  const models = [
    {
      id: "opencode/free",
      model: "opencode/free",
      modelProvider: "opencode",
      upstreamProviderId: "opencode",
      upstreamProviderDisplayName: "OpenCode Zen",
      logoProviderId: "opencode-zen",
      contextWindow: { input: 128000 },
    },
  ];

  const capped = capOpenCodeModelsForMobileList(models);
  assert.equal(capped.length, 1);
  assert.equal(capped[0].logoProviderId, "opencode-zen");
  assert.equal(capped[0].contextWindow, undefined);
});

test("mergeModelListResult annotates Codex models and appends provider models", () => {
  const result = mergeModelListResult(
    { items: [{ id: "gpt-5.5", model: "gpt-5.5", provider: "openai" }] },
    [{ id: "opencode/gpt-5.5", modelProvider: "opencode" }],
  );

  assert.deepEqual(
    result.items.map((model) => model.modelProvider),
    ["codex", "opencode"],
  );
  assert.equal(result.items[0].provider, "codex");
});

test("mergeModelListResult attaches opencode meta when provided", () => {
  const result = mergeModelListResult(
    { items: [] },
    [],
    {
      opencode: {
        reasonCode: "no_connected_providers",
        connectedProviderIds: [],
        fetchedAt: "2026-06-03T12:00:00.000Z",
        stale: false,
        modelCountBeforeCap: 0,
        modelCountAfterCap: 0,
      },
    },
  );
  assert.equal(result.opencode.reasonCode, "no_connected_providers");
});

test("mergeThreadListResult omits discovered stub when owned thread shares sessionId", () => {
  const result = mergeThreadListResult(
    { data: [] },
    [
      {
        id: "opencode-session-ses_shared",
        title: "Mac CLI session",
        modelProvider: "opencode",
        metadata: {
          provider: "opencode",
          discoveredExternally: true,
          sessionId: "ses_shared",
        },
      },
      {
        id: "opencode-thread-owned",
        title: "Phone-owned session",
        modelProvider: "opencode",
        metadata: {
          provider: "opencode",
          sessionId: "ses_shared",
        },
      },
    ],
  );

  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].id, "opencode-thread-owned");
});

test("mergeThreadListResult passes through provider meta", () => {
  const result = mergeThreadListResult(
    { data: [{ id: "thread-1", title: "Codex", modelProvider: "codex" }] },
    [],
    {
      meta: {
        materializationBlocked: 3,
        sdkValidationsCap: 20,
      },
    },
  );

  assert.equal(result.meta.materializationBlocked, 3);
  assert.equal(result.meta.sdkValidationsCap, 20);
});

test("mergeThreadListResult keeps owned thread when duplicate sessionId stubs collide", () => {
  const result = mergeThreadListResult(
    { data: [] },
    [
      {
        id: "opencode-thread-owned",
        title: "Owned copy",
        modelProvider: "opencode",
        updatedAt: "2026-06-08T10:00:00.000Z",
        metadata: {
          provider: "opencode",
          sessionId: "ses_dup",
        },
      },
      {
        id: "opencode-thread-stale",
        title: "Stale duplicate",
        modelProvider: "opencode",
        updatedAt: "2026-06-08T09:00:00.000Z",
        metadata: {
          provider: "opencode",
          sessionId: "ses_dup",
        },
      },
    ],
  );

  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].id, "opencode-thread-owned");
});

test("mergeThreadListResult deduplicates provider-owned thread copies", () => {
  const result = mergeThreadListResult(
    {
      data: [
        {
          id: "thread-1",
          title: "Codex copy",
          modelProvider: "codex",
          updatedAt: "2026-05-20T10:00:00Z",
        },
      ],
    },
    [
      {
        id: "thread-1",
        title: "OpenCode copy",
        modelProvider: "opencode",
        updatedAt: "2026-05-21T10:00:00Z",
      },
    ],
  );

  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].title, "OpenCode copy");
  assert.equal(result.data[0].modelProvider, "opencode");
});

test("providerForRequest routes explicit OpenCode and honors explicit Codex fallback", () => {
  const provider = makeProvider(["thread-1"]);

  // Use helper (per review on Issue 9) to mute console for the 3 direct calls (prevents
  // pollution from providerForRequest decision/owns_call side-effects added for RP-MSG-1).
  // Sibling tests that assert on emitted logs use their own collecting pattern instead.
  withMutedConsole(() => {
    assert.equal(
      providerForRequest({ method: "turn/start", params: { threadId: "thread-1" } }, [provider]),
      provider,
    );
    assert.equal(
      providerForRequest(
        {
          method: "turn/start",
          params: {
            threadId: "thread-1",
            modelProvider: "codex",
          },
        },
        [provider],
      ),
      null,
    );
    assert.equal(
      providerForRequest(
        {
          method: "turn/start",
          params: {
            threadId: "codex-thread",
            collaborationMode: {
              settings: {
                model_provider: "open-code",
              },
            },
          },
        },
        [provider],
      ),
      provider,
    );
  });
});

test("stripRuntimeProviderFieldsForCodex removes top-level and nested provider selectors", () => {
  const stripped = JSON.parse(
    stripRuntimeProviderFieldsForCodex(
      JSON.stringify({
        id: 1,
        method: "turn/start",
        params: {
          threadId: "thread-1",
          model: "gpt-5.5",
          modelProvider: "codex",
          collaborationMode: {
            settings: {
              model: "gpt-5.5",
              model_provider: "codex",
              reasoning_effort: "medium",
            },
          },
        },
      }),
    ),
  );

  assert.equal(stripped.params.modelProvider, undefined);
  assert.equal(stripped.params.collaborationMode.settings.model_provider, undefined);
  assert.equal(stripped.params.collaborationMode.settings.reasoning_effort, "medium");
});

test("thread/list remembers Codex and provider project folders", async () => {
  const remembered = [];
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({
      data: [
        {
          id: "codex-thread",
          cwd: "/Users/me/work/codex-app",
          provider: "codex",
        },
      ],
    }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    projectRegistry: {
      rememberProjectsFromThreads(threads, metadata) {
        remembered.push({ threads, metadata });
      },
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listThreads() {
          return {
            data: [
              {
                id: "ses_test",
                cwd: "/Users/me/work/opencode-app",
                modelProvider: "opencode",
              },
            ],
          };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  assert.equal(
    router.handleApplicationMessage(
      JSON.stringify({
        id: "threads-1",
        method: "thread/list",
        params: {},
      }),
    ),
    true,
  );
  await responsePromise;

  assert.equal(responsePayload.id, "threads-1");
  assert.deepEqual(
    remembered.map((call) => call.threads.map((thread) => thread.cwd)),
    [["/Users/me/work/codex-app"], ["/Users/me/work/opencode-app"]],
  );
  assert.deepEqual(
    remembered.map((call) => call.metadata.source),
    ["codex-thread-list", "provider-thread-list"],
  );
});

test("thread/list merges discovered external OpenCode sessions from provider", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ data: [] }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listThreads() {
          return {
            data: [
              {
                id: "opencode-session-ses_router_external",
                title: "Mac session",
                cwd: "/Users/me/work/router-external",
                modelProvider: "opencode",
                provider: "opencode",
                metadata: {
                  discoveredExternally: true,
                  sessionId: "ses_router_external",
                },
              },
            ],
          };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "threads-discovered",
      method: "thread/list",
      params: {},
    }),
  );
  await responsePromise;

  assert.equal(responsePayload.id, "threads-discovered");
  const row = responsePayload.result.data.find(
    (thread) => thread.id === "opencode-session-ses_router_external",
  );
  assert.ok(row);
  assert.equal(row.cwd, "/Users/me/work/router-external");
  assert.equal(row.modelProvider, "opencode");
  assert.equal(row.metadata.discoveredExternally, true);
});

test("model/list returns Codex models when OpenCode listModels never resolves", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const startedAt = Date.now();
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ items: [{ id: "gpt-5.5", model: "gpt-5.5" }] }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        listModels() {
          return new Promise(() => {});
        },
        async listAgents() {
          return [];
        },
        async listThreads() {
          return { data: [] };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "models-opencode-hang",
      method: "model/list",
      params: {},
    }),
  );
  await responsePromise;

  const elapsedMs = Date.now() - startedAt;
  const opencodeBudgetMs = opencodeModelListBudgetMs();
  assert.ok(
    elapsedMs < opencodeBudgetMs + 1_500,
    `expected model/list within OpenCode budget, took ${elapsedMs}ms`,
  );
  const providers = responsePayload.result.items.map((model) => model.modelProvider);
  assert.ok(providers.includes("codex"));
  assert.equal(providers.filter((provider) => provider === "opencode").length, 0);
});

test("opencodeModelListBudgetMs defaults to serve-start budget and honors env override", () => {
  assert.equal(opencodeModelListBudgetMs({}), DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS);
  assert.equal(
    opencodeModelListBudgetMs({ REMODEX_MODEL_LIST_OPENCODE_BUDGET_MS: "12000" }),
    12_000,
  );
});

test("model/list mobile payload stays within OpenCode cap", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const opencodeModels = [];
  for (let index = 0; index < 300; index += 1) {
    opencodeModels.push({
      id: `openai/gpt-${index}`,
      model: `openai/gpt-${index}`,
      modelProvider: "opencode",
      upstreamProviderId: "openai",
    });
  }

  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ items: [{ id: "gpt-5.5", model: "gpt-5.5" }] }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return opencodeModels;
        },
        async listAgents() {
          return [];
        },
        async listThreads() {
          return { data: [] };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "models-size-cap",
      method: "model/list",
      params: {},
    }),
  );
  await responsePromise;

  const opencodeCount = responsePayload.result.items.filter(
    (model) => model.modelProvider === "opencode",
  ).length;
  assert.ok(opencodeCount <= 120);
  assert.ok(JSON.stringify(responsePayload.result).length < 512_000);
});

test("model/list still returns OpenCode models when Codex model/list fails", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => {
      throw new Error("codex offline");
    },
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [
            {
              id: "openai/gpt-5.5",
              model: "openai/gpt-5.5",
              modelProvider: "opencode",
              upstreamProviderId: "openai",
            },
          ];
        },
        async listAgents() {
          return [];
        },
        async listThreads() {
          return { data: [] };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "models-codex-fail",
      method: "model/list",
      params: {},
    }),
  );
  await responsePromise;

  const ids = responsePayload.result.items.map((model) => model.id);
  assert.deepEqual(ids, ["openai/gpt-5.5"]);
});

test("model/list omits placeholder when OpenCode is enabled with real models", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ items: [{ id: "gpt-5.5", model: "gpt-5.5" }] }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [
            {
              id: "anthropic/claude-sonnet-4",
              model: "anthropic/claude-sonnet-4",
              modelProvider: "opencode",
              upstreamProviderId: "anthropic",
              upstreamProviderDisplayName: "Anthropic",
            },
            {
              id: "openai/gpt-5.5",
              model: "openai/gpt-5.5",
              modelProvider: "opencode",
              upstreamProviderId: "openai",
              upstreamProviderDisplayName: "OpenAI",
            },
          ];
        },
        async listAgents() {
          return [{ id: "build", label: "Build" }];
        },
        async listThreads() {
          return { data: [] };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "models-1",
      method: "model/list",
      params: {},
    }),
  );
  await responsePromise;

  const ids = responsePayload.result.items.map((model) => model.id);
  assert.ok(ids.includes("anthropic/claude-sonnet-4"));
  assert.ok(ids.includes("openai/gpt-5.5"));
  assert.equal(ids.filter((id) => id === "opencode/gpt-5.5").length, 0);

  const { OPENCODE_CAPABILITIES } = require("../src/provider-capabilities");
  const opencodeModel = responsePayload.result.items.find(
    (model) => model.modelProvider === "opencode",
  );
  assert.ok(opencodeModel, "expected at least one OpenCode model in model/list");
  assert.deepEqual(opencodeModel.capabilities, OPENCODE_CAPABILITIES);
});

test("command/list returns commands from opencode provider", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listCommands(directory) {
          return [
            { token: "/build", title: "Build", description: "Build the project" },
            { token: "/test", title: "Test", description: "Run tests" },
          ];
        },
        listThreads: async () => ({ data: [] }),
        ownsThread() {
          return false;
        },
        handleRequest() {},
      },
    ],
  });

  assert.equal(
    router.handleApplicationMessage(
      JSON.stringify({
        id: "cmd-1",
        method: "command/list",
        params: { directory: "/tmp/test" },
      }),
    ),
    true,
  );
  await responsePromise;

  assert.equal(responsePayload.id, "cmd-1");
  assert.ok(Array.isArray(responsePayload.result.commands));
  assert.equal(responsePayload.result.commands.length, 2);
  assert.equal(responsePayload.result.commands[0].token, "/build");
  assert.equal(responsePayload.result.commands[1].token, "/test");
});

test("resolvePrimaryProvider prefers codex when both runtimes contribute", () => {
  assert.equal(resolvePrimaryProvider(["opencode", "codex"]), "codex");
  assert.equal(resolvePrimaryProvider(["opencode"]), "opencode");
  assert.equal(resolvePrimaryProvider(["custom-runtime"]), "custom-runtime");
});

test("mergeSkillsAcrossProviders dedupes case-folded names and attaches providers[]", () => {
  const merged = mergeSkillsAcrossProviders([
    {
      name: "Review",
      description: "Codex copy",
      path: "/tmp/repo/.agents/skills/review/SKILL.md",
      scope: "project",
      enabled: true,
      provider: "codex",
    },
    {
      name: "review",
      description: "OpenCode copy",
      path: "/tmp/repo/.opencode/skills/review/SKILL.md",
      scope: "project",
      enabled: true,
      provider: "opencode",
    },
    {
      name: "deploy",
      description: "OpenCode only",
      path: "/tmp/repo/.opencode/skills/deploy/SKILL.md",
      scope: "project",
      enabled: true,
      provider: "opencode",
    },
  ]);

  assert.equal(merged.length, 2);
  const review = merged.find((skill) => skill.name === "Review");
  assert.ok(review);
  assert.equal(review.provider, "codex");
  assert.deepEqual(review.providers, ["codex", "opencode"]);
  assert.equal(review.description, "Codex copy");
  const deploy = merged.find((skill) => skill.name === "deploy");
  assert.ok(deploy);
  assert.equal(deploy.provider, "opencode");
  assert.deepEqual(deploy.providers, ["opencode"]);
});

test("mergeSkillsAcrossProviders prefers enabled skill metadata", () => {
  const merged = mergeSkillsAcrossProviders([
    {
      name: "lint",
      description: "Disabled Codex copy",
      enabled: false,
      provider: "codex",
    },
    {
      name: "lint",
      description: "Enabled OpenCode copy",
      enabled: true,
      provider: "opencode",
    },
  ]);

  assert.equal(merged.length, 1);
  assert.equal(merged[0].description, "Enabled OpenCode copy");
  assert.equal(merged[0].provider, "codex");
  assert.deepEqual(merged[0].providers, ["codex", "opencode"]);
});

test("skills/list merges overlapping skills into unified providers[] in data[] shape", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({
      data: [
        {
          cwd: "/tmp/repo",
          skills: [
            {
              name: "review",
              description: "From Codex",
              path: "/tmp/repo/.agents/skills/review/SKILL.md",
              scope: "project",
              enabled: true,
              provider: "codex",
            },
          ],
        },
      ],
    }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listSkills(directory) {
          return [
            {
              name: "review",
              description: "From OpenCode",
              path: `${directory}/.opencode/skills/review/SKILL.md`,
              scope: "project",
              enabled: true,
              provider: "opencode",
            },
            {
              name: "opencode-only",
              description: "OpenCode exclusive",
              path: `${directory}/.opencode/skills/opencode-only/SKILL.md`,
              scope: "project",
              enabled: true,
              provider: "opencode",
            },
          ];
        },
        listThreads: async () => ({ data: [] }),
        ownsThread() {
          return false;
        },
        handleRequest() {},
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "skills-overlap-data",
      method: "skills/list",
      params: { cwds: ["/tmp/repo"] },
    }),
  );
  await responsePromise;

  const bucket = responsePayload.result.data.find((entry) => entry.cwd === "/tmp/repo");
  assert.ok(bucket);
  assert.equal(bucket.skills.length, 2);
  const review = bucket.skills.find((skill) => skill.name === "review");
  assert.ok(review);
  assert.equal(review.provider, "codex");
  assert.deepEqual(review.providers, ["codex", "opencode"]);
  const opencodeOnly = bucket.skills.find((skill) => skill.name === "opencode-only");
  assert.ok(opencodeOnly);
  assert.deepEqual(opencodeOnly.providers, ["opencode"]);
});

test("skills/list merges overlapping skills into unified providers[] in flat skills[] shape", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({
      skills: [
        {
          name: "review",
          description: "From Codex",
          path: "/tmp/repo/.agents/skills/review/SKILL.md",
          scope: "project",
          enabled: true,
          provider: "codex",
        },
      ],
    }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listSkills() {
          return [
            {
              name: "review",
              description: "From OpenCode",
              path: "/tmp/repo/.opencode/skills/review/SKILL.md",
              scope: "project",
              enabled: true,
              provider: "opencode",
            },
          ];
        },
        listThreads: async () => ({ data: [] }),
        ownsThread() {
          return false;
        },
        handleRequest() {},
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "skills-overlap-flat",
      method: "skills/list",
      params: { cwd: "/tmp/repo" },
    }),
  );
  await responsePromise;

  assert.ok(Array.isArray(responsePayload.result.skills));
  assert.equal(responsePayload.result.skills.length, 1);
  assert.equal(responsePayload.result.skills[0].provider, "codex");
  assert.deepEqual(responsePayload.result.skills[0].providers, ["codex", "opencode"]);
});

test("skills/list returns Codex-only skills when OpenCode provider is absent", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
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
              provider: "codex",
            },
          ],
        },
      ],
    }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "skills-codex-only",
      method: "skills/list",
      params: { cwds: ["/tmp/repo"] },
    }),
  );
  await responsePromise;

  const bucket = responsePayload.result.data.find((entry) => entry.cwd === "/tmp/repo");
  assert.ok(bucket);
  assert.equal(bucket.skills.length, 1);
  assert.equal(bucket.skills[0].name, "codex-skill");
  assert.equal(bucket.skills[0].provider, "codex");
  assert.deepEqual(bucket.skills[0].providers, ["codex"]);
});

test("skills/list merges Codex and OpenCode skill buckets", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
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
              provider: "codex",
            },
          ],
        },
      ],
    }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listSkills(directory) {
          return [
            {
              name: "opencode-skill",
              description: "From OpenCode",
              path: `${directory}/.agents/skills/opencode-skill/SKILL.md`,
              scope: "project",
              enabled: true,
              provider: "opencode",
            },
          ];
        },
        listThreads: async () => ({ data: [] }),
        ownsThread() {
          return false;
        },
        handleRequest() {},
      },
    ],
  });

  assert.equal(
    router.handleApplicationMessage(
      JSON.stringify({
        id: "skills-1",
        method: "skills/list",
        params: { cwds: ["/tmp/repo"] },
      }),
    ),
    true,
  );
  await responsePromise;

  assert.equal(responsePayload.id, "skills-1");
  const bucket = responsePayload.result.data.find((entry) => entry.cwd === "/tmp/repo");
  assert.ok(bucket);
  const names = bucket.skills.map((skill) => skill.name).sort();
  assert.deepEqual(names, ["codex-skill", "opencode-skill"]);
});

test("command/execute routes to opencode provider commandExecute", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listCommands() {
          return [{ token: "/skills", title: "Skills", description: "" }];
        },
        async commandExecute(request) {
          assert.equal(request.method, "command/execute");
          assert.equal(request.params.command, "/skills");
          return { ok: true, sessionId: "ses_router" };
        },
        listThreads: async () => ({ data: [] }),
        ownsThread() {
          return false;
        },
        handleRequest() {},
      },
    ],
  });

  assert.equal(
    router.handleApplicationMessage(
      JSON.stringify({
        id: "cmd-exec-1",
        method: "command/execute",
        params: { threadId: "opencode-thread-1", command: "/skills" },
      }),
    ),
    true,
  );
  await responsePromise;

  assert.equal(responsePayload.id, "cmd-exec-1");
  assert.deepEqual(responsePayload.result, { ok: true, sessionId: "ses_router" });
});

test("command/list returns empty when no opencode provider", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "cmd-2",
      method: "command/list",
      params: {},
    }),
  );
  await responsePromise;

  assert.equal(responsePayload.id, "cmd-2");
  assert.ok(Array.isArray(responsePayload.result.commands));
  assert.equal(responsePayload.result.commands.length, 0);
});

function waitOneTick() {
  return new Promise((resolve) => setImmediate(resolve));
}

test("runtime/catalog omits opencode when OpenCode is explicitly disabled", async () => {
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    providers: [
      {
        id: "opencode",
        async listAgents() {
          return [{ id: "build", label: "Build" }];
        },
      },
    ],
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  process.env.REMODEX_DISABLE_OPENCODE = "1";

  router.handleApplicationMessage(
    JSON.stringify({ id: "catalog-disabled", method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === "catalog-disabled")?.result;
  const codexRuntime = catalog.runtimes.find((runtime) => runtime.id === "codex");
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.equal(codexRuntime.reasonCode, null);
  assert.equal(opencodeRuntime, undefined);

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
});

test("runtime/catalog sets reasonCode when OpenCode agents cannot be listed", async () => {
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    providers: [
      {
        id: "opencode",
        async listAgents() {
          throw new Error("agents unavailable");
        },
      },
    ],
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;

  router.handleApplicationMessage(
    JSON.stringify({ id: "catalog-agents", method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === "catalog-agents")?.result;
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.equal(opencodeRuntime.enabled, false);
  assert.equal(opencodeRuntime.reasonCode, "opencode_agents_unavailable");
  assert.equal(opencodeRuntime.unavailableReason, "OpenCode agents could not be listed");

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
});

test("runtime/catalog surfaces OpenCode server start failures from provider", async () => {
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    providers: [
      {
        id: "opencode",
        getCatalogAvailability() {
          return {
            unavailableReason: "OpenCode port 4200 is already in use on this Mac.",
            reasonCode: "opencode_port_in_use",
          };
        },
        async listAgents() {
          return [];
        },
      },
    ],
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;

  router.handleApplicationMessage(
    JSON.stringify({ id: "catalog-server-down", method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === "catalog-server-down")?.result;
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.equal(opencodeRuntime.enabled, false);
  assert.equal(opencodeRuntime.reasonCode, "opencode_port_in_use");
  assert.match(opencodeRuntime.unavailableReason, /port 4200/i);

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
});

test("runtime/catalog clears reasonCode when OpenCode is enabled with agents", async () => {
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    providers: [
      {
        id: "opencode",
        async listAgents() {
          return [{ id: "build", label: "Build" }];
        },
      },
    ],
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;

  router.handleApplicationMessage(
    JSON.stringify({ id: "catalog-enabled", method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === "catalog-enabled")?.result;
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.equal(opencodeRuntime.enabled, true);
  assert.equal(opencodeRuntime.reasonCode, null);
  assert.equal(opencodeRuntime.unavailableReason, null);
  assert.equal(opencodeRuntime.capabilities.supportsSteer, false);
  assert.equal(opencodeRuntime.capabilities.supportsQueue, true);
  assert.equal(opencodeRuntime.capabilities.supportsAccessMode, false);
  assert.equal(opencodeRuntime.capabilities.supportsSkillAutocomplete, true);
  assert.equal(opencodeRuntime.capabilities.supportsStructuredSkillInput, false); // RP-SKILL-3: remains false (SDK lacks skills[] in prompt; gated)

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
});

test("runtime/catalog includes opencode.providers logo catalog (id,name,logoAssetId?,fallbackSymbol?) shape + count from inventory", async () => {
  const responses = [];
  // simulate providerInventory rows (as produced by buildProviderInventory + withLogoProviderId post-extend)
  const mockInventory = [
    { id: "anthropic", displayName: "Anthropic", logoProviderId: "anthropic", logoAssetId: "provider-anthropic-logo" },
    { id: "opencode-go", displayName: "OpenCode Go", logoProviderId: "opencode-go" },
    { id: "opencode", displayName: "OpenCode Zen", logoProviderId: "opencode-zen" },
  ];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    providers: [
      {
        id: "opencode",
        getRuntimeStatus() {
          return { providerInventory: mockInventory };
        },
        async listAgents() {
          return [{ id: "build", label: "Build" }];
        },
      },
    ],
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;

  router.handleApplicationMessage(
    JSON.stringify({ id: "catalog-providers", method: "runtime/catalog" }),
  );
  await waitOneTick();

  const catalog = responses.find((r) => r.id === "catalog-providers")?.result;
  const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
  assert.ok(opencodeRuntime, "opencode runtime present");
  const op = opencodeRuntime.opencode || {};
  assert.ok(Array.isArray(op.providers), "opencode.providers must be present array (catalog shape)");
  assert.equal(op.providers.length, 3, "providers count matches input inventory count");
  const go = op.providers.find((p) => p.id === "opencode-go");
  assert.ok(go);
  assert.equal(go.name, "OpenCode Go");
  assert.equal(go.logoAssetId, "provider-opencode-go-logo");
  assert.equal(go.fallbackSymbol, undefined);
  const zen = op.providers.find((p) => p.id === "opencode");
  assert.ok(zen);
  assert.equal(zen.logoAssetId, "provider-opencode-zen-logo");
  const anthropic = op.providers.find((p) => p.id === "anthropic");
  assert.ok(anthropic);
  assert.equal(anthropic.name, "Anthropic");
  assert.equal(anthropic.logoAssetId, "provider-anthropic-logo");

  if (previousDisable === undefined) {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  } else {
    process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
  }
});

test("rejects explicit provider switches on owned threads", async () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-router-ownership-"));

  try {
    const ownershipStore = createThreadOwnershipStore({
      storagePath: path.join(tempDir, "thread-ownership.json"),
      fsImpl: fs,
    });
    ownershipStore.setOwnership("thread-owned", "opencode");

    const responses = [];
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ items: [] }),
      sendApplicationResponse: (message) => {
        responses.push(JSON.parse(message));
      },
      sendRuntimeMessage: () => {},
      ownershipStore,
      providers: [makeProvider(["thread-owned"])],
    });

    const handled = router.handleApplicationMessage(
      JSON.stringify({
        id: "ownership-mismatch",
        method: "turn/start",
        params: {
          threadId: "thread-owned",
          modelProvider: "codex",
        },
      }),
    );

    assert.equal(handled, true);
    await waitOneTick();
    const response = responses.find((entry) => entry.id === "ownership-mismatch");
    assert.equal(response?.error?.data?.errorCode, "thread_provider_mismatch");
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("routes providerless owned thread RPCs by durable ownership", async () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-router-providerless-"));

  try {
    const ownershipStore = createThreadOwnershipStore({
      storagePath: path.join(tempDir, "thread-ownership.json"),
      fsImpl: fs,
    });
    ownershipStore.setOwnership("thread-owned", "opencode");

    const handledRequests = [];
    const responses = [];
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ items: [] }),
      sendApplicationResponse: (message) => {
        responses.push(JSON.parse(message));
      },
      sendRuntimeMessage: () => {},
      ownershipStore,
      providers: [
        {
          id: "opencode",
          ownsThread(threadId) {
            return threadId === "thread-owned";
          },
          async handleRequest(request) {
            handledRequests.push(request);
            return { thread: { id: request.params.threadId, modelProvider: "opencode" } };
          },
        },
      ],
    });

    const handled = router.handleApplicationMessage(
      JSON.stringify({
        id: "providerless-owned-read",
        method: "thread/read",
        params: {
          threadId: "thread-owned",
          includeTurns: true,
        },
      }),
    );

    assert.equal(handled, true);
    await waitOneTick();
    assert.equal(handledRequests.length, 1);
    assert.equal(handledRequests[0].method, "thread/read");
    const response = responses.find((entry) => entry.id === "providerless-owned-read");
    assert.equal(response?.error, undefined);
    assert.equal(response?.result?.thread?.modelProvider, "opencode");
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("permission/reply rejects explicit provider switches on owned threads", async () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-router-perm-ownership-"));

  try {
    const ownershipStore = createThreadOwnershipStore({
      storagePath: path.join(tempDir, "thread-ownership.json"),
      fsImpl: fs,
    });
    ownershipStore.setOwnership("thread-owned", "opencode");

    const responses = [];
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({}),
      sendApplicationResponse: (message) => {
        responses.push(JSON.parse(message));
      },
      sendRuntimeMessage: () => {},
      ownershipStore,
      providers: [makeProvider(["thread-owned"])],
    });

    const handled = router.handleApplicationMessage(
      JSON.stringify({
        id: "perm-ownership-mismatch",
        method: "permission/reply",
        params: {
          permissionId: "perm-owned",
          allow: true,
          threadId: "thread-owned",
          modelProvider: "codex",
        },
      }),
    );

    assert.equal(handled, true);
    await waitOneTick();
    const response = responses.find((entry) => entry.id === "perm-ownership-mismatch");
    assert.equal(response?.error?.data?.errorCode, "thread_provider_mismatch");
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("permission/reply routes to opencode provider", async () => {
  const handledRequests = [];
  const responses = [];
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (message) => {
      responses.push(JSON.parse(message));
    },
    sendRuntimeMessage: () => {},
    providers: [
      {
        id: "opencode",
        ownsThread() {
          return false;
        },
        async handleRequest(request) {
          handledRequests.push(request);
          return { success: true, permissionId: request.params.permissionId, allow: true };
        },
      },
    ],
  });

  const handled = router.handleApplicationMessage(
    JSON.stringify({
      id: "perm-reply-route",
      method: "permission/reply",
      params: { permissionId: "perm-route", allow: true },
    }),
  );

  assert.equal(handled, true);
  await waitOneTick();
  assert.equal(handledRequests.length, 1);
  assert.equal(handledRequests[0].method, "permission/reply");
  const response = responses.find((entry) => entry.id === "perm-reply-route");
  assert.equal(response?.error, undefined);
  assert.equal(response?.result?.success, true);
});

test("turn/start logs bridge_turn_start_audit and bridge_ownership_mismatch", async () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-router-audit-"));
  const logs = [];
  const originalLog = console.log;
  console.log = (...args) => {
    logs.push(args.map((entry) => String(entry)).join(" "));
  };

  try {
    const ownershipStore = createThreadOwnershipStore({
      storagePath: path.join(tempDir, "thread-ownership.json"),
      fsImpl: fs,
    });
    ownershipStore.setOwnership("thread-owned", "opencode");

    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ items: [] }),
      sendApplicationResponse: () => {},
      sendRuntimeMessage: () => {},
      ownershipStore,
      providers: [makeProvider(["thread-owned"])],
    });

    router.handleApplicationMessage(
      JSON.stringify({
        id: "audit-mismatch",
        method: "turn/start",
        params: {
          threadId: "thread-owned",
          modelProvider: "codex",
        },
      }),
    );
    await waitOneTick();

    const audit = logs
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter(Boolean);
    const turnStartAudit = audit.find((entry) => entry.event === "bridge_turn_start_audit");
    const mismatchLog = audit.find((entry) => entry.event === "bridge_ownership_mismatch");
    assert.equal(turnStartAudit?.threadId, "thread-owned");
    assert.equal(turnStartAudit?.requestedProvider, "codex");
    assert.equal(turnStartAudit?.storedProvider, "opencode");
    assert.equal(turnStartAudit?.mismatch, true);
    assert.equal(mismatchLog?.errorCode, "thread_provider_mismatch");
  } finally {
    console.log = originalLog;
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("providerForRequest logs ownsThread decision and router init", async () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-router-decision-"));
  const logs = [];
  const originalLog = console.log;
  console.log = (...args) => {
    logs.push(args.map((entry) => String(entry)).join(" "));
  };

  try {
    const ownershipStore = createThreadOwnershipStore({
      storagePath: path.join(tempDir, "thread-ownership.json"),
      fsImpl: fs,
    });
    ownershipStore.setOwnership("thread-owned-oc", "opencode");

    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ items: [] }),
      sendApplicationResponse: () => {},
      sendRuntimeMessage: () => {},
      ownershipStore,
      providers: [makeProvider(["thread-owned-oc"])],
    });

    // providerless request on owned thread hits owns lookup path (plus decision + init logs for RP-MSG-1)
    router.handleApplicationMessage(
      JSON.stringify({
        id: "decision-owns",
        method: "turn/start",
        params: {
          threadId: "thread-owned-oc",
        },
      }),
    );
    await waitOneTick();

    const parsedLogs = logs
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter(Boolean);

    const decision = parsedLogs.find((entry) => entry.event === "provider_for_request_decision");
    const ownsCall = parsedLogs.find((entry) => entry.event === "provider_for_request_owns_call");
    const initLog = parsedLogs.find((entry) => entry.event === "runtime_provider_router_init");

    assert.equal(decision?.requestedProvider, null);
    assert.equal(decision?.hasExplicitProviderField, false);
    assert.equal(decision?.storedProvider, "opencode");
    assert.equal(decision?.resolvedProvider, "opencode");
    assert.equal(decision?.matchReason, "owns_thread_match");
    assert.equal(decision?.owns, true);
    assert.equal(ownsCall?.threadId, "thread-owned-oc");
    assert.ok(initLog, "startup router init log present");
  } finally {
    console.log = originalLog;
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("shouldWarmProviderInventory is true for empty, partial, or non-ok auth discovery", () => {
  assert.equal(shouldWarmProviderInventory({ providerInventory: [] }), true);
  assert.equal(
    shouldWarmProviderInventory({
      providerInventory: [{ id: "openai", authenticated: true, connected: true }],
      authDiscoveryReasonCode: "ok",
      providerInventoryPartial: true,
    }),
    true,
  );
  assert.equal(
    shouldWarmProviderInventory({
      providerInventory: [{ id: "openai", authenticated: true, connected: true }],
      authDiscoveryReasonCode: "auth_probe_pending",
      providerInventoryPartial: false,
    }),
    true,
  );
  assert.equal(
    shouldWarmProviderInventory({
      providerInventory: [{ id: "openai", authenticated: true, connected: true }],
      authDiscoveryReasonCode: "ok",
      providerInventoryPartial: false,
    }),
    false,
  );
});

test("shouldWarmProviderInventory honors REMODEX_CATALOG_WARM_INVENTORY=0", () => {
  assert.equal(
    shouldWarmProviderInventory({ providerInventory: [] }, { REMODEX_CATALOG_WARM_INVENTORY: "0" }),
    false,
  );
});

test("runtime/catalog warms empty inventory and attaches catalogRevision", async () => {
  resetCatalogPushState();
  const responses = [];
  const runtimeMessages = [];
  const logs = [];
  const originalLog = console.log;
  console.log = (...args) => {
    logs.push(args.join(" "));
  };

  let inventory = [];
  const provider = {
    id: "opencode",
    async listAgents() {
      return [{ id: "build", label: "Build" }];
    },
    async listModels(options = {}) {
      assert.equal(options.refreshProviders, true);
      inventory = [
        { id: "openai", authenticated: true, connected: true },
        { id: "anthropic", authenticated: true, connected: true },
      ];
      return { models: [], meta: { reasonCode: "ok", connectedProviderIds: ["openai", "anthropic"] } };
    },
    getRuntimeStatus() {
      return {
        providerInventory: inventory,
        authDiscoveryReasonCode: inventory.length > 0 ? "ok" : "auth_probe_pending",
        providerInventoryPartial: inventory.length === 0,
      };
    },
  };

  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({}),
    sendApplicationResponse: (msg) => responses.push(JSON.parse(msg)),
    sendRuntimeMessage: (msg) => runtimeMessages.push(JSON.parse(msg)),
    providers: [provider],
  });

  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;

  try {
    router.handleApplicationMessage(
      JSON.stringify({ id: "catalog-warm", method: "runtime/catalog" }),
    );
    await waitOneTick();

    const catalog = responses.find((entry) => entry.id === "catalog-warm")?.result;
    const opencodeRuntime = catalog.runtimes.find((runtime) => runtime.id === "opencode");
    assert.equal(opencodeRuntime.opencode.providerInventory.length, 2);
    assert.match(opencodeRuntime.opencode.catalogRevision, /^fp:[0-9a-f]{8}$/);
    assert.equal(runtimeMessages.length, 1);
    assert.equal(runtimeMessages[0].method, "runtime/catalog/updated");
    assert.equal(runtimeMessages[0].params.catalogRevision, opencodeRuntime.opencode.catalogRevision);

    const warmLog = logs
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .find((entry) => entry?.event === "runtime_catalog_warm_inventory");
    assert.ok(warmLog);
    assert.equal(warmLog.authenticatedBefore, 0);
    assert.equal(warmLog.authenticatedAfter, 2);
    assert.equal(warmLog.timedOut, false);
  } finally {
    console.log = originalLog;
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
});

test("runtime/catalog skips warm when REMODEX_CATALOG_WARM_INVENTORY=0", async () => {
  resetCatalogPushState();
  let warmCalls = 0;
  const provider = {
    id: "opencode",
    async listAgents() {
      return [{ id: "build", label: "Build" }];
    },
    async listModels() {
      warmCalls += 1;
      return { models: [] };
    },
    getRuntimeStatus() {
      return {
        providerInventory: [],
        authDiscoveryReasonCode: "auth_probe_pending",
        providerInventoryPartial: true,
      };
    },
  };

  await buildCatalogOpenCodeRuntime(
    [provider],
    { REMODEX_CATALOG_WARM_INVENTORY: "0" },
    () => {},
  );

  assert.equal(warmCalls, 0);
});

test("identical subsequent model/list does not push runtime/catalog/updated again", async () => {
  resetCatalogPushState();
  const runtimeMessages = [];
  const inventory = [{ id: "openai", authenticated: true, connected: true }];
  const provider = {
    id: "opencode",
    async listModels() {
      return {
        models: [
          {
            id: "openai/gpt-5.5",
            model: "openai/gpt-5.5",
            modelProvider: "opencode",
            upstreamProviderId: "openai",
          },
        ],
      };
    },
    getRuntimeStatus() {
      return {
        providerInventory: inventory,
        authDiscoveryReasonCode: "ok",
        providerInventoryPartial: false,
      };
    },
    async listAgents() {
      return [];
    },
    async listThreads() {
      return { data: [] };
    },
    ownsThread() {
      return false;
    },
    handleRequest() {
      return {};
    },
  };

  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ items: [] }),
    sendApplicationResponse: () => {},
    sendRuntimeMessage: (msg) => runtimeMessages.push(JSON.parse(msg)),
    providers: [provider],
  });

  const request = JSON.stringify({ id: "models-no-dup-push", method: "model/list", params: {} });
  router.handleApplicationMessage(request);
  await waitOneTick();
  router.handleApplicationMessage(request);
  await waitOneTick();

  const catalogUpdates = runtimeMessages.filter((message) => message.method === "runtime/catalog/updated");
  assert.equal(catalogUpdates.length, 1);
});

test("computeCatalogFingerprint changes when only connectedOnServe flips", () => {
  const before = computeCatalogFingerprint({
    providerInventory: [{ id: "openai", authenticated: true, connectedOnServe: false }],
    authDiscoveryReasonCode: "ok",
    providerInventoryPartial: false,
  });
  const after = computeCatalogFingerprint({
    providerInventory: [{ id: "openai", authenticated: true, connectedOnServe: true }],
    authDiscoveryReasonCode: "ok",
    providerInventoryPartial: false,
  });
  assert.notEqual(before, after);
  assert.notEqual(computeCatalogRevision({
    providerInventory: [{ id: "openai", authenticated: true, connectedOnServe: false }],
    authDiscoveryReasonCode: "ok",
    providerInventoryPartial: false,
  }), computeCatalogRevision({
    providerInventory: [{ id: "openai", authenticated: true, connectedOnServe: true }],
    authDiscoveryReasonCode: "ok",
    providerInventoryPartial: false,
  }));
});

function makeDiscoverProjectRegistryFixture() {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-router-discover-"));
  const registry = createProjectRegistry({
    storagePath: path.join(homeDir, "remodex", "known-projects.json"),
    homeDir,
  });
  return { homeDir, registry };
}

function makeDiscoverProvider(overrides = {}) {
  return {
    id: "opencode",
    async listModels() {
      return [];
    },
    async listThreads() {
      return { data: [] };
    },
    ownsThread() {
      return false;
    },
    handleRequest() {
      return {};
    },
    ...overrides,
  };
}

function withDiscoverEnv(overrides = {}, fn) {
  const previous = {
    discoverProjects: process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS,
    discoverTtl: process.env.REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS,
    disableOpenCode: process.env.REMODEX_DISABLE_OPENCODE,
  };
  resetOpenCodeProjectDiscoverState();
  if (overrides.discoverProjects !== undefined) {
    process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS = overrides.discoverProjects;
  } else {
    delete process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS;
  }
  if (overrides.discoverTtl !== undefined) {
    process.env.REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS = overrides.discoverTtl;
  } else {
    delete process.env.REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS;
  }
  if (overrides.disableOpenCode !== undefined) {
    process.env.REMODEX_DISABLE_OPENCODE = overrides.disableOpenCode;
  } else {
    delete process.env.REMODEX_DISABLE_OPENCODE;
  }
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      resetOpenCodeProjectDiscoverState();
      if (previous.discoverProjects === undefined) {
        delete process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS;
      } else {
        process.env.REMODEX_OPENCODE_DISCOVER_PROJECTS = previous.discoverProjects;
      }
      if (previous.discoverTtl === undefined) {
        delete process.env.REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS;
      } else {
        process.env.REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS = previous.discoverTtl;
      }
      if (previous.disableOpenCode === undefined) {
        delete process.env.REMODEX_DISABLE_OPENCODE;
      } else {
        process.env.REMODEX_DISABLE_OPENCODE = previous.disableOpenCode;
      }
    });
}

test("isOpenCodeDiscoverProjectsEnabled honors client params and env overrides", () => {
  assert.equal(isOpenCodeDiscoverProjectsEnabled({}, {}), false);
  assert.equal(
    isOpenCodeDiscoverProjectsEnabled({}, { discoverOpenCodeProjects: true }),
    true,
  );
  assert.equal(isOpenCodeDiscoverProjectsEnabled({ REMODEX_OPENCODE_DISCOVER_PROJECTS: "0" }, {}), false);
  assert.equal(isOpenCodeDiscoverProjectsEnabled({ REMODEX_OPENCODE_DISCOVER_PROJECTS: "1" }, {}), true);
  assert.equal(isOpenCodeDiscoverProjectsEnabled({ REMODEX_OPENCODE_DISCOVER_PROJECTS: "true" }, {}), true);
});

test("readDiscoverProjectTtlMs defaults to 120s and honors env override", () => {
  assert.equal(readDiscoverProjectTtlMs({}), 120_000);
  assert.equal(readDiscoverProjectTtlMs({ REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS: "5000" }), 5_000);
});

test("thread/list skips hot-path project discover when REMODEX_OPENCODE_DISCOVER_PROJECTS=0", async () => {
  await withDiscoverEnv({}, async () => {
    let discoverCalls = 0;
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ data: [] }),
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      projectRegistry: makeDiscoverProjectRegistryFixture().registry,
      providers: [
        makeDiscoverProvider({
          async discoverProjects() {
            discoverCalls += 1;
            return [];
          },
        }),
      ],
    });

    router.handleApplicationMessage(
      JSON.stringify({
        id: "discover-flag-off",
        method: "thread/list",
        params: { discoverOpenCodeProjects: false },
      }),
    );
    await responsePromise;
    await waitOneTick();

    assert.equal(responsePayload.id, "discover-flag-off");
    assert.equal(discoverCalls, 0);
  });
});

test("thread/list debounces project discover within TTL and remembers projects", async () => {
  await withDiscoverEnv({ discoverProjects: "1", discoverTtl: "60000" }, async () => {
    const { homeDir, registry } = makeDiscoverProjectRegistryFixture();
    const projectDir = path.join(homeDir, "workspace", "demo");
    fs.mkdirSync(projectDir, { recursive: true });
    let discoverCalls = 0;
    const router = createRuntimeProviderRouter({
      homeDir,
      sendCodexRequest: async () => ({ data: [] }),
      sendApplicationResponse: () => {},
      projectRegistry: registry,
      providers: [
        makeDiscoverProvider({
          async discoverProjects() {
            discoverCalls += 1;
            return [{ id: "proj-1", path: projectDir, name: "Demo" }];
          },
        }),
      ],
    });

    const request = JSON.stringify({
      id: "discover-debounce",
      method: "thread/list",
      params: { discoverOpenCodeProjects: true },
    });
    router.handleApplicationMessage(request);
    await waitOneTick();
    router.handleApplicationMessage(request);
    await waitOneTick();
    await new Promise((resolve) => setTimeout(resolve, 20));

    assert.equal(discoverCalls, 1);
    assert.equal(registry.listProjects().length, 1);
    assert.equal(registry.listProjects()[0].path, fs.realpathSync(projectDir));
    fs.rmSync(homeDir, { recursive: true });
  });
});

test("thread/list returns before slow project discover completes", async () => {
  await withDiscoverEnv({ discoverProjects: "1" }, async () => {
    let discoverStarted = false;
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ data: [{ id: "codex-thread", cwd: "/Users/me/codex" }] }),
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      projectRegistry: makeDiscoverProjectRegistryFixture().registry,
      providers: [
        makeDiscoverProvider({
          discoverProjects() {
            discoverStarted = true;
            return new Promise(() => {});
          },
        }),
      ],
    });

    const startedAt = Date.now();
    router.handleApplicationMessage(
      JSON.stringify({
        id: "discover-nonblocking",
        method: "thread/list",
        params: { discoverOpenCodeProjects: true },
      }),
    );
    await responsePromise;

    assert.ok(Date.now() - startedAt < 500);
    assert.equal(responsePayload.id, "discover-nonblocking");
    assert.equal(responsePayload.result.data.length, 1);
    assert.equal(discoverStarted, true);
  });
});

test("thread/list logs thread_list_wall_ms and opencode_discover_on_list when discover enabled", async () => {
  await withDiscoverEnv({ discoverProjects: "1" }, async () => {
    const logs = [];
    const originalLog = console.log;
    console.log = (...args) => {
      logs.push(args.map((entry) => String(entry)).join(" "));
    };

    try {
      let responsePayload = null;
      let resolveResponse;
      const responsePromise = new Promise((resolve) => {
        resolveResponse = resolve;
      });
      const router = createRuntimeProviderRouter({
        sendCodexRequest: async () => ({ data: [] }),
        sendApplicationResponse(payload) {
          responsePayload = JSON.parse(payload);
          resolveResponse();
        },
        projectRegistry: makeDiscoverProjectRegistryFixture().registry,
        providers: [
          makeDiscoverProvider({
            async discoverProjects() {
              return [];
            },
          }),
        ],
      });

      router.handleApplicationMessage(
        JSON.stringify({
          id: "discover-logs",
          method: "thread/list",
          params: { discoverOpenCodeProjects: true },
        }),
      );
      await responsePromise;

      const parsedLogs = logs
        .map((line) => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(Boolean);
      const codexLog = parsedLogs.find((entry) => entry.event === "thread_list_codex_ms");
      const opencodeLog = parsedLogs.find((entry) => entry.event === "thread_list_opencode_ms");
      const wallLog = parsedLogs.find((entry) => entry.event === "thread_list_wall_ms");
      const discoverLog = parsedLogs.find((entry) => entry.event === "opencode_discover_on_list");
      assert.ok(codexLog, "thread_list_codex_ms log present");
      assert.ok(opencodeLog, "thread_list_opencode_ms log present");
      assert.ok(wallLog, "thread_list_wall_ms log present");
      assert.equal(typeof codexLog.ms, "number");
      assert.equal(typeof opencodeLog.ms, "number");
      assert.equal(typeof wallLog.wallMs, "number");
      assert.equal(typeof wallLog.codexMs, "number");
      assert.equal(typeof wallLog.opencodeMs, "number");
      assert.equal(wallLog.discoverProjectsEnabled, true);
      assert.ok(discoverLog, "opencode_discover_on_list log present");
      assert.equal(discoverLog.ttlMs, 120_000);
      assert.equal(responsePayload.id, "discover-logs");
    } finally {
      console.log = originalLog;
    }
  });
});

test("thread/list returns Codex threads when OpenCode listThreads never resolves", async () => {
  const previousBudget = process.env.REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS;
  process.env.REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS = "200";
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const startedAt = Date.now();
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({
      data: [{ id: "codex-thread-only", modelProvider: "codex" }],
    }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        listThreads() {
          return new Promise(() => {});
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "threads-opencode-hang",
      method: "thread/list",
      params: {},
    }),
  );
  await responsePromise;

  const elapsedMs = Date.now() - startedAt;
  const opencodeBudgetMs = opencodeThreadListBudgetMs();
  assert.ok(
    elapsedMs < opencodeBudgetMs + 500,
    `expected thread/list within OpenCode budget, took ${elapsedMs}ms`,
  );
  assert.equal(responsePayload.result.data.length, 1);
  assert.equal(responsePayload.result.data[0].id, "codex-thread-only");
  if (previousBudget === undefined) {
    delete process.env.REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS;
  } else {
    process.env.REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS = previousBudget;
  }
});

test("thread/list returns OpenCode threads when Codex thread/list never resolves", async () => {
  const previousBudget = process.env.REMODEX_THREAD_LIST_CODEX_BUDGET_MS;
  process.env.REMODEX_THREAD_LIST_CODEX_BUDGET_MS = "200";
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const startedAt = Date.now();
  const router = createRuntimeProviderRouter({
    sendCodexRequest: () => new Promise(() => {}),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listThreads() {
          return {
            data: [{ id: "opencode-thread-only", modelProvider: "opencode" }],
          };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "threads-codex-hang",
      method: "thread/list",
      params: {},
    }),
  );
  await responsePromise;

  const elapsedMs = Date.now() - startedAt;
  const codexBudgetMs = codexThreadListBudgetMs();
  assert.ok(
    elapsedMs < codexBudgetMs + 500,
    `expected thread/list within Codex budget, took ${elapsedMs}ms`,
  );
  assert.equal(responsePayload.result.data.length, 1);
  assert.equal(responsePayload.result.data[0].id, "opencode-thread-only");
  if (previousBudget === undefined) {
    delete process.env.REMODEX_THREAD_LIST_CODEX_BUDGET_MS;
  } else {
    process.env.REMODEX_THREAD_LIST_CODEX_BUDGET_MS = previousBudget;
  }
});

test("thread/list still returns OpenCode threads when Codex thread/list fails", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => {
      throw new Error("codex offline");
    },
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listThreads() {
          return {
            data: [{ id: "opencode-thread-only", modelProvider: "opencode" }],
          };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "threads-codex-fail",
      method: "thread/list",
      params: {},
    }),
  );
  await responsePromise;

  assert.equal(responsePayload.result.data.length, 1);
  assert.equal(responsePayload.result.data[0].id, "opencode-thread-only");
});

test("thread/list runs Codex and OpenCode legs in parallel", async () => {
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const legDelayMs = 60;
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => {
      await new Promise((resolve) => setTimeout(resolve, legDelayMs));
      return { data: [{ id: "codex-parallel", modelProvider: "codex" }] };
    },
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listThreads() {
          await new Promise((resolve) => setTimeout(resolve, legDelayMs));
          return {
            data: [{ id: "opencode-parallel", modelProvider: "opencode" }],
          };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  const startedAt = Date.now();
  router.handleApplicationMessage(
    JSON.stringify({
      id: "threads-parallel",
      method: "thread/list",
      params: {},
    }),
  );
  await responsePromise;
  const elapsedMs = Date.now() - startedAt;

  assert.ok(
    elapsedMs < legDelayMs * 2,
    `expected parallel thread/list (~${legDelayMs}ms), took ${elapsedMs}ms`,
  );
  assert.equal(responsePayload.result.data.length, 2);
});

test("codexThreadListBudgetMs and opencodeThreadListBudgetMs honor env overrides", () => {
  assert.equal(codexThreadListBudgetMs({}), CODEX_THREAD_LIST_BUDGET_MS);
  assert.equal(
    codexThreadListBudgetMs({ REMODEX_THREAD_LIST_CODEX_BUDGET_MS: "9000" }),
    9_000,
  );
  assert.equal(
    codexThreadListBudgetMs({ REMODEX_THREAD_LIST_CODEX_BUDGET_MS: "60000" }),
    THREAD_LIST_BUDGET_CEILING_MS,
  );
  assert.equal(opencodeThreadListBudgetMs({}), DEFAULT_OPENCODE_THREAD_LIST_BUDGET_MS);
  assert.equal(
    opencodeThreadListBudgetMs({ REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS: "8500" }),
    8_500,
  );
});

function percentile(values, p) {
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil((p / 100) * sorted.length) - 1),
  );
  return sorted[index];
}

test("thread/list wall-clock p99 stays under 11s with KD-10 discover-on fixtures", async () => {
  const codexDelayMs = 1_200;
  const coldServeDelayMs = 1_500;
  const stubCount = 20;
  const samples = [];
  const iterations = 3;

  for (let index = 0; index < iterations; index += 1) {
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => {
        await new Promise((resolve) => setTimeout(resolve, codexDelayMs));
        return { data: [{ id: `codex-slo-${index}`, modelProvider: "codex" }] };
      },
      sendApplicationResponse() {
        resolveResponse();
      },
      providers: [
        {
          id: "opencode",
          async listModels() {
            return [];
          },
          async listThreads(params) {
            assert.equal(params.discoverOpenCodeSessions, true);
            await new Promise((resolve) => setTimeout(resolve, coldServeDelayMs));
            const data = [];
            for (let stubIndex = 0; stubIndex < stubCount; stubIndex += 1) {
              data.push({
                id: `opencode-session-ses_kd10_${stubIndex}`,
                title: `KD10 stub ${stubIndex}`,
                modelProvider: "opencode",
                metadata: {
                  provider: "opencode",
                  discoveredExternally: true,
                  sessionId: `ses_kd10_${stubIndex}`,
                },
              });
            }
            return { data };
          },
          ownsThread() {
            return false;
          },
          handleRequest() {
            return {};
          },
        },
      ],
    });

    const startedAt = Date.now();
    router.handleApplicationMessage(
      JSON.stringify({
        id: `threads-slo-${index}`,
        method: "thread/list",
        params: { discoverOpenCodeSessions: true, discoverOpenCodeProjects: true },
      }),
    );
    await responsePromise;
    samples.push(Date.now() - startedAt);
  }

  const p99 = percentile(samples, 99);
  assert.ok(
    p99 < 11_000,
    `expected thread/list p99 < 11s, got ${p99}ms from samples=${samples.join(",")}`,
  );
  assert.ok(
    p99 < codexDelayMs + coldServeDelayMs - 1_000,
    `expected parallel wall < sequential sum, got ${p99}ms`,
  );
});

test("thread/list wall-clock p95 stays under 3s on warm-cache fixtures", async () => {
  const legDelayMs = 40;
  const samples = [];
  const iterations = 12;

  for (let index = 0; index < iterations; index += 1) {
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => {
        await new Promise((resolve) => setTimeout(resolve, legDelayMs));
        return { data: [{ id: `codex-warm-${index}`, modelProvider: "codex" }] };
      },
      sendApplicationResponse() {
        resolveResponse();
      },
      providers: [
        {
          id: "opencode",
          async listModels() {
            return [];
          },
          async listThreads() {
            await new Promise((resolve) => setTimeout(resolve, legDelayMs));
            return {
              data: [{ id: `opencode-warm-${index}`, modelProvider: "opencode" }],
            };
          },
          ownsThread() {
            return false;
          },
          handleRequest() {
            return {};
          },
        },
      ],
    });

    const startedAt = Date.now();
    router.handleApplicationMessage(
      JSON.stringify({
        id: `threads-warm-${index}`,
        method: "thread/list",
        params: { discoverOpenCodeSessions: true, discoverOpenCodeProjects: true },
      }),
    );
    await responsePromise;
    samples.push(Date.now() - startedAt);
  }

  const p95 = percentile(samples, 95);
  assert.ok(
    p95 < 3_000,
    `expected thread/list p95 cache-hit < 3s, got ${p95}ms from samples=${samples.join(",")}`,
  );
});

test("thread/list merges client-param session discover when env discover is unset", async () => {
  const previousSessions = process.env.REMODEX_OPENCODE_DISCOVER_SESSIONS;
  delete process.env.REMODEX_OPENCODE_DISCOVER_SESSIONS;
  let responsePayload = null;
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });
  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ data: [] }),
    sendApplicationResponse(payload) {
      responsePayload = JSON.parse(payload);
      resolveResponse();
    },
    providers: [
      {
        id: "opencode",
        async listModels() {
          return [];
        },
        async listThreads(params) {
          assert.equal(params.discoverOpenCodeSessions, true);
          return {
            data: [
              {
                id: "opencode-session-ses_client_param",
                title: "Mac CLI session",
                modelProvider: "opencode",
                metadata: {
                  provider: "opencode",
                  discoveredExternally: true,
                  sessionId: "ses_client_param",
                },
              },
            ],
          };
        },
        ownsThread() {
          return false;
        },
        handleRequest() {
          return {};
        },
      },
    ],
  });

  router.handleApplicationMessage(
    JSON.stringify({
      id: "threads-client-discover",
      method: "thread/list",
      params: { discoverOpenCodeSessions: true },
    }),
  );
  await responsePromise;

  assert.equal(responsePayload.result.data.length, 1);
  assert.equal(responsePayload.result.data[0].id, "opencode-session-ses_client_param");
  if (previousSessions === undefined) {
    delete process.env.REMODEX_OPENCODE_DISCOVER_SESSIONS;
  } else {
    process.env.REMODEX_OPENCODE_DISCOVER_SESSIONS = previousSessions;
  }
});

test("thread/list skips OpenCode leg when cursor is present", async () => {
  const logs = [];
  const originalLog = console.log;
  console.log = (...args) => {
    logs.push(args.map((entry) => String(entry)).join(" "));
  };

  try {
    let listThreadsCalls = 0;
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({
        data: [{ id: "codex-page-2", modelProvider: "codex" }],
      }),
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      providers: [
        {
          id: "opencode",
          async listModels() {
            return [];
          },
          async listThreads() {
            listThreadsCalls += 1;
            throw new Error("OpenCode listThreads should not run with cursor");
          },
          ownsThread() {
            return false;
          },
          handleRequest() {
            return {};
          },
        },
      ],
    });

    router.handleApplicationMessage(
      JSON.stringify({
        id: "threads-cursor-page",
        method: "thread/list",
        params: { cursor: "page-2" },
      }),
    );
    await responsePromise;

    assert.equal(listThreadsCalls, 0);
    assert.equal(responsePayload.result.data.length, 1);
    assert.equal(responsePayload.result.data[0].id, "codex-page-2");
    const parsedLogs = logs
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter(Boolean);
    const opencodeLog = parsedLogs.find((entry) => entry.event === "thread_list_opencode_ms");
    assert.ok(opencodeLog, "thread_list_opencode_ms log present");
    assert.equal(opencodeLog.ms, 0);
  } finally {
    console.log = originalLog;
    resetThreadListInFlightState();
  }
});

test("thread/list coalesces concurrent OpenCode listThreads calls per provider", async () => {
  resetThreadListInFlightState();
  let listThreadsCalls = 0;
  const provider = {
    id: "opencode",
    async listModels() {
      return [];
    },
    async listThreads() {
      listThreadsCalls += 1;
      await new Promise((resolve) => setTimeout(resolve, 60));
      return { data: [{ id: "opencode-coalesced", modelProvider: "opencode" }] };
    },
    ownsThread() {
      return false;
    },
    handleRequest() {
      return {};
    },
  };

  const first = listProviderThreadsForThreadList([provider], {});
  const second = listProviderThreadsForThreadList([provider], {});
  const [firstResult, secondResult] = await Promise.all([first, second]);

  assert.equal(listThreadsCalls, 1);
  assert.equal(firstResult.threads.length, 1);
  assert.equal(secondResult.threads.length, 1);
  resetThreadListInFlightState();
});

test("thread/list with DISABLE_OPENCODE and iOS-default discover params stays Codex-only", async () => {
  await withDiscoverEnv({ discoverProjects: "1", disableOpenCode: "1" }, async () => {
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ data: [{ id: "codex-ios-shaped" }] }),
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      projectRegistry: makeDiscoverProjectRegistryFixture().registry,
    });

    router.handleApplicationMessage(
      JSON.stringify({
        id: "discover-disable-ios-params",
        method: "thread/list",
        params: {
          discoverOpenCodeSessions: true,
          discoverOpenCodeProjects: true,
        },
      }),
    );
    await responsePromise;

    assert.deepEqual(
      router.providers.map((provider) => provider.id),
      [],
      "OpenCode provider should not register when DISABLE_OPENCODE=1",
    );
    assert.equal(responsePayload.result.data.length, 1);
    assert.equal(responsePayload.result.data[0].id, "codex-ios-shaped");
  });
});

test("thread/list does not call project discover when REMODEX_DISABLE_OPENCODE=1", async () => {
  await withDiscoverEnv({ discoverProjects: "1", disableOpenCode: "1" }, async () => {
    let discoverCalls = 0;
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => ({ data: [{ id: "codex-only" }] }),
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      projectRegistry: makeDiscoverProjectRegistryFixture().registry,
      providers: [
        makeDiscoverProvider({
          async discoverProjects() {
            discoverCalls += 1;
            return [];
          },
        }),
      ],
    });

    router.handleApplicationMessage(
      JSON.stringify({ id: "discover-disabled-runtime", method: "thread/list", params: {} }),
    );
    await responsePromise;
    await waitOneTick();

    assert.equal(responsePayload.id, "discover-disabled-runtime");
    assert.equal(discoverCalls, 0);
  });
});

test("auth inventory change via model/list pushes runtime/catalog/updated once", async () => {
  resetCatalogPushState();
  const runtimeMessages = [];
  let authenticated = false;
  const provider = {
    id: "opencode",
    async listModels() {
      return {
        models: authenticated
          ? [
              {
                id: "openai/gpt-5.5",
                model: "openai/gpt-5.5",
                modelProvider: "opencode",
                upstreamProviderId: "openai",
              },
            ]
          : [],
      };
    },
    getRuntimeStatus() {
      return {
        providerInventory: [
          {
            id: "openai",
            authenticated,
            connected: authenticated,
          },
        ],
        authDiscoveryReasonCode: authenticated ? "ok" : "auth_probe_pending",
        providerInventoryPartial: !authenticated,
      };
    },
    async listAgents() {
      return [];
    },
    async listThreads() {
      return { data: [] };
    },
    ownsThread() {
      return false;
    },
    handleRequest() {
      return {};
    },
  };

  const router = createRuntimeProviderRouter({
    sendCodexRequest: async () => ({ items: [] }),
    sendApplicationResponse: () => {},
    sendRuntimeMessage: (msg) => runtimeMessages.push(JSON.parse(msg)),
    providers: [provider],
  });

  router.handleApplicationMessage(
    JSON.stringify({ id: "models-auth-1", method: "model/list", params: {} }),
  );
  await waitOneTick();

  authenticated = true;
  router.handleApplicationMessage(
    JSON.stringify({ id: "models-auth-2", method: "model/list", params: {} }),
  );
  await waitOneTick();

  const catalogUpdates = runtimeMessages.filter((message) => message.method === "runtime/catalog/updated");
  assert.equal(catalogUpdates.length, 2);
  assert.notEqual(
    catalogUpdates[0].params.catalogRevision,
    catalogUpdates[1].params.catalogRevision,
  );
  assert.equal(
    computeCatalogRevision({
      providerInventory: [{ id: "openai", authenticated: true, connected: true }],
      authDiscoveryReasonCode: "ok",
      providerInventoryPartial: false,
    }),
    catalogUpdates[1].params.catalogRevision,
  );
});

function withOpenCodeRuntimeEnabled(fn) {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;
  try {
    return fn();
  } finally {
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
}

test("providerForRequest routes discovered external thread ids when OpenCode runtime is enabled", () => {
  withOpenCodeRuntimeEnabled(() => {
    const provider = makeProvider([]);
    withMutedConsole(() => {
      assert.equal(
        providerForRequest(
          { method: "thread/resume", params: { threadId: "opencode-session-ses_router" } },
          [provider],
        ),
        provider,
      );
      assert.equal(
        providerForRequest(
          { method: "thread/resume", params: { threadId: "opencode-session-ses_router" } },
          [provider],
          null,
        ),
        provider,
      );
    });
  });
});

test("thread/read routes providerless discovered external ids to OpenCode provider", async () => {
  await withOpenCodeRuntimeEnabled(async () => {
    let handledMethod = null;
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => {
        throw new Error("Codex passthrough should not run for discovered external read");
      },
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      providers: [
        {
          id: "opencode",
          async listModels() {
            return [];
          },
          async listThreads() {
            return { data: [] };
          },
          ownsThread() {
            return false;
          },
          async handleRequest(request) {
            handledMethod = request.method;
            return { thread: { id: request.params.threadId, title: "Adopted" } };
          },
        },
      ],
    });

    router.handleApplicationMessage(
      JSON.stringify({
        id: "discovered-read",
        method: "thread/read",
        params: { threadId: "opencode-session-ses_router_read" },
      }),
    );
    await responsePromise;

    assert.equal(handledMethod, "thread/read");
    assert.equal(responsePayload.id, "discovered-read");
    assert.equal(responsePayload.result.thread.id, "opencode-session-ses_router_read");
  });
});

test("thread/resume routes providerless discovered external ids to OpenCode provider", async () => {
  await withOpenCodeRuntimeEnabled(async () => {
    let handledMethod = null;
    let responsePayload = null;
    let resolveResponse;
    const responsePromise = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const router = createRuntimeProviderRouter({
      sendCodexRequest: async () => {
        throw new Error("Codex passthrough should not run for discovered external resume");
      },
      sendApplicationResponse(payload) {
        responsePayload = JSON.parse(payload);
        resolveResponse();
      },
      providers: [
        {
          id: "opencode",
          async listModels() {
            return [];
          },
          async listThreads() {
            return { data: [] };
          },
          ownsThread() {
            return false;
          },
          async handleRequest(request) {
            handledMethod = request.method;
            return { thread: { id: request.params.threadId, title: "Adopted" } };
          },
        },
      ],
    });

    router.handleApplicationMessage(
      JSON.stringify({
        id: "discovered-resume",
        method: "thread/resume",
        params: { threadId: "opencode-session-ses_router_resume" },
      }),
    );
    await responsePromise;

    assert.equal(handledMethod, "thread/resume");
    assert.equal(responsePayload.id, "discovered-resume");
    assert.equal(responsePayload.result.thread.id, "opencode-session-ses_router_resume");
  });
});
