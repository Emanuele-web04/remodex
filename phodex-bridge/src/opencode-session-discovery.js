const { readString, resolvedParam } = require("./normalize");
const { normalizeSessionMessagesResponse } = require("./opencode-client");
const {
  compareThreadsByUpdatedAt,
  messagesToTurns,
  normalizeOpenCodeModel,
  OPENCODE_PROVIDER_ID,
  publicThread,
  readThreadId,
  removeUndefinedValues,
} = require("./opencode-models");
const { resolveDiscoverSessionsEnabled } = require("./opencode-discovery-policy");
const { validateDirectory } = require("./project-path-policy");
const {
  DISCOVERED_THREAD_ID_PREFIX,
  ERROR_CODES,
  assertOwnershipPersisted,
  formatStructuredError,
  maybeLogOpenCodePruneOpsHint,
  parseDiscoveredThreadSessionId,
  pathNotAllowedError,
  resolveAdoptMutexTimeoutMs,
  resolveAllowedDirectory,
  resolveDiscoverSessionsCap,
  resolveDiscoverSessionsTtlMs,
  resolveEnsureStartedListCapMs,
  resolveEnsureStartedServeWakeCapMs,
  resolveListThreadsValidateCap,
  resolveListThreadsValidateCacheTtlMs,
  resolveValidationRpcLimitPerMin,
  threadNotFoundError,
} = require("./opencode-provider-shared");

