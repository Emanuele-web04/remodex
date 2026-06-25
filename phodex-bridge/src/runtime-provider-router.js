// FILE: runtime-provider-router.js
// Purpose: Routes provider-aware Remodex RPCs between Codex app-server and local provider harnesses.
// Layer: Bridge runtime routing
// Exports: createRuntimeProviderRouter plus merge helpers used by tests
// Depends on: ./opencode-models, ./opencode-provider, ./provider-capabilities, ./thread-ownership-store, ./runtime-catalog

const os = require("os");

const { readString, resolvedParam } = require("./normalize");
const { handleOpenCodeProjectDiscoverRequest } = require("./opencode-project-discover-handler");
const { handleOpenCodeSessionUsageRequest } = require("./opencode-session-usage-handler");
const { createOpenCodeProvider } = require("./opencode-provider");
const { safeParseJSON } = require("./safe-json");
const {
  CODEX_PROVIDER_ID,
  OPENCODE_PROVIDER_ID,
  capOpenCodeModelsForMobileList,
  isDiscoveredExternalThreadId,
  isOpenCodeProvider,
  readModelProvider,
  readThreadId,
} = require("./opencode-models");
const { isOpenCodeRuntimeDisabled, isOpenCodeRuntimeEnabled } = require("./opencode-runtime-policy");
const { resolveDiscoverProjectsEnabled } = require("./opencode-discovery-policy");
const { START_TIMEOUT_MS, HEALTH_TIMEOUT_MS } = require("./opencode-server");
const {
  resolveModelCapabilities,
} = require("./provider-capabilities");
const { createThreadOwnershipStore } = require("./thread-ownership-store");
const {
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
} = require("./runtime-catalog");
const {
  PROVIDER_FIELD_KEYS,
  firstArrayKey,
  mergeModelListResult,
  mergeThreadListResult,
  stripRuntimeProviderFieldsForCodex,
} = require("./runtime-merge");

const ROUTABLE_THREAD_METHODS = new Set([
  "thread/start",
  "thread/resume",
  "thread/read",
  "thread/turns/list",
  "thread/name/set",
  "thread/archive",
  "thread/unarchive",
  "thread/fork",
  "turn/start",
  "turn/interrupt",
]);

