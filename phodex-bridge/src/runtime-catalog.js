// FILE: runtime-catalog.js
// Purpose: Runtime catalog assembly, fingerprinting, and OpenCode project discover side effects.
// Layer: Bridge runtime routing
// Exports: catalog builders, fingerprint helpers, discover hooks, reset helpers
// Depends on: ./opencode-models, ./opencode-provider-inventory, ./provider-capabilities, ./opencode-runtime-status

const { createHash } = require("crypto");

const { resolveOpenCodeHandoffEnabled } = require("./bridge-operator-profile");
const { readString } = require("./normalize");
const { projectDiscoverFromOpenCode } = require("./opencode-project-discover-handler");
const {
  CODEX_CAPABILITIES,
  resolveModelCapabilities,
  resolveOpenCodeCatalogCapabilities,
} = require("./provider-capabilities");
const {
  DEFAULT_OPENCODE_MODEL,
  OPENCODE_PROVIDER_ID,
  buildOpenCodeModelOption,
} = require("./opencode-models");
const { resolveDiscoverProjectsEnabled } = require("./opencode-discovery-policy");
const { isOpenCodeRuntimeDisabled } = require("./opencode-runtime-policy");
const { START_TIMEOUT_MS, HEALTH_TIMEOUT_MS } = require("./opencode-server");
const { buildOpenCodeRuntimeStatus } = require("./opencode-runtime-status");
const { buildProviderLogoCatalog } = require("./opencode-provider-inventory");

const RUNTIME_CATALOG_AGENT_BUDGET_MS = 2_000;
const DEFAULT_OPENCODE_DISCOVER_PROJECT_TTL_MS = 120_000;
const DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS =
  START_TIMEOUT_MS + HEALTH_TIMEOUT_MS + 5_000;

let lastOpenCodeCatalogAgents = [];
let lastEmittedCatalogFingerprint = null;
let lastOpenCodeProjectDiscoverAt = 0;
let openCodeProjectDiscoverInFlight = false;

function shortHash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 8);
}

function computeCatalogFingerprint(runtimeStatus) {
  const inventory = runtimeStatus?.providerInventory ?? [];
  return [
    runtimeStatus?.providerInventoryPartial ? "partial:1" : "partial:0",
    runtimeStatus?.authDiscoveryReasonCode ?? "unknown",
    ...inventory
      .map((provider) => {
        const connectedOnServe = provider.connectedOnServe ?? provider.connected;
        return `${provider.id}:${provider.authenticated ? 1 : 0}:${connectedOnServe ? 1 : 0}`;
      })
      .sort(),
  ].join("|");
}

function computeCatalogRevision(runtimeStatus) {
  return `fp:${shortHash(computeCatalogFingerprint(runtimeStatus))}`;
}

function countAuthenticated(inventory) {
  if (!Array.isArray(inventory)) {
    return 0;
  }
  return inventory.filter((provider) => provider?.authenticated === true).length;
}

function isCatalogWarmInventoryEnabled(env = process.env) {
  const raw = readString(env?.REMODEX_CATALOG_WARM_INVENTORY);
  if (!raw) {
    return true;
  }
  const normalized = raw.toLowerCase();
  return normalized !== "0" && normalized !== "false";
}

function shouldWarmProviderInventory(runtimeStatus, env = process.env) {
  if (!isCatalogWarmInventoryEnabled(env)) {
    return false;
  }
  const inventory = runtimeStatus?.providerInventory ?? [];
  if (!Array.isArray(inventory) || inventory.length === 0) {
    return true;
  }
  if (runtimeStatus?.providerInventoryPartial === true) {
    return true;
  }
  if (readString(runtimeStatus?.authDiscoveryReasonCode) !== "ok") {
    return true;
  }
  return false;
}

