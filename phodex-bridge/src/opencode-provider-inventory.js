// FILE: opencode-provider-inventory.js
// Purpose: Connected-only OpenCode provider/model discovery from GET /provider (v1).
// Layer: Bridge runtime utility
// Exports: loadProviderListInventory, resolvePreferredProviders,
//          flattenConnectedProviderModels, refreshProviderInventory,
//          resolveProviderListPayload, buildInventoryMeta,
//          buildProviderLogoCatalog (for RP-BRAND-1 logo registry in catalog)
// Depends on: ./opencode-client (buildModelFromAny, resolveProviderListPayload pattern)

const { readString } = require("./normalize");

function resolveProviderListPayload(response) {
  if (!response || typeof response !== "object") return response;

  if (Array.isArray(response.providers) || Array.isArray(response.all)) {
    return response;
  }

  const nested = response.data;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    return nested;
  }

  return response;
}

function loadProviderListInventory(client) {
  if (!client || typeof client.provider?.list !== "function") {
    return Promise.reject(new Error("OpenCode client missing provider.list()"));
  }
  return client.provider.list().then((response) => {
    const payload = resolveProviderListPayload(response);
    if (!payload || typeof payload !== "object") {
      return { all: [], connected: [], default: {} };
    }
    return {
      all: Array.isArray(payload.all) ? payload.all : [],
      connected: Array.isArray(payload.connected) ? payload.connected : [],
      default: payload.default && typeof payload.default === "object" ? payload.default : {},
    };
  });
}

function isOpenCodeManagedProvider(provider) {
  const normalizedId = readString(provider?.id).trim().toLowerCase();
  const normalizedName = readString(provider?.name).trim().toLowerCase();
  const envVars = new Set(
    (Array.isArray(provider?.env) ? provider.env : [])
      .map((value) => readString(value).trim().toUpperCase())
      .filter(Boolean),
  );

  return (
    envVars.has("OPENCODE_API_KEY") ||
    normalizedId === "opencode" ||
    normalizedId.startsWith("opencode-") ||
    normalizedName.startsWith("opencode")
  );
}

function resolvePreferredProviders(inventory, options = {}) {
  const credentialProviderIDs = options.credentialProviderIDs || [];
  const consoleManagedProviders = options.consoleManagedProviders || [];

  const connected = new Set(
    Array.isArray(inventory?.connected) ? inventory.connected.map((id) => readString(id)) : [],
  );
  const all = Array.isArray(inventory?.all) ? inventory.all : [];
  const connectedProviders = all.filter((provider) => connected.has(readString(provider?.id)));

  if (connectedProviders.length === 0) {
    return [];
  }

  const credentialProviders = new Set(credentialProviderIDs.map((id) => readString(id)));
  const authenticatedConnectedProviders = connectedProviders.filter((provider) =>
    credentialProviders.has(readString(provider?.id)),
  );

  const consoleManaged = new Set(consoleManagedProviders.map((id) => readString(id)));
  const consoleManagedConnectedProviders = connectedProviders.filter((provider) =>
    consoleManaged.has(readString(provider?.id)),
  );

  const openCodeManagedConnectedProviders = connectedProviders.filter(isOpenCodeManagedProvider);

  const preferredProviderIDs = new Set(
    [
      ...authenticatedConnectedProviders,
      ...consoleManagedConnectedProviders,
      ...openCodeManagedConnectedProviders,
    ].map((provider) => readString(provider.id)),
  );

  if (preferredProviderIDs.size > 0) {
    const hasEnvConnected = connectedProviders.some(
      (provider) => readString(provider?.source) === "env",
    );
    const hasNonEnvConnected = connectedProviders.some(
      (provider) => readString(provider?.source) !== "env",
    );
    if (hasEnvConnected && hasNonEnvConnected) {
      return connectedProviders;
    }
    return connectedProviders.filter((provider) => preferredProviderIDs.has(readString(provider.id)));
  }

  const nonEnvironmentConnectedProviders = connectedProviders.filter(
    (provider) => readString(provider?.source) !== "env",
  );
  if (nonEnvironmentConnectedProviders.length > 0) {
    return nonEnvironmentConnectedProviders;
  }

  return connectedProviders;
}