function createRuntimeProviderRouter({
  sendCodexRequest,
  sendApplicationResponse,
  sendRuntimeMessage,
  providers = null,
  projectRegistry = null,
  ownershipStore = null,
  homeDir = null,
  logPrefix = "[remodex]",
  getCodexLaunchState = null,
} = {}) {
  const resolvedHomeDir = readString(homeDir) || os.homedir();
  const threadOwnership = ownershipStore || createThreadOwnershipStore();
  const runtimeProviders = resolveProviders({
    providers,
    env: process.env,
    createOpenCodeProvider,
    sendRuntimeMessage,
    sendApplicationResponse,
    projectRegistry,
    ownershipStore: threadOwnership,
    logPrefix,
  });

  const opencodeProvider = runtimeProviders.find((provider) => provider.id === OPENCODE_PROVIDER_ID);
  const skipOpenCodeWarmup =
    readString(process.env.REMODEX_TEST) === "1" || readString(process.env.NODE_ENV) === "test";
  if (opencodeProvider && typeof opencodeProvider.warmup === "function" && !skipOpenCodeWarmup) {
    void opencodeProvider.warmup();
  }

  console.log(
    JSON.stringify({
      event: "runtime_provider_router_init",
      providers: runtimeProviders.map((p) => p && p.id).filter(Boolean),
      opencodeWarmupSkipped: skipOpenCodeWarmup,
    }),
  );

  function handleApplicationMessage(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return false;
    }

    const responseProvider = runtimeProviders.find(
      (provider) =>
        parsed.id != null &&
        !parsed.method &&
        typeof provider.handleApplicationResponse === "function" &&
        provider.handleApplicationResponse(parsed),
    );
    if (responseProvider) {
      return true;
    }

    const method = readString(parsed.method);
    if (!method) {
      return false;
    }

    if (method === "model/list") {
      respondAsync(parsed, async () => {
        const params = parsed.params || {};
        const forceProviders = params.refreshProviders === true;
        const fullList = params.full === true;
        const catalogOpenCode = catalogOpenCodeSnapshotForModelList(runtimeProviders, process.env);
        const [codexResult, providerListResult] = await Promise.all([
          withModelListBudget(
            resolveCodexLegPromise(
              getCodexLaunchState,
              () => sendCodexRequest("model/list", params),
              { items: [] },
            ).catch((error) => {
              console.warn(
                `${logPrefix} Codex model/list failed: ${error?.message || error}`,
              );
              return { items: [] };
            }),
            CODEX_MODEL_LIST_BUDGET_MS,
            { items: [] },
          ),
          listProviderModelsForModelList(runtimeProviders, logPrefix, {
            force: forceProviders,
            sendRuntimeMessage,
            full: fullList,
          }),
        ]);
        const { models: providerModels, opencodeMeta } = providerListResult;
        const capped = fullList
          ? providerModels
          : providerModelsForModelList(
            providerModels,
            catalogOpenCode,
            opencodeMeta,
          );
        if (opencodeMeta) {
          const opencodeOnly = providerModels.filter(
            (model) => readModelProvider(model) === OPENCODE_PROVIDER_ID,
          );
          opencodeMeta.modelCountBeforeCap = opencodeOnly.length;
          opencodeMeta.modelCountAfterCap = (fullList ? opencodeOnly : capped.filter(
            (model) => readModelProvider(model) === OPENCODE_PROVIDER_ID,
          )).length;
          opencodeMeta.truncated = !fullList && opencodeMeta.modelCountAfterCap < opencodeMeta.modelCountBeforeCap;
          opencodeMeta.full = fullList;
        }
        return mergeModelListResult(codexResult, capped, { opencode: opencodeMeta });
      });
      return true;
    }

    if (method === "thread/list") {
      respondAsync(parsed, async () => {
        const startedAt = Date.now();
        const threadListParams = parsed.params || {};
        const shouldIncludeProviders = !hasCursor(threadListParams);
        const codexLegPromise = (async () => {
          const legStarted = Date.now();
          const result = await withThreadListBudget(
            resolveCodexLegPromise(
              getCodexLaunchState,
              () => sendCodexRequest("thread/list", threadListParams),
              { data: [] },
            ).catch((error) => {
              console.log(
                JSON.stringify({
                  event: "thread_list_codex_failed",
                  message: readString(error?.message) || "Codex thread/list failed",
                }),
              );
              return { data: [] };
            }),
            codexThreadListBudgetMs(process.env),
            { data: [] },
            { leg: "codex" },
          );
          return { result, ms: Date.now() - legStarted };
        })();
        const opencodeLegPromise = shouldIncludeProviders
          ? (async () => {
              const legStarted = Date.now();
              const result = await listProviderThreadsForThreadList(
                runtimeProviders,
                threadListParams,
                logPrefix,
              );
              return { result, ms: Date.now() - legStarted };
            })()
          : Promise.resolve({ result: [], ms: 0 });
        const [codexLeg, opencodeLeg] = await Promise.all([
          codexLegPromise,
          opencodeLegPromise,
        ]);
        const codexResult = codexLeg.result;
        const providerLeg = opencodeLeg.result;
        const providerThreads = Array.isArray(providerLeg?.threads)
          ? providerLeg.threads
          : Array.isArray(providerLeg)
            ? providerLeg
            : [];
        const providerMeta =
          providerLeg && typeof providerLeg === "object" && !Array.isArray(providerLeg)
            ? providerLeg.meta
            : null;
        const codexMs = codexLeg.ms;
        const opencodeMs = opencodeLeg.ms;
        registerThreadProjects(projectRegistry, threadsFromListResult(codexResult), {
          source: "codex-thread-list",
          provider: CODEX_PROVIDER_ID,
        });
        registerThreadProjects(projectRegistry, providerThreads, {
          source: "provider-thread-list",
        });
        const merged = mergeThreadListResult(codexResult, providerThreads, { meta: providerMeta });
        maybeDiscoverOpenCodeProjects({
          opencodeProvider,
          projectRegistry,
          homeDir: resolvedHomeDir,
          env: process.env,
          params: threadListParams,
          logPrefix,
        });
        const wallMs = Date.now() - startedAt;
        const discoverProjectsEnabled = resolveDiscoverProjectsEnabled(
          process.env,
          threadListParams,
        );
        console.log(JSON.stringify({ event: "thread_list_codex_ms", ms: codexMs }));
        console.log(JSON.stringify({ event: "thread_list_opencode_ms", ms: opencodeMs }));
        console.log(
          JSON.stringify({
            event: "thread_list_wall_ms",
            wallMs,
            codexMs,
            opencodeMs,
            discoverProjectsEnabled,
          }),
        );
        return merged;
      });
      return true;
    }

    if (method === "runtime/catalog") {
      respondAsync(parsed, async () =>
        buildRuntimeCatalog(runtimeProviders, process.env, sendRuntimeMessage, getCodexLaunchState));
      return true;
    }

    if (method === "command/list") {
      respondAsync(parsed, async () => {
        const directory = readString(parsed.params?.directory || parsed.params?.cwd);
        if (opencodeProvider && typeof opencodeProvider.listCommands === "function") {
          // thin wrap (shape {commands: [...] of {token,title,description}}); full builtins+derived union done in provider/client per RP-CMD-1
          return { commands: await opencodeProvider.listCommands(directory) };
        }
        return { commands: [] };
      });
      return true;
    }

    if (method === "command/execute") {
      respondAsync(parsed, async () => {
        const ownershipMismatch = resolveThreadOwnershipMismatch(parsed, threadOwnership);
        if (ownershipMismatch) {
          throw ownershipMismatch;
        }
        if (!opencodeProvider || typeof opencodeProvider.commandExecute !== "function") {
          return { ok: false, errorCode: "opencode_unavailable" };
        }
        rememberProjectFromRequest(projectRegistry, parsed, {
          source: "command-execute",
          provider: OPENCODE_PROVIDER_ID,
        });
        return opencodeProvider.commandExecute(parsed);
      });
      return true;
    }

    if (method === "skills/list") {
      respondAsync(parsed, async () =>
        mergeSkillsListResult(parsed.params || {}, runtimeProviders, sendCodexRequest, getCodexLaunchState));
      return true;
    }

    if (method === "permission/reply") {
      respondAsync(parsed, async () => {
        const ownershipMismatch = resolveThreadOwnershipMismatch(parsed, threadOwnership);
        if (ownershipMismatch) {
          throw ownershipMismatch;
        }
        if (!opencodeProvider || typeof opencodeProvider.handleRequest !== "function") {
          const error = new Error("OpenCode provider unavailable for permission/reply");
          error.errorCode = "opencode_unavailable";
          throw error;
        }
        return opencodeProvider.handleRequest(parsed);
      });
      return true;
    }

    if (!ROUTABLE_THREAD_METHODS.has(method)) {
      return false;
    }

    if (method === "turn/start") {
      logBridgeTurnStartAudit(parsed, threadOwnership);
    }

    const ownershipMismatch = resolveThreadOwnershipMismatch(parsed, threadOwnership);
    if (ownershipMismatch) {
      logBridgeOwnershipMismatch(parsed, threadOwnership, ownershipMismatch);
      respondAsync(parsed, async () => {
        throw ownershipMismatch;
      });
      return true;
    }

    const provider = providerForRequest(parsed, runtimeProviders, threadOwnership);
    if (!provider) {
      return false;
    }

    rememberProjectFromRequest(projectRegistry, parsed, {
      source: "provider-request",
      provider: provider.id,
    });
    respondAsync(parsed, () => provider.handleRequest(parsed));
    return true;
  }

  function respondAsync(request, resolveResult) {
    Promise.resolve()
      .then(resolveResult)
      .then((result) => {
        if (request.id != null) {
          sendApplicationResponse(
            JSON.stringify({
              id: request.id,
              result,
            }),
          );
        }
      })
      .catch((error) => {
        if (request.id != null) {
          sendApplicationResponse(
            createJsonRpcErrorResponse(
              request.id,
              error,
              error?.errorCode || "runtime_provider_failed",
            ),
          );
        }
      });
  }

  function handleAuxiliaryRequest(rawMessage) {
    if (
      handleOpenCodeSessionUsageRequest(rawMessage, sendApplicationResponse, {
        ownershipStore: threadOwnership,
        opencodeProvider,
      })
    ) {
      return true;
    }
    if (
      handleOpenCodeProjectDiscoverRequest(rawMessage, sendApplicationResponse, {
        homeDir: resolvedHomeDir,
        projectRegistry,
        opencodeProvider,
      })
    ) {
      return true;
    }
    return false;
  }

  return {
    handleApplicationMessage,
    handleAuxiliaryRequest,
    providers: runtimeProviders,
    shutdown() {
      for (const provider of runtimeProviders) {
        provider.shutdown?.();
      }
    },
  };
}

