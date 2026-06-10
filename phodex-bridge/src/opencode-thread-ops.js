const { readString, resolvedParam } = require("./normalize");
const { normalizeSessionMessagesResponse } = require("./opencode-client");
const {
  boundedPositiveInteger,
  compareThreadsByUpdatedAt,
  messagesToTurns,
  normalizeOpenCodeModel,
  OPENCODE_PROVIDER_ID,
  publicThread,
  readThreadId,
} = require("./opencode-models");
const { resolveDiscoverSessionsEnabled } = require("./opencode-discovery-policy");
const {
  ERROR_CODES,
  assertOwnershipPersisted,
  formatStructuredError,
  maybeLogOpenCodePruneOpsHint,
  paginateTurnList,
  parseDiscoveredThreadSessionId,
  resolveAllowedDirectory,
  resolveDiscoverSessionsCap,
  resolveEnsureStartedListCapMs,
  resolveListThreadsValidateCap,
  resolveListThreadsValidateCacheTtlMs,
  threadNotFoundError,
} = require("./opencode-provider-shared");

function createOpenCodeThreadOps(ctx) {
  
  async function listThreads(params = {}) {
    const limit = boundedPositiveInteger(params.limit, 50);
    const includeArchived = params.includeArchived === true || params.include_archived === true;
    const includeFullRehydrate = readString(ctx.env.REMODEX_LIST_THREADS_FULL_REHYDRATE) === "1";

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
    const sdkCap = resolveListThreadsValidateCap(ctx.env);
    const hasOwnedThreadState =
      ctx.threads.size > 0 ||
      ctx.ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID).length > 0 ||
      ctx.sessions.entries().length > 0;
    let wakeDegraded = false;
    if ((!ctx.healthy || !ctx.client) && hasOwnedThreadState) {
      try {
        const wakeResult = await ctx.ensureStartedWithCap({
          capMs: resolveEnsureStartedListCapMs(ctx.env),
          onTimeout: () => {
            console.log(
              JSON.stringify({
                event: "opencode_list_threads_wake_timeout",
                capMs: resolveEnsureStartedListCapMs(ctx.env),
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
    const canValidateSessions = ctx.healthy && ctx.client;

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
      if (ctx.threadHasActiveTurn(thread.id)) {
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
        const valid = await ctx.validateOwnedThreadSession(sessionId);
        if (!valid) {
          prunedInvalid += 1;
          ctx.invalidSessionThreadIds.add(thread.id);
          ctx.removeOrphanOpenCodeThread(thread.id);
          return false;
        }
        const hasActivity = await ctx.validateThreadHasActivity(thread.id, sessionId);
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

    for (const thread of ctx.threads.values()) {
      if (await includeInMemoryThread(thread)) {
        localThreads.push(publicThread(thread));
      }
    }

    try {
      const ownedThreads = ctx.ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID);
      for (const entry of ownedThreads) {
        const threadId = entry.threadId;
        const live = ctx.threads.get(threadId);
        if (live) {
          continue;
        }

        const storeEntry = ctx.sessions.getEntry(threadId);
        if (!includeArchived && storeEntry?.archived === true) {
          continue;
        }
        const sessionId = readString(storeEntry?.sessionId) || ctx.sessions.get(threadId);
        if (!sessionId) {
          const removed = ctx.removeOrphanOpenCodeThread(threadId);
          if (removed.removedOwnership) {
            removedOrphanOwnership += 1;
          }
          if (removed.removedSession) {
            removedOrphanSession += 1;
          }
          continue;
        }

        if (ctx.invalidSessionThreadIds.has(threadId)) {
          const removed = ctx.removeOrphanOpenCodeThread(threadId);
          if (removed.removedOwnership) {
            removedOrphanOwnership += 1;
          }
          if (removed.removedSession) {
            removedOrphanSession += 1;
          }
          continue;
        }

        if (ctx.threadHasActiveTurn(threadId)) {
          ownedStubs.push(ctx.ownershipStubFromStore(threadId, storeEntry));
          continue;
        }

        if (includeFullRehydrate && canValidateSessions) {
          try {
            const thread = await ctx.rehydrateThreadIfNeeded(threadId);
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
            const stub = ctx.ownershipStubFromStore(threadId, storeEntry);
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
          const valid = await ctx.validateOwnedThreadSession(sessionId);
          if (!valid) {
            ctx.invalidSessionThreadIds.add(threadId);
            prunedInvalid += 1;
            const removed = ctx.removeOrphanOpenCodeThread(threadId);
            if (removed.removedOwnership) {
              removedOrphanOwnership += 1;
            }
            if (removed.removedSession) {
              removedOrphanSession += 1;
            }
            continue;
          }
          const hasActivity = await ctx.validateThreadHasActivity(threadId, sessionId);
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
          ownedStubs.push(ctx.ownershipStubFromStore(threadId, storeEntry));
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
    if (resolveDiscoverSessionsEnabled(ctx.env, params)) {
      try {
        discoveredRows = await ctx.discoverExternalSessions();
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
        ownership: ctx.ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID).length,
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
      agent: readString(params.agent) || ctx.defaultAgent,
      createdAt: now,
      updatedAt: now,
      archived: false,
      hasProjectCwd: Boolean(requestedCwd),
      turns: [],
      sessionId: resolvedSessionId || "",
      userStartedInProcess: true,
    };
    ctx.threads.set(threadId, thread);
    assertOwnershipPersisted(
      ctx.ownership.setOwnership(threadId, OPENCODE_PROVIDER_ID),
      threadId,
    );
    if (resolvedSessionId) {
      thread.sessionId = resolvedSessionId;
      ctx.persistSessionRecord(thread);
    }
    ctx.rememberThreadProject(thread, "opencode-thread-start");
    return { thread: publicThread(thread) };
  }

  
  async function threadRead(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    let thread = await ctx.internalAdoptDiscoveredSession(threadId);
    if (!thread) {
      thread = await ctx.requireThread(threadId);
    }
    thread = await ctx.ensureThreadSession(thread);

    ctx.rememberThreadProject(thread, "opencode-thread-read");
    const responseThread = { ...publicThread(thread) };
    if (params.includeTurns === true || params.include_turns === true) {
      responseThread.turns = thread.turns || [];
    }
    return { thread: responseThread };
  }

  
  async function threadTurnsList(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const thread = await ctx.ensureThreadSession(await ctx.requireThread(threadId));

    const limit = boundedPositiveInteger(params.limit, 50);
    const sortDirection = resolvedParam(params, 'sortDirection', 'sort_direction') || "desc";
    const cursor = resolvedParam(params, 'cursor');
    const turns = [...(thread.turns || [])];

    // In-memory turns carry canonical bridge turn/item ids that match live notifications.
    // SDK-derived turns use synthetic ids (turn-0, user-0) and cause duplicate iOS bubbles
    // when history pagination reconciles against optimistic/live rows.
    if (turns.length > 0) {
      return paginateTurnList(turns, { limit, sortDirection, cursor });
    }

    // Try SDK messages if session exists (e.g. provider restart with empty in-memory turns)
    if (thread.sessionId) {
      try {
        await ctx.ensureStarted();
        const messages = normalizeSessionMessagesResponse(await ctx.client.getMessages(thread.sessionId));
        if (messages && messages.length > 0) {
          const sdkTurns = messagesToTurns(messages, threadId);
          return paginateTurnList(sdkTurns, { limit, sortDirection, cursor });
        }
      } catch {
        // Fall through to in-memory turns
      }
    }

    return paginateTurnList(turns, { limit, sortDirection, cursor });
  }

  
  async function threadNameSet(request) {
    const params = request.params || {};
    const thread = await ctx.requireThread(readThreadId(params));

    const name = resolvedParam(params, 'name', 'title');
    if (name) {
      thread.title = name;
      thread.updatedAt = new Date().toISOString();
      ctx.persistSessionRecord(thread);
    }

    const publicValue = publicThread(thread);
    ctx.emit("thread/name/updated", {
      threadId: publicValue.id,
      thread_id: publicValue.id,
      name: publicValue.name,
      title: publicValue.title,
    });
    return { thread: publicValue };
  }

  
  async function threadArchive(request, archived) {
    const threadId = readThreadId(request.params);
    const inMemory = ctx.threads.get(threadId);
    if (inMemory) {
      inMemory.archived = archived;
      inMemory.updatedAt = new Date().toISOString();
      ctx.persistSessionRecord(inMemory);
      return { thread: publicThread(inMemory) };
    }

    if (!ctx.ownership.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
      throw threadNotFoundError(threadId);
    }

    if (archived) {
      ctx.removeOrphanOpenCodeThread(threadId, "opencode_thread_archived_stub_removed");
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
    const thread = await ctx.requireThread(threadId);
    if (!thread.sessionId) {
      const error = new Error("OpenCode fork requires a session on the source thread");
      error.errorCode = "opencode_fork_requires_session";
      throw error;
    }

    try {
      await ctx.ensureStarted();
    } catch (error) {
      if (error.errorCode === ERROR_CODES.OPENCODE_NOT_INSTALLED.errorCode) {
        const forkError = new Error("OpenCode server is unreachable. Fork could not complete.");
        forkError.errorCode = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
        forkError.action = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.action;
        throw forkError;
      }
      throw error;
    }
    const newSessionId = await ctx.client.fork(thread.sessionId);
    if (!readString(newSessionId)) {
      const error = new Error(
        "OpenCode session.fork returned no session id; cannot start forked thread.",
      );
      error.errorCode = "opencode_fork_empty_session";
      throw error;
    }
    return ctx.threadStart({
      params: {
        sessionId: newSessionId,
        model: thread.model,
        agent: thread.agent,
        ...(thread.hasProjectCwd ? { cwd: thread.cwd } : {}),
      },
    });
  }

  return {
    listThreads,
    threadStart,
    threadRead,
    threadTurnsList,
    threadNameSet,
    threadArchive,
    threadFork,
  };
}

module.exports = { createOpenCodeThreadOps };