function maybeEmitCatalogUpdated(runtimeStatus, sendRuntimeMessage) {
  if (typeof sendRuntimeMessage !== "function") {
    return false;
  }
  const fingerprint = computeCatalogFingerprint(runtimeStatus);
  if (fingerprint === lastEmittedCatalogFingerprint) {
    return false;
  }
  lastEmittedCatalogFingerprint = fingerprint;
  const catalogRevision = computeCatalogRevision(runtimeStatus);
  sendRuntimeMessage(
    JSON.stringify({
      method: "runtime/catalog/updated",
      params: {
        catalogRevision,
        providerInventoryPartial: runtimeStatus?.providerInventoryPartial ?? false,
      },
    }),
  );
  return true;
}

function resetCatalogPushState() {
  lastEmittedCatalogFingerprint = null;
}

function resetOpenCodeProjectDiscoverState() {
  lastOpenCodeProjectDiscoverAt = 0;
  openCodeProjectDiscoverInFlight = false;
}

function readDiscoverProjectTtlMs(env = process.env) {
  const numeric = Number(readString(env?.REMODEX_OPENCODE_DISCOVER_PROJECT_TTL_MS));
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return DEFAULT_OPENCODE_DISCOVER_PROJECT_TTL_MS;
  }
  return Math.floor(numeric);
}

function isOpenCodeDiscoverProjectsEnabled(env = process.env, params = {}) {
  return resolveDiscoverProjectsEnabled(env, params);
}

function maybeDiscoverOpenCodeProjects({
  opencodeProvider,
  projectRegistry,
  homeDir,
  env = process.env,
  params = {},
  logPrefix = "[remodex]",
} = {}) {
  if (!resolveDiscoverProjectsEnabled(env, params)) {
    return false;
  }
  if (isOpenCodeRuntimeDisabled(env)) {
    return false;
  }
  if (!opencodeProvider || !projectRegistry) {
    return false;
  }

  const ttlMs = readDiscoverProjectTtlMs(env);
  const now = Date.now();
  if (now - lastOpenCodeProjectDiscoverAt < ttlMs) {
    return false;
  }
  if (openCodeProjectDiscoverInFlight) {
    return false;
  }

  lastOpenCodeProjectDiscoverAt = now;
  openCodeProjectDiscoverInFlight = true;

  console.log(
    JSON.stringify({
      event: "opencode_discover_on_list",
      ttlMs,
    }),
  );

  void projectDiscoverFromOpenCode({}, { homeDir, opencodeProvider, projectRegistry })
    .catch((error) => {
      console.warn(
        `${logPrefix} OpenCode project discover on thread/list failed: ${error?.message || error}`,
      );
    })
    .finally(() => {
      openCodeProjectDiscoverInFlight = false;
    });

  return true;
}

function readModelListBudgetMs(env, key, fallbackMs) {
  const numeric = Number(readString(env?.[key]));
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return fallbackMs;
  }
  return Math.min(Math.floor(numeric), 60_000);
}

function opencodeModelListBudgetMs(env = process.env) {
  return readModelListBudgetMs(
    env,
    "REMODEX_MODEL_LIST_OPENCODE_BUDGET_MS",
    DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS,
  );
}

function withModelListBudget(promise, budgetMs, fallback) {
  let timeoutId;
  const budget = new Promise((resolve) => {
    timeoutId = setTimeout(() => resolve(fallback), budgetMs);
  });

  return Promise.race([promise, budget]).finally(() => {
    clearTimeout(timeoutId);
  });
}

function buildCatalogOpenCodePlaceholderModels() {
  const model = buildOpenCodeModelOption(DEFAULT_OPENCODE_MODEL, { isDefault: true });
  if (!model) {
    return [];
  }
  return [
    {
      ...model,
      capabilities: resolveModelCapabilities(OPENCODE_PROVIDER_ID, model),
    },
  ];
}

function readOpenCodeCatalogAvailability(opencodeProvider) {
  if (!opencodeProvider || typeof opencodeProvider.getCatalogAvailability !== "function") {
    return null;
  }
  return opencodeProvider.getCatalogAvailability();
}

function catalogOpenCodeSnapshotForModelList(providers, env) {
  if (isOpenCodeRuntimeDisabled(env)) {
    return null;
  }
  const opencodeProvider = providers.find((provider) => provider.id === OPENCODE_PROVIDER_ID);
  if (!opencodeProvider) {
    return null;
  }
  const availability = readOpenCodeCatalogAvailability(opencodeProvider);
  return {
    id: OPENCODE_PROVIDER_ID,
    enabled: !availability?.unavailableReason,
  };
}

function isCodexRuntimeConnected(getCodexLaunchState) {
  if (typeof getCodexLaunchState !== "function") {
    return true;
  }
  const state = getCodexLaunchState();
  return state !== "degraded" && state !== "error";
}

async function buildCatalogOpenCodeRuntime(providers, env, sendRuntimeMessage = null) {
  if (isOpenCodeRuntimeDisabled(env)) {
    return null;
  }

  const opencodeProvider = providers.find((p) => p.id === OPENCODE_PROVIDER_ID);
  const hasCommand = readString(env.REMODEX_OPENCODE_COMMAND) || "opencode";
  let agents = [];
  let unavailableReason = null;
  let reasonCode = null;

  const serverAvailability = readOpenCodeCatalogAvailability(opencodeProvider);
  let runtimeStatus =
    typeof opencodeProvider?.getRuntimeStatus === "function"
      ? opencodeProvider.getRuntimeStatus(env)
      : buildOpenCodeRuntimeStatus({
          enabled: false,
          command: hasCommand,
          handoffEnvEnabled: resolveOpenCodeHandoffEnabled(env),
        });

  const inventoryBefore = Array.isArray(runtimeStatus?.providerInventory)
    ? runtimeStatus.providerInventory
    : [];
  if (opencodeProvider?.listModels && shouldWarmProviderInventory(runtimeStatus, env)) {
    const warmResult = await withModelListBudget(
      opencodeProvider.listModels({ refreshProviders: true }),
      opencodeModelListBudgetMs(env),
      null,
    );
    runtimeStatus =
      typeof opencodeProvider.getRuntimeStatus === "function"
        ? opencodeProvider.getRuntimeStatus(env)
        : runtimeStatus;
    const inventoryAfter = Array.isArray(runtimeStatus?.providerInventory)
      ? runtimeStatus.providerInventory
      : [];
    console.log(
      JSON.stringify({
        event: "runtime_catalog_warm_inventory",
        authenticatedBefore: countAuthenticated(inventoryBefore),
        authenticatedAfter: countAuthenticated(inventoryAfter),
        timedOut: warmResult === null,
      }),
    );
  }

  const providersForLogos = Array.isArray(runtimeStatus?.providerInventory)
    ? runtimeStatus.providerInventory
    : [];
  const logoProviders = buildProviderLogoCatalog(providersForLogos);
  const catalogRevision = computeCatalogRevision(runtimeStatus);

  if (serverAvailability?.unavailableReason) {
    maybeEmitCatalogUpdated(runtimeStatus, sendRuntimeMessage);
    return {
      id: OPENCODE_PROVIDER_ID,
      label: "OpenCode",
      enabled: false,
      showsBetaLabel: true,
      unavailableReason: serverAvailability.unavailableReason,
      reasonCode: serverAvailability.reasonCode || "opencode_server_failed",
      agents: [],
      capabilities: resolveOpenCodeCatalogCapabilities(env),
      opencode: {
        ...runtimeStatus,
        enabled: false,
        lastError: serverAvailability.unavailableReason,
        version: readString(serverAvailability.version) || runtimeStatus.version,
        catalogRevision,
        providers: logoProviders,
      },
    };
  }

  if (opencodeProvider) {
    try {
      const raw = await withModelListBudget(
        opencodeProvider.listAgents(),
        RUNTIME_CATALOG_AGENT_BUDGET_MS,
        null,
      );
      const mapped = (raw || []).map((a) => ({
        id: readString(a?.id || a),
        label: readString(a?.label || a?.name || a?.displayName || a?.id || a),
      }));
      if (mapped.length > 0) {
        lastOpenCodeCatalogAgents = mapped;
        agents = mapped;
      } else if (lastOpenCodeCatalogAgents.length > 0) {
        console.log(JSON.stringify({ event: "runtime_catalog_agents_stale" }));
        agents = lastOpenCodeCatalogAgents;
      } else if (
        typeof opencodeProvider.getLastCatalogAgents === "function" &&
        opencodeProvider.getLastCatalogAgents().length > 0
      ) {
        console.log(JSON.stringify({ event: "runtime_catalog_agents_stale" }));
        agents = opencodeProvider.getLastCatalogAgents().map((a) => ({
          id: readString(a?.id || a),
          label: readString(a?.label || a?.name || a?.displayName || a?.id || a),
        }));
        lastOpenCodeCatalogAgents = agents;
      } else {
        agents = [];
      }
    } catch {
      if (lastOpenCodeCatalogAgents.length > 0) {
        console.log(JSON.stringify({ event: "runtime_catalog_agents_stale" }));
        agents = lastOpenCodeCatalogAgents;
      } else {
        agents = [];
        unavailableReason = "OpenCode agents could not be listed";
      }
    }
  } else if (!hasCommand) {
    unavailableReason = "OpenCode command is not configured on this Mac";
  }

  const enabled = Boolean(opencodeProvider) && !unavailableReason && Boolean(hasCommand);
  if (!enabled && unavailableReason) {
    reasonCode = "opencode_agents_unavailable";
  } else if (!enabled) {
    reasonCode = "opencode_not_enabled";
  }

  maybeEmitCatalogUpdated(runtimeStatus, sendRuntimeMessage);

  return {
    id: OPENCODE_PROVIDER_ID,
    label: "OpenCode",
    enabled,
    showsBetaLabel: true,
    unavailableReason: enabled
      ? null
      : unavailableReason || "OpenCode is not available on this Mac",
    reasonCode,
    agents,
    capabilities: resolveOpenCodeCatalogCapabilities(env),
    opencode: {
      ...runtimeStatus,
      enabled: enabled && runtimeStatus.enabled !== false,
      lastError: enabled ? null : runtimeStatus.lastError || unavailableReason,
      connectedProviders: runtimeStatus.connectedProviders || null,
      providerDiscoveryReasonCode: runtimeStatus.providerDiscoveryReasonCode || null,
      providerInventory: runtimeStatus.providerInventory || null,
      authDiscoveryReasonCode: runtimeStatus.authDiscoveryReasonCode || null,
      providerInventoryPartial: runtimeStatus.providerInventoryPartial ?? null,
      catalogRevision,
      providers: logoProviders,
    },
  };
}

async function buildRuntimeCatalog(providers, env, sendRuntimeMessage = null, getCodexLaunchState = null) {
  const codexConnected = isCodexRuntimeConnected(getCodexLaunchState);
  const runtimes = [
    {
      id: "codex",
      label: "Codex",
      enabled: codexConnected,
      codexAvailable: codexConnected,
      showsBetaLabel: false,
      unavailableReason: codexConnected
        ? null
        : "Codex CLI is not available on this Mac. OpenCode is carrying the bridge.",
      reasonCode: codexConnected ? null : "codex_degraded",
      agents: [],
      capabilities: { ...CODEX_CAPABILITIES },
    },
  ];

  const opencodeRuntime = await buildCatalogOpenCodeRuntime(providers, env, sendRuntimeMessage);
  if (opencodeRuntime) {
    runtimes.push(opencodeRuntime);
  }

  return { runtimes };
}

module.exports = {
  buildCatalogOpenCodePlaceholderModels,
  buildCatalogOpenCodeRuntime,
  buildRuntimeCatalog,
  catalogOpenCodeSnapshotForModelList,
  computeCatalogFingerprint,
  computeCatalogRevision,
  countAuthenticated,
  isOpenCodeDiscoverProjectsEnabled,
  maybeDiscoverOpenCodeProjects,
  maybeEmitCatalogUpdated,
  readDiscoverProjectTtlMs,
  readOpenCodeCatalogAvailability,
  resetCatalogPushState,
  resetOpenCodeProjectDiscoverState,
  shouldWarmProviderInventory,
  shortHash,
};