function modelsForProvider(provider) {
  const models = provider?.models;
  if (Array.isArray(models)) return models;
  if (models && typeof models === "object") return Object.values(models);
  return [];
}

function flattenConnectedProviderModels(preferredProviders) {
  const { buildModelFromAny } = require("./opencode-client");
  return preferredProviders.flatMap((provider) => {
    const providerId = readString(provider.id || provider.providerId || provider.providerID);
    const displayName = readString(provider.name) || undefined;
    return modelsForProvider(provider).map((model) => buildModelFromAny(model, provider));
  });
}

function discoveryReasonCodeFromInventory(inventory) {
  if (!inventory || typeof inventory !== "object") {
    return "unknown";
  }
  if (!Array.isArray(inventory.connected)) {
    return "unknown";
  }
  if (inventory.connected.length === 0) {
    return "no_connected_providers";
  }
  return "ok";
}

function resolveInventoryReasonCode(inventory, models) {
  const base = discoveryReasonCodeFromInventory(inventory);
  if (base !== "ok") {
    return base;
  }
  if (!Array.isArray(models) || models.length === 0) {
    return "unknown";
  }
  return "ok";
}

function buildInventoryMeta({ inventory, models, fetchedAt, stale = false }) {
  const connectedProviderIds = Array.isArray(inventory?.connected)
    ? inventory.connected.map((id) => readString(id)).filter(Boolean)
    : [];
  const reasonCode = resolveInventoryReasonCode(inventory, models);
  const modelCountBeforeCap = Array.isArray(models) ? models.length : 0;

  return {
    reasonCode,
    connectedProviderIds,
    fetchedAt: fetchedAt || new Date().toISOString(),
    stale: Boolean(stale),
    modelCountBeforeCap,
    modelCountAfterCap: modelCountBeforeCap,
  };
}

function buildConnectedProviderSummaries(preferredProviders) {
  return preferredProviders.map((provider) => {
    const id = readString(provider.id);
    return {
      id,
      displayName: readString(provider.name) || id,
      modelCount: modelsForProvider(provider).length,
    };
  });
}

function canonicalProviderId(id) {
  return readString(id).trim().toLowerCase();
}

