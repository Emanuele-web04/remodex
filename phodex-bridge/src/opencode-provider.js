// FILE: opencode-provider.js
// Purpose: Adapts OpenCode SDK (opencode serve + @opencode-ai/sdk/v2) to Remodex
//          provider-aware thread/turn RPCs. Manages server lifecycle, session
//          mapping, event streaming, and permission bridging.
// Layer: Bridge runtime provider
// Exports: createOpenCodeProvider
// Depends on: ./opencode-server, ./opencode-client, ./opencode-models, ./provider-capabilities, ./thread-ownership-store

const path = require("path");
const { readString, resolvedParam } = require("./normalize");
const { createOpenCodeServer } = require("./opencode-server");
const {
  buildStaticSlashCommands,
  createOpenCodeClient,
  normalizeCommandNameForSdk,
  normalizeCommandTokenForAllowlist,
  normalizeSessionMessagesResponse,
} = require("./opencode-client");
const {
  deriveRequiresArguments,
  normalizeArgumentFields,
  serializeCommandArguments,
} = require("./opencode-command-arguments");
const {
  DEFAULT_OPENCODE_MODEL,
  OPENCODE_PROVIDER_ID,
  appendNonEmpty,
  boundedPositiveInteger,
  buildPromptFromTurnInput,
  compareThreadsByUpdatedAt,
  messagesToTurns,
  extractOpenCodeMessageText,
  isOpenCodeAssistantMessage,
  normalizeOpenCodeModel,
  publicThread,
  readThreadId,
  removeUndefinedValues,
  textContent,
} = require("./opencode-models");
const { createThreadOwnershipStore } = require("./thread-ownership-store");
const { createOpenCodeSessionStore } = require("./opencode-session-store");
const {
  buildOpenCodeRuntimeStatus,
  isVersionBelowMinimum,
  OPENCODE_MIN_CLI_VERSION,
} = require("./opencode-runtime-status");
const { isOpenCodeHandoffEnabled } = require("./opencode-handoff");
const { resolveDefaultOpenCodeAgent } = require("./opencode-runtime-policy");
const { parseOpenCodeModelSlug } = require("./opencode-model-slug");
const { resolveOpenCodeVariantForPrompt } = require("./opencode-variant-resolve");
const { createOpenCodeAuthErrorNotifier } = require("./opencode-auth-error-handler");
const { mapOpenCodeSessionToContextUsage } = require("./opencode-usage-mapper");
const { createAttachmentStore, isAttachmentsEnabled } = require("./attachment-store");
const { validateDirectory } = require("./project-path-policy");
const { resolveDiscoverSessionsEnabled } = require("./opencode-discovery-policy");

const ERROR_CODES = {
  OPENCODE_NOT_INSTALLED: { errorCode: "opencode_not_installed", action: "show_install_instructions" },
  OPENCODE_SERVER_UNREACHABLE: { errorCode: "opencode_server_unreachable", action: "show_retry" },
  OPENCODE_MODEL_UNAVAILABLE: { errorCode: "opencode_model_unavailable", action: "pick_different_model" },
  OPENCODE_AGENT_UNAVAILABLE: { errorCode: "opencode_agent_unavailable", action: "pick_different_agent" },
  OPENCODE_SESSION_EXPIRED: { errorCode: "opencode_session_expired", action: "restart_thread" },
  OPENCODE_TURN_FAILED: { errorCode: "opencode_turn_failed", action: "show_retry" },
  OPENCODE_PERMISSION_TIMEOUT: { errorCode: "opencode_permission_timeout", action: "show_timeout" },
};

const HEALTH_RESTART_WINDOW_MS = 5 * 60 * 1000;
const HEALTH_MAX_RESTARTS = 3;
const HEALTH_IDLE_SHUTDOWN_MS = 10 * 60 * 1000;
const LIST_THREADS_SESSION_VALIDATE_CAP = 20;
const STARTUP_PRUNE_SESSION_VALIDATE_CAP = 20;
const DEFAULT_DISCOVER_SESSIONS_CAP = 30;
const DEFAULT_DISCOVER_SESSIONS_TTL_MS = 60_000;
const DEFAULT_LIST_THREADS_VALIDATE_CACHE_TTL_MS = 60_000;
const DEFAULT_ENSURE_STARTED_LIST_CAP_MS = 4_000;
const DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS = 8_000;
const DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN = 120;
const DISCOVERED_THREAD_ID_PREFIX = "opencode-session-";
const DEFAULT_OPENCODE_TURN_WATCHDOG_MS = 120 * 1000;
const ADOPT_MUTEX_TIMEOUT_MS = 30_000;
const OPENCODE_PRUNE_OPS_HINT =
  "node phodex-bridge/scripts/prune-opencode-ownership.js --apply";

function resolveListThreadsValidateCap(env = process.env) {
  const fromEnv = Number(env?.REMODEX_LIST_THREADS_VALIDATE_CAP);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return boundedPositiveInteger(fromEnv, LIST_THREADS_SESSION_VALIDATE_CAP);
  }
  return LIST_THREADS_SESSION_VALIDATE_CAP;
}

function resolveDiscoverSessionsCap(env = process.env) {
  const fromEnv = Number(env?.REMODEX_LIST_THREADS_DISCOVER_CAP);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return boundedPositiveInteger(fromEnv, DEFAULT_DISCOVER_SESSIONS_CAP);
  }
  return DEFAULT_DISCOVER_SESSIONS_CAP;
}

function resolveDiscoverSessionsTtlMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_DISCOVER_TTL_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_DISCOVER_SESSIONS_TTL_MS;
}

function resolveEnsureStartedListCapMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_ENSURE_STARTED_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_ENSURE_STARTED_LIST_CAP_MS;
}

function resolveEnsureStartedServeWakeCapMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_SERVE_WAKE_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS;
}

function resolveValidationRpcLimitPerMin(env = process.env) {
  const fromEnv = Number(env?.REMODEX_VALIDATION_RPC_LIMIT_PER_MIN);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN;
}

function createValidationRpcTokenBucket({
  limitPerMin = DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN,
  now = () => Date.now(),
} = {}) {
  let tokens = limitPerMin;
  let lastRefillAt = now();

  return {
    tryConsume(cost = 1) {
      const normalizedCost = Number.isFinite(cost) && cost > 0 ? cost : 1;
      const current = now();
      const elapsed = current - lastRefillAt;
      if (elapsed > 0) {
        tokens = Math.min(limitPerMin, tokens + (elapsed / 60_000) * limitPerMin);
        lastRefillAt = current;
      }
      if (tokens < normalizedCost) {
        return false;
      }
      tokens -= normalizedCost;
      return true;
    },
    getAvailableTokens() {
      const current = now();
      const elapsed = current - lastRefillAt;
      if (elapsed > 0) {
        tokens = Math.min(limitPerMin, tokens + (elapsed / 60_000) * limitPerMin);
        lastRefillAt = current;
      }
      return tokens;
    },
    reset() {
      tokens = limitPerMin;
      lastRefillAt = now();
    },
  };
}

function resolveListThreadsValidateCacheTtlMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_LIST_THREADS_VALIDATE_CACHE_TTL_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_LIST_THREADS_VALIDATE_CACHE_TTL_MS;
}

function parseDiscoveredThreadSessionId(threadId) {
  const normalized = readString(threadId);
  if (!normalized || !normalized.startsWith(DISCOVERED_THREAD_ID_PREFIX)) {
    return "";
  }
  return readString(normalized.slice(DISCOVERED_THREAD_ID_PREFIX.length));
}

function maybeLogOpenCodePruneOpsHint({ materializationBlocked = 0, prunedCount = 0 } = {}) {
  if (materializationBlocked > 50 || prunedCount > 50) {
    console.log(
      JSON.stringify({
        event: "opencode_prune_ops_hint",
        hint: `Run: ${OPENCODE_PRUNE_OPS_HINT}`,
        materialization_blocked: materializationBlocked,
        pruned_count: prunedCount,
      }),
    );
  }
}

function resolveOpenCodeTurnWatchdogMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_TURN_WATCHDOG_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_OPENCODE_TURN_WATCHDOG_MS;
}

function resolveAdoptMutexTimeoutMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_ADOPT_TIMEOUT_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return ADOPT_MUTEX_TIMEOUT_MS;
}

function assertOwnershipPersisted(ok, threadId) {
  if (ok) {
    return;
  }
  const error = new Error(`Failed to persist thread ownership for ${threadId}`);
  error.errorCode = "thread_ownership_persist_failed";
  throw error;
}

function pathNotAllowedError() {
  const error = new Error("That folder is outside the allowed local project locations.");
  error.errorCode = "path_not_allowed";
  error.userMessage = error.message;
  return error;
}

async function resolveAllowedDirectory(candidatePath) {
  const validation = await validateDirectory(candidatePath);
  if (!validation.isAllowed) {
    throw pathNotAllowedError();
  }
  return validation.path;
}

const SENSITIVE_PERMISSION_ARG_KEYS = new Set(["command", "script", "token", "secret", "password"]);
const ATTACHMENT_CLEANUP_INTERVAL_MS = 60 * 60 * 1000;

// iOS plan toggle sends turn/start collaborationMode {mode:"plan"} (snake_case
// accepted for legacy callers); anything else means the thread's normal agent.
function isPlanModeRequested(params) {
  const mode = params?.collaborationMode?.mode ?? params?.collaboration_mode?.mode;
  return readString(mode) === "plan";
}

function formatStructuredError(logPrefix, message, context = {}) {
  const structuredContext = {
    timestamp: new Date().toISOString(),
    ...context,
  };
  return `${logPrefix} ${message} ${JSON.stringify(structuredContext)}`;
}

function createOpenCodeProvider({
  sendApplicationMessage,
  env = process.env,
  projectRegistry = null,
  ownershipStore = null,
  sessionStore = null,
  logPrefix = "[remodex]",
  serverFactory = null,
  clientFactory = null,
  attachmentStore: injectedAttachmentStore = undefined,
} = {}) {
  const server = serverFactory
    ? serverFactory({ env, logPrefix: `${logPrefix}:server` })
    : createOpenCodeServer({ env, logPrefix: `${logPrefix}:server` });
  const ownership = ownershipStore || createThreadOwnershipStore();
  const sessions = sessionStore || createOpenCodeSessionStore();

  let client = null;
  let healthy = false;
  let restartCount = 0;
  let restartWindowStart = 0;
  let lastActivityAt = 0;
  let idleTimer = null;
  let catalogUnavailable = null;
  let cachedAuthConfigured = null;
  let lastModelListMeta = null;
  let lastConnectedProviders = [];
  let lastListedModels = [];
  let lastCatalogAgents = [];
  const defaultAgent = resolveDefaultOpenCodeAgent(env);
  let lastProviderInventory = [];
  let lastAuthDiscoveryReasonCode = "ok";
  let lastProviderInventoryPartial = false;

  const threads = new Map();
  const activeTurns = new Map();
  const inFlightThreadIds = new Set();
  const eventUnsubscribers = new Map();
  /** @type {Map<string, number>} */
  const completedTurnIds = new Map();
  const invalidSessionThreadIds = new Set();
  const COMMAND_EXECUTE_DEDUPE_TTL_MS = 5000;
  const COMPLETED_TURN_IDS_TTL_MS = 300_000;
  /** @type {Map<string, number>} */
  const commandExecuteDedupeByKey = new Map();
  const authErrorNotifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage,
    logPrefix,
  });
  const attachmentStore = injectedAttachmentStore !== undefined
    ? injectedAttachmentStore
    : (isAttachmentsEnabled(env) ? createAttachmentStore() : null);
  let lastAttachmentCleanupAt = 0;
  let sseReconnectCount = 0;
  /** @type {Map<string, { permissionId: string, threadId: string, turnId?: string, sessionId?: string, tool: string, requestedAt: string, watchdog?: ReturnType<typeof setTimeout> }>} */
  const pendingPermissions = new Map();
  /** @type {Map<string, Set<string>>} */
  const sessionPermissionGrants = new Map();
  const PERMISSION_WATCHDOG_MS = resolveOpenCodeTurnWatchdogMs(env);
  const MAX_PENDING_PERMISSIONS = 20;
  let discoveredSessionsCache = { rows: [], fetchedAt: 0 };
  let discoverRefreshInFlight = null;
  /** @type {Map<string, { valid?: boolean, hasActivity?: boolean, fetchedAt: number }>} */
  const sessionValidationCache = new Map();
  const adoptMutexes = new Map();
  const validationRpcTokenBucket = createValidationRpcTokenBucket({
    limitPerMin: resolveValidationRpcLimitPerMin(env),
  });

  function consumeValidationRpcToken(cost = 1) {
    if (validationRpcTokenBucket.tryConsume(cost)) {
      return true;
    }
    console.log(
      JSON.stringify({
        event: "opencode_validation_rpc_rate_limited",
        limitPerMin: resolveValidationRpcLimitPerMin(env),
      }),
    );
    return false;
  }

  function readSessionValidationCache(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return null;
    }
    const entry = sessionValidationCache.get(normalizedSessionId);
    if (!entry) {
      return null;
    }
    const ttlMs = resolveListThreadsValidateCacheTtlMs(env);
    if (Date.now() - entry.fetchedAt >= ttlMs) {
      sessionValidationCache.delete(normalizedSessionId);
      return null;
    }
    return entry;
  }

  function writeSessionValidationCache(sessionId, patch = {}) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return;
    }
    const previous = readSessionValidationCache(sessionId) || {};
    sessionValidationCache.set(normalizedSessionId, {
      ...previous,
      ...patch,
      fetchedAt: Date.now(),
    });
  }

  function commandExecuteDedupeKey(threadId, allowlistToken, clientCommandId) {
    const tid = readString(threadId);
    const token = readString(allowlistToken);
    const cid = readString(clientCommandId);
    if (!tid || !token || !cid) {
      return "";
    }
    return `${tid}\0${token}\0${cid}`;
  }

  function pruneCommandExecuteDedupe(now = Date.now()) {
    for (const [key, seenAt] of commandExecuteDedupeByKey.entries()) {
      if (now - seenAt >= COMMAND_EXECUTE_DEDUPE_TTL_MS) {
        commandExecuteDedupeByKey.delete(key);
      }
    }
  }

  function pruneCompletedTurnIds(now = Date.now()) {
    for (const [turnId, completedAt] of completedTurnIds.entries()) {
      if (now - completedAt >= COMPLETED_TURN_IDS_TTL_MS) {
        completedTurnIds.delete(turnId);
      }
    }
  }

  function removeOrphanOpenCodeThread(threadId, reason = "opencode_ownership_orphan_removed") {
    const removedOwnership = ownership.removeOwnership(threadId);
    const removedSession = sessions.remove(threadId);
    invalidSessionThreadIds.delete(threadId);
    if (removedOwnership || removedSession) {
      console.log(
        JSON.stringify({
          event: reason,
          threadId,
          removedOwnership: Boolean(removedOwnership),
          removedSession: Boolean(removedSession),
        }),
      );
    }
    return { removedOwnership: Boolean(removedOwnership), removedSession: Boolean(removedSession) };
  }

  function ownershipStubFromStore(threadId, storeEntry) {
    const updatedAt = readString(storeEntry?.updatedAt) || new Date().toISOString();
    const cwd = readString(storeEntry?.cwd) || "";
    return {
      id: threadId,
      title: readString(storeEntry?.title) || "OpenCode chat",
      name: readString(storeEntry?.title) || "OpenCode chat",
      cwd,
      hasProjectCwd: Boolean(cwd),
      model: normalizeOpenCodeModel(storeEntry?.model) || DEFAULT_OPENCODE_MODEL,
      modelProvider: OPENCODE_PROVIDER_ID,
      provider: OPENCODE_PROVIDER_ID,
      createdAt: updatedAt,
      updatedAt,
      archived: false,
    };
  }

  async function validateOwnedThreadSession(sessionId) {
    const cached = readSessionValidationCache(sessionId);
    if (cached?.valid !== undefined) {
      return cached.valid;
    }
    if (!consumeValidationRpcToken()) {
      const error = new Error("OpenCode validation RPC rate limit exceeded.");
      error.errorCode = "opencode_validation_rate_limited";
      throw error;
    }
    try {
      await client.getSession(sessionId);
      writeSessionValidationCache(sessionId, { valid: true });
      return true;
    } catch (error) {
      if (isInvalidOpenCodeSessionError(error)) {
        writeSessionValidationCache(sessionId, { valid: false, hasActivity: false });
        return false;
      }
      throw error;
    }
  }

  async function pruneOpenCodeStorageMismatch({
    maxSessionValidations = STARTUP_PRUNE_SESSION_VALIDATE_CAP,
  } = {}) {
    let ownershipWithoutSession = 0;
    let sessionWithoutOwnership = 0;
    let invalidSessionPruned = 0;
    let sdkValidations = 0;

    for (const { threadId } of ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID)) {
      if (threads.has(threadId)) {
        continue;
      }
      if (!sessions.get(threadId)) {
        ownershipWithoutSession += 1;
        removeOrphanOpenCodeThread(threadId);
      }
    }

    for (const [threadId] of sessions.entries()) {
      if (threads.has(threadId)) {
        continue;
      }
      if (!ownership.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
        sessionWithoutOwnership += 1;
        sessions.remove(threadId);
        continue;
      }
      if (invalidSessionThreadIds.has(threadId)) {
        invalidSessionPruned += 1;
        removeOrphanOpenCodeThread(threadId);
        continue;
      }
      if (sdkValidations >= maxSessionValidations) {
        continue;
      }
      const sessionId = sessions.get(threadId);
      if (!sessionId) {
        continue;
      }
      sdkValidations += 1;
      const valid = await validateOwnedThreadSession(sessionId);
      if (!valid) {
        invalidSessionThreadIds.add(threadId);
        invalidSessionPruned += 1;
        removeOrphanOpenCodeThread(threadId);
      }
    }

    const prunedCount =
      ownershipWithoutSession + sessionWithoutOwnership + invalidSessionPruned;
    console.log(
      JSON.stringify({
        event: "opencode_storage_mismatch",
        ownership_without_session: ownershipWithoutSession,
        session_without_ownership: sessionWithoutOwnership,
        invalid_session_pruned: invalidSessionPruned,
        sdk_validations: sdkValidations,
      }),
    );
    maybeLogOpenCodePruneOpsHint({ prunedCount });
    return {
      ownershipWithoutSession,
      sessionWithoutOwnership,
      invalidSessionPruned,
      sdkValidations,
      prunedCount,
    };
  }

  function scheduleStartupPrune() {
    const fullPass = readString(env.REMODEX_PRUNE_OPENCODE_OWNERSHIP) === "1";
    const maxSessionValidations = fullPass
      ? Number.MAX_SAFE_INTEGER
      : STARTUP_PRUNE_SESSION_VALIDATE_CAP;
    const run = () => {
      if (!healthy || !client) {
        return Promise.resolve();
      }
      return pruneOpenCodeStorageMismatch({ maxSessionValidations }).catch((error) => {
        console.warn(
          `${logPrefix} OpenCode startup prune failed: ${(error && error.message) || error}`,
        );
      });
    };
    if (fullPass) {
      return run();
    }
    setImmediate(run);
    return Promise.resolve();
  }

  function scheduleAttachmentCleanup() {
    if (!attachmentStore) {
      return 0;
    }
    const now = Date.now();
    if (now - lastAttachmentCleanupAt < ATTACHMENT_CLEANUP_INTERVAL_MS) {
      return 0;
    }
    lastAttachmentCleanupAt = now;
    try {
      return attachmentStore.cleanupExpired();
    } catch (error) {
      console.warn(`${logPrefix} attachment cleanup failed: ${error.message}`);
      return 0;
    }
  }

  async function ensureStarted() {
    if (healthy && client) {
      scheduleAttachmentCleanup();
      return;
    }

    if (server.isRunning && !client) {
      client = clientFactory
        ? await clientFactory({ baseUrl: server.baseUrl, logPrefix: `${logPrefix}:sdk` })
        : await createOpenCodeClient({ baseUrl: server.baseUrl, logPrefix: `${logPrefix}:sdk` });
      healthy = true;
      await refreshAuthConfigured({ forceInventory: true });
      await restoreSessions();
      await scheduleStartupPrune();
      scheduleAttachmentCleanup();
      return;
    }

    if (!healthy) {
      try {
        await startServer();
      } catch (error) {
        const enriched = new Error(catalogUnavailable?.message || "OpenCode is not available on this Mac.");
        enriched.errorCode =
          catalogUnavailable?.reasonCode === "opencode_not_installed"
            ? ERROR_CODES.OPENCODE_NOT_INSTALLED.errorCode
            : ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
        enriched.action =
          catalogUnavailable?.reasonCode === "opencode_not_installed"
            ? ERROR_CODES.OPENCODE_NOT_INSTALLED.action
            : ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.action;
        enriched.reasonCode = catalogUnavailable?.reasonCode || enriched.errorCode;
        throw enriched;
      }
    }
  }

  async function startServer() {
    if (Date.now() - restartWindowStart > HEALTH_RESTART_WINDOW_MS) {
      restartCount = 0;
      restartWindowStart = Date.now();
    }

    if (restartCount >= HEALTH_MAX_RESTARTS) {
      catalogUnavailable = {
        unavailableReason:
          "OpenCode server could not stay running on this Mac. Check OpenCode logs.",
        reasonCode: "opencode_server_failed",
      };
      throw new Error(catalogUnavailable.unavailableReason);
    }

    restartCount++;
    console.log(
      `${logPrefix} Starting OpenCode server (attempt ${restartCount}/${HEALTH_MAX_RESTARTS})...`,
    );

    try {
      await server.start();
    } catch (error) {
      const failure = server.getLastStartFailure?.() || null;
      const reasonCode =
        readString(error?.reasonCode) ||
        readString(failure?.reasonCode) ||
        "opencode_server_failed";
      catalogUnavailable = {
        unavailableReason:
          readString(failure?.message) ||
          readString(error?.message) ||
          "OpenCode is not available on this Mac.",
        reasonCode,
      };
      throw error;
    }

    catalogUnavailable = null;
    client = clientFactory
      ? await clientFactory({ baseUrl: server.baseUrl, logPrefix: `${logPrefix}:sdk` })
      : await createOpenCodeClient({ baseUrl: server.baseUrl, logPrefix: `${logPrefix}:sdk` });
    healthy = true;
    await refreshAuthConfigured({ forceInventory: true });
    await restoreSessions();
    await scheduleStartupPrune();

    resetIdleTimer();
    scheduleAttachmentCleanup();
  }

  async function refreshAuthConfigured({ forceInventory = false } = {}) {
    if (!client) {
      cachedAuthConfigured = null;
      lastModelListMeta = null;
      lastConnectedProviders = [];
      return;
    }
    if (typeof client.listProviderInventory === "function") {
      try {
        const result = await client.listProviderInventory({ force: forceInventory });
        const connectedIds = result?.meta?.connectedProviderIds || [];
        lastModelListMeta = result?.meta || null;
        lastConnectedProviders = result?.connectedProviders || [];
        if (Array.isArray(connectedIds) && connectedIds.length > 0) {
          cachedAuthConfigured = true;
          return;
        }
        if (result?.meta?.reasonCode === "no_connected_providers") {
          cachedAuthConfigured = false;
          return;
        }
        if (result?.meta?.reasonCode === "provider_list_failed") {
          cachedAuthConfigured = null;
          return;
        }
        if (result?.meta?.reasonCode === "unknown") {
          cachedAuthConfigured = null;
          return;
        }
        cachedAuthConfigured = false;
        return;
      } catch {
        cachedAuthConfigured = null;
        return;
      }
    }
    if (typeof client.probeConnectedProviders === "function") {
      const connected = await client.probeConnectedProviders();
      if (connected === true) {
        cachedAuthConfigured = true;
        return;
      }
      if (connected === false) {
        cachedAuthConfigured = false;
      }
    }
  }

  function persistSessionRecord(thread) {
    if (!thread?.id || !thread.sessionId) return;
    sessions.set(thread.id, thread.sessionId, {
      cwd: thread.cwd,
      model: thread.model,
      agent: thread.agent,
      title: thread.title,
    });
  }

  async function rehydrateThreadIfNeeded(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    if (!normalizedThreadId) {
      throw threadNotFoundError(threadId);
    }

    const existing = threads.get(normalizedThreadId);
    if (existing) {
      return existing;
    }

    if (!ownership.ownsThread(normalizedThreadId, OPENCODE_PROVIDER_ID)) {
      throw threadNotFoundError(normalizedThreadId);
    }

    const storeEntry = sessions.getEntry(normalizedThreadId);
    const sessionId = storeEntry?.sessionId || sessions.get(normalizedThreadId);
    if (!sessionId) {
      throw threadNotFoundError(normalizedThreadId);
    }

    await ensureStarted();

    let sdkSession = null;
    try {
      sdkSession = await client.getSession(sessionId);
    } catch (error) {
      if (!isInvalidOpenCodeSessionError(error)) {
        throw error;
      }
      sessions.remove(normalizedThreadId);
      ownership.removeOwnership(normalizedThreadId);
      invalidSessionThreadIds.add(normalizedThreadId);
      throw createOpenCodeSessionExpiredError(normalizedThreadId);
    }

    const now = new Date().toISOString();
    const cwd =
      readString(storeEntry?.cwd) ||
      readString(sdkSession?.directory) ||
      readString(sdkSession?.cwd) ||
      process.cwd();
    const thread = {
      id: normalizedThreadId,
      title: readString(storeEntry?.title) || "OpenCode chat",
      cwd,
      model: normalizeOpenCodeModel(storeEntry?.model || sdkSession?.model),
      agent: readString(storeEntry?.agent) || defaultAgent,
      createdAt: readString(storeEntry?.updatedAt) || now,
      updatedAt: now,
      archived: false,
      hasProjectCwd: Boolean(readString(storeEntry?.cwd)),
      turns: [],
      sessionId,
      userStartedInProcess: false,
    };

    try {
      const messages = normalizeSessionMessagesResponse(await client.getMessages(sessionId));
      if (messages && messages.length > 0) {
        thread.turns = messagesToTurns(messages, normalizedThreadId);
      }
    } catch {
      // In-memory turns stay empty; thread/read still succeeds.
    }

    threads.set(normalizedThreadId, thread);
    persistSessionRecord(thread);
    rememberThreadProject(thread, "opencode-rehydrate");
    return thread;
  }

  async function requireThread(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    const existing = threads.get(normalizedThreadId);
    if (existing) {
      return existing;
    }
    return rehydrateThreadIfNeeded(normalizedThreadId);
  }

  async function ensureThreadSession(thread) {
    if (readString(thread?.sessionId)) {
      return thread;
    }
    return rehydrateThreadIfNeeded(thread.id);
  }

  function markUserStartedInProcess(thread) {
    if (!thread) {
      return;
    }
    thread.userStartedInProcess = true;
  }

  function threadHasActiveTurn(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    for (const active of activeTurns.values()) {
      if (active.thread.id === normalizedThreadId) {
        return true;
      }
    }
    return false;
  }

  async function validateThreadHasActivity(threadId, sessionId) {
    if (threadHasActiveTurn(threadId)) {
      return true;
    }
    const cached = readSessionValidationCache(sessionId);
    if (cached?.hasActivity !== undefined) {
      return cached.hasActivity;
    }
    if (!consumeValidationRpcToken()) {
      const error = new Error("OpenCode validation RPC rate limit exceeded.");
      error.errorCode = "opencode_validation_rate_limited";
      throw error;
    }
    try {
      const messages = normalizeSessionMessagesResponse(
        await client.getMessages(sessionId, { limit: 1 }),
      );
      const hasActivity = Array.isArray(messages) && messages.length > 0;
      writeSessionValidationCache(sessionId, { hasActivity });
      return hasActivity;
    } catch {
      writeSessionValidationCache(sessionId, { hasActivity: false });
      return false;
    }
  }

  function ownsThread(threadId) {
    const normalized = readString(threadId);
    return ownership.ownsThread(normalized, OPENCODE_PROVIDER_ID) || threads.has(normalized);
  }

  function syncAuthAndMetaFromListResult(result) {
    if (!result || typeof result !== "object") {
      return;
    }
    if (result.meta && typeof result.meta === "object") {
      lastModelListMeta = result.meta;
    }
    if (Array.isArray(result.connectedProviders)) {
      lastConnectedProviders = result.connectedProviders;
    }

    const meta = result.meta || {};
    const reasonCode = readString(meta.reasonCode);
    const connectedIds = Array.isArray(meta.connectedProviderIds) ? meta.connectedProviderIds : [];
    const modelCount = Array.isArray(result.models) ? result.models.length : 0;

    if (reasonCode === "provider_list_failed" || reasonCode === "unknown") {
      cachedAuthConfigured = null;
      return;
    }
    if (reasonCode === "no_connected_providers") {
      cachedAuthConfigured = false;
      return;
    }
    if (reasonCode === "ok" && modelCount > 0) {
      cachedAuthConfigured = true;
      return;
    }
    if (connectedIds.length > 0 && modelCount === 0) {
      cachedAuthConfigured = null;
      return;
    }
    cachedAuthConfigured = false;
  }

  async function resolveAuthCredentialBundle() {
    const { readAuthProviderIds } = require("./opencode-auth-providers");
    const fromFile = readAuthProviderIds();
    let ids = fromFile.ids;
    let authDiscoveryReasonCode = fromFile.authDiscoveryReasonCode;
    let providerInventoryPartial = false;

    if (fromFile.authDiscoveryReasonCode !== "ok" || ids.length === 0) {
      try {
        await ensureStarted();
        const probeIds =
          typeof client.listAuthProviderIds === "function"
            ? await client.listAuthProviderIds()
            : [];
        if (probeIds.length > 0) {
          ids = probeIds;
          if (fromFile.authDiscoveryReasonCode !== "ok") {
            authDiscoveryReasonCode = "auth_probe_ok";
          }
        } else if (fromFile.authDiscoveryReasonCode !== "ok") {
          providerInventoryPartial = true;
        }
      } catch {
        if (fromFile.authDiscoveryReasonCode !== "ok") {
          providerInventoryPartial = true;
        }
      }
    }

    return { ids, authDiscoveryReasonCode, providerInventoryPartial };
  }

  async function listModels(options = {}) {
    try {
      await ensureStarted();
    } catch {
      return {
        models: [],
        meta: {
          reasonCode: "provider_list_failed",
          connectedProviderIds: [],
          fetchedAt: new Date().toISOString(),
          stale: false,
          modelCountBeforeCap: 0,
          modelCountAfterCap: 0,
        },
      };
    }
    const force = options.force === true || options.refreshProviders === true;
    const authBundle = await resolveAuthCredentialBundle();
    const result = await client.listModels({
      force,
      credentialProviderIDs: authBundle.ids,
      authDiscoveryReasonCode: authBundle.authDiscoveryReasonCode,
    });
    if (result && typeof result === "object" && Array.isArray(result.models)) {
      syncAuthAndMetaFromListResult(result);
      lastListedModels = result.models;
      if (Array.isArray(result.providerInventory)) {
        lastProviderInventory = result.providerInventory;
      }
      if (Array.isArray(result.connectedProviders)) {
        lastConnectedProviders = result.connectedProviders;
      }
      lastAuthDiscoveryReasonCode = readString(result.authDiscoveryReasonCode) || authBundle.authDiscoveryReasonCode;
      lastProviderInventoryPartial =
        result.providerInventoryPartial === true || authBundle.providerInventoryPartial;
      return result;
    }
    const models = Array.isArray(result) ? result : [];
    lastListedModels = models;
    return {
      models,
      meta: lastModelListMeta || {
        reasonCode: models.length > 0 ? "ok" : "unknown",
        connectedProviderIds: [],
        fetchedAt: new Date().toISOString(),
        stale: false,
        modelCountBeforeCap: models.length,
        modelCountAfterCap: models.length,
      },
    };
  }

  // Starts opencode serve in the background so the first model/list is not capped out.
  async function warmup() {
    try {
      await ensureStarted();
      console.log(`${logPrefix} OpenCode warmup complete`);
    } catch (error) {
      console.warn(
        `${logPrefix} OpenCode warmup failed: ${(error && error.message) || error}`,
      );
    }
  }

  async function listAgents() {
    try {
      await ensureStarted();
    } catch {
      return [];
    }
    const agents = await client.listAgents();
    rememberCatalogAgents(agents);
    return agents;
  }

  async function listCommands(directory) {
    const staticBuiltins = buildStaticSlashCommands();
    try {
      await ensureStarted();
    } catch {
      return staticBuiltins;
    }
    // listCommands composes full set (SDK client.command.list + static BUILTINS union in client); dir passed through.
    try {
      return await client.listCommands(directory);
    } catch {
      return staticBuiltins;
    }
  }

  async function listSkills(directory) {
    try {
      await ensureStarted();
    } catch {
      return [];
    }
    return client.listSkills(directory);
  }

  function collectOwnedSessionIds() {
    const ids = new Set();
    for (const [, entry] of sessions.entries()) {
      const sessionId = readString(typeof entry === "string" ? entry : entry?.sessionId);
      if (sessionId) {
        ids.add(sessionId);
      }
    }
    for (const thread of threads.values()) {
      const sessionId = readString(thread.sessionId);
      if (sessionId) {
        ids.add(sessionId);
      }
    }
    return ids;
  }

  function filterDiscoveredRows(rows) {
    const ownedSessionIds = collectOwnedSessionIds();
    return rows.filter((row) => {
      const sessionId = readString(row.metadata?.sessionId || row.sessionId);
      return sessionId && !ownedSessionIds.has(sessionId) && !threads.has(row.id);
    });
  }

  function removeDiscoveredRowFromCache(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId || discoveredSessionsCache.rows.length === 0) {
      return;
    }
    discoveredSessionsCache = {
      ...discoveredSessionsCache,
      rows: discoveredSessionsCache.rows.filter(
        (row) => readString(row.metadata?.sessionId || row.sessionId) !== normalizedSessionId,
      ),
    };
  }

  function scheduleAsyncDiscoverRefresh() {
    if (discoverRefreshInFlight) {
      return;
    }
    void refreshDiscoveredSessionsCache({
      force: true,
      background: true,
    }).catch(() => {});
  }

  async function ensureStartedWithCap({ onTimeout, capMs } = {}) {
    const resolvedCapMs =
      Number.isFinite(capMs) && capMs > 0
        ? capMs
        : resolveEnsureStartedServeWakeCapMs(env);
    const startedAt = Date.now();
    let timeoutId;
    try {
      await Promise.race([
        ensureStarted(),
        new Promise((_, reject) => {
          timeoutId = setTimeout(
            () => reject(new Error("ensure_started_timeout")),
            resolvedCapMs,
          );
          if (readString(env.REMODEX_TEST) === "1" && typeof timeoutId?.unref === "function") {
            timeoutId.unref();
          }
        }),
      ]);
      return { started: true, ms: Date.now() - startedAt, capMs: resolvedCapMs };
    } catch (error) {
      if (readString(error?.message) === "ensure_started_timeout") {
        if (typeof onTimeout === "function") {
          onTimeout();
        }
        return { started: false, ms: Date.now() - startedAt, capMs: resolvedCapMs };
      }
      throw error;
    } finally {
      if (timeoutId) {
        clearTimeout(timeoutId);
      }
    }
  }

  async function ensureStartedWithDiscoverCap() {
    const result = await ensureStartedWithCap({
      capMs: resolveEnsureStartedListCapMs(env),
      onTimeout: () => {
        console.log(
          JSON.stringify({
            event: "discover_refresh_async",
            reason: "ensure_started_timeout",
          }),
        );
        scheduleAsyncDiscoverRefresh();
      },
    });
    return result.started;
  }

  async function refreshDiscoveredSessionsCache({ force = false, background = false } = {}) {
    const cap = resolveDiscoverSessionsCap(env);
    const ttlMs = resolveDiscoverSessionsTtlMs(env);
    const now = Date.now();
    const cacheFresh =
      !force &&
      discoveredSessionsCache.fetchedAt > 0 &&
      now - discoveredSessionsCache.fetchedAt < ttlMs;

    if (cacheFresh) {
      const rows = filterDiscoveredRows(discoveredSessionsCache.rows);
      console.log(
        JSON.stringify({
          event: "opencode_discover_sessions",
          listed: rows.length,
          cache_hit: true,
          background,
        }),
      );
      return rows;
    }

    if (discoverRefreshInFlight) {
      return discoverRefreshInFlight;
    }

    const refreshPromise = (async () => {
      const started = await ensureStartedWithDiscoverCap();
      if (!started && discoveredSessionsCache.rows.length > 0) {
        return filterDiscoveredRows(discoveredSessionsCache.rows);
      }
      if (!healthy || !client || typeof client.listSessions !== "function") {
        return filterDiscoveredRows(discoveredSessionsCache.rows);
      }

      const listResult = await client.listSessions({ limit: cap });
      const ownedSessionIds = collectOwnedSessionIds();
      const rows = [];

      for (const thread of listResult.data || []) {
        const sessionId = readString(thread.metadata?.sessionId || thread.sessionId);
        if (!sessionId) {
          continue;
        }
        if (ownedSessionIds.has(sessionId)) {
          continue;
        }
        if (threads.has(thread.id)) {
          continue;
        }

        if (typeof sessions.setDiscovered === "function") {
          sessions.setDiscovered(sessionId, {
            threadId: thread.id,
            cwd: readString(thread.cwd),
            title: readString(thread.title),
            model: readString(thread.model),
            agent: readString(thread.agent),
          });
        }

        rows.push(thread);
        if (rows.length >= cap) {
          break;
        }
      }

      discoveredSessionsCache = { rows, fetchedAt: Date.now() };
      console.log(
        JSON.stringify({
          event: "opencode_discover_sessions",
          listed: rows.length,
          cache_hit: false,
          background,
        }),
      );
      return rows;
    })();

    discoverRefreshInFlight = refreshPromise.finally(() => {
      if (discoverRefreshInFlight === refreshPromise) {
        discoverRefreshInFlight = null;
      }
    });
    return discoverRefreshInFlight;
  }

  async function discoverExternalSessions() {
    return refreshDiscoveredSessionsCache();
  }

  async function internalAdoptDiscoveredSession(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    const sessionId = parseDiscoveredThreadSessionId(normalizedThreadId);
    if (!sessionId) {
      return null;
    }

    if (ownership.ownsThread(normalizedThreadId, OPENCODE_PROVIDER_ID)) {
      const existing = threads.get(normalizedThreadId);
      if (existing) {
        return existing;
      }
      return rehydrateThreadIfNeeded(normalizedThreadId);
    }

    const ownedBySession =
      typeof sessions.getBySessionId === "function" ? sessions.getBySessionId(sessionId) : null;
    if (ownedBySession?.threadId) {
      if (typeof sessions.markAdopted === "function") {
        sessions.markAdopted(sessionId);
      }
      const ownedThreadId = ownedBySession.threadId;
      if (threads.has(ownedThreadId)) {
        return threads.get(ownedThreadId);
      }
      return rehydrateThreadIfNeeded(ownedThreadId);
    }

    if (adoptMutexes.has(normalizedThreadId)) {
      return adoptMutexes.get(normalizedThreadId);
    }

    const adoptionControl = { cancelled: false };

    function abortAdoptError() {
      const error = new Error("OpenCode session adoption timed out.");
      error.errorCode = "opencode_adopt_timeout";
      return error;
    }

    const adoptPromise = (async () => {
      try {
        let discoveredMeta =
          typeof sessions.getDiscovered === "function"
            ? sessions.getDiscovered(sessionId)
            : null;
        if (!discoveredMeta) {
          const cacheRow = discoveredSessionsCache.rows.find(
            (row) =>
              row.id === normalizedThreadId ||
              readString(row.metadata?.sessionId) === sessionId,
          );
          if (cacheRow) {
            discoveredMeta = {
              threadId: cacheRow.id,
              sessionId,
              cwd: readString(cacheRow.cwd),
              title: readString(cacheRow.title),
              model: readString(cacheRow.model),
              agent: readString(cacheRow.agent),
            };
          }
        }
        if (!discoveredMeta) {
          await refreshDiscoveredSessionsCache({ force: true });
          discoveredMeta =
            typeof sessions.getDiscovered === "function"
              ? sessions.getDiscovered(sessionId)
              : null;
        }
        if (!discoveredMeta) {
          throw threadNotFoundError(normalizedThreadId);
        }

        const ensureStartedResult = await ensureStartedWithCap();
        console.log(
          JSON.stringify({
            event: "adopt_ensure_started_ms",
            ms: ensureStartedResult.ms,
            started: ensureStartedResult.started,
            sessionId,
            threadId: normalizedThreadId,
          }),
        );

        const cwdCandidate = readString(discoveredMeta.cwd) || process.cwd();
        const cwd = await resolveAllowedDirectory(cwdCandidate);
        const title = readString(discoveredMeta.title) || "OpenCode chat";
        const model = normalizeOpenCodeModel(discoveredMeta.model);
        const agent = readString(discoveredMeta.agent) || defaultAgent;
        const now = new Date().toISOString();

        if (adoptionControl.cancelled) {
          throw abortAdoptError();
        }

        const sessionSetOk = sessions.set(normalizedThreadId, sessionId, {
          cwd,
          title,
          model,
          agent,
          discovered: true,
        });
        if (!sessionSetOk) {
          const error = new Error(`Failed to adopt OpenCode session ${sessionId}`);
          error.errorCode = "opencode_adopt_failed";
          throw error;
        }

        try {
          assertOwnershipPersisted(
            ownership.setOwnership(normalizedThreadId, OPENCODE_PROVIDER_ID),
            normalizedThreadId,
          );
        } catch {
          sessions.remove(normalizedThreadId);
          const error = new Error(`Failed to adopt OpenCode session ${sessionId}`);
          error.errorCode = "opencode_adopt_failed";
          throw error;
        }

        if (adoptionControl.cancelled) {
          sessions.remove(normalizedThreadId);
          ownership.removeOwnership(normalizedThreadId);
          throw abortAdoptError();
        }

        const thread = {
          id: normalizedThreadId,
          title,
          cwd,
          model,
          agent,
          createdAt: now,
          updatedAt: now,
          archived: false,
          hasProjectCwd: Boolean(cwd),
          turns: [],
          sessionId,
          userStartedInProcess: true,
        };

        if (ensureStartedResult.started && client && typeof client.getMessages === "function") {
          try {
            const messages = normalizeSessionMessagesResponse(
              await client.getMessages(sessionId),
            );
            if (messages && messages.length > 0) {
              thread.turns = messagesToTurns(messages, normalizedThreadId);
            }
          } catch {
            // thread/read still succeeds with empty turns.
          }
        }

        if (adoptionControl.cancelled) {
          sessions.remove(normalizedThreadId);
          ownership.removeOwnership(normalizedThreadId);
          throw abortAdoptError();
        }

        threads.set(normalizedThreadId, thread);
        if (typeof sessions.markAdopted === "function") {
          sessions.markAdopted(sessionId);
        }
        removeDiscoveredRowFromCache(sessionId);
        rememberThreadProject(thread, "opencode-discovered-adopt");
        return thread;
      } finally {
        if (adoptionControl.cancelled) {
          sessions.remove(normalizedThreadId);
          ownership.removeOwnership(normalizedThreadId);
          threads.delete(normalizedThreadId);
        }
        if (adoptMutexes.get(normalizedThreadId) === racedPromise) {
          adoptMutexes.delete(normalizedThreadId);
        }
      }
    })();

    const timeoutPromise = new Promise((_, reject) => {
      setTimeout(() => {
        adoptionControl.cancelled = true;
        if (adoptMutexes.get(normalizedThreadId) === racedPromise) {
          adoptMutexes.delete(normalizedThreadId);
        }
        reject(abortAdoptError());
      }, resolveAdoptMutexTimeoutMs(env));
    });

    const racedPromise = Promise.race([adoptPromise, timeoutPromise]);
    adoptMutexes.set(normalizedThreadId, racedPromise);
    return racedPromise;
  }

  async function listThreads(params = {}) {
    const limit = boundedPositiveInteger(params.limit, 50);
    const includeArchived = params.includeArchived === true || params.include_archived === true;
    const includeFullRehydrate = readString(env.REMODEX_LIST_THREADS_FULL_REHYDRATE) === "1";

    let removedOrphanOwnership = 0;
    let removedOrphanSession = 0;
    let sdkValidations = 0;
    let userStartedIncluded = 0;
    let activityValidated = 0;
    let materializationBlocked = 0;
    let validationErrors = 0;
    let prunedInvalid = 0;
    let rehydrateSkipped = 0;
    let discoveredExternal = 0;
    let degradedWakeStubs = 0;
    const sdkCap = resolveListThreadsValidateCap(env);
    const hasOwnedThreadState =
      threads.size > 0 ||
      ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID).length > 0 ||
      sessions.entries().length > 0;
    let wakeDegraded = false;
    if ((!healthy || !client) && hasOwnedThreadState) {
      try {
        const wakeResult = await ensureStartedWithCap({
          capMs: resolveEnsureStartedListCapMs(env),
          onTimeout: () => {
            console.log(
              JSON.stringify({
                event: "opencode_list_threads_wake_timeout",
                capMs: resolveEnsureStartedListCapMs(env),
              }),
            );
          },
        });
        if (!wakeResult.started) {
          wakeDegraded = true;
          console.log(
            JSON.stringify({
              event: "opencode_list_threads_wake_failed",
              message: "OpenCode could not start for thread/list within cap",
              ms: wakeResult.ms,
            }),
          );
        }
      } catch (error) {
        console.log(
          JSON.stringify({
            event: "opencode_list_threads_wake_failed",
            message: readString(error?.message) || "OpenCode could not start for thread/list",
          }),
        );
      }
    }
    const canValidateSessions = healthy && client;

    const localThreads = [];
    const ownedStubs = [];

    const consumeSdkValidationBudget = () => {
      if (sdkValidations >= sdkCap) {
        return false;
      }
      sdkValidations += 1;
      return true;
    };

    async function includeInMemoryThread(thread) {
      if (!includeArchived && thread.archived) {
        return false;
      }
      if (thread.userStartedInProcess === true) {
        userStartedIncluded += 1;
        return true;
      }
      if (threadHasActiveTurn(thread.id)) {
        return true;
      }
      const sessionId = readString(thread.sessionId);
      if (!sessionId) {
        materializationBlocked += 1;
        console.log(
          JSON.stringify({
            event: "materialization_blocked",
            threadId: thread.id,
            reason: "in_memory_no_session",
          }),
        );
        return false;
      }
      if (!canValidateSessions) {
        materializationBlocked += 1;
        return false;
      }
      if (!consumeSdkValidationBudget()) {
        materializationBlocked += 1;
        return false;
      }
      try {
        const valid = await validateOwnedThreadSession(sessionId);
        if (!valid) {
          prunedInvalid += 1;
          invalidSessionThreadIds.add(thread.id);
          removeOrphanOpenCodeThread(thread.id);
          return false;
        }
        const hasActivity = await validateThreadHasActivity(thread.id, sessionId);
        if (!hasActivity) {
          materializationBlocked += 1;
          console.log(
            JSON.stringify({
              event: "materialization_blocked",
              threadId: thread.id,
              reason: "no_activity",
            }),
          );
          return false;
        }
        activityValidated += 1;
        return true;
      } catch (error) {
        validationErrors += 1;
        console.log(
          JSON.stringify({
            event: "opencode_list_threads_validation_error",
            threadId: thread.id,
            message: readString(error?.message) || "OpenCode session validation failed",
          }),
        );
        materializationBlocked += 1;
        return false;
      }
    }

    for (const thread of threads.values()) {
      if (await includeInMemoryThread(thread)) {
        localThreads.push(publicThread(thread));
      }
    }

    try {
      const ownedThreads = ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID);
      for (const entry of ownedThreads) {
        const threadId = entry.threadId;
        const live = threads.get(threadId);
        if (live) {
          continue;
        }

        const storeEntry = sessions.getEntry(threadId);
        const sessionId = readString(storeEntry?.sessionId) || sessions.get(threadId);
        if (!sessionId) {
          const removed = removeOrphanOpenCodeThread(threadId);
          if (removed.removedOwnership) {
            removedOrphanOwnership += 1;
          }
          if (removed.removedSession) {
            removedOrphanSession += 1;
          }
          continue;
        }

        if (invalidSessionThreadIds.has(threadId)) {
          const removed = removeOrphanOpenCodeThread(threadId);
          if (removed.removedOwnership) {
            removedOrphanOwnership += 1;
          }
          if (removed.removedSession) {
            removedOrphanSession += 1;
          }
          continue;
        }

        if (threadHasActiveTurn(threadId)) {
          ownedStubs.push(ownershipStubFromStore(threadId, storeEntry));
          continue;
        }

        if (includeFullRehydrate && canValidateSessions) {
          try {
            const thread = await rehydrateThreadIfNeeded(threadId);
            if (await includeInMemoryThread(thread)) {
              ownedStubs.push(publicThread(thread));
            }
          } catch {
            // Skip rows that cannot be rehydrated.
          }
          continue;
        }

        rehydrateSkipped += 1;

        if (!canValidateSessions) {
          if (wakeDegraded) {
            const stub = ownershipStubFromStore(threadId, storeEntry);
            ownedStubs.push({
              ...stub,
              metadata: {
                provider: OPENCODE_PROVIDER_ID,
                degradedWake: true,
              },
            });
            degradedWakeStubs += 1;
            console.log(
              JSON.stringify({
                event: "opencode_list_threads_degraded_stubs",
                threadId,
                reason: "wake_timeout",
              }),
            );
            continue;
          }
          materializationBlocked += 1;
          continue;
        }

        if (!consumeSdkValidationBudget()) {
          materializationBlocked += 1;
          continue;
        }

        try {
          const valid = await validateOwnedThreadSession(sessionId);
          if (!valid) {
            invalidSessionThreadIds.add(threadId);
            prunedInvalid += 1;
            const removed = removeOrphanOpenCodeThread(threadId);
            if (removed.removedOwnership) {
              removedOrphanOwnership += 1;
            }
            if (removed.removedSession) {
              removedOrphanSession += 1;
            }
            continue;
          }
          const hasActivity = await validateThreadHasActivity(threadId, sessionId);
          if (!hasActivity) {
            materializationBlocked += 1;
            console.log(
              JSON.stringify({
                event: "materialization_blocked",
                threadId,
                reason: "no_activity",
              }),
            );
            continue;
          }
          activityValidated += 1;
          ownedStubs.push(ownershipStubFromStore(threadId, storeEntry));
        } catch (error) {
          validationErrors += 1;
          materializationBlocked += 1;
          console.log(
            JSON.stringify({
              event: "opencode_list_threads_validation_error",
              threadId,
              message: readString(error?.message) || "OpenCode session validation failed",
            }),
          );
        }
      }
    } catch {
      // Return in-memory threads when ownership or OpenCode is unavailable.
    }

    let discoveredRows = [];
    if (resolveDiscoverSessionsEnabled(env, params)) {
      try {
        discoveredRows = await discoverExternalSessions();
        discoveredExternal = discoveredRows.length;
      } catch (error) {
        console.log(
          JSON.stringify({
            event: "opencode_discover_sessions_failed",
            message: readString(error?.message) || "discoverExternalSessions failed",
          }),
        );
      }
    }

    console.log(
      JSON.stringify({
        event: "opencode_list_threads_filtered",
        ownership: ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID).length,
        listed: localThreads.length + ownedStubs.length + discoveredExternal,
        local_memory: localThreads.length,
        discovered_external: discoveredExternal,
        removed_orphan_ownership: removedOrphanOwnership,
        removed_orphan_session: removedOrphanSession,
        sdk_validations: sdkValidations,
        sdk_validations_cap: sdkCap,
        user_started_included: userStartedIncluded,
        activity_validated: activityValidated,
        rehydrate_skipped: rehydrateSkipped,
        pruned_invalid: prunedInvalid,
        validation_errors: validationErrors,
        materialization_blocked: materializationBlocked,
        degraded_wake_stubs: degradedWakeStubs,
      }),
    );
    maybeLogOpenCodePruneOpsHint({ materializationBlocked });

    const seen = new Set();
    const data = [...localThreads, ...ownedStubs, ...discoveredRows]
      .filter((thread) => {
        if (!thread?.id || seen.has(thread.id)) return false;
        seen.add(thread.id);
        return true;
      })
      .toSorted(compareThreadsByUpdatedAt)
      .slice(0, limit);

    return {
      data,
      nextCursor: null,
      meta: {
        materializationBlocked,
        sdkValidations,
        sdkValidationsCap: sdkCap,
      },
    };
  }

  async function handleRequest(request) {
    const method = readString(request?.method);
    switch (method) {
      case "thread/start":
        return threadStart(request);
      case "thread/resume":
      case "thread/read":
        return threadRead(request);
      case "thread/turns/list":
        return threadTurnsList(request);
      case "thread/name/set":
        return threadNameSet(request);
      case "thread/archive":
        return threadArchive(request, true);
      case "thread/unarchive":
        return threadArchive(request, false);
      case "thread/fork":
        return threadFork(request);
      case "turn/start":
        return turnStart(request);
      case "turn/interrupt":
        return turnInterrupt(request);
      case "permission/reply":
        return permissionReply(request);
      default:
        throw unsupportedMethodError(method);
    }
  }

  function handleApplicationResponse() {
    return false;
  }

  async function shutdown() {
    stopIdleTimer();
    for (const [, unsubscribe] of eventUnsubscribers) {
      unsubscribe();
    }
    eventUnsubscribers.clear();
    clearAllPendingPermissions();
    activeTurns.clear();
    inFlightThreadIds.clear();
    completedTurnIds.clear();
    await server.stop();
    client = null;
    healthy = false;
  }

  async function threadStart(request) {
    const params = request.params || {};
    const now = new Date().toISOString();
    const requestedCwd = resolvedParam(params, 'cwd', 'current_working_directory', 'working_directory');
    const threadId = `${OPENCODE_PROVIDER_ID}-thread-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const resolvedSessionId = resolvedParam(params, 'sessionId', 'session_id');
    let cwd = process.cwd();
    if (requestedCwd) {
      cwd = await resolveAllowedDirectory(requestedCwd);
    }
    const thread = {
      id: threadId,
      title: readString(params.title) || "OpenCode chat",
      cwd,
      model: normalizeOpenCodeModel(params.model),
      agent: readString(params.agent) || defaultAgent,
      createdAt: now,
      updatedAt: now,
      archived: false,
      hasProjectCwd: Boolean(requestedCwd),
      turns: [],
      sessionId: resolvedSessionId || "",
      userStartedInProcess: true,
    };
    threads.set(threadId, thread);
    assertOwnershipPersisted(
      ownership.setOwnership(threadId, OPENCODE_PROVIDER_ID),
      threadId,
    );
    if (resolvedSessionId) {
      thread.sessionId = resolvedSessionId;
      persistSessionRecord(thread);
    }
    rememberThreadProject(thread, "opencode-thread-start");
    return { thread: publicThread(thread) };
  }

  async function threadRead(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    let thread = await internalAdoptDiscoveredSession(threadId);
    if (!thread) {
      thread = await requireThread(threadId);
    }
    thread = await ensureThreadSession(thread);

    rememberThreadProject(thread, "opencode-thread-read");
    const responseThread = { ...publicThread(thread) };
    if (params.includeTurns === true || params.include_turns === true) {
      responseThread.turns = thread.turns || [];
    }
    return { thread: responseThread };
  }

  async function threadTurnsList(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const thread = await ensureThreadSession(await requireThread(threadId));

    const limit = boundedPositiveInteger(params.limit, 50);
    const sortDirection = resolvedParam(params, 'sortDirection', 'sort_direction') || "desc";
    const turns = [...(thread.turns || [])];
    if (sortDirection === "asc") turns.reverse();

    // In-memory turns carry canonical bridge turn/item ids that match live notifications.
    // SDK-derived turns use synthetic ids (turn-0, user-0) and cause duplicate iOS bubbles
    // when history pagination reconciles against optimistic/live rows.
    if (turns.length > 0) {
      return { data: turns.slice(0, limit), nextCursor: null };
    }

    // Try SDK messages if session exists (e.g. provider restart with empty in-memory turns)
    if (thread.sessionId) {
      try {
        await ensureStarted();
        const messages = normalizeSessionMessagesResponse(await client.getMessages(thread.sessionId));
        if (messages && messages.length > 0) {
          const sdkTurns = messagesToTurns(messages, threadId);
          return { data: sdkTurns.slice(0, limit), nextCursor: null };
        }
      } catch {
        // Fall through to in-memory turns
      }
    }

    return { data: turns.slice(0, limit), nextCursor: null };
  }

  async function turnStart(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const thread = await requireThread(threadId);
    markUserStartedInProcess(thread);

    for (const [, active] of activeTurns) {
      if (active.thread.id === threadId) throw activeTurnError(threadId);
    }
    if (inFlightThreadIds.has(threadId)) {
      throw activeTurnError(threadId);
    }

    const model = normalizeOpenCodeModel(params.model || thread.model);
    const { inputText, prompt, parts, skills: structuredSkills = [] } = buildPromptFromTurnInput(params.input, {
      attachmentStore,
      attachmentsEnabled: isAttachmentsEnabled(env),
    });
    if (!prompt && (!Array.isArray(parts) || parts.length === 0)) {
      const error = new Error("OpenCode turn/start requires text input.");
      error.errorCode = "opencode_input_required";
      throw error;
    }

    const requestedAgent = resolvedParam(params, 'agent', 'mode');
    if (requestedAgent && Array.isArray(lastCatalogAgents) && lastCatalogAgents.length > 0) {
      const agentKnown = lastCatalogAgents.some(
        (entry) => readString(entry?.id || entry?.name || entry) === requestedAgent,
      );
      if (!agentKnown) {
        const error = new Error(`OpenCode agent "${requestedAgent}" is not available in the current catalog.`);
        error.errorCode = "opencode_agent_unavailable";
        throw error;
      }
    }
    thread.model = model;
    thread.agent = requestedAgent || thread.agent || defaultAgent;
    thread.updatedAt = new Date().toISOString();

    // Plan mode is per-turn: iOS sends collaborationMode {mode:"plan"}; the
    // thread's selected agent stays untouched and the override is resolved
    // against the agent catalog inside executeTurn.
    const planModeRequested = isPlanModeRequested(params);

    const turnId = `${OPENCODE_PROVIDER_ID}-turn-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const effort = resolvedParam(params, 'reasoningEffort', 'reasoning_effort', 'effort');
    const now = new Date().toISOString();
    const assistantItemId = `${OPENCODE_PROVIDER_ID}-agent-${turnId}`;

    const turn = {
      id: turnId,
      model,
      status: "running",
      createdAt: now,
      items: [
        {
          id: `${OPENCODE_PROVIDER_ID}-user-${turnId}`,
          type: "userMessage",
          role: "user",
          text: inputText,
          content: textContent(inputText),
          createdAt: now,
        },
        {
          id: assistantItemId,
          type: "agentMessage",
          role: "assistant",
          phase: "final",
          text: "",
          content: textContent(""),
          createdAt: now,
        },
      ],
      metadata: { threadId, provider: OPENCODE_PROVIDER_ID },
    };
    thread.turns.push(turn);

    const active = {
      agent: thread.agent,
      assistantItemId,
      effort,
      planModeRequested,
      sessionId: "",
      thread,
      turn,
      started: false,
      completed: false,
    };
    activeTurns.set(turnId, active);
    assertOwnershipPersisted(
      ownership.setOwnership(thread.id, OPENCODE_PROVIDER_ID),
      thread.id,
    );

    Promise.resolve()
      .then(() => executeTurn(active, model, thread.agent, effort, prompt, parts, thread.cwd, structuredSkills))
      .catch((error) => {
        console.error(`${logPrefix} OpenCode turn execution failed: ${error.message}`);
        internalCompleteTurn({
          status: "failed",
          errorMessage: error.message || "OpenCode turn execution failed",
          errorCode: error.errorCode || "opencode_turn_failed",
          action: error.action || "show_retry",
          active,
          source: "executeTurn_error",
        });
      });
    return { turnId, turn: { id: turnId, threadId: thread.id, status: "running" } };
  }

  function extractLatestAssistantText(messages) {
    if (!Array.isArray(messages)) {
      return "";
    }
    let latest = "";
    for (const message of messages) {
      if (!isOpenCodeAssistantMessage(message)) {
        continue;
      }
      const text = extractOpenCodeMessageText(message);
      if (text) {
        latest = text;
      }
    }
    return latest;
  }

  function extractAssistantTextAfterCurrentPrompt(messages, prompt) {
    if (!Array.isArray(messages)) {
      return "";
    }

    const normalizedPrompt = readString(prompt).trim();
    if (!normalizedPrompt) {
      return extractLatestAssistantText(messages);
    }

    let promptIndex = -1;
    for (let index = 0; index < messages.length; index += 1) {
      const message = messages[index];
      if (isOpenCodeAssistantMessage(message)) {
        continue;
      }
      const text = extractOpenCodeMessageText(message).trim();
      if (text === normalizedPrompt) {
        promptIndex = index;
      }
    }

    if (promptIndex >= 0) {
      let latest = "";
      for (let index = promptIndex + 1; index < messages.length; index += 1) {
        const message = messages[index];
        if (isOpenCodeAssistantMessage(message)) {
          const text = extractOpenCodeMessageText(message);
          if (text) {
            latest = text;
          }
        } else {
          const text = extractOpenCodeMessageText(message).trim();
          if (text) {
            latest = "";
          }
        }
      }
      return latest;
    }

    const hasUserMessages = messages.some(
      (message) => !isOpenCodeAssistantMessage(message) && extractOpenCodeMessageText(message).trim(),
    );
    if (hasUserMessages) {
      return "";
    }

    return extractLatestAssistantText(messages);
  }

  function assistantAgentItem(active) {
    return active.turn.items.find((item) => item.type === "agentMessage");
  }

  function isTurnAssistantFinalized(active) {
    const assistantItem = assistantAgentItem(active);
    return Boolean(assistantItem?.finalized === true && readString(assistantItem.text));
  }

  function tryCompleteTurnWhenAssistantReady(active, source = "") {
    if (active.completed || !isTurnAssistantFinalized(active)) {
      return false;
    }
    return internalCompleteTurn({
      status: "completed",
      active,
      source: readString(source) || "assistant_ready",
    });
  }

  function emitAssistantCompletedOnce(active, params, source) {
    const assistantItem = active.turn.items.find((item) => item.type === "agentMessage");
    if (!assistantItem) {
      return false;
    }
    if (assistantItem.finalized === true) {
      console.log(
        JSON.stringify({
          event: "opencode_item_completed_skipped",
          threadId: active.thread.id,
          turnId: active.turn.id,
          source,
          reason: "already_finalized",
        }),
      );
      return false;
    }

    const text =
      readString(params?.message) ||
      readString(params?.item?.text) ||
      readString(assistantItem.text) ||
      "";
    if (!text) {
      return false;
    }
    assistantItem.text = text;

    const canonicalParams = {
      ...params,
      threadId: active.thread.id,
      turnId: active.turn.id,
      itemId: assistantItem.id,
      message: text,
      item: {
        ...(params?.item ?? {}),
        id: assistantItem.id,
        turnId: active.turn.id,
        type: "agentMessage",
        phase: "final",
        text,
      },
    };

    assistantItem.finalized = true;
    emit("item/completed", canonicalParams);
    return true;
  }

  async function hydrateAssistantFromSessionMessages(active) {
    if (!client || !readString(active.sessionId) || active.completed) {
      return false;
    }

    let messages = [];
    try {
      messages = normalizeSessionMessagesResponse(await client.getMessages(active.sessionId));
    } catch (error) {
      console.log(
        JSON.stringify({
          event: "opencode_hydrate_messages_error",
          threadId: active.thread.id,
          turnId: active.turn.id,
          message: readString(error?.message) || "getMessages failed",
        }),
      );
      return false;
    }

    const userItem = active.turn.items.find((item) => item.type === "userMessage");
    const text = extractAssistantTextAfterCurrentPrompt(messages, userItem?.text);
    if (!text) {
      return false;
    }

    const assistantItem = active.turn.items.find((item) => item.type === "agentMessage");
    if (!assistantItem) {
      return false;
    }

    const hadText = Boolean(readString(assistantItem.text));
    assistantItem.text = text;
    if (!hadText) {
      emit("item/agentMessage/delta", {
        threadId: active.thread.id,
        turnId: active.turn.id,
        itemId: assistantItem.id,
        delta: text,
        textDelta: text,
        assistantPhase: "final",
      });
    }

    const completed = emitAssistantCompletedOnce(
      active,
      {
        message: text,
        assistantPhase: "final_answer",
        item: {
          id: assistantItem.id,
          turnId: active.turn.id,
          type: "agentMessage",
          phase: "final",
          text,
        },
      },
      "hydrate",
    );
    if (!completed) {
      return false;
    }

    console.log(
      JSON.stringify({
        event: "opencode_turn_hydrated",
        threadId: active.thread.id,
        turnId: active.turn.id,
        assistantLen: text.length,
        hadStreamedText: hadText,
      }),
    );
    return true;
  }

  function delayMs(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function pollForAssistantCompletion(active) {
    const intervalMs = readString(env.REMODEX_TEST) === "1" ? 10 : 2000;
    const deadline = Date.now() + resolveOpenCodeTurnWatchdogMs(env);
    while (!active.completed && Date.now() < deadline) {
      await hydrateAssistantFromSessionMessages(active);
      if (tryCompleteTurnWhenAssistantReady(active, "poll_messages")) {
        return;
      }
      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        break;
      }
      await delayMs(Math.min(intervalMs, remainingMs));
    }
  }

  async function executeTurn(active, model, agent, effort, prompt, parts, cwd, skills = []) {
    const threadId = active.thread.id;
    inFlightThreadIds.add(threadId);
    try {
      const ensureStartedResult = await ensureStartedWithCap({
        capMs: resolveEnsureStartedServeWakeCapMs(env),
      });
      if (!ensureStartedResult.started) {
        const error = new Error("OpenCode is still starting. Try again in a moment.");
        error.errorCode = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
        error.action = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.action;
        throw error;
      }

      if (!active.started) {
        active.started = true;
        emit("turn/started", {
          threadId: active.thread.id,
          turnId: active.turn.id,
          turn: { id: active.turn.id, status: "running" },
        });
        console.log(
          JSON.stringify({
            event: "opencode_turn_started_after_wake",
            threadId: active.thread.id,
            turnId: active.turn.id,
            ensureStartedMs: ensureStartedResult.ms,
            capMs: ensureStartedResult.capMs,
          }),
        );
      }

      if (!active.thread.sessionId) {
        const sessionId = await client.createSession({ cwd });
        if (!readString(sessionId)) {
          const error = new Error(
            "OpenCode createSession returned no session id; cannot persist session or send prompt.",
          );
          error.errorCode = ERROR_CODES.OPENCODE_TURN_FAILED.errorCode;
          error.action = ERROR_CODES.OPENCODE_TURN_FAILED.action;
          throw error;
        }
        active.sessionId = sessionId;
        active.thread.sessionId = sessionId;
        persistSessionRecord(active.thread);
      } else {
        active.sessionId = active.thread.sessionId;
      }

      if (!readString(active.sessionId)) {
        const error = new Error(
          "OpenCode turn requires a session id before prompt; session id is missing.",
        );
        error.errorCode = ERROR_CODES.OPENCODE_TURN_FAILED.errorCode;
        error.action = ERROR_CODES.OPENCODE_TURN_FAILED.action;
        throw error;
      }

      const effectiveAgent = active.planModeRequested
        ? await resolvePlanAgentOverride(agent)
        : agent;

      const clearWatchdog = () => {
        if (active.watchdogTimer) {
          clearTimeout(active.watchdogTimer);
          active.watchdogTimer = null;
        }
      };

      const scheduleWatchdog = () => {
        clearWatchdog();
        active.watchdogTimer = setTimeout(() => {
          if (active.completed) {
            return;
          }
          // Enforce watchdog: fire error if no complete within window (no hydrate recovery here).
          internalCompleteTurn({
            status: "failed",
            errorMessage: "OpenCode turn timed out waiting for completion.",
            errorCode: "opencode_turn_watchdog_timeout",
            active,
            source: "watchdog",
          });
        }, resolveOpenCodeTurnWatchdogMs(env));
        if (readString(process.env.REMODEX_TEST) === "1" && typeof active.watchdogTimer?.unref === "function") {
          active.watchdogTimer.unref();
        }
      };

      const sseReconnectEnabled = readString(env.REMODEX_OPENCODE_SSE_RECONNECT) !== "0";
      const unsubscribe = client.subscribeToEvents((method, params) => {
        if (active.completed) return;

        const eventTurnId = readString(params.turnId || params.turnID);
        pruneCompletedTurnIds();
        if (method === "turn/completed" && completedTurnIds.has(active.turn.id)) {
          return;
        }

        console.log(
          JSON.stringify({
            event: "opencode_turn_event",
            sseType: method,
            threadId: active.thread.id,
            turnId: active.turn.id,
            hasTurnId: Boolean(eventTurnId),
          }),
        );

        // Strict late guard (MSG-3): skip + trace if event's turnId no longer matches active for thread.
        // Prevents late deltas/completions from prior turns on same thread being forwarded after new turn starts.
        const eventThreadId = readString(params && (params.threadId || params.thread_id)) || readString(active.thread.id);
        const eventTurnIdForCheck = readString(eventTurnId || (params && (params.turnId || params.turn_id)));
        if (eventTurnIdForCheck && eventThreadId) {
          const currentActiveForThread = findActiveTurnByThread(eventThreadId);
          if (currentActiveForThread && currentActiveForThread !== eventTurnIdForCheck) {
            console.log(
              JSON.stringify({
                event: "bridge_late_delta_suppressed",
                threadId: eventThreadId,
                turnId: eventTurnIdForCheck,
                activeTurnId: currentActiveForThread,
                method,
                reason: "active_turn_mismatch",
              })
            );
            return;
          }
        }

        const enriched = {
          ...params,
          threadId: active.thread.id,
          turnId: active.turn.id,
        };

        if (method === "item/agentMessage/delta") {
          const assistantItem = active.turn.items.find((item) => item.type === "agentMessage");
          if (assistantItem) {
            assistantItem.text += readString(params.delta || "");
          }
        }

        if (method === "turn/failed") {
          if (eventTurnId && eventTurnId !== active.turn.id) {
            return;
          }
          authErrorNotifier.inspectTurnFailure({
            threadId: active.thread.id,
            turnId: active.turn.id,
            message: readString(params.message),
            error: params.error,
          });
          internalCompleteTurn({
            status: "failed",
            errorMessage: readString(params.message) || "OpenCode session error",
            active,
            source: "turn_failed",
          });
          clearWatchdog();
          return;
        }

        if (method === "runtime/auth/error") {
          authErrorNotifier.notifyAuthError({
            ...params,
            threadId: active.thread.id,
            turnId: active.turn.id,
          });
          return;
        }

        if (method === "turn/completed") {
          if (eventTurnId && eventTurnId !== active.turn.id) {
            return;
          }
          const completionSource = readString(params.completionSource);
          void (async () => {
            await hydrateAssistantFromSessionMessages(active);
            if (active.completed) {
              return;
            }
            if (completionSource === "session.idle" && !isTurnAssistantFinalized(active)) {
              return;
            }
            internalCompleteTurn({
              status: readString(params.status) || "completed",
              active,
              source: completionSource || "turn_completed",
            });
            clearWatchdog();
          })();
          return;
        }

        if (method === "item/completed") {
          emitAssistantCompletedOnce(active, enriched, "sse");
          tryCompleteTurnWhenAssistantReady(active, "sse_item_completed");
          return;
        }

        if (method === "permission/request") {
          handlePermissionRequestEvent(active, enriched);
          return;
        }

        if (method === "event/streamError") {
          console.log(
            JSON.stringify({
              event: "opencode_sse_stream_error",
              threadId: active.thread.id,
              turnId: active.turn.id,
              message: readString(params.message),
              attempt: params.attempt,
            }),
          );
          return;
        }

        emit(method, enriched);
      }, {
        reconnectEnabled: sseReconnectEnabled,
        onResubscribe: () => {
          sseReconnectCount += 1;
          void hydrateAssistantFromSessionMessages(active)
            .then((hydrated) => {
              if (hydrated) {
                tryCompleteTurnWhenAssistantReady(active, "sse_resubscribe_hydrate");
              }
            })
            .catch(() => {});
        },
      });
      eventUnsubscribers.set(active.turn.id, unsubscribe);

      const parsedModel = parseOpenCodeModelSlug(model);
      const catalogModel = lastListedModels.find(
        (entry) => readString(entry.id || entry.model) === readString(model),
      );
      const { variant, omittedReason } = resolveOpenCodeVariantForPrompt({
        effort,
        modelRecord: catalogModel?.serveVariants
          ? { variants: catalogModel.serveVariants }
          : null,
      });
      if (omittedReason) {
        console.log(
          JSON.stringify({
            event: "opencode_turn_prompt",
            variant_omitted_reason: omittedReason,
            effort: readString(effort) || null,
          }),
        );
      }

      if (active.completed) {
        return;
      }

      scheduleWatchdog();

      const pollTask = pollForAssistantCompletion(active);
      try {
        await client.prompt({
          sessionID: active.sessionId,
          prompt,
          parts,
          cwd,
          model: parsedModel || model,
          agent: effectiveAgent,
          variant,
          threadId: active.thread.id,
          turnId: active.turn.id,
          skills,
        });
      } finally {
        if (!active.completed) {
          await hydrateAssistantFromSessionMessages(active);
          tryCompleteTurnWhenAssistantReady(active, "prompt_finally");
        }
      }
      if (!active.completed) {
        await pollTask;
      }
      if (!active.completed) {
        tryCompleteTurnWhenAssistantReady(active, "prompt_post_poll");
      }
    } catch (error) {
      if (!active.completed) {
        internalCompleteTurn({
          errorMessage: error?.message || "OpenCode SDK turn failed.",
          errorCode: error?.errorCode || ERROR_CODES.OPENCODE_TURN_FAILED.errorCode,
          action: error?.action || ERROR_CODES.OPENCODE_TURN_FAILED.action,
          status: "failed",
          active,
        });
      }
    } finally {
      inFlightThreadIds.delete(threadId);
    }
  }

  function internalCompleteTurn({
    errorMessage = "",
    errorCode = "",
    action = "",
    status,
    active,
    source = "",
  }) {
    const turnId = active.turn.id;
    pruneCompletedTurnIds();
    if (active.completed || completedTurnIds.has(turnId)) return false;
    active.completed = true;
    completedTurnIds.set(turnId, Date.now());

    if (active.watchdogTimer) {
      clearTimeout(active.watchdogTimer);
      active.watchdogTimer = null;
    }

    const unsubscribe = eventUnsubscribers.get(turnId);
    if (unsubscribe) {
      unsubscribe();
      eventUnsubscribers.delete(turnId);
    }

    activeTurns.delete(turnId);
    active.thread.updatedAt = new Date().toISOString();
    active.turn.status = status;
    active.turn.completedAt = active.thread.updatedAt;

    if (errorMessage) {
      active.turn.error = { message: errorMessage, errorCode: errorCode || null, action: action || null };
    }

    const assistantItem = assistantAgentItem(active);
    if (assistantItem && assistantItem.text && assistantItem.finalized !== true) {
      emitAssistantCompletedOnce(
        active,
        {
          message: assistantItem.text,
          assistantPhase: "final_answer",
          item: {
            id: assistantItem.id,
            turnId,
            type: "agentMessage",
            phase: "final",
            text: assistantItem.text,
          },
        },
        "completeTurn",
      );
    }

    const completionEvent = status === "failed" ? "opencode_turn_failed" : "opencode_turn_completed";
    console.log(
      JSON.stringify({
        event: completionEvent,
        threadId: active.thread.id,
        turnId,
        status,
        source: readString(source) || null,
        assistantLen: readString(assistantItem?.text).length,
        ...(errorMessage
          ? { message: errorMessage, errorCode: errorCode || null }
          : {}),
      }),
    );

    emit("turn/completed", {
      threadId: active.thread.id,
      turnId,
      model: active.thread.model,
      status,
      turn: { id: turnId, status, error: errorMessage ? { message: errorMessage } : undefined },
    });

    if (status !== "failed") {
      void pushThreadUsageUpdate(active.thread);
    } else {
      authErrorNotifier.inspectTurnFailure({
        threadId: active.thread.id,
        turnId,
        message: errorMessage,
        error: active.turn.error,
      });
    }

    resetIdleTimer();
    return true;
  }

  function isOpenCodePermissionsUIEnabled(currentEnv = env) {
    const raw = readString(currentEnv?.REMODEX_OPENCODE_PERMISSIONS_UI);
    return raw !== "0" && raw?.toLowerCase() !== "false";
  }

  function redactPermissionArgs(args) {
    if (!args || typeof args !== "object") {
      return "";
    }
    const lines = Object.entries(args).map(([key, value]) => {
      const rendered = typeof value === "string" ? value : JSON.stringify(value);
      if (/^[A-Z0-9_]+$/.test(key) || SENSITIVE_PERMISSION_ARG_KEYS.has(key.toLowerCase())) {
        return `${key}=***`;
      }
      return `${key}=${rendered}`;
    });
    let summary = lines.join("\n");
    if (summary.length > 500) {
      summary = `${summary.slice(0, 500)}…(truncated)`;
    }
    return summary;
  }

  function clearPermissionWatchdog(entry) {
    if (entry?.watchdog) {
      clearTimeout(entry.watchdog);
      entry.watchdog = null;
    }
  }

  function clearAllPendingPermissions() {
    for (const pending of pendingPermissions.values()) {
      clearPermissionWatchdog(pending);
    }
    pendingPermissions.clear();
  }

  function evictOldestPendingPermission() {
    const oldestPermissionId = pendingPermissions.keys().next().value;
    if (!oldestPermissionId) {
      return null;
    }

    const evicted = pendingPermissions.get(oldestPermissionId);
    clearPermissionWatchdog(evicted);
    pendingPermissions.delete(oldestPermissionId);
    void (async () => {
      try {
        await ensureStarted();
        await client.replyToPermission(oldestPermissionId, false);
      } catch (error) {
        const context = evicted ? {
          permissionId: oldestPermissionId,
          threadId: evicted.threadId,
          turnId: evicted.turnId,
          sessionId: evicted.sessionId,
        } : { permissionId: oldestPermissionId };
        console.error(formatStructuredError(
          logPrefix,
          "permission cap eviction auto-deny failed",
          { ...context, error: error.message }
        ));
      }
    })();
    return evicted;
  }

  function armPermissionWatchdog(entry, payload) {
    clearPermissionWatchdog(entry);
    entry.watchdog = setTimeout(() => {
      void (async () => {
        pendingPermissions.delete(payload.permissionId);
        try {
          await ensureStarted();
          await client.replyToPermission(payload.permissionId, false);
          emit("turn/failed", {
            threadId: payload.threadId,
            turnId: payload.turnId,
            message: "Permission required — update Remodex to respond.",
            errorCode: ERROR_CODES.OPENCODE_PERMISSION_TIMEOUT.errorCode,
          });
        } catch (error) {
          console.error(formatStructuredError(
            logPrefix,
            "permission auto-deny failed",
            {
              permissionId: payload.permissionId,
              threadId: payload.threadId,
              turnId: payload.turnId,
              sessionId: payload.sessionId,
              error: error.message,
            }
          ));
        }
      })();
    }, PERMISSION_WATCHDOG_MS);
    if (readString(process.env.REMODEX_TEST) === "1" && typeof entry.watchdog?.unref === "function") {
      entry.watchdog.unref();
    }
  }

  function handlePermissionRequestEvent(active, params) {
    const permissionId = readString(params.permissionId || params.permission_id || params.requestId);
    const tool = readString(params.tool || params.toolName) || "tool";
    const sessionId = readString(params.sessionId || params.session_id || active.sessionId);
    if (!permissionId) {
      return;
    }

    if (sessionId) {
      const grants = sessionPermissionGrants.get(sessionId);
      if (grants?.has(tool)) {
        void (async () => {
          try {
            await ensureStarted();
            await client.replyToPermission(permissionId, true);
          } catch (error) {
            console.error(formatStructuredError(
              logPrefix,
              "auto-allow permission failed",
              {
                permissionId,
                threadId: active.thread?.id,
                turnId: active.turn?.id,
                sessionId,
                tool,
                error: error.message,
              }
            ));
          }
        })();
        return;
      }
    }

    const requestedAt = new Date().toISOString();
    const payload = {
      permissionId,
      threadId: readString(params.threadId || active.thread.id),
      turnId: readString(params.turnId || active.turn.id),
      sessionId: sessionId || null,
      tool,
      args: params.args && typeof params.args === "object" ? params.args : {},
      cwd: readString(params.cwd || active.thread.cwd) || null,
      requestedAt,
    };

    const existing = pendingPermissions.get(permissionId);
    clearPermissionWatchdog(existing);
    if (!existing) {
      while (pendingPermissions.size >= MAX_PENDING_PERMISSIONS) {
        evictOldestPendingPermission();
      }
    }
    const entry = { ...payload, watchdog: null };
    pendingPermissions.set(permissionId, entry);

    if (!isOpenCodePermissionsUIEnabled()) {
      armPermissionWatchdog(entry, payload);
      return;
    }

    emit("permission/request", {
      permissionId: payload.permissionId,
      threadId: payload.threadId,
      turnId: payload.turnId,
      sessionId: payload.sessionId,
      tool: payload.tool,
      cwd: payload.cwd,
      requestedAt: payload.requestedAt,
      argsSummary: redactPermissionArgs(payload.args),
    });
    armPermissionWatchdog(entry, payload);
  }

  function testSeedPendingPermission(permissionId, fields = {}) {
    pendingPermissions.set(permissionId, {
      permissionId,
      threadId: readString(fields.threadId) || "test-thread",
      turnId: readString(fields.turnId) || null,
      sessionId: readString(fields.sessionId) || null,
      tool: readString(fields.tool) || "bash",
      requestedAt: new Date().toISOString(),
      watchdog: null,
    });
  }

  function getObservabilityMetrics() {
    return {
      sseReconnectCount,
      permissionPendingCount: pendingPermissions.size,
      catalogRefreshMs: lastModelListMeta?.refreshMs ?? null,
    };
  }

  async function permissionReply(request) {
    const params = request.params || {};
    const permissionId = readString(
      params.permissionId || params.permission_id || params.requestId,
    );
    const allow = params.allow === true || params.approved === true || params.accept === true;
    const scope = readString(params.scope) || "once";
    const sessionId = readString(params.sessionId || params.session_id);
    if (!permissionId) {
      return { success: false, reason: "Missing permission ID" };
    }

    const pending = pendingPermissions.get(permissionId);
    if (!pending) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "unknown_or_expired",
        }),
      );
      return { success: false, reason: "Unknown or expired permission ID" };
    }

    const replyThreadId = readThreadId(params);
    if (!replyThreadId) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "missing_thread_id",
        }),
      );
      return { success: false, reason: "Missing thread ID" };
    }
    if (replyThreadId !== pending.threadId) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "thread_id_mismatch",
          expectedThreadId: pending.threadId,
          replyThreadId,
        }),
      );
      return { success: false, reason: "Permission thread ID does not match" };
    }

    if (sessionId && sessionId !== readString(pending.sessionId)) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "session_id_mismatch",
          expectedSessionId: pending.sessionId,
          replySessionId: sessionId,
        }),
      );
      return { success: false, reason: "Permission session ID does not match" };
    }

    clearPermissionWatchdog(pending);

    try {
      await ensureStarted();
      await client.replyToPermission(permissionId, allow);

      if (allow && scope === "session") {
        const resolvedSessionId = sessionId || pending.sessionId;
        const tool = readString(pending.tool);
        if (resolvedSessionId && tool) {
          const grants = sessionPermissionGrants.get(resolvedSessionId) || new Set();
          grants.add(tool);
          sessionPermissionGrants.set(resolvedSessionId, grants);
        }
      }

      pendingPermissions.delete(permissionId);
      return { success: true, permissionId, allow, scope };
    } catch (error) {
      pendingPermissions.set(permissionId, pending);
      if (!isOpenCodePermissionsUIEnabled()) {
        armPermissionWatchdog(pending, {
          permissionId,
          threadId: pending.threadId,
          turnId: pending.turnId,
        });
      }
      return { success: false, reason: error.message };
    }
  }

  async function turnInterrupt(request) {
    const params = request.params || {};
    const turnId = readString(params.turnId || params.turn_id);
    const threadId = readThreadId(params);
    const resolvedTurnId = turnId || findActiveTurnByThread(threadId);
    const active = activeTurns.get(resolvedTurnId);
    if (!active) return { success: true, interrupted: false };

    try {
      if (readString(active.sessionId)) {
        await ensureStarted();
        await client.abort(active.sessionId);
      }
    } catch {
      // Best effort
    }

    internalCompleteTurn({ status: "stopped", active });
    return { success: true, interrupted: true };
  }

  function findActiveTurnByThread(threadId) {
    for (const [turnId, active] of activeTurns) {
      if (active.thread.id === threadId) return turnId;
    }
    return "";
  }

  async function threadNameSet(request) {
    const params = request.params || {};
    const thread = await requireThread(readThreadId(params));

    const name = resolvedParam(params, 'name', 'title');
    if (name) {
      thread.title = name;
      thread.updatedAt = new Date().toISOString();
      persistSessionRecord(thread);
    }

    const publicValue = publicThread(thread);
    emit("thread/name/updated", {
      threadId: publicValue.id,
      thread_id: publicValue.id,
      name: publicValue.name,
      title: publicValue.title,
    });
    return { thread: publicValue };
  }

  async function threadArchive(request, archived) {
    const threadId = readThreadId(request.params);
    const inMemory = threads.get(threadId);
    if (inMemory) {
      inMemory.archived = archived;
      inMemory.updatedAt = new Date().toISOString();
      persistSessionRecord(inMemory);
      return { thread: publicThread(inMemory) };
    }

    if (!ownership.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
      throw threadNotFoundError(threadId);
    }

    if (archived) {
      removeOrphanOpenCodeThread(threadId, "opencode_thread_archived_stub_removed");
      return {
        thread: {
          id: threadId,
          title: "OpenCode chat",
          archived: true,
          provider: OPENCODE_PROVIDER_ID,
          modelProvider: OPENCODE_PROVIDER_ID,
        },
      };
    }

    throw threadNotFoundError(threadId);
  }

  async function threadFork(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const thread = await requireThread(threadId);
    if (!thread.sessionId) {
      const error = new Error("OpenCode fork requires a session on the source thread");
      error.errorCode = "opencode_fork_requires_session";
      throw error;
    }

    try {
      await ensureStarted();
    } catch (error) {
      if (error.errorCode === ERROR_CODES.OPENCODE_NOT_INSTALLED.errorCode) {
        const forkError = new Error("OpenCode server is unreachable. Fork could not complete.");
        forkError.errorCode = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
        forkError.action = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.action;
        throw forkError;
      }
      throw error;
    }
    const newSessionId = await client.fork(thread.sessionId);
    if (!readString(newSessionId)) {
      const error = new Error(
        "OpenCode session.fork returned no session id; cannot start forked thread.",
      );
      error.errorCode = "opencode_fork_empty_session";
      throw error;
    }
    return threadStart({
      params: {
        sessionId: newSessionId,
        model: thread.model,
        agent: thread.agent,
        ...(thread.hasProjectCwd ? { cwd: thread.cwd } : {}),
      },
    });
  }

  function resetIdleTimer() {
    stopIdleTimer();
    idleTimer = setTimeout(() => {
      const idleDuration = Date.now() - lastActivityAt;
      if (idleDuration >= HEALTH_IDLE_SHUTDOWN_MS && activeTurns.size === 0) {
        console.log(
          `${logPrefix} OpenCode server idle for ${Math.round(idleDuration / 60000)}min, shutting down.`,
        );
        server.stop().then(() => {
          clearAllPendingPermissions();
          client = null;
          healthy = false;
        });
      }
    }, HEALTH_IDLE_SHUTDOWN_MS);
    // Unit tests create many short-lived providers; do not hold the process open for 10 minutes.
    if (readString(process.env.REMODEX_TEST) === "1" && typeof idleTimer?.unref === "function") {
      idleTimer.unref();
    }
  }

  function stopIdleTimer() {
    if (idleTimer) {
      clearTimeout(idleTimer);
      idleTimer = null;
    }
  }

  async function restoreSessions() {
    for (const [threadId, entry] of sessions.entries()) {
      const sessionId =
        typeof entry === "string" ? entry : readString(entry?.sessionId);
      const thread = threads.get(threadId);
      if (!thread) {
        continue;
      }
      if (sessionId) {
        thread.sessionId = sessionId;
      }
      const storeEntry = sessions.getEntry(threadId);
      if (storeEntry) {
        if (readString(storeEntry.cwd)) {
          thread.cwd = readString(storeEntry.cwd);
        }
        if (readString(storeEntry.title)) {
          thread.title = readString(storeEntry.title);
        }
        if (readString(storeEntry.model)) {
          thread.model = normalizeOpenCodeModel(storeEntry.model);
        }
        if (readString(storeEntry.agent)) {
          thread.agent = readString(storeEntry.agent);
        }
      }
    }
  }

  async function commandExecute(request) {
    const params = request?.params || {};
    const threadId = readThreadId(params);
    const commandToken = readString(params.command);
    const commandSdk = normalizeCommandNameForSdk(commandToken);
    const allowlistToken = normalizeCommandTokenForAllowlist(commandToken);

    if (!allowlistToken) {
      const error = new Error("command/execute requires a slash command token.");
      error.errorCode = "command_required";
      logCommandExecute({ commandToken, commandSdk, ok: false, errorCode: error.errorCode, threadId });
      throw error;
    }

    let thread;
    try {
      thread = await ensureThreadSession(await requireThread(threadId));
    } catch (error) {
      logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: readString(error?.errorCode) || "command_execute_failed",
        threadId,
        clientCommandId: readString(params.clientCommandId),
      });
      throw error;
    }

    const clientCommandId = readString(params.clientCommandId);
    const dedupeKey = commandExecuteDedupeKey(thread.id, allowlistToken, clientCommandId);
    if (dedupeKey) {
      pruneCommandExecuteDedupe();
      const seenAt = commandExecuteDedupeByKey.get(dedupeKey);
      if (seenAt && Date.now() - seenAt < COMMAND_EXECUTE_DEDUPE_TTL_MS) {
        logCommandExecute({
          commandToken,
          commandSdk,
          ok: true,
          threadId: thread.id,
          sessionId: thread.sessionId,
          clientCommandId,
          deduped: true,
        });
        return { ok: true, sessionId: thread.sessionId, deduped: true };
      }
      commandExecuteDedupeByKey.set(dedupeKey, Date.now());
    }

    const explicitDirectory = readString(params.directory || params.cwd);
    const directoryCandidate = explicitDirectory || readString(thread.cwd) || process.cwd();
    let directory = directoryCandidate;
    const skipPathValidation =
      !explicitDirectory &&
      !thread.hasProjectCwd &&
      path.resolve(directoryCandidate) === path.resolve(process.cwd());
    if (!skipPathValidation) {
      directory = await resolveAllowedDirectory(directoryCandidate);
    }
    const allowedCommands = await listCommands(directory);
    const allowedTokens = new Set(
      allowedCommands.map((entry) => normalizeCommandTokenForAllowlist(entry.token)),
    );
    if (!allowedTokens.has(allowlistToken)) {
      const error = new Error(`Slash command not allowed: ${commandToken}`);
      error.errorCode = "command_not_allowed";
      logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: error.errorCode,
        threadId: thread.id,
        directory,
      });
      throw error;
    }

    await ensureStarted();
    if (!client || typeof client.sessionCommand !== "function") {
      const error = new Error("OpenCode session.command is unavailable.");
      error.errorCode = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
      logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: error.errorCode,
        threadId: thread.id,
      });
      throw error;
    }

    if (!readString(thread.sessionId)) {
      const sessionId = await client.createSession({ cwd: directory });
      if (!readString(sessionId)) {
        const error = new Error(
          "OpenCode createSession returned no session id; cannot execute slash command.",
        );
        error.errorCode = ERROR_CODES.OPENCODE_TURN_FAILED.errorCode;
        logCommandExecute({
          commandToken,
          commandSdk,
          ok: false,
          errorCode: error.errorCode,
          threadId: thread.id,
        });
        throw error;
      }
      thread.sessionId = sessionId;
      persistSessionRecord(thread);
    }

    const matchedCommand =
      allowedCommands.find(
        (entry) => normalizeCommandTokenForAllowlist(entry.token) === allowlistToken,
      ) || null;
    const template =
      readString(params.template) || readString(matchedCommand?.template) || "";
    const hints = Array.isArray(params.hints)
      ? params.hints.map((entry) => readString(entry)).filter(Boolean)
      : Array.isArray(matchedCommand?.hints)
        ? matchedCommand.hints.map((entry) => readString(entry)).filter(Boolean)
        : [];
    const argumentFields = normalizeArgumentFields(params.argumentFields);
    const requiresArguments =
      matchedCommand?.requiresArguments === true ||
      deriveRequiresArguments(template, hints);

    let args = readString(params.arguments) || readString(params.args) || "";
    if (argumentFields.length > 0) {
      args = serializeCommandArguments({ template, hints, fields: argumentFields });
    } else if (requiresArguments && !readString(args)) {
      const error = new Error(
        "command/execute requires argumentFields for slash commands that need input.",
      );
      error.errorCode = "command_arguments_required";
      logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: error.errorCode,
        threadId: thread.id,
        directory,
      });
      throw error;
    }

    try {
      await client.sessionCommand({
        sessionID: thread.sessionId,
        command: commandToken,
        arguments: args,
        cwd: directory,
        model: thread.model,
        agent: thread.agent,
      });
      markUserStartedInProcess(thread);
      thread.updatedAt = new Date().toISOString();
      threads.set(thread.id, thread);
      logCommandExecute({
        commandToken,
        commandSdk,
        ok: true,
        threadId: thread.id,
        sessionId: thread.sessionId,
        directory,
        clientCommandId,
      });
      return { ok: true, sessionId: thread.sessionId };
    } catch (error) {
      if (isInvalidOpenCodeSessionError(error)) {
        const expired = createOpenCodeSessionExpiredError(thread.id);
        logCommandExecute({
          commandToken,
          commandSdk,
          ok: false,
          errorCode: expired.errorCode,
          threadId: thread.id,
        });
        throw expired;
      }
      const failed = new Error(
        readString(error?.message) || "OpenCode slash command execution failed.",
      );
      failed.errorCode = readString(error?.errorCode) || ERROR_CODES.OPENCODE_TURN_FAILED.errorCode;
      logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: failed.errorCode,
        threadId: thread.id,
      });
      throw failed;
    }
  }

  function logCommandExecute({
    commandToken,
    commandSdk,
    ok,
    errorCode = null,
    threadId = null,
    sessionId = null,
    directory = null,
    clientCommandId = null,
    deduped = false,
  } = {}) {
    const payload = {
      event: deduped === true ? "opencode_command_execute_deduped" : "opencode_command_execute",
      commandToken: readString(commandToken) || null,
      commandSdk: readString(commandSdk) || null,
      ok: ok === true,
      errorCode: readString(errorCode) || null,
      threadId: readString(threadId) || null,
      sessionId: readString(sessionId) || null,
      directory: readString(directory) || null,
      clientCommandId: readString(clientCommandId) || null,
    };
    if (deduped === true) {
      payload.deduped = true;
    }
    console.log(JSON.stringify(payload));
  }

  function rememberThreadProject(thread, source) {
    if (!projectRegistry || !thread?.hasProjectCwd) return;
    try {
      projectRegistry.rememberProjectPath(thread.cwd, {
        source,
        provider: OPENCODE_PROVIDER_ID,
        lastSeenAt: thread.updatedAt || thread.createdAt,
      });
    } catch {}
  }

  function emit(method, params) {
    sendApplicationMessage?.(
      JSON.stringify({ method, params: removeUndefinedValues(params || {}) }),
    );
  }

  function getCatalogAvailability() {
    if (catalogUnavailable) {
      return { ...catalogUnavailable };
    }
    const runtimeVersion = readString(server.version);
    if (runtimeVersion && server.isRunning) {
      if (isVersionBelowMinimum(runtimeVersion, OPENCODE_MIN_CLI_VERSION)) {
        return {
          unavailableReason: `OpenCode ${runtimeVersion} is below minimum ${OPENCODE_MIN_CLI_VERSION}. Upgrade OpenCode on this Mac.`,
          reasonCode: "opencode_version_below_minimum",
          version: runtimeVersion,
        };
      }
    }
    return runtimeVersion ? { version: runtimeVersion } : null;
  }

  function getRuntimeStatus(env = process.env) {
    const availability = getCatalogAvailability();
    return buildOpenCodeRuntimeStatus({
      enabled: healthy && !availability?.unavailableReason,
      serveUrl: server.baseUrl,
      version: readString(server.version) || readString(availability?.version),
      sessionCount: threads.size,
      lastError: readString(availability?.unavailableReason),
      command: readString(env.REMODEX_OPENCODE_COMMAND) || "opencode",
      handoffEnvEnabled: isOpenCodeHandoffEnabled(env),
      authConfigured: cachedAuthConfigured,
      connectedProviders: lastConnectedProviders,
      providerDiscoveryReasonCode: readString(lastModelListMeta?.reasonCode) || null,
      providerInventory: lastProviderInventory,
      authDiscoveryReasonCode: lastAuthDiscoveryReasonCode,
      providerInventoryPartial: lastProviderInventoryPartial,
    });
  }

  function getLastCatalogAgents() {
    return lastCatalogAgents;
  }

  function rememberCatalogAgents(agents) {
    if (Array.isArray(agents) && agents.length > 0) {
      lastCatalogAgents = agents;
    }
  }

  // Maps plan-mode turns to OpenCode's built-in read-only "plan" agent, but only
  // when the agent catalog proves it exists; otherwise keep the requested agent.
  async function resolvePlanAgentOverride(fallbackAgent) {
    let agents = lastCatalogAgents;
    if (!Array.isArray(agents) || agents.length === 0) {
      try {
        agents = await listAgents();
      } catch {
        agents = [];
      }
    }
    const hasPlanAgent =
      Array.isArray(agents) &&
      agents.some((entry) => readString(entry?.id || entry?.name || entry) === "plan");
    return hasPlanAgent ? "plan" : fallbackAgent;
  }

  function getLastModelListMeta() {
    return lastModelListMeta ? { ...lastModelListMeta } : null;
  }

  async function getHandoffContext(threadId, { sessionId = "", directory = "" } = {}) {
    const normalizedThreadId = readThreadId({ threadId });
    if (!normalizedThreadId) {
      throw threadNotFoundError(threadId);
    }

    const thread = await requireThread(normalizedThreadId);
    // Client-supplied sessionId/directory are hints only; never override owned thread state.
    const requestedSessionId = readString(sessionId);
    const requestedDirectory = readString(directory);
    if (requestedSessionId && requestedSessionId !== thread.sessionId) {
      console.warn(
        `${logPrefix} Ignoring untrusted handoff sessionId for thread ${normalizedThreadId}`,
      );
    }
    if (requestedDirectory && requestedDirectory !== thread.cwd) {
      console.warn(
        `${logPrefix} Ignoring untrusted handoff directory for thread ${normalizedThreadId}`,
      );
    }

    if (!thread.sessionId) {
      const expired = new Error("OpenCode session is missing for this thread.");
      expired.errorCode = ERROR_CODES.OPENCODE_SESSION_EXPIRED.errorCode;
      expired.action = ERROR_CODES.OPENCODE_SESSION_EXPIRED.action;
      throw expired;
    }

    return {
      threadId: thread.id,
      sessionId: thread.sessionId,
      cwd: thread.cwd,
      model: thread.model,
      agent: thread.agent,
      title: thread.title,
    };
  }

  async function selectTuiSession(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return false;
    }
    await ensureStarted();
    if (!client || typeof client.selectTuiSession !== "function") {
      return false;
    }
    return client.selectTuiSession(normalizedSessionId);
  }

  function resolveModelContextWindow(modelId) {
    const normalizedModelId = readString(modelId);
    if (!normalizedModelId) {
      return 0;
    }
    const catalogModel = lastListedModels.find(
      (entry) => readString(entry.id || entry.model) === normalizedModelId,
    );
    return Number(catalogModel?.contextWindow || catalogModel?.context_window) || 0;
  }

  async function discoverProjects({ directory } = {}) {
    await ensureStarted();
    if (!client || typeof client.listProjects !== "function") {
      return [];
    }
    return client.listProjects({ directory });
  }

  async function getUsageStatsForThread(threadId) {
    const thread = await requireThread(threadId);
    const sessionId = readString(thread.sessionId) || sessions.get(thread.id);
    if (!sessionId) {
      return { sessionId: null, usage: null };
    }

    await ensureStarted();
    const session = await client.getSession(sessionId, { directory: thread.cwd });
    const usage = mapOpenCodeSessionToContextUsage(session, {
      tokenLimit: resolveModelContextWindow(thread.model),
    });
    return { sessionId, usage };
  }

  async function pushThreadUsageUpdate(thread) {
    if (!thread?.id) {
      return;
    }
    try {
      const usageResult = await getUsageStatsForThread(thread.id);
      if (!usageResult?.usage) {
        return;
      }
      emit("thread/tokenUsage/updated", {
        threadId: thread.id,
        usage: usageResult.usage,
        source: "opencode_session",
      });
    } catch (error) {
      console.warn(
        `${logPrefix} OpenCode usage push failed for ${thread.id}: ${error?.message || error}`,
      );
    }
  }

  return {
    id: OPENCODE_PROVIDER_ID,
    ownsThread,
    listModels,
    listAgents,
    listCommands,
    commandExecute,
    listSkills,
    listThreads,
    handleRequest,
    handleApplicationResponse,
    warmup,
    shutdown,
    getCatalogAvailability,
    getRuntimeStatus,
    getLastModelListMeta,
    getLastCatalogAgents,
    getHandoffContext,
    selectTuiSession,
    discoverProjects,
    getUsageStatsForThread,
    pushThreadUsageUpdate,
    getObservabilityMetrics,
    testSeedPendingPermission,
    __test: {
      redactPermissionArgs,
      handlePermissionRequestEvent,
      hasPendingPermissionWatchdog: (permissionId) =>
        Boolean(pendingPermissions.get(permissionId)?.watchdog),
      scheduleAttachmentCleanup,
      setLastAttachmentCleanupAt: (timestamp) => {
        lastAttachmentCleanupAt = timestamp;
      },
      setHealthy: (value) => {
        healthy = value === true;
      },
      setClient: (value) => {
        client = value;
      },
      setDiscoverCache: (rows, fetchedAt = Date.now()) => {
        discoveredSessionsCache = { rows, fetchedAt };
      },
      getValidationRpcAvailableTokens: () => validationRpcTokenBucket.getAvailableTokens(),
      resetValidationRpcTokenBucket: () => {
        validationRpcTokenBucket.reset();
      },
      getInternalState: () => ({
        completedTurnIds,
        activeTurns,
      }),
      pruneCompletedTurnIds: (now = Date.now()) => {
        pruneCompletedTurnIds(now);
      },
      setDiscoveredSessionsCache: (cache) => {
        discoveredSessionsCache = cache;
      },
      adoptDiscoveredSession: (threadId) => {
        return internalAdoptDiscoveredSession(threadId);
      },
      completeTurn: (params) => {
        return internalCompleteTurn(params);
      },
    },
  };
}

