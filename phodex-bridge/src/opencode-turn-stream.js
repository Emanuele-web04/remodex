const path = require("path");
const { readString, resolvedParam } = require("./normalize");
const { buildStaticSlashCommands, normalizeCommandNameForSdk, normalizeSessionMessagesResponse } = require("./opencode-client");
const { deriveRequiresArguments, normalizeArgumentFields, serializeCommandArguments } = require("./opencode-command-arguments");
const { DEFAULT_OPENCODE_MODEL, OPENCODE_PROVIDER_ID, appendNonEmpty, buildPromptFromTurnInput, extractOpenCodeMessageText, isOpenCodeAssistantMessage, normalizeOpenCodeModel, readThreadId, textContent } = require("./opencode-models");
const { parseOpenCodeModelSlug } = require("./opencode-model-slug");
const { resolveOpenCodeVariantForPrompt } = require("./opencode-variant-resolve");
const { isAttachmentsEnabled } = require("./attachment-store");
const { mapOpenCodeSessionToContextUsage } = require("./opencode-usage-mapper");
const { validateDirectory } = require("./project-path-policy");
const { ERROR_CODES, activeTurnError, assertOwnershipPersisted, createOpenCodeSessionExpiredError, formatStructuredError, isInvalidOpenCodeSessionError, isPlanModeRequested, pathNotAllowedError, resolveAllowedDirectory, resolveEnsureStartedServeWakeCapMs, resolveOpenCodeTurnWatchdogMs, threadNotFoundError } = require("./opencode-provider-shared");

function createOpenCodeTurnStream(ctx) {

  async function turnStart(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const thread = await ctx.requireThread(threadId);
    ctx.markUserStartedInProcess(thread);

    for (const [, active] of ctx.activeTurns) {
      if (active.thread.id === threadId) throw activeTurnError(threadId);
    }
    if (ctx.inFlightThreadIds.has(threadId)) {
      throw activeTurnError(threadId);
    }

    const model = normalizeOpenCodeModel(params.model || thread.model);
    const { inputText, prompt, parts, skills: structuredSkills = [] } = buildPromptFromTurnInput(params.input, {
      attachmentStore: ctx.attachmentStore,
      attachmentsEnabled: isAttachmentsEnabled(ctx.env),
    });
    if (!prompt && (!Array.isArray(parts) || parts.length === 0)) {
      const error = new Error("OpenCode turn/start requires text input.");
      error.errorCode = "opencode_input_required";
      throw error;
    }

    const requestedAgent = resolvedParam(params, 'agent', 'mode');
    if (requestedAgent && Array.isArray(ctx.lastCatalogAgents) && ctx.lastCatalogAgents.length > 0) {
      const agentKnown = ctx.lastCatalogAgents.some(
        (entry) => readString(entry?.id || entry?.name || entry) === requestedAgent,
      );
      if (!agentKnown) {
        const error = new Error(`OpenCode agent ${requestedAgent} is not available in the current catalog.`);
        error.errorCode = "opencode_agent_unavailable";
        throw error;
      }
    }
    thread.model = model;
    thread.agent = requestedAgent || thread.agent || ctx.defaultAgent;
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
    ctx.activeTurns.set(turnId, active);
    assertOwnershipPersisted(
      ctx.ownership.setOwnership(thread.id, OPENCODE_PROVIDER_ID),
      thread.id,
    );

    Promise.resolve()
      .then(() => ctx.executeTurn(active, model, thread.agent, effort, prompt, parts, thread.cwd, structuredSkills))
      .catch((error) => {
        console.error(`${ctx.logPrefix} OpenCode turn execution failed: ${error.message}`);
        ctx.internalCompleteTurn({
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
      return ctx.extractLatestAssistantText(messages);
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

    return ctx.extractLatestAssistantText(messages);
  }


  function assistantAgentItem(active) {
    return active.turn.items.find((item) => item.type === "agentMessage");
  }


  function isTurnAssistantFinalized(active) {
    const assistantItem = ctx.assistantAgentItem(active);
    return Boolean(assistantItem?.finalized === true && readString(assistantItem.text));
  }


  function tryCompleteTurnWhenAssistantReady(active, source = "") {
    if (active.completed || !ctx.isTurnAssistantFinalized(active)) {
      return false;
    }
    return ctx.internalCompleteTurn({
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
    ctx.emit("item/completed", canonicalParams);
    return true;
  }


  async function hydrateAssistantFromSessionMessages(active) {
    if (!ctx.client || !readString(active.sessionId) || active.completed) {
      return false;
    }

    let messages = [];
    try {
      messages = normalizeSessionMessagesResponse(await ctx.client.getMessages(active.sessionId));
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
    const text = ctx.extractAssistantTextAfterCurrentPrompt(messages, userItem?.text);
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
      ctx.emit("item/agentMessage/delta", {
        threadId: active.thread.id,
        turnId: active.turn.id,
        itemId: assistantItem.id,
        delta: text,
        textDelta: text,
        assistantPhase: "final",
      });
    }

    const completed = ctx.emitAssistantCompletedOnce(
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
    const intervalMs = readString(ctx.env.REMODEX_TEST) === "1" ? 10 : 2000;
    const deadline = Date.now() + resolveOpenCodeTurnWatchdogMs(ctx.env);
    while (!active.completed && Date.now() < deadline) {
      await ctx.hydrateAssistantFromSessionMessages(active);
      if (ctx.tryCompleteTurnWhenAssistantReady(active, "poll_messages")) {
        return;
      }
      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        break;
      }
      await ctx.delayMs(Math.min(intervalMs, remainingMs));
    }
  }


  async function executeTurn(active, model, agent, effort, prompt, parts, cwd, skills = []) {
    const threadId = active.thread.id;
    ctx.inFlightThreadIds.add(threadId);
    try {
      const ensureStartedResult = await ctx.ensureStartedWithCap({
        capMs: resolveEnsureStartedServeWakeCapMs(ctx.env),
      });
      if (!ensureStartedResult.started) {
        const error = new Error("OpenCode is still starting. Try again in a moment.");
        error.errorCode = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
        error.action = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.action;
        throw error;
      }

      if (!active.started) {
        active.started = true;
        ctx.emit("turn/started", {
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
        const sessionId = await ctx.client.createSession({ cwd });
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
        ctx.persistSessionRecord(active.thread);
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
        ? await ctx.resolvePlanAgentOverride(agent)
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
          ctx.internalCompleteTurn({
            status: "failed",
            errorMessage: "OpenCode turn timed out waiting for completion.",
            errorCode: "opencode_turn_watchdog_timeout",
            active,
            source: "watchdog",
          });
        }, resolveOpenCodeTurnWatchdogMs(ctx.env));
        if (readString(process.env.REMODEX_TEST) === "1" && typeof active.watchdogTimer?.unref === "function") {
          active.watchdogTimer.unref();
        }
      };

      const sseReconnectEnabled = readString(ctx.env.REMODEX_OPENCODE_SSE_RECONNECT) !== "0";
      const unsubscribe = ctx.client.subscribeToEvents((method, params) => {
        if (active.completed) return;

        const eventTurnId = readString(params.turnId || params.turnID);
        ctx.pruneCompletedTurnIds();
        if (method === "turn/completed" && ctx.completedTurnIds.has(active.turn.id)) {
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
          const currentActiveForThread = ctx.findActiveTurnByThread(eventThreadId);
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
          ctx.authErrorNotifier.inspectTurnFailure({
            threadId: active.thread.id,
            turnId: active.turn.id,
            message: readString(params.message),
            error: params.error,
          });
          ctx.internalCompleteTurn({
            status: "failed",
            errorMessage: readString(params.message) || "OpenCode session error",
            active,
            source: "turn_failed",
          });
          clearWatchdog();
          return;
        }

        if (method === "runtime/auth/error") {
          ctx.authErrorNotifier.notifyAuthError({
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
            await ctx.hydrateAssistantFromSessionMessages(active);
            if (active.completed) {
              return;
            }
            if (completionSource === "session.idle" && !ctx.isTurnAssistantFinalized(active)) {
              return;
            }
            ctx.internalCompleteTurn({
              status: readString(params.status) || "completed",
              active,
              source: completionSource || "turn_completed",
            });
            clearWatchdog();
          })();
          return;
        }

        if (method === "item/completed") {
          ctx.emitAssistantCompletedOnce(active, enriched, "sse");
          ctx.tryCompleteTurnWhenAssistantReady(active, "sse_item_completed");
          return;
        }

        if (method === "permission/request") {
          ctx.handlePermissionRequestEvent(active, enriched);
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

        ctx.emit(method, enriched);
      }, {
        reconnectEnabled: sseReconnectEnabled,
        onResubscribe: () => {
          ctx.sseReconnectCount += 1;
          void ctx.hydrateAssistantFromSessionMessages(active)
            .then((hydrated) => {
              if (hydrated) {
                ctx.tryCompleteTurnWhenAssistantReady(active, "sse_resubscribe_hydrate");
              }
            })
            .catch(() => {});
        },
      });
      ctx.eventUnsubscribers.set(active.turn.id, unsubscribe);

      const parsedModel = parseOpenCodeModelSlug(model);
      const catalogModel = ctx.lastListedModels.find(
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

      const pollTask = ctx.pollForAssistantCompletion(active);
      try {
        await ctx.client.prompt({
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
          await ctx.hydrateAssistantFromSessionMessages(active);
          ctx.tryCompleteTurnWhenAssistantReady(active, "prompt_finally");
        }
      }
      if (!active.completed) {
        await pollTask;
      }
      if (!active.completed) {
        ctx.tryCompleteTurnWhenAssistantReady(active, "prompt_post_poll");
      }
    } catch (error) {
      if (!active.completed) {
        ctx.internalCompleteTurn({
          errorMessage: error?.message || "OpenCode SDK turn failed.",
          errorCode: error?.errorCode || ERROR_CODES.OPENCODE_TURN_FAILED.errorCode,
          action: error?.action || ERROR_CODES.OPENCODE_TURN_FAILED.action,
          status: "failed",
          active,
        });
      }
    } finally {
      ctx.inFlightThreadIds.delete(threadId);
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
    ctx.pruneCompletedTurnIds();
    if (active.completed || ctx.completedTurnIds.has(turnId)) return false;
    active.completed = true;
    ctx.completedTurnIds.set(turnId, Date.now());

    if (active.watchdogTimer) {
      clearTimeout(active.watchdogTimer);
      active.watchdogTimer = null;
    }

    const unsubscribe = ctx.eventUnsubscribers.get(turnId);
    if (unsubscribe) {
      unsubscribe();
      ctx.eventUnsubscribers.delete(turnId);
    }

    ctx.activeTurns.delete(turnId);
    active.thread.updatedAt = new Date().toISOString();
    active.turn.status = status;
    active.turn.completedAt = active.thread.updatedAt;

    if (errorMessage) {
      active.turn.error = { message: errorMessage, errorCode: errorCode || null, action: action || null };
    }

    const assistantItem = ctx.assistantAgentItem(active);
    if (assistantItem && assistantItem.text && assistantItem.finalized !== true) {
      ctx.emitAssistantCompletedOnce(
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

    ctx.emit("turn/completed", {
      threadId: active.thread.id,
      turnId,
      model: active.thread.model,
      status,
      turn: { id: turnId, status, error: errorMessage ? { message: errorMessage } : undefined },
    });

    if (status !== "failed") {
      void ctx.pushThreadUsageUpdate(active.thread);
    } else {
      ctx.authErrorNotifier.inspectTurnFailure({
        threadId: active.thread.id,
        turnId,
        message: errorMessage,
        error: active.turn.error,
      });
    }

    ctx.resetIdleTimer();
    return true;
  }


  async function turnInterrupt(request) {
    const params = request.params || {};
    const turnId = readString(params.turnId || params.turn_id);
    const threadId = readThreadId(params);
    const resolvedTurnId = turnId || ctx.findActiveTurnByThread(threadId);
    const active = ctx.activeTurns.get(resolvedTurnId);
    if (!active) return { success: true, interrupted: false };

    try {
      if (readString(active.sessionId)) {
        await ctx.ensureStarted();
        await ctx.client.abort(active.sessionId);
      }
    } catch {
      // Best effort
    }

    ctx.internalCompleteTurn({ status: "stopped", active });
    return { success: true, interrupted: true };
  }


  function findActiveTurnByThread(threadId) {
    for (const [turnId, active] of ctx.activeTurns) {
      if (active.thread.id === threadId) return turnId;
    }
    return "";
  }

  return {
    turnStart,
    extractLatestAssistantText,
    extractAssistantTextAfterCurrentPrompt,
    assistantAgentItem,
    isTurnAssistantFinalized,
    tryCompleteTurnWhenAssistantReady,
    emitAssistantCompletedOnce,
    hydrateAssistantFromSessionMessages,
    delayMs,
    pollForAssistantCompletion,
    executeTurn,
    internalCompleteTurn,
    turnInterrupt,
    findActiveTurnByThread,
  };
}

module.exports = { createOpenCodeTurnStream };
