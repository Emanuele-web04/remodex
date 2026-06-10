// FILE: runtime-router.harness.js

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

function waitOneTick() {
  return new Promise((resolve) => setImmediate(resolve));
}

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

function percentile(values, p) {
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil((p / 100) * sorted.length) - 1),
  );
  return sorted[index];
}

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
test.afterEach(() => {
  resetThreadListInFlightState();
});


module.exports = {
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
};