function createOpenCodeSessionDiscovery(ctx) {

  function collectOwnedSessionIds() {
    const ids = new Set();
    for (const [, entry] of ctx.sessions.entries()) {
      const sessionId = readString(typeof entry === "string" ? entry : entry?.sessionId);
      if (sessionId) {
        ids.add(sessionId);
      }
    }
    for (const thread of ctx.threads.values()) {
      const sessionId = readString(thread.sessionId);
      if (sessionId) {
        ids.add(sessionId);
      }
    }
    return ids;
  }


  function filterDiscoveredRows(rows) {
    const ownedSessionIds = ctx.collectOwnedSessionIds();
    return rows.filter((row) => {
      const sessionId = readString(row.metadata?.sessionId || row.sessionId);
      return sessionId && !ownedSessionIds.has(sessionId) && !ctx.threads.has(row.id);
    });
  }


  function removeDiscoveredRowFromCache(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId || ctx.discoveredSessionsCache.rows.length === 0) {
      return;
    }
    ctx.discoveredSessionsCache = {
      ...ctx.discoveredSessionsCache,
      rows: ctx.discoveredSessionsCache.rows.filter(
        (row) => readString(row.metadata?.sessionId || row.sessionId) !== normalizedSessionId,
      ),
    };
  }


  function scheduleAsyncDiscoverRefresh() {
    if (ctx.discoverRefreshInFlight) {
      return;
    }
    void ctx.refreshDiscoveredSessionsCache({
      force: true,
      background: true,
    }).catch(() => {});
  }


  async function ensureStartedWithDiscoverCap() {
    const result = await ctx.ensureStartedWithCap({
      capMs: resolveEnsureStartedListCapMs(ctx.env),
      onTimeout: () => {
        console.log(
          JSON.stringify({
            event: "discover_refresh_async",
            reason: "ensure_started_timeout",
          }),
        );
        ctx.scheduleAsyncDiscoverRefresh();
      },
    });
    return result.started;
  }


  async function refreshDiscoveredSessionsCache({ force = false, background = false } = {}) {
    const cap = resolveDiscoverSessionsCap(ctx.env);
    const ttlMs = resolveDiscoverSessionsTtlMs(ctx.env);
    const now = Date.now();
    const cacheFresh =
      !force &&
      ctx.discoveredSessionsCache.fetchedAt > 0 &&
      now - ctx.discoveredSessionsCache.fetchedAt < ttlMs;

    if (cacheFresh) {
      const rows = ctx.filterDiscoveredRows(ctx.discoveredSessionsCache.rows);
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

    if (ctx.discoverRefreshInFlight) {
      return ctx.discoverRefreshInFlight;
    }

    const refreshPromise = (async () => {
      const started = await ctx.ensureStartedWithDiscoverCap();
      if (!started && ctx.discoveredSessionsCache.rows.length > 0) {
        return ctx.filterDiscoveredRows(ctx.discoveredSessionsCache.rows);
      }
      if (!ctx.healthy || !ctx.client || typeof ctx.client.listSessions !== "function") {
        return ctx.filterDiscoveredRows(ctx.discoveredSessionsCache.rows);
      }

      const listResult = await ctx.client.listSessions({ limit: cap });
      const ownedSessionIds = ctx.collectOwnedSessionIds();
      const rows = [];

      for (const thread of listResult.data || []) {
        const sessionId = readString(thread.metadata?.sessionId || thread.sessionId);
        if (!sessionId) {
          continue;
        }
        if (ownedSessionIds.has(sessionId)) {
          continue;
        }
        if (ctx.threads.has(thread.id)) {
          continue;
        }

        if (typeof ctx.sessions.setDiscovered === "function") {
          ctx.sessions.setDiscovered(sessionId, {
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

      ctx.discoveredSessionsCache = { rows, fetchedAt: Date.now() };
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

    ctx.discoverRefreshInFlight = refreshPromise.finally(() => {
      if (ctx.discoverRefreshInFlight === refreshPromise) {
        ctx.discoverRefreshInFlight = null;
      }
    });
    return ctx.discoverRefreshInFlight;
  }


  async function discoverExternalSessions() {
    return ctx.refreshDiscoveredSessionsCache();
  }


  async function internalAdoptDiscoveredSession(threadId) {
    const normalizedThreadId = readThreadId({ threadId });
    const sessionId = parseDiscoveredThreadSessionId(normalizedThreadId);
    if (!sessionId) {
      return null;
    }

    if (ctx.ownership.ownsThread(normalizedThreadId, OPENCODE_PROVIDER_ID)) {
      const existing = ctx.threads.get(normalizedThreadId);
      if (existing) {
        return existing;
      }
      return ctx.rehydrateThreadIfNeeded(normalizedThreadId);
    }

    const ownedBySession =
      typeof ctx.sessions.getBySessionId === "function" ? ctx.sessions.getBySessionId(sessionId) : null;
    if (ownedBySession?.threadId) {
      if (typeof ctx.sessions.markAdopted === "function") {
        ctx.sessions.markAdopted(sessionId);
      }
      const ownedThreadId = ownedBySession.threadId;
      if (ctx.threads.has(ownedThreadId)) {
        return ctx.threads.get(ownedThreadId);
      }
      return ctx.rehydrateThreadIfNeeded(ownedThreadId);
    }

    if (ctx.adoptMutexes.has(normalizedThreadId)) {
      return ctx.adoptMutexes.get(normalizedThreadId);
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
          typeof ctx.sessions.getDiscovered === "function"
            ? ctx.sessions.getDiscovered(sessionId)
            : null;
        if (!discoveredMeta) {
          const cacheRow = ctx.discoveredSessionsCache.rows.find(
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
          await ctx.refreshDiscoveredSessionsCache({ force: true });
          discoveredMeta =
            typeof ctx.sessions.getDiscovered === "function"
              ? ctx.sessions.getDiscovered(sessionId)
              : null;
        }
        if (!discoveredMeta) {
          throw threadNotFoundError(normalizedThreadId);
        }

        const ensureStartedResult = await ctx.ensureStartedWithCap();
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
        const agent = readString(discoveredMeta.agent) || ctx.defaultAgent;
        const now = new Date().toISOString();

        if (adoptionControl.cancelled) {
          throw abortAdoptError();
        }

        const sessionSetOk = ctx.sessions.set(normalizedThreadId, sessionId, {
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
            ctx.ownership.setOwnership(normalizedThreadId, OPENCODE_PROVIDER_ID),
            normalizedThreadId,
          );
        } catch {
          ctx.sessions.remove(normalizedThreadId);
          const error = new Error(`Failed to adopt OpenCode session ${sessionId}`);
          error.errorCode = "opencode_adopt_failed";
          throw error;
        }

        if (adoptionControl.cancelled) {
          ctx.sessions.remove(normalizedThreadId);
          ctx.ownership.removeOwnership(normalizedThreadId);
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

        if (ensureStartedResult.started && ctx.client && typeof ctx.client.getMessages === "function") {
          try {
            const messages = normalizeSessionMessagesResponse(
              await ctx.client.getMessages(sessionId),
            );
            if (messages && messages.length > 0) {
              thread.turns = messagesToTurns(messages, normalizedThreadId);
            }
          } catch {
            // thread/read still succeeds with empty turns.
          }
        }

        if (adoptionControl.cancelled) {
          ctx.sessions.remove(normalizedThreadId);
          ctx.ownership.removeOwnership(normalizedThreadId);
          throw abortAdoptError();
        }

        ctx.threads.set(normalizedThreadId, thread);
        if (typeof ctx.sessions.markAdopted === "function") {
          ctx.sessions.markAdopted(sessionId);
        }
        ctx.removeDiscoveredRowFromCache(sessionId);
        ctx.rememberThreadProject(thread, "opencode-discovered-adopt");
        return thread;
      } finally {
        if (adoptionControl.cancelled) {
          ctx.sessions.remove(normalizedThreadId);
          ctx.ownership.removeOwnership(normalizedThreadId);
          ctx.threads.delete(normalizedThreadId);
        }
        if (ctx.adoptMutexes.get(normalizedThreadId) === racedPromise) {
          ctx.adoptMutexes.delete(normalizedThreadId);
        }
      }
    })();

    const timeoutPromise = new Promise((_, reject) => {
      setTimeout(() => {
        adoptionControl.cancelled = true;
        if (ctx.adoptMutexes.get(normalizedThreadId) === racedPromise) {
          ctx.adoptMutexes.delete(normalizedThreadId);
        }
        reject(abortAdoptError());
      }, resolveAdoptMutexTimeoutMs(ctx.env));
    });

    const racedPromise = Promise.race([adoptPromise, timeoutPromise]);
    ctx.adoptMutexes.set(normalizedThreadId, racedPromise);
    return racedPromise;
  }

  return {
    collectOwnedSessionIds,
    filterDiscoveredRows,
    removeDiscoveredRowFromCache,
    scheduleAsyncDiscoverRefresh,
    ensureStartedWithDiscoverCap,
    refreshDiscoveredSessionsCache,
    discoverExternalSessions,
    internalAdoptDiscoveredSession,
  };
}

module.exports = { createOpenCodeSessionDiscovery };