function formatProviderDisplayNameFromId(id) {
  const normalized = readString(id);
  if (!normalized) {
    return "Unknown";
  }
  return normalized
    .split(/[-_]/g)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

// 56 providers with committed Assets.xcassets imagesets (provider-{id}-logo).
// Includes 52 external providers + 4 core providers (codex, opencode, opencode-go, opencode-zen).
const COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS = new Set([
  "anthropic",
  "openai",
  "google",
  "xai",
  "groq",
  "deepseek",
  "mistral",
  "cohere",
  "perplexity",
  "together",
  "amazon",
  "azure",
  "openrouter",
  "github",
  "bedrock",
  "alibaba",
  "cerebras",
  "cloudflare",
  "databricks",
  "deepinfra",
  "fireworks",
  "gitlab",
  "google-vertex",
  "huggingface",
  "lmstudio",
  "minimax",
  "nebius",
  "novita",
  "ovhcloud",
  "scaleway",
  "zai",
  "moonshot",
  "xiaomi",
  "siliconflow",
  "tencent",
  "ollama",
  "stepfun",
  "poe",
  "venice",
  "nvidia",
  "digitalocean",
  "vultr",
  "sap-ai-core",
  "requesty",
  "friendli",
  "helicone",
  "kilo",
  "upstage",
  "inception",
  "inference",
  "llmgateway",
  "vercel",
  "codex",
  "opencode",
  "opencode-go",
  "opencode-zen",
]);

// Maps upstream OpenCode provider IDs to committed logo asset provider IDs.
const PROVIDER_LOGO_ID_ALIASES = {
  "amazon-bedrock": "bedrock",
  "github-copilot": "github",
  vertex: "google-vertex",
  "google-vertex-anthropic": "google-vertex",
  aws: "amazon",
  gemini: "google",
  zhipuai: "zai",
  "zhipuai-coding-plan": "zai",
  "zai-coding-plan": "zai",
  togetherai: "together",
  "fireworks-ai": "fireworks",
  "novita-ai": "novita",
  "perplexity-agent": "perplexity",
  "azure-cognitive-services": "azure",
  "github-models": "github",
  moonshotai: "moonshot",
  "moonshotai-cn": "moonshot",
  "xiaomi-token-plan-cn": "xiaomi",
  "xiaomi-token-plan-sgp": "xiaomi",
  "xiaomi-token-plan-ams": "xiaomi",
  "siliconflow-cn": "siliconflow",
  "minimax-cn": "minimax",
  "minimax-cn-coding-plan": "minimax",
  "tencent-coding-plan": "tencent",
  "tencent-tokenhub": "tencent",
  "alibaba-coding-plan-cn": "alibaba",
  zenmux: "opencode",
  nova: "amazon",
  v0: "vercel",
  "ollama-cloud": "ollama",
};

// Validate alias targets at module load time so a bad alias fails tests immediately.
for (const [alias, target] of Object.entries(PROVIDER_LOGO_ID_ALIASES)) {
  if (!COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.has(target)) {
    throw new Error(
      `Alias "${alias}" -> "${target}" but "${target}" not in COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS`,
    );
  }
}

// Variant suffixes that indicate a regional or plan variant of a parent brand.
// Sorted longest-first so compound suffixes (e.g. "-cn-coding-plan") strip before
// their component parts (e.g. "-cn").
const PROVIDER_LOGO_VARIANT_SUFFIXES = [
  "-cn-coding-plan",
  "-coding-plan",
  "-token-plan",
  "-workers-ai",
  "-ai-gateway",
  "-tokenhub",
  "-models",
  "-cloud",
  "-agent",
  "-sgp",
  "-ams",
  "-ai",
  "-cn",
];

function stripVariantSuffixes(id) {
  for (const suffix of PROVIDER_LOGO_VARIANT_SUFFIXES) {
    if (id.endsWith(suffix)) {
      return id.slice(0, -suffix.length);
    }
  }
  return id;
}

function resolveLogoProviderId(id, displayName) {
  const canonical = canonicalProviderId(id);
  if (!canonical) {
    return undefined;
  }
  if (canonical === "opencode-go") {
    return "opencode-go";
  }
  if (canonical === "opencode") {
    const normalized = readString(displayName).trim().toLowerCase();
    if (normalized === "opencode zen") {
      return "opencode-zen";
    }
    // Fall through to committed set check for standard "opencode"
  }

  const alias = PROVIDER_LOGO_ID_ALIASES[canonical];
  if (alias) {
    if (!COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.has(alias)) {
      return undefined;
    }
    return alias;
  }

  const stripped = stripVariantSuffixes(canonical);
  if (stripped !== canonical && COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.has(stripped)) {
    return stripped;
  }

  if (COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.has(canonical)) {
    return canonical;
  }
  return undefined;
}

function withLogoProviderId(entry) {
  const logoProviderId = resolveLogoProviderId(entry.id, entry.displayName);
  if (!logoProviderId) {
    return entry;
  }
  const logoAssetId = `provider-${logoProviderId}-logo`;
  return { ...entry, logoProviderId, logoAssetId };
}

function buildProviderLogoCatalog(entries) {
  const list = Array.isArray(entries) ? entries : [];
  return list.map((entry) => {
    const id = readString(entry.id);
    const name = readString(entry.displayName) || formatProviderDisplayNameFromId(id) || id || "Unknown";
    let logoAssetId = readString(entry.logoAssetId);
    if (!logoAssetId) {
      const lp = readString(entry.logoProviderId);
      if (lp) logoAssetId = `provider-${lp}-logo`;
    }
    const item = { id, name };
    if (logoAssetId) {
      item.logoAssetId = logoAssetId;
    }
    // fallbackSymbol?: string — reserved for RP-BRAND-5 (SF Symbols e.g. "globe"); additive only, omitted here
    return item;
  });
}

function buildProviderInventory(inventory, options = {}) {
  const credentialProviderIDs = Array.isArray(options.credentialProviderIDs)
    ? options.credentialProviderIDs
    : [];
  const connectedSet = new Set(
    (Array.isArray(inventory?.connected) ? inventory.connected : []).map((id) =>
      canonicalProviderId(id),
    ),
  );
  const authenticatedSet = new Set(
    credentialProviderIDs.map((id) => canonicalProviderId(id)).filter(Boolean),
  );
  const all = Array.isArray(inventory?.all) ? inventory.all : [];
  const byCanonical = new Map();

  for (const provider of all) {
    const id = readString(provider.id || provider.providerId || provider.providerID);
    if (!id) {
      continue;
    }
    const canonical = canonicalProviderId(id);
    byCanonical.set(
      canonical,
      withLogoProviderId({
        id,
        displayName: readString(provider.name) || formatProviderDisplayNameFromId(id),
        connectedOnServe: connectedSet.has(canonical),
        authenticated: authenticatedSet.has(canonical),
        modelCount: modelsForProvider(provider).length,
      }),
    );
  }

  for (const authId of credentialProviderIDs) {
    const id = readString(authId);
    if (!id) {
      continue;
    }
    const canonical = canonicalProviderId(id);
    if (byCanonical.has(canonical)) {
      const entry = byCanonical.get(canonical);
      entry.authenticated = true;
      continue;
    }
    byCanonical.set(
      canonical,
      withLogoProviderId({
        id,
        displayName: formatProviderDisplayNameFromId(id),
        connectedOnServe: connectedSet.has(canonical),
        authenticated: true,
        modelCount: null,
      }),
    );
  }

  const entries = [...byCanonical.values()];
  entries.sort((left, right) => {
    if (left.connectedOnServe !== right.connectedOnServe) {
      return left.connectedOnServe ? -1 : 1;
    }
    if (left.authenticated !== right.authenticated) {
      return left.authenticated ? -1 : 1;
    }
    return left.displayName.localeCompare(right.displayName);
  });
  return entries;
}

async function refreshProviderInventory(client, options = {}) {
  const force = options.force === true;
  const credentialProviderIDs = options.credentialProviderIDs || [];
  const consoleManagedProviders = options.consoleManagedProviders || [];
  const authDiscoveryReasonCode = readString(options.authDiscoveryReasonCode) || "ok";
  const providerInventoryPartial = options.providerInventoryPartial === true;
  const cached = options.cached || null;
  const cacheTtlMs = Number.isFinite(options.cacheTtlMs) ? options.cacheTtlMs : 60_000;
  const now = Date.now();

  if (
    !force &&
    cached?.inventory &&
    cached?.fetchedAt &&
    now - cached.fetchedAt < cacheTtlMs
  ) {
    const models = cached.models || [];
    const preferredCached = resolvePreferredProviders(cached.inventory, {
      credentialProviderIDs,
      consoleManagedProviders,
    });
    return {
      inventory: cached.inventory,
      models,
      meta: {
        ...(cached.meta || buildInventoryMeta({ inventory: cached.inventory, models })),
        stale: false,
      },
      connectedProviders:
        cached.connectedProviders || buildConnectedProviderSummaries(preferredCached),
      providerInventory:
        cached.providerInventory ||
        buildProviderInventory(cached.inventory, { credentialProviderIDs }),
      authDiscoveryReasonCode: cached.authDiscoveryReasonCode || authDiscoveryReasonCode,
      providerInventoryPartial:
        cached.providerInventoryPartial === true || providerInventoryPartial,
    };
  }

  const refreshStartedAt = Date.now();
  try {
    const inventory = await loadProviderListInventory(client);
    const preferred = resolvePreferredProviders(inventory, {
      credentialProviderIDs,
      consoleManagedProviders,
    });
    const models = flattenConnectedProviderModels(preferred);
    const reasonCode = resolveInventoryReasonCode(inventory, models);

    if (reasonCode === "no_connected_providers" || reasonCode === "unknown") {
      const meta = buildInventoryMeta({ inventory, models: [], fetchedAt: new Date().toISOString() });
      meta.refreshMs = Date.now() - refreshStartedAt;
      if (reasonCode === "unknown") {
        meta.reasonCode = "unknown";
      }
      return {
        inventory,
        models: [],
        meta,
        connectedProviders: [],
        providerInventory: buildProviderInventory(inventory, { credentialProviderIDs }),
        authDiscoveryReasonCode,
        providerInventoryPartial,
      };
    }

    const meta = buildInventoryMeta({
      inventory,
      models,
      fetchedAt: new Date().toISOString(),
    });
    meta.refreshMs = Date.now() - refreshStartedAt;
    meta.reasonCode = reasonCode;
    const providerInventory = buildProviderInventory(inventory, { credentialProviderIDs });
    console.log(
      JSON.stringify({
        event: "provider_inventory_built",
        connected: providerInventory.filter((entry) => entry.connectedOnServe).length,
        authenticated: providerInventory.filter((entry) => entry.authenticated).length,
        auth_only_synthetic: providerInventory.filter(
          (entry) => entry.authenticated && !entry.connectedOnServe,
        ).length,
        auth_provider_ids_count: credentialProviderIDs.length,
      }),
    );
    return {
      inventory,
      models,
      meta,
      connectedProviders: buildConnectedProviderSummaries(preferred),
      providerInventory,
      authDiscoveryReasonCode,
      providerInventoryPartial,
    };
  } catch (error) {
    if (cached?.inventory && Array.isArray(cached.models)) {
      return {
        inventory: cached.inventory,
        models: cached.models,
        meta: {
          ...(cached.meta || buildInventoryMeta({ inventory: cached.inventory, models: cached.models })),
          reasonCode: "provider_list_failed",
          stale: true,
          refreshMs: Date.now() - refreshStartedAt,
        },
        connectedProviders: cached.connectedProviders || [],
        providerInventory: cached.providerInventory || [],
        authDiscoveryReasonCode: cached.authDiscoveryReasonCode || authDiscoveryReasonCode,
        providerInventoryPartial:
          cached.providerInventoryPartial === true || providerInventoryPartial,
        error,
      };
    }

    return {
      inventory: { all: [], connected: [], default: {} },
      models: [],
      meta: {
        reasonCode: "provider_list_failed",
        connectedProviderIds: [],
        fetchedAt: new Date().toISOString(),
        stale: false,
        modelCountBeforeCap: 0,
        modelCountAfterCap: 0,
        refreshMs: Date.now() - refreshStartedAt,
      },
      connectedProviders: [],
      providerInventory: [],
      authDiscoveryReasonCode,
      providerInventoryPartial: true,
      error,
    };
  }
}

module.exports = {
  loadProviderListInventory,
  resolvePreferredProviders,
  flattenConnectedProviderModels,
  refreshProviderInventory,
  buildInventoryMeta,
  buildConnectedProviderSummaries,
  buildProviderInventory,
  canonicalProviderId,
  discoveryReasonCodeFromInventory,
  resolveInventoryReasonCode,
  isOpenCodeManagedProvider,
  resolveProviderListPayload,
  resolveLogoProviderId,
  buildProviderLogoCatalog,
  stripVariantSuffixes,
  COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS,
  PROVIDER_LOGO_ID_ALIASES,
  PROVIDER_LOGO_VARIANT_SUFFIXES,
};