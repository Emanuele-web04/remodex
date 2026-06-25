// FILE: runtime-catalog.test.js
// Purpose: Runtime catalog assembly, fingerprinting, and inventory warm paths.

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

