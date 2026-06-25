// FILE: runtime-merge.test.js
// Purpose: Runtime merge helpers for model/thread/skills list payloads.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  CODEX_THREAD_LIST_BUDGET_MS,
  DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS,
  DEFAULT_OPENCODE_THREAD_LIST_BUDGET_MS,
  MODEL_LIST_PROVIDER_BUDGET_MS,
  THREAD_LIST_BUDGET_CEILING_MS,
  buildCatalogOpenCodeRuntime,
  capOpenCodeModelsForMobileList,
  codexThreadListBudgetMs,
  computeCatalogFingerprint,
  computeCatalogRevision,
  createProjectRegistry,
  createRuntimeProviderRouter,
  isOpenCodeDiscoverProjectsEnabled,
  listProviderThreadsForThreadList,
  makeDiscoverProjectRegistryFixture,
  makeDiscoverProvider,
  makeProvider,
  mergeModelListResult,
  mergeSkillsAcrossProviders,
  mergeThreadListResult,
  opencodeModelListBudgetMs,
  opencodeThreadListBudgetMs,
  percentile,
  providerForRequest,
  providerModelsForModelList,
  readDiscoverProjectTtlMs,
  resetCatalogPushState,
  resetOpenCodeProjectDiscoverState,
  resetThreadListInFlightState,
  resolvePrimaryProvider,
  shouldWarmProviderInventory,
  stripRuntimeProviderFieldsForCodex,
  waitOneTick,
  withDiscoverEnv,
  withMutedConsole,
  withOpenCodeRuntimeEnabled,
} = require("./runtime-router.harness.js");

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