async function listProviderModels(providers) {
  const settled = await Promise.allSettled(providers.map((provider) => provider.listModels()));
  return settled.flatMap((result) => (result.status === "fulfilled" ? result.value : []));
}

const CODEX_MODEL_LIST_BUDGET_MS = 3_000;
const MODEL_LIST_PROVIDER_BUDGET_MS = 3_000;
const CODEX_THREAD_LIST_BUDGET_MS = 10_000;
const THREAD_LIST_PROVIDER_BUDGET_MS = 10_000;
const DEFAULT_OPENCODE_THREAD_LIST_BUDGET_MS = 10_000;
const THREAD_LIST_BUDGET_CEILING_MS = 11_000;
const threadListInFlightByProvider = new Map();
// Cold `opencode serve` can take START_TIMEOUT_MS + health polling; 8s was too short on device.
const DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS =
  START_TIMEOUT_MS + HEALTH_TIMEOUT_MS + 5_000;
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

function readThreadListBudgetMs(env, key, fallbackMs) {
  const numeric = Number(readString(env?.[key]));
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return fallbackMs;
  }
  return Math.min(Math.floor(numeric), THREAD_LIST_BUDGET_CEILING_MS);
}

function codexThreadListBudgetMs(env = process.env) {
  return readThreadListBudgetMs(
    env,
    "REMODEX_THREAD_LIST_CODEX_BUDGET_MS",
    CODEX_THREAD_LIST_BUDGET_MS,
  );
}

function opencodeThreadListBudgetMs(env = process.env) {
  return readThreadListBudgetMs(
    env,
    "REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS",
    DEFAULT_OPENCODE_THREAD_LIST_BUDGET_MS,
  );
}

// Caps one leg of model/list so Codex and OpenCode discovery stay within mobile budgets.
function withModelListBudget(promise, budgetMs, fallback) {
  let timeoutId;
  const budget = new Promise((resolve) => {
    timeoutId = setTimeout(() => resolve(fallback), budgetMs);
  });

  return Promise.race([promise, budget]).finally(() => {
    clearTimeout(timeoutId);
  });
}

// Caps one leg of thread/list; logs abandonment when the budget fallback wins the race.
function withThreadListBudget(promise, budgetMs, fallback, options = {}) {
  let timeoutId;
  let budgetWon = false;
  const budget = new Promise((resolve) => {
    timeoutId = setTimeout(() => {
      budgetWon = true;
      console.log(
        JSON.stringify({
          event: "thread_list_leg_abandoned",
          leg: readString(options.leg) || null,
          budgetMs,
        }),
      );
      resolve(fallback);
    }, budgetMs);
  });

  return Promise.race([promise, budget]).finally(() => {
    clearTimeout(timeoutId);
    void budgetWon;
  });
}

// OpenCode model discovery can take several seconds; never block Codex on it.
async function listProviderModelsForModelList(
  providers,
  logPrefix = "[remodex]",
  options = {},
) {
  const env = options.env || process.env;
  const force = options.force === true;
  let opencodeMeta = null;
  const settled = await Promise.allSettled(
    providers.map((provider) => {
      const budgetMs =
        provider.id === OPENCODE_PROVIDER_ID
          ? opencodeModelListBudgetMs(env)
          : MODEL_LIST_PROVIDER_BUDGET_MS;
      const listPromise =
        provider.id === OPENCODE_PROVIDER_ID && force
          ? provider.listModels({ force: true, refreshProviders: true })
          : provider.listModels();
      return withModelListBudget(
        listPromise.catch((error) => {
          console.warn(
            `${logPrefix} ${provider.id} model/list failed: ${error?.message || error}`,
          );
          return provider.id === OPENCODE_PROVIDER_ID
            ? {
                models: [],
                meta: {
                  reasonCode: "provider_list_failed",
                  connectedProviderIds: [],
                  fetchedAt: new Date().toISOString(),
                  stale: false,
                  modelCountBeforeCap: 0,
                  modelCountAfterCap: 0,
                },
              }
            : [];
        }),
        budgetMs,
        provider.id === OPENCODE_PROVIDER_ID
          ? {
              models: [],
              meta: {
                reasonCode: "provider_list_failed",
                connectedProviderIds: [],
                fetchedAt: new Date().toISOString(),
                stale: false,
                modelCountBeforeCap: 0,
                modelCountAfterCap: 0,
              },
            }
          : [],
      );
    }),
  );

  const models = [];
  for (const result of settled) {
    if (result.status !== "fulfilled") {
      continue;
    }
    const value = result.value;
    if (value && typeof value === "object" && Array.isArray(value.models)) {
      if (value.meta) {
        opencodeMeta = value.meta;
      }
      models.push(...value.models);
      continue;
    }
    if (Array.isArray(value)) {
      models.push(...value);
    }
  }

  if (!opencodeMeta) {
    const opencodeProvider = providers.find((provider) => provider.id === OPENCODE_PROVIDER_ID);
    if (opencodeProvider && typeof opencodeProvider.getLastModelListMeta === "function") {
      opencodeMeta = opencodeProvider.getLastModelListMeta();
    }
  }

  const opencodeProvider = providers.find((provider) => provider.id === OPENCODE_PROVIDER_ID);
  if (opencodeProvider && typeof opencodeProvider.getRuntimeStatus === "function") {
    const runtimeStatus = opencodeProvider.getRuntimeStatus(env);
    maybeEmitCatalogUpdated(runtimeStatus, options.sendRuntimeMessage);
  }

  return { models, opencodeMeta };
}

function resetThreadListInFlightState() {
  threadListInFlightByProvider.clear();
}

async function listProviderThreadsForThreadList(
  providers,
  params,
  logPrefix = "[remodex]",
  options = {},
) {
  const env = options.env || process.env;
  const settled = await Promise.allSettled(
    providers.map((provider) => {
      const inFlightKey = readString(provider?.id);
      if (inFlightKey && threadListInFlightByProvider.has(inFlightKey)) {
        return threadListInFlightByProvider.get(inFlightKey);
      }

      const budgetMs =
        provider.id === OPENCODE_PROVIDER_ID
          ? opencodeThreadListBudgetMs(env)
          : THREAD_LIST_PROVIDER_BUDGET_MS;
      const listWork = provider.listThreads(params).catch((error) => {
        console.log(
          JSON.stringify({
            event: "thread_list_provider_failed",
            providerId: provider.id,
            message: readString(error?.message) || `${provider.id} thread/list failed`,
          }),
        );
        return { data: [], meta: null };
      });
      const listPromise = withThreadListBudget(
        listWork,
        budgetMs,
        { data: [], meta: null },
        { leg: provider.id },
      );

      if (inFlightKey) {
        const shared = listPromise.finally(() => {
          if (threadListInFlightByProvider.get(inFlightKey) === shared) {
            threadListInFlightByProvider.delete(inFlightKey);
          }
        });
        threadListInFlightByProvider.set(inFlightKey, shared);
        return shared;
      }

      return listPromise;
    }),
  );
  const threads = [];
  let meta = null;
  for (const result of settled) {
    if (result.status !== "fulfilled") {
      continue;
    }
    const payload = result.value;
    if (Array.isArray(payload?.data)) {
      threads.push(...payload.data);
    }
    if (payload?.meta && typeof payload.meta === "object") {
      meta = { ...(meta || {}), ...payload.meta };
    }
  }
  return { threads, meta };
}

function logBridgeTurnStartAudit(request, ownershipStore) {
  const params = request.params || {};
  const threadId = readThreadId(params);
  const normalizedRequested = normalizeExplicitRequestedProvider(params);
  const storedProvider = threadId && ownershipStore && typeof ownershipStore.getOwnership === "function"
    ? ownershipStore.getOwnership(threadId)
    : null;
  const hasExplicit = hasExplicitProviderField(params);

  console.log(
    JSON.stringify({
      event: "bridge_turn_start_audit",
      threadId,
      rpcRequestId: request.id ?? null,
      requestedProvider: normalizedRequested,
      hasExplicitProviderField: hasExplicit,
      storedProvider: storedProvider || null,
      mismatch: Boolean(
        storedProvider && normalizedRequested && storedProvider !== normalizedRequested,
      ),
    }),
  );
}

function logBridgeOwnershipMismatch(request, ownershipStore, error) {
  const params = request.params || {};
  const threadId = readThreadId(params);
  const normalizedRequested = normalizeExplicitRequestedProvider(params);
  const storedProvider = threadId ? ownershipStore.getOwnership(threadId) : null;

  console.log(
    JSON.stringify({
      event: "bridge_ownership_mismatch",
      threadId,
      rpcRequestId: request.id ?? null,
      requestedProvider: normalizedRequested,
      storedProvider: storedProvider || null,
      errorCode: error?.errorCode || "thread_provider_mismatch",
    }),
  );
}

function resolveThreadOwnershipMismatch(request, ownershipStore) {
  const params = request.params || {};
  const threadId = readThreadId(params);
  const storedProvider = threadId && ownershipStore && typeof ownershipStore.getOwnership === "function"
    ? ownershipStore.getOwnership(threadId)
    : null;
  const requestedProvider = readModelProvider(params);
  const hasExplicit = hasExplicitProviderField(params);
  const normalizedRequested = hasExplicit && requestedProvider
    ? (isOpenCodeProvider(requestedProvider) ? OPENCODE_PROVIDER_ID : CODEX_PROVIDER_ID)
    : null;

  console.log(
    JSON.stringify({
      event: "resolve_thread_ownership_check",
      rpcRequestId: request.id ?? null,
      threadId: threadId || null,
      requestedProvider: normalizedRequested,
      hasExplicitProviderField: hasExplicit,
      storedProvider: storedProvider || null,
    }),
  );

  if (!threadId) {
    return null;
  }
  if (!storedProvider) {
    return null;
  }
  if (!hasExplicit) {
    return null;
  }
  if (storedProvider === normalizedRequested) {
    return null;
  }

  const error = new Error(
    `Thread ${threadId} is owned by ${storedProvider}, not ${normalizedRequested}`,
  );
  error.errorCode = "thread_provider_mismatch";
  error.userMessage = `This chat is tied to ${storedProvider}. Start a new chat to switch providers.`;
  return error;
}

function normalizeExplicitRequestedProvider(params = {}) {
  if (!hasExplicitProviderField(params)) {
    return null;
  }
  return isOpenCodeProvider(readModelProvider(params)) ? OPENCODE_PROVIDER_ID : CODEX_PROVIDER_ID;
}

function providerForRequest(request, providers, ownershipStore = null) {
  const params = request.params || {};
  const providerFromRequest = readModelProvider(params);
  const hasProviderField = hasExplicitProviderField(params);
  const threadId = readThreadId(params);
  const storedProvider = threadId && ownershipStore && typeof ownershipStore.getOwnership === "function"
    ? ownershipStore.getOwnership(threadId)
    : null;

  // Use normalized form for requestedProvider in logs (for consistency with resolve/audit which use canonical OPENCODE/CODEX or null when !hasExplicit).
  // This avoids raw variants (e.g. "open-code") or default-"codex" (for !has) in the field.
  const requestedProviderForLog = hasProviderField
    ? (isOpenCodeProvider(providerFromRequest) ? OPENCODE_PROVIDER_ID : CODEX_PROVIDER_ID)
    : null;

  if (isOpenCodeProvider(providerFromRequest)) {
    const resolved = providers.find((provider) => provider.id === OPENCODE_PROVIDER_ID) || null;
    console.log(
      JSON.stringify({
        event: "provider_for_request_decision",
        rpcRequestId: request.id ?? null,
        requestedProvider: requestedProviderForLog,
        hasExplicitProviderField: hasProviderField,
        storedProvider: storedProvider || null,
        resolvedProvider: resolved ? resolved.id : null,
        matchReason: "explicit_opencode",
        owns: false,
      }),
    );
    return resolved;
  }
  if (hasProviderField) {
    console.log(
      JSON.stringify({
        event: "provider_for_request_decision",
        rpcRequestId: request.id ?? null,
        requestedProvider: requestedProviderForLog,
        hasExplicitProviderField: hasProviderField,
        storedProvider: storedProvider || null,
        resolvedProvider: null,
        matchReason: "explicit_non_oc_passthrough",
        owns: false,
      }),
    );
    return null;
  }

  if (!threadId) {
    console.log(
      JSON.stringify({
        event: "provider_for_request_decision",
        rpcRequestId: request.id ?? null,
        requestedProvider: requestedProviderForLog,
        hasExplicitProviderField: hasProviderField,
        storedProvider: storedProvider || null,
        resolvedProvider: null,
        matchReason: "no_thread_id",
        owns: false,
      }),
    );
    return null;
  }

  console.log(
    JSON.stringify({
      event: "provider_for_request_owns_call",
      rpcRequestId: request.id ?? null,
      threadId,
      requestedProvider: requestedProviderForLog,
      hasExplicitProviderField: hasProviderField,
      storedProvider: storedProvider || null,
    }),
  );
  let resolved = providers.find((provider) => provider.ownsThread(threadId)) || null;
  let matchReason = resolved ? "owns_thread_match" : "no_owning_provider";
  if (
    !resolved &&
    isOpenCodeRuntimeEnabled(process.env) &&
    readString(threadId).startsWith("opencode-thread-")
  ) {
    const opencodeProvider = providers.find((provider) => provider.id === OPENCODE_PROVIDER_ID);
    if (opencodeProvider?.ownsThread?.(threadId)) {
      resolved = opencodeProvider;
      matchReason = "opencode_thread_session_mapping";
    }
  }
  if (
    !resolved &&
    isOpenCodeRuntimeEnabled(process.env) &&
    isDiscoveredExternalThreadId(threadId)
  ) {
    resolved = providers.find((provider) => provider.id === OPENCODE_PROVIDER_ID) || null;
    matchReason = resolved ? "discovered_external_thread_id" : "discovered_external_no_provider";
  }
  console.log(
    JSON.stringify({
      event: "provider_for_request_decision",
      rpcRequestId: request.id ?? null,
      requestedProvider: requestedProviderForLog,
      hasExplicitProviderField: hasProviderField,
      storedProvider: storedProvider || null,
      resolvedProvider: resolved ? resolved.id : null,
      matchReason,
      owns: matchReason === "owns_thread_match",
    }),
  );
  return resolved;
}

function threadsFromListResult(result) {
  const key = firstArrayKey(result, ["data", "items", "threads"]);
  return key && Array.isArray(result?.[key]) ? result[key] : [];
}

function registerThreadProjects(projectRegistry, threads, metadata = {}) {
  if (!projectRegistry || !Array.isArray(threads) || !threads.length) {
    return;
  }

  try {
    projectRegistry.rememberProjectsFromThreads(threads, metadata);
  } catch {
    // Project history is a cache; provider routing should not fail when it cannot be persisted.
  }
}

function rememberProjectFromRequest(projectRegistry, request, metadata = {}) {
  if (!projectRegistry) {
    return;
  }

  const params = request?.params || {};
  const cwd = resolvedParam(params, 'cwd', 'current_working_directory', 'working_directory');
  if (!cwd) {
    return;
  }

  try {
    projectRegistry.rememberProjectPath(cwd, metadata);
  } catch {
    // Best-effort cache write; the runtime request remains authoritative.
  }
}

function hasCursor(params = {}) {
  const cursor = params.cursor ?? params.nextCursor ?? params.next_cursor;
  return cursor != null && cursor !== "" && cursor !== false;
}

function hasExplicitProviderField(params = {}) {
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return false;
  }
  if (PROVIDER_FIELD_KEYS.some((key) => readString(params[key]))) {
    return true;
  }

  for (const key of ["collaborationMode", "collaboration_mode"]) {
    const settings = params[key]?.settings;
    if (settings && typeof settings === "object" && !Array.isArray(settings)) {
      return PROVIDER_FIELD_KEYS.some((providerKey) => readString(settings[providerKey]));
    }
  }

  return false;
}

function createJsonRpcErrorResponse(requestId, error, defaultErrorCode) {
  return JSON.stringify({
    id: requestId,
    error: {
      code: -32000,
      message: error?.userMessage || error?.message || "Runtime provider request failed.",
      data: {
        errorCode: error?.errorCode || defaultErrorCode,
      },
    },
  });
}

function resolveProviders({
  providers,
  env,
  createOpenCodeProvider,
  sendRuntimeMessage,
  sendApplicationResponse,
  projectRegistry,
  ownershipStore,
  logPrefix,
}) {
  if (providers !== null && providers !== undefined) {
    return providers;
  }
  if (isOpenCodeRuntimeDisabled(env)) {
    return [];
  }
  // MSG-3: reliability metrics/rates (late guard, buffer drain, watchdog, dedup persist) active for OC notify paths.
  // DISABLE=1 regression ensures codex notify/router paths unaffected (see opencode-regression.test.js).
  return [
    createOpenCodeProvider({
      sendApplicationMessage: sendRuntimeMessage || sendApplicationResponse,
      projectRegistry,
      ownershipStore,
      logPrefix,
    }),
  ];
}

function providerModelsForModelList(providerModels, catalogOpenCode, opencodeMeta = null) {
  const opencodeModels = providerModels.filter(
    (model) => readModelProvider(model) === OPENCODE_PROVIDER_ID,
  );
  const connectedProviderIds = opencodeMeta?.connectedProviderIds || null;
  const cappedOpenCode = capOpenCodeModelsForMobileList(
    opencodeModels,
    process.env,
    connectedProviderIds,
  );
  const placeholderModels =
    catalogOpenCode && !catalogOpenCode.enabled && cappedOpenCode.length === 0
      ? buildCatalogOpenCodePlaceholderModels()
      : [];
  return [...cappedOpenCode, ...placeholderModels];
}

function resolveSkillsListCwds(params = {}) {
  const cwds = [];
  if (Array.isArray(params.cwds)) {
    for (const entry of params.cwds) {
      const cwd = readString(entry);
      if (cwd) {
        cwds.push(cwd);
      }
    }
  }
  const singleCwd = readString(params.cwd || params.directory);
  if (singleCwd) {
    cwds.push(singleCwd);
  }
  if (cwds.length === 0) {
    cwds.push(process.cwd());
  }
  return [...new Set(cwds)];
}

function readSkillProvider(skill) {
  return readString(skill?.provider) || CODEX_PROVIDER_ID;
}

function resolvePrimaryProvider(providerIds) {
  const ids = [...new Set(providerIds.map((id) => readString(id)).filter(Boolean))].sort();
  if (ids.includes(CODEX_PROVIDER_ID)) {
    return CODEX_PROVIDER_ID;
  }
  if (ids.includes(OPENCODE_PROVIDER_ID)) {
    return OPENCODE_PROVIDER_ID;
  }
  return ids[0] || CODEX_PROVIDER_ID;
}

function shouldPreferSkillRecord(existing, incoming) {
  if (incoming.enabled !== false && existing.enabled === false) {
    return true;
  }
  if (existing.enabled !== false && incoming.enabled === false) {
    return false;
  }
  const existingProvider = readSkillProvider(existing);
  const incomingProvider = readSkillProvider(incoming);
  if (incomingProvider === CODEX_PROVIDER_ID && existingProvider !== CODEX_PROVIDER_ID) {
    return true;
  }
  return false;
}

function mergeSkillsAcrossProviders(skills) {
  const byFoldedName = new Map();
  for (const skill of skills) {
    const name = readString(skill?.name);
    if (!name) {
      continue;
    }
    const key = name.trim().toLowerCase();
    const providerId = readSkillProvider(skill);
    const existing = byFoldedName.get(key);
    if (!existing) {
      byFoldedName.set(key, {
        skill: { ...skill, name: name.trim() },
        providers: new Set([providerId]),
      });
      continue;
    }
    existing.providers.add(providerId);
    if (shouldPreferSkillRecord(existing.skill, skill)) {
      existing.skill = { ...skill, name: name.trim() };
    }
  }

  return [...byFoldedName.values()]
    .map(({ skill, providers }) => {
      const providerIds = [...providers].sort();
      const primary = resolvePrimaryProvider(providerIds);
      return {
        ...skill,
        name: readString(skill.name),
        provider: primary,
        providers: providerIds,
      };
    })
    .sort((a, b) =>
      readString(a.name).localeCompare(readString(b.name), undefined, { sensitivity: "base" }),
    );
}

function isCodexRuntimeUnavailable(getCodexLaunchState) {
  if (typeof getCodexLaunchState !== "function") {
    return false;
  }
  const state = getCodexLaunchState();
  return state === "degraded" || state === "error";
}

function isCodexRuntimeConnected(getCodexLaunchState) {
  return !isCodexRuntimeUnavailable(getCodexLaunchState);
}

function resolveCodexLegPromise(getCodexLaunchState, runCodexLeg, fallback) {
  if (!isCodexRuntimeConnected(getCodexLaunchState)) {
    return Promise.resolve(fallback);
  }
  return runCodexLeg();
}

async function mergeSkillsListResult(params, providers, sendCodexRequest, getCodexLaunchState = null) {
  const cwds = resolveSkillsListCwds(params);
  const codexParams = { ...params };
  if (!Array.isArray(codexParams.cwds) || codexParams.cwds.length === 0) {
    codexParams.cwds = cwds;
  }

  const [codexResult, opencodeBuckets] = await Promise.all([
    resolveCodexLegPromise(
      getCodexLaunchState,
      () => sendCodexRequest("skills/list", codexParams),
      { data: [] },
    ).catch((error) => {
      console.warn(`[remodex] Codex skills/list failed: ${error?.message || error}`);
      return { data: [] };
    }),
    listOpenCodeSkillsBuckets(providers, cwds),
  ]);

  const codexBuckets = normalizeSkillsBuckets(codexResult);
  const mergedBuckets = mergeSkillsBuckets(codexBuckets, opencodeBuckets);
  if (Array.isArray(codexResult?.data)) {
    return { ...codexResult, data: mergedBuckets };
  }
  if (Array.isArray(codexResult?.skills)) {
    return {
      skills: mergeSkillsAcrossProviders(
        mergedBuckets.flatMap((bucket) => bucket.skills || []),
      ),
    };
  }
  return { data: mergedBuckets };
}

async function listOpenCodeSkillsBuckets(providers, cwds) {
  const opencodeProvider = providers.find((p) => p.id === OPENCODE_PROVIDER_ID);
  if (!opencodeProvider || typeof opencodeProvider.listSkills !== "function") {
    return [];
  }
  const buckets = [];
  for (const cwd of cwds) {
    const skills = await opencodeProvider.listSkills(cwd);
    if (skills.length > 0) {
      buckets.push({ cwd, skills });
    }
  }
  return buckets;
}

function normalizeSkillsBuckets(result) {
  if (Array.isArray(result?.data)) {
    return result.data.map((bucket) => ({
      cwd: readString(bucket?.cwd) || "",
      skills: Array.isArray(bucket?.skills) ? bucket.skills : [],
    }));
  }
  if (Array.isArray(result?.skills)) {
    return [{ cwd: "", skills: result.skills }];
  }
  return [];
}

function mergeSkillsBuckets(codexBuckets, opencodeBuckets) {
  const byCwd = new Map();
  for (const bucket of [...codexBuckets, ...opencodeBuckets]) {
    const cwd = readString(bucket?.cwd) || "";
    const existing = byCwd.get(cwd) || { cwd, skills: [] };
    existing.skills = [...(existing.skills || []), ...(bucket.skills || [])];
    byCwd.set(cwd, existing);
  }
  return [...byCwd.values()].map((bucket) => ({
    cwd: bucket.cwd,
    skills: mergeSkillsAcrossProviders(bucket.skills || []),
  }));
}

module.exports = {
  buildCatalogOpenCodeRuntime,
  readOpenCodeCatalogAvailability,
  buildCatalogOpenCodePlaceholderModels,
  computeCatalogFingerprint,
  computeCatalogRevision,
  countAuthenticated,
  CODEX_MODEL_LIST_BUDGET_MS,
  CODEX_THREAD_LIST_BUDGET_MS,
  DEFAULT_OPENCODE_MODEL_LIST_BUDGET_MS,
  DEFAULT_OPENCODE_THREAD_LIST_BUDGET_MS,
  MODEL_LIST_PROVIDER_BUDGET_MS,
  THREAD_LIST_BUDGET_CEILING_MS,
  THREAD_LIST_PROVIDER_BUDGET_MS,
  codexThreadListBudgetMs,
  opencodeThreadListBudgetMs,
  maybeEmitCatalogUpdated,
  opencodeModelListBudgetMs,
  createRuntimeProviderRouter,
  capOpenCodeModelsForMobileList,
  catalogOpenCodeSnapshotForModelList,
  listProviderModelsForModelList,
  listProviderThreadsForThreadList,
  resetCatalogPushState,
  resetOpenCodeProjectDiscoverState,
  resetThreadListInFlightState,
  isOpenCodeDiscoverProjectsEnabled,
  readDiscoverProjectTtlMs,
  maybeDiscoverOpenCodeProjects,
  shouldWarmProviderInventory,
  shortHash,
  withModelListBudget,
  withThreadListBudget,
  mergeModelListResult,
  mergeSkillsAcrossProviders,
  mergeSkillsListResult,
  mergeThreadListResult,
  resolvePrimaryProvider,
  providerForRequest,
  providerModelsForModelList,
  registerThreadProjects,
  stripRuntimeProviderFieldsForCodex,
  threadsFromListResult,
};