function isInvalidOpenCodeSessionError(error) {
  if (!error || typeof error !== "object") {
    return false;
  }

  const status = Number(error.status ?? error.statusCode ?? error.response?.status);
  if (status === 404) {
    return true;
  }

  const message = readString(error.message).toLowerCase();
  if (!message) {
    return false;
  }

  return (
    message.includes("session not found") ||
    message.includes("unknown session") ||
    message.includes("invalid session") ||
    message.includes("session does not exist") ||
    message.includes("session id not found")
  );
}

function createOpenCodeSessionExpiredError(threadId) {
  const expired = new Error(
    `OpenCode session expired for thread ${threadId}. Start a new thread.`,
  );
  expired.errorCode = ERROR_CODES.OPENCODE_SESSION_EXPIRED.errorCode;
  expired.action = ERROR_CODES.OPENCODE_SESSION_EXPIRED.action;
  expired.reasonCode = "opencode_session_expired";
  return expired;
}

function unsupportedMethodError(method) {
  const error = new Error(`Unsupported OpenCode provider method: ${method || "unknown"}`);
  error.errorCode = "unsupported_opencode_method";
  return error;
}

function threadNotFoundError(threadId) {
  const error = new Error(`OpenCode thread not found: ${threadId || "unknown"}`);
  error.errorCode = "thread_not_found";
  return error;
}

function activeTurnError(threadId) {
  const error = new Error(`OpenCode thread already has a running turn: ${threadId}`);
  error.errorCode = "thread_turn_active";
  return error;
}

module.exports = {
  createOpenCodeProvider,
  createValidationRpcTokenBucket,
  resolveEnsureStartedListCapMs,
  resolveEnsureStartedServeWakeCapMs,
  resolveValidationRpcLimitPerMin,
  DEFAULT_ENSURE_STARTED_LIST_CAP_MS,
  DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS,
  DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN,
};
