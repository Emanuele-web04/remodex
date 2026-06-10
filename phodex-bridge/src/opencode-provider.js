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

const { ERROR_CODES, HEALTH_IDLE_SHUTDOWN_MS, HEALTH_MAX_RESTARTS, HEALTH_RESTART_WINDOW_MS, STARTUP_PRUNE_SESSION_VALIDATE_CAP, ATTACHMENT_CLEANUP_INTERVAL_MS, activeTurnError, assertOwnershipPersisted, createOpenCodeSessionExpiredError, createValidationRpcTokenBucket, DEFAULT_ENSURE_STARTED_LIST_CAP_MS, DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS, DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN, formatStructuredError, isInvalidOpenCodeSessionError, isPlanModeRequested, maybeLogOpenCodePruneOpsHint, paginateTurnList, pathNotAllowedError, resolveAllowedDirectory, resolveEnsureStartedListCapMs, resolveEnsureStartedServeWakeCapMs, resolveListThreadsValidateCacheTtlMs, resolveOpenCodeTurnWatchdogMs, resolveValidationRpcLimitPerMin, threadNotFoundError, unsupportedMethodError } = require("./opencode-provider-shared");
const { createOpenCodeSessionDiscovery } = require("./opencode-session-discovery");
const { createOpenCodePermissions } = require("./opencode-permissions");
const { createOpenCodeTurnStream } = require("./opencode-turn-stream");
const { createOpenCodeThreadOps } = require("./opencode-thread-ops");
const { createOpenCodeCommandExecute } = require("./opencode-command-execute");

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
  const ctx = { env, logPrefix, sendApplicationMessage, projectRegistry, clientFactory, serverFactory };

  ctx.server = serverFactory
    ? serverFactory({ env, logPrefix: `${logPrefix}:server` })
    : createOpenCodeServer({ env, logPrefix: `${logPrefix}:server` });
  ctx.ownership = ownershipStore || createThreadOwnershipStore();
  ctx.sessions = sessionStore || createOpenCodeSessionStore();
  if (typeof ctx.ownership.setRetainThreadIdPredicate === "function") {
    ctx.ownership.setRetainThreadIdPredicate((threadId) => Boolean(ctx.sessions.get(threadId)));
  }

  ctx.client = null;
  ctx.healthy = false;
  ctx.restartCount = 0;
  ctx.restartWindowStart = 0;
  ctx.lastActivityAt = 0;
  ctx.idleTimer = null;
  ctx.catalogUnavailable = null;
  ctx.cachedAuthConfigured = null;
  ctx.lastModelListMeta = null;
  ctx.lastConnectedProviders = [];
  ctx.lastListedModels = [];
  ctx.lastCatalogAgents = [];
  ctx.defaultAgent = resolveDefaultOpenCodeAgent(env);
  ctx.lastProviderInventory = [];
  ctx.lastAuthDiscoveryReasonCode = "ok";
  ctx.lastProviderInventoryPartial = false;

  ctx.threads = new Map();
  ctx.activeTurns = new Map();
  ctx.inFlightThreadIds = new Set();
  ctx.eventUnsubscribers = new Map();
  /** @type {Map<string, number>} */
  ctx.completedTurnIds = new Map();
  ctx.invalidSessionThreadIds = new Set();
  ctx.COMMAND_EXECUTE_DEDUPE_TTL_MS = 5000;
  ctx.COMPLETED_TURN_IDS_TTL_MS = 300_000;
  /** @type {Map<string, number>} */
  ctx.commandExecuteDedupeByKey = new Map();
  ctx.authErrorNotifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: ctx.sendApplicationMessage,
    logPrefix: ctx.logPrefix,
  });
  ctx.attachmentStore = injectedAttachmentStore !== undefined
    ? injectedAttachmentStore
    : (isAttachmentsEnabled(env) ? createAttachmentStore() : null);
  ctx.lastAttachmentCleanupAt = 0;
  ctx.sseReconnectCount = 0;
  /** @type {Map<string, { permissionId: string, threadId: string, turnId?: string, sessionId?: string, tool: string, requestedAt: string, watchdog?: ReturnType<typeof setTimeout> }>} */
  ctx.pendingPermissions = new Map();
  /** @type {Map<string, Set<string>>} */
  ctx.sessionPermissionGrants = new Map();
  ctx.PERMISSION_WATCHDOG_MS = resolveOpenCodeTurnWatchdogMs(env);
  ctx.MAX_PENDING_PERMISSIONS = 20;
  ctx.discoveredSessionsCache = { rows: [], fetchedAt: 0 };
  ctx.discoverRefreshInFlight = null;
  /** @type {Map<string, { valid?: boolean, hasActivity?: boolean, fetchedAt: number }>} */
  ctx.sessionValidationCache = new Map();
  ctx.adoptMutexes = new Map();
  ctx.validationRpcTokenBucket = createValidationRpcTokenBucket({
    limitPerMin: resolveValidationRpcLimitPerMin(env),
  });

  
  function consumeValidationRpcToken(cost = 1) {
    if (ctx.validationRpcTokenBucket.tryConsume(cost)) {
      return true;
    }
    console.log(
      JSON.stringify({
        event: "opencode_validation_rpc_rate_limited",
        limitPerMin: resolveValidationRpcLimitPerMin(ctx.env),
      }),
    );
    return false;
  }

  
  function readSessionValidationCache(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return null;
    }
    const entry = ctx.sessionValidationCache.get(normalizedSessionId);
    if (!entry) {
      return null;
    }
    const ttlMs = resolveListThreadsValidateCacheTtlMs(ctx.env);
    if (Date.now() - entry.fetchedAt >= ttlMs) {
      ctx.sessionValidationCache.delete(normalizedSessionId);
      return null;
    }
    return entry;
  }

  
  function writeSessionValidationCache(sessionId, patch = {}) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return;
    }
    const previous = ctx.readSessionValidationCache(sessionId) || {};
    ctx.sessionValidationCache.set(normalizedSessionId, {
      ...previous,
      ...patch,
      fetchedAt: Date.now(),
    });
  }

  
  function pruneCompletedTurnIds(now = Date.now()) {
    for (const [turnId, completedAt] of ctx.completedTurnIds.entries()) {
      if (now - completedAt >= ctx.COMPLETED_TURN_IDS_TTL_MS) {
        ctx.completedTurnIds.delete(turnId);
      }
    }
  }

  
  function removeOrphanOpenCodeThread(threadId, reason = "opencode_ownership_orphan_removed") {
    const removedOwnership = ctx.ownership.removeOwnership(threadId);
    const removedSession = ctx.sessions.remove(threadId);
    ctx.invalidSessionThreadIds.delete(threadId);
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
      archived: storeEntry?.archived === true,
    };
  }

  async function validateOwnedThreadSession(sessionId) {
    const cached = ctx.readSessionValidationCache(sessionId);
    if (cached?.valid !== undefined) {
      return cached.valid;
    }
    if (!ctx.consumeValidationRpcToken()) {
      const error = new Error("OpenCode validation RPC rate limit exceeded.");
      error.errorCode = "opencode_validation_rate_limited";
      throw error;
    }
    try {
      await ctx.client.getSession(sessionId);
      ctx.writeSessionValidationCache(sessionId, { valid: true });
      return true;
    } catch (error) {
      if (isInvalidOpenCodeSessionError(error)) {
        ctx.writeSessionValidationCache(sessionId, { valid: false, hasActivity: false });
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

    for (const { threadId } of ctx.ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID)) {
      if (ctx.threads.has(threadId)) {
        continue;
      }
      if (!ctx.sessions.get(threadId)) {
        ownershipWithoutSession += 1;
        ctx.removeOrphanOpenCodeThread(threadId);
      }
    }

    for (const [threadId] of ctx.sessions.entries()) {
      if (ctx.threads.has(threadId)) {
        continue;
      }
      if (!ctx.ownership.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
        sessionWithoutOwnership += 1;
        ctx.sessions.remove(threadId);
        continue;
      }
      if (ctx.invalidSessionThreadIds.has(threadId)) {
        invalidSessionPruned += 1;
        ctx.removeOrphanOpenCodeThread(threadId);
        continue;
      }
      if (sdkValidations >= maxSessionValidations) {
        continue;
      }
      const sessionId = ctx.sessions.get(threadId);
      if (!sessionId) {
        continue;
      }
      sdkValidations += 1;
      const valid = await ctx.validateOwnedThreadSession(sessionId);
      if (!valid) {
        ctx.invalidSessionThreadIds.add(threadId);
        invalidSessionPruned += 1;
        ctx.removeOrphanOpenCodeThread(threadId);
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
    const fullPass = readString(ctx.env.REMODEX_PRUNE_OPENCODE_OWNERSHIP) === "1";
    const maxSessionValidations = fullPass
      ? Number.MAX_SAFE_INTEGER
      : STARTUP_PRUNE_SESSION_VALIDATE_CAP;
    const run = () => {
      if (!ctx.healthy || !ctx.client) {
        return Promise.resolve();
      }
      return ctx.pruneOpenCodeStorageMismatch({ maxSessionValidations }).catch((error) => {
        console.warn(
          `${ctx.logPrefix} OpenCode startup prune failed: ${(error && error.message) || error}`,
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
    if (!ctx.attachmentStore) {
      return 0;
    }
    const now = Date.now();
    if (now - ctx.lastAttachmentCleanupAt < ATTACHMENT_CLEANUP_INTERVAL_MS) {
      return 0;
    }
    ctx.lastAttachmentCleanupAt = now;
    try {
      return ctx.attachmentStore.cleanupExpired();
    } catch (error) {
      console.warn(`${ctx.logPrefix} attachment cleanup failed: ${error.message}`);
      return 0;
    }
  }

  
  async function ensureStarted() {
    if (ctx.healthy && ctx.client) {
      ctx.scheduleAttachmentCleanup();
      return;
    }

    if (ctx.server.isRunning && !ctx.client) {
      ctx.client = ctx.clientFactory
        ? await ctx.clientFactory({ baseUrl: ctx.server.baseUrl, logPrefix: `${ctx.logPrefix}:sdk` })
        : await createOpenCodeClient({ baseUrl: ctx.server.baseUrl, logPrefix: `${ctx.logPrefix}:sdk` });
      ctx.healthy = true;
      await ctx.refreshAuthConfigured({ forceInventory: true });
      await ctx.restoreSessions();
      await ctx.scheduleStartupPrune();
      ctx.scheduleAttachmentCleanup();
      return;
    }

    if (!ctx.healthy) {
      try {
        await ctx.startServer();
      } catch (error) {
        const enriched = new Error(ctx.catalogUnavailable?.message || "OpenCode is not available on this Mac.");
        enriched.errorCode =
          ctx.catalogUnavailable?.reasonCode === "opencode_not_installed"
            ? ERROR_CODES.OPENCODE_NOT_INSTALLED.errorCode
            : ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
        enriched.action =
          ctx.catalogUnavailable?.reasonCode === "opencode_not_installed"
            ? ERROR_CODES.OPENCODE_NOT_INSTALLED.action
            : ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.action;
        enriched.reasonCode = ctx.catalogUnavailable?.reasonCode || enriched.errorCode;
        throw enriched;
      }
    }
  }

  
  async function startServer() {
    if (Date.now() - ctx.restartWindowStart > HEALTH_RESTART_WINDOW_MS) {
      ctx.restartCount = 0;
      ctx.restartWindowStart = Date.now();
    }

    if (ctx.restartCount >= HEALTH_MAX_RESTARTS) {
      ctx.catalogUnavailable = {
        unavailableReason:
          "OpenCode server could not stay running on this Mac. Check OpenCode logs.",
        reasonCode: "opencode_server_failed",
      };
      throw new Error(ctx.catalogUnavailable.unavailableReason);
    }

    ctx.restartCount++;
    console.log(
      `${ctx.logPrefix} Starting OpenCode server (attempt ${ctx.restartCount}/${HEALTH_MAX_RESTARTS})...`,
    );

    try {
      await ctx.server.start();
    } catch (error) {
      const failure = ctx.server.getLastStartFailure?.() || null;
      const reasonCode =
        readString(error?.reasonCode) ||
        readString(failure?.reasonCode) ||
        "opencode_server_failed";
      ctx.catalogUnavailable = {
        unavailableReason:
          readString(failure?.message) ||
          readString(error?.message) ||
          "OpenCode is not available on this Mac.",
        reasonCode,
      };
      throw error;
    }

    ctx.catalogUnavailable = null;
    ctx.client = ctx.clientFactory
      ? await ctx.clientFactory({ baseUrl: ctx.server.baseUrl, logPrefix: `${ctx.logPrefix}:sdk` })
      : await createOpenCodeClient({ baseUrl: ctx.server.baseUrl, logPrefix: `${ctx.logPrefix}:sdk` });
    ctx.healthy = true;
    await ctx.refreshAuthConfigured({ forceInventory: true });
    await ctx.restoreSessions();
    await ctx.scheduleStartupPrune();

    ctx.resetIdleTimer();
    ctx.scheduleAttachmentCleanup();
  }

  
  async function refreshAuthConfigured({ forceInventory = false } = {}) {
    if (!ctx.client) {
      ctx.cachedAuthConfigured = null;
      ctx.lastModelListMeta = null;
      ctx.lastConnectedProviders = [];
      return;
    }
    if (typeof ctx.client.listProviderInventory === "function") {
      try {
        const result = await ctx.client.listProviderInventory({ force: forceInventory });
        const connectedIds = result?.meta?.connectedProviderIds || [];
        ctx.lastModelListMeta = result?.meta || null;
        ctx.lastConnectedProviders = result?.connectedProviders || [];
        if (Array.isArray(connectedIds) && connectedIds.length > 0) {
          ctx.cachedAuthConfigured = true;
          return;
        }
        if (result?.meta?.reasonCode === "no_connected_providers") {
          ctx.cachedAuthConfigured = false;
          return;
        }
        if (result?.meta?.reasonCode === "provider_list_failed") {
          ctx.cachedAuthConfigured = null;
          return;
        }
        if (result?.meta?.reasonCode === "unknown") {
          ctx.cachedAuthConfigured = null;
          return;
        }
        ctx.cachedAuthConfigured = false;
        return;
      } catch {
        ctx.cachedAuthConfigured = null;
        return;
      }
    }
    if (typeof ctx.client.probeConnectedProviders === "function") {
      const connected = await ctx.client.probeConnectedProviders();
      if (connected === true) {
        ctx.cachedAuthConfigured = true;
        return;
      }
      if (connected === false) {
        ctx.cachedAuthConfigured = false;
      }
    }
  }

  
  function persistSessionRecord(thread) {
    if (!thread?.id || !thread.sessionId) return;
    ctx.sessions.set(thread.id, thread.sessionId, {
      cwd: thread.cwd,
      model: thread.model,
      agent: thread.agent,
      title: thread.title,
      archived: thread.archived === true,
    });
  }

  
  async function rehydrateThreadIfNeeded(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    if (!normalizedThreadId) {
      throw threadNotFoundError(threadId);
    }

    const existing = ctx.threads.get(normalizedThreadId);
    if (existing) {
      return existing;
    }

    if (!ctx.ownership.ownsThread(normalizedThreadId, OPENCODE_PROVIDER_ID)) {
      throw threadNotFoundError(normalizedThreadId);
    }

    const storeEntry = ctx.sessions.getEntry(normalizedThreadId);
    const sessionId = storeEntry?.sessionId || ctx.sessions.get(normalizedThreadId);
    if (!sessionId) {
      throw threadNotFoundError(normalizedThreadId);
    }

    await ctx.ensureStarted();

    let sdkSession = null;
    try {
      sdkSession = await ctx.client.getSession(sessionId);
    } catch (error) {
      if (!isInvalidOpenCodeSessionError(error)) {
        throw error;
      }
      ctx.sessions.remove(normalizedThreadId);
      ctx.ownership.removeOwnership(normalizedThreadId);
      ctx.invalidSessionThreadIds.add(normalizedThreadId);
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
      agent: readString(storeEntry?.agent) || ctx.defaultAgent,
      createdAt: readString(storeEntry?.updatedAt) || now,
      updatedAt: now,
      archived: storeEntry?.archived === true,
      hasProjectCwd: Boolean(readString(storeEntry?.cwd)),
      turns: [],
      sessionId,
      userStartedInProcess: false,
    };

    try {
      const messages = normalizeSessionMessagesResponse(await ctx.client.getMessages(sessionId));
      if (messages && messages.length > 0) {
        thread.turns = messagesToTurns(messages, normalizedThreadId);
      }
    } catch {
      // In-memory turns stay empty; thread/read still succeeds.
    }

    ctx.threads.set(normalizedThreadId, thread);
    ctx.persistSessionRecord(thread);
    ctx.rememberThreadProject(thread, "opencode-rehydrate");
    return thread;
  }

  
  async function requireThread(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    const existing = ctx.threads.get(normalizedThreadId);
    if (existing) {
      return existing;
    }
    return ctx.rehydrateThreadIfNeeded(normalizedThreadId);
  }

  
  async function ensureThreadSession(thread) {
    if (readString(thread?.sessionId)) {
      return thread;
    }
    return ctx.rehydrateThreadIfNeeded(thread.id);
  }

  
  function markUserStartedInProcess(thread) {
    if (!thread) {
      return;
    }
    thread.userStartedInProcess = true;
  }

  
  function threadHasActiveTurn(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    for (const active of ctx.activeTurns.values()) {
      if (active.thread.id === normalizedThreadId) {
        return true;
      }
    }
    return false;
  }

  
  async function validateThreadHasActivity(threadId, sessionId) {
    if (ctx.threadHasActiveTurn(threadId)) {
      return true;
    }
    const cached = ctx.readSessionValidationCache(sessionId);
    if (cached?.hasActivity !== undefined) {
      return cached.hasActivity;
    }
    if (!ctx.consumeValidationRpcToken()) {
      const error = new Error("OpenCode validation RPC rate limit exceeded.");
      error.errorCode = "opencode_validation_rate_limited";
      throw error;
    }
    try {
      const messages = normalizeSessionMessagesResponse(
        await ctx.client.getMessages(sessionId, { limit: 1 }),
      );
      const hasActivity = Array.isArray(messages) && messages.length > 0;
      ctx.writeSessionValidationCache(sessionId, { hasActivity });
      return hasActivity;
    } catch {
      ctx.writeSessionValidationCache(sessionId, { hasActivity: false });
      return false;
    }
  }

  
  function ownsThread(threadId) {
    const normalized = readString(threadId);
    return (
      ctx.ownership.ownsThread(normalized, OPENCODE_PROVIDER_ID) ||
      ctx.threads.has(normalized) ||
      Boolean(ctx.sessions.get(normalized))
    );
  }

  
  function syncAuthAndMetaFromListResult(result) {
    if (!result || typeof result !== "object") {
      return;
    }
    if (result.meta && typeof result.meta === "object") {
      ctx.lastModelListMeta = result.meta;
    }
    if (Array.isArray(result.connectedProviders)) {
      ctx.lastConnectedProviders = result.connectedProviders;
    }

    const meta = result.meta || {};
    const reasonCode = readString(meta.reasonCode);
    const connectedIds = Array.isArray(meta.connectedProviderIds) ? meta.connectedProviderIds : [];
    const modelCount = Array.isArray(result.models) ? result.models.length : 0;

    if (reasonCode === "provider_list_failed" || reasonCode === "unknown") {
      ctx.cachedAuthConfigured = null;
      return;
    }
    if (reasonCode === "no_connected_providers") {
      ctx.cachedAuthConfigured = false;
      return;
    }
    if (reasonCode === "ok" && modelCount > 0) {
      ctx.cachedAuthConfigured = true;
      return;
    }
    if (connectedIds.length > 0 && modelCount === 0) {
      ctx.cachedAuthConfigured = null;
      return;
    }
    ctx.cachedAuthConfigured = false;
  }

  
  async function resolveAuthCredentialBundle() {
    const { readAuthProviderIds } = require("./opencode-auth-providers");
    const fromFile = readAuthProviderIds();
    let ids = fromFile.ids;
    let authDiscoveryReasonCode = fromFile.authDiscoveryReasonCode;
    let providerInventoryPartial = false;

    if (fromFile.authDiscoveryReasonCode !== "ok" || ids.length === 0) {
      try {
        await ctx.ensureStarted();
        const probeIds =
          typeof ctx.client.listAuthProviderIds === "function"
            ? await ctx.client.listAuthProviderIds()
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
      await ctx.ensureStarted();
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
    const authBundle = await ctx.resolveAuthCredentialBundle();
    const result = await ctx.client.listModels({
      force,
      credentialProviderIDs: authBundle.ids,
      authDiscoveryReasonCode: authBundle.authDiscoveryReasonCode,
    });
    if (result && typeof result === "object" && Array.isArray(result.models)) {
      ctx.syncAuthAndMetaFromListResult(result);
      ctx.lastListedModels = result.models;
      if (Array.isArray(result.providerInventory)) {
        ctx.lastProviderInventory = result.providerInventory;
      }
      if (Array.isArray(result.connectedProviders)) {
        ctx.lastConnectedProviders = result.connectedProviders;
      }
      ctx.lastAuthDiscoveryReasonCode = readString(result.authDiscoveryReasonCode) || authBundle.authDiscoveryReasonCode;
      ctx.lastProviderInventoryPartial =
        result.providerInventoryPartial === true || authBundle.providerInventoryPartial;
      return result;
    }
    const models = Array.isArray(result) ? result : [];
    ctx.lastListedModels = models;
    return {
      models,
      meta: ctx.lastModelListMeta || {
        reasonCode: models.length > 0 ? "ok" : "unknown",
        connectedProviderIds: [],
        fetchedAt: new Date().toISOString(),
        stale: false,
        modelCountBeforeCap: models.length,
        modelCountAfterCap: models.length,
      },
    };
  }

    async function warmup() {
    try {
      await ctx.ensureStarted();
      console.log(`${ctx.logPrefix} OpenCode warmup complete`);
    } catch (error) {
      console.warn(
        `${ctx.logPrefix} OpenCode warmup failed: ${(error && error.message) || error}`,
      );
    }
  }

  
  async function listAgents() {
    try {
      await ctx.ensureStarted();
    } catch {
      return [];
    }
    const agents = await ctx.client.listAgents();
    ctx.rememberCatalogAgents(agents);
    return agents;
  }

  
  async function listCommands(directory) {
    const staticBuiltins = buildStaticSlashCommands();
    try {
      await ctx.ensureStarted();
    } catch {
      return staticBuiltins;
    }
    // listCommands composes full set (SDK client.command.list + static BUILTINS union in client); dir passed through.
    try {
      return await ctx.client.listCommands(directory);
    } catch {
      return staticBuiltins;
    }
  }

  
  async function listSkills(directory) {
    try {
      await ctx.ensureStarted();
    } catch {
      return [];
    }
    return ctx.client.listSkills(directory);
  }

  
  async function ensureStartedWithCap({ onTimeout, capMs } = {}) {
    const resolvedCapMs =
      Number.isFinite(capMs) && capMs > 0
        ? capMs
        : resolveEnsureStartedServeWakeCapMs(ctx.env);
    const startedAt = Date.now();
    let timeoutId;
    try {
      await Promise.race([
        ctx.ensureStarted(),
        new Promise((_, reject) => {
          timeoutId = setTimeout(
            () => reject(new Error("ensure_started_timeout")),
            resolvedCapMs,
          );
          if (readString(ctx.env.REMODEX_TEST) === "1" && typeof timeoutId?.unref === "function") {
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

  
  function handleApplicationResponse() {
    return false;
  }

  
  async function shutdown() {
    ctx.stopIdleTimer();
    for (const [, unsubscribe] of ctx.eventUnsubscribers) {
      unsubscribe();
    }
    ctx.eventUnsubscribers.clear();
    ctx.clearAllPendingPermissions();
    ctx.activeTurns.clear();
    ctx.inFlightThreadIds.clear();
    ctx.completedTurnIds.clear();
    await ctx.server.stop();
    ctx.client = null;
    ctx.healthy = false;
  }

  
  function resetIdleTimer() {
    ctx.stopIdleTimer();
    ctx.idleTimer = setTimeout(() => {
      const idleDuration = Date.now() - ctx.lastActivityAt;
      if (idleDuration >= HEALTH_IDLE_SHUTDOWN_MS && ctx.activeTurns.size === 0) {
        console.log(
          `${ctx.logPrefix} OpenCode server idle for ${Math.round(idleDuration / 60000)}min, shutting down.`,
        );
        ctx.server.stop().then(() => {
          ctx.clearAllPendingPermissions();
          ctx.client = null;
          ctx.healthy = false;
        });
      }
    }, HEALTH_IDLE_SHUTDOWN_MS);
    // Unit tests create many short-lived providers; do not hold the process open for 10 minutes.
    if (readString(process.env.REMODEX_TEST) === "1" && typeof ctx.idleTimer?.unref === "function") {
      ctx.idleTimer.unref();
    }
  }

  
  function stopIdleTimer() {
    if (ctx.idleTimer) {
      clearTimeout(ctx.idleTimer);
      ctx.idleTimer = null;
    }
  }

  
  async function restoreSessions() {
    for (const [threadId, entry] of ctx.sessions.entries()) {
      const sessionId =
        typeof entry === "string" ? entry : readString(entry?.sessionId);
      const thread = ctx.threads.get(threadId);
      if (!thread) {
        continue;
      }
      if (sessionId) {
        thread.sessionId = sessionId;
      }
      const storeEntry = ctx.sessions.getEntry(threadId);
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

  
  function rememberThreadProject(thread, source) {
    if (!ctx.projectRegistry || !thread?.hasProjectCwd) return;
    try {
      ctx.projectRegistry.rememberProjectPath(thread.cwd, {
        source,
        provider: OPENCODE_PROVIDER_ID,
        lastSeenAt: thread.updatedAt || thread.createdAt,
      });
    } catch {}
  }

  
  function emit(method, params) {
    ctx.sendApplicationMessage?.(
      JSON.stringify({ method, params: removeUndefinedValues(params || {}) }),
    );
  }

  
  function getCatalogAvailability() {
    if (ctx.catalogUnavailable) {
      return { ...ctx.catalogUnavailable };
    }
    const runtimeVersion = readString(ctx.server.version);
    if (runtimeVersion && ctx.server.isRunning) {
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
    const availability = ctx.getCatalogAvailability();
    return buildOpenCodeRuntimeStatus({
      enabled: ctx.healthy && !availability?.unavailableReason,
      serveUrl: ctx.server.baseUrl,
      version: readString(ctx.server.version) || readString(availability?.version),
      sessionCount: ctx.threads.size,
      lastError: readString(availability?.unavailableReason),
      command: readString(ctx.env.REMODEX_OPENCODE_COMMAND) || "opencode",
      handoffEnvEnabled: isOpenCodeHandoffEnabled(ctx.env),
      authConfigured: ctx.cachedAuthConfigured,
      connectedProviders: ctx.lastConnectedProviders,
      providerDiscoveryReasonCode: readString(ctx.lastModelListMeta?.reasonCode) || null,
      providerInventory: ctx.lastProviderInventory,
      authDiscoveryReasonCode: ctx.lastAuthDiscoveryReasonCode,
      providerInventoryPartial: ctx.lastProviderInventoryPartial,
    });
  }

  
  function getLastCatalogAgents() {
    return ctx.lastCatalogAgents;
  }

  
  function rememberCatalogAgents(agents) {
    if (Array.isArray(agents) && agents.length > 0) {
      ctx.lastCatalogAgents = agents;
    }
  }

    async function resolvePlanAgentOverride(fallbackAgent) {
    let agents = ctx.lastCatalogAgents;
    if (!Array.isArray(agents) || agents.length === 0) {
      try {
        agents = await ctx.listAgents();
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
    return ctx.lastModelListMeta ? { ...ctx.lastModelListMeta } : null;
  }

  
  async function getHandoffContext(threadId, { sessionId = "", directory = "" } = {}) {
    const normalizedThreadId = readThreadId({ threadId });
    if (!normalizedThreadId) {
      throw threadNotFoundError(threadId);
    }

    const thread = await ctx.ensureThreadSession(await ctx.requireThread(normalizedThreadId));
    // Client-supplied sessionId/directory are hints only; never override owned thread state.
    const requestedSessionId = readString(sessionId);
    const requestedDirectory = readString(directory);
    if (requestedSessionId && requestedSessionId !== thread.sessionId) {
      console.warn(
        `${ctx.logPrefix} Ignoring untrusted handoff sessionId for thread ${normalizedThreadId}`,
      );
    }
    if (requestedDirectory && requestedDirectory !== thread.cwd) {
      console.warn(
        `${ctx.logPrefix} Ignoring untrusted handoff directory for thread ${normalizedThreadId}`,
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
    await ctx.ensureStarted();
    if (!ctx.client || typeof ctx.client.selectTuiSession !== "function") {
      return false;
    }
    return ctx.client.selectTuiSession(normalizedSessionId);
  }

  
  function resolveModelContextWindow(modelId) {
    const normalizedModelId = readString(modelId);
    if (!normalizedModelId) {
      return 0;
    }
    const catalogModel = ctx.lastListedModels.find(
      (entry) => readString(entry.id || entry.model) === normalizedModelId,
    );
    return Number(catalogModel?.contextWindow || catalogModel?.context_window) || 0;
  }

  
  async function discoverProjects({ directory } = {}) {
    await ctx.ensureStarted();
    if (!ctx.client || typeof ctx.client.listProjects !== "function") {
      return [];
    }
    return ctx.client.listProjects({ directory });
  }

  
  async function getUsageStatsForThread(threadId) {
    const thread = await ctx.requireThread(threadId);
    const sessionId = readString(thread.sessionId) || ctx.sessions.get(thread.id);
    if (!sessionId) {
      return { sessionId: null, usage: null };
    }

    await ctx.ensureStarted();
    const session = await ctx.client.getSession(sessionId, { directory: thread.cwd });
    const usage = mapOpenCodeSessionToContextUsage(session, {
      tokenLimit: ctx.resolveModelContextWindow(thread.model),
    });
    return { sessionId, usage };
  }

  
  async function pushThreadUsageUpdate(thread) {
    if (!thread?.id) {
      return;
    }
    try {
      const usageResult = await ctx.getUsageStatsForThread(thread.id);
      if (!usageResult?.usage) {
        return;
      }
      ctx.emit("thread/tokenUsage/updated", {
        threadId: thread.id,
        usage: usageResult.usage,
        source: "opencode_session",
      });
    } catch (error) {
      console.warn(
        `${ctx.logPrefix} OpenCode usage push failed for ${thread.id}: ${error?.message || error}`,
      );
    }
  }

  ctx.consumeValidationRpcToken = consumeValidationRpcToken;
  ctx.readSessionValidationCache = readSessionValidationCache;
  ctx.writeSessionValidationCache = writeSessionValidationCache;
  ctx.pruneCompletedTurnIds = pruneCompletedTurnIds;
  ctx.removeOrphanOpenCodeThread = removeOrphanOpenCodeThread;
  ctx.ownershipStubFromStore = ownershipStubFromStore;
  ctx.validateOwnedThreadSession = validateOwnedThreadSession;
  ctx.pruneOpenCodeStorageMismatch = pruneOpenCodeStorageMismatch;
  ctx.scheduleStartupPrune = scheduleStartupPrune;
  ctx.scheduleAttachmentCleanup = scheduleAttachmentCleanup;
  ctx.ensureStarted = ensureStarted;
  ctx.startServer = startServer;
  ctx.refreshAuthConfigured = refreshAuthConfigured;
  ctx.persistSessionRecord = persistSessionRecord;
  ctx.rehydrateThreadIfNeeded = rehydrateThreadIfNeeded;
  ctx.requireThread = requireThread;
  ctx.ensureThreadSession = ensureThreadSession;
  ctx.markUserStartedInProcess = markUserStartedInProcess;
  ctx.threadHasActiveTurn = threadHasActiveTurn;
  ctx.validateThreadHasActivity = validateThreadHasActivity;
  ctx.ownsThread = ownsThread;
  ctx.syncAuthAndMetaFromListResult = syncAuthAndMetaFromListResult;
  ctx.resolveAuthCredentialBundle = resolveAuthCredentialBundle;
  ctx.listModels = listModels;
  ctx.warmup = warmup;
  ctx.listAgents = listAgents;
  ctx.listCommands = listCommands;
  ctx.listSkills = listSkills;
  ctx.ensureStartedWithCap = ensureStartedWithCap;
  ctx.handleApplicationResponse = handleApplicationResponse;
  ctx.shutdown = shutdown;
  ctx.resetIdleTimer = resetIdleTimer;
  ctx.stopIdleTimer = stopIdleTimer;
  ctx.restoreSessions = restoreSessions;
  ctx.rememberThreadProject = rememberThreadProject;
  ctx.emit = emit;
  ctx.getCatalogAvailability = getCatalogAvailability;
  ctx.getRuntimeStatus = getRuntimeStatus;
  ctx.getLastCatalogAgents = getLastCatalogAgents;
  ctx.rememberCatalogAgents = rememberCatalogAgents;
  ctx.resolvePlanAgentOverride = resolvePlanAgentOverride;
  ctx.getLastModelListMeta = getLastModelListMeta;
  ctx.getHandoffContext = getHandoffContext;
  ctx.selectTuiSession = selectTuiSession;
  ctx.resolveModelContextWindow = resolveModelContextWindow;
  ctx.discoverProjects = discoverProjects;
  ctx.getUsageStatsForThread = getUsageStatsForThread;
  ctx.pushThreadUsageUpdate = pushThreadUsageUpdate;

  Object.assign(ctx, createOpenCodeSessionDiscovery(ctx));
  Object.assign(ctx, createOpenCodePermissions(ctx));
  Object.assign(ctx, createOpenCodeTurnStream(ctx));
  Object.assign(ctx, createOpenCodeThreadOps(ctx));
  Object.assign(ctx, createOpenCodeCommandExecute(ctx));

  
  async function handleRequest(request) {
    const method = readString(request?.method);
    switch (method) {
      case "thread/start":
        return ctx.threadStart(request);
      case "thread/resume":
      case "thread/read":
        return ctx.threadRead(request);
      case "thread/turns/list":
        return ctx.threadTurnsList(request);
      case "thread/name/set":
        return ctx.threadNameSet(request);
      case "thread/archive":
        return ctx.threadArchive(request, true);
      case "thread/unarchive":
        return ctx.threadArchive(request, false);
      case "thread/fork":
        return ctx.threadFork(request);
      case "turn/start":
        return ctx.turnStart(request);
      case "turn/interrupt":
        return ctx.turnInterrupt(request);
      case "permission/reply":
        return ctx.permissionReply(request);
      default:
        throw unsupportedMethodError(method);
    }
  }
  ctx.handleRequest = handleRequest;

  return {
    id: OPENCODE_PROVIDER_ID,
    ownsThread: ctx.ownsThread,
    listModels: ctx.listModels,
    listAgents: ctx.listAgents,
    listCommands: ctx.listCommands,
    commandExecute: ctx.commandExecute,
    listSkills: ctx.listSkills,
    listThreads: ctx.listThreads,
    handleRequest: ctx.handleRequest,
    handleApplicationResponse: ctx.handleApplicationResponse,
    warmup: ctx.warmup,
    shutdown: ctx.shutdown,
    getCatalogAvailability: ctx.getCatalogAvailability,
    getRuntimeStatus: ctx.getRuntimeStatus,
    getLastModelListMeta: ctx.getLastModelListMeta,
    getLastCatalogAgents: ctx.getLastCatalogAgents,
    getHandoffContext: ctx.getHandoffContext,
    selectTuiSession: ctx.selectTuiSession,
    discoverProjects: ctx.discoverProjects,
    getUsageStatsForThread: ctx.getUsageStatsForThread,
    pushThreadUsageUpdate: ctx.pushThreadUsageUpdate,
    getObservabilityMetrics: ctx.getObservabilityMetrics,
    testSeedPendingPermission: ctx.testSeedPendingPermission,
    __test: {
      redactPermissionArgs: ctx.redactPermissionArgs,
      handlePermissionRequestEvent: ctx.handlePermissionRequestEvent,
      hasPendingPermissionWatchdog: (permissionId) =>
        Boolean(ctx.pendingPermissions.get(permissionId)?.watchdog),
      scheduleAttachmentCleanup: ctx.scheduleAttachmentCleanup,
      setLastAttachmentCleanupAt: (timestamp) => {
        ctx.lastAttachmentCleanupAt = timestamp;
      },
      setHealthy: (value) => {
        ctx.healthy = value === true;
      },
      setClient: (value) => {
        ctx.client = value;
      },
      setDiscoverCache: (rows, fetchedAt = Date.now()) => {
        ctx.discoveredSessionsCache = { rows, fetchedAt };
      },
      getValidationRpcAvailableTokens: () => ctx.validationRpcTokenBucket.getAvailableTokens(),
      resetValidationRpcTokenBucket: () => {
        ctx.validationRpcTokenBucket.reset();
      },
      getInternalState: () => ({
        completedTurnIds: ctx.completedTurnIds,
        activeTurns: ctx.activeTurns,
      }),
      pruneCompletedTurnIds: (now = Date.now()) => {
        ctx.pruneCompletedTurnIds(now);
      },
      setDiscoveredSessionsCache: (cache) => {
        ctx.discoveredSessionsCache = cache;
      },
      adoptDiscoveredSession: (threadId) => {
        return ctx.internalAdoptDiscoveredSession(threadId);
      },
      completeTurn: (params) => {
        return ctx.internalCompleteTurn(params);
      },
    },
  };

}

module.exports = { createOpenCodeProvider, paginateTurnList, createValidationRpcTokenBucket, resolveEnsureStartedListCapMs, resolveEnsureStartedServeWakeCapMs, resolveValidationRpcLimitPerMin, DEFAULT_ENSURE_STARTED_LIST_CAP_MS, DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS, DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN };
