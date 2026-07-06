// FILE: rollout-live-mirror.js
// Purpose: Mirrors desktop-origin rollout activity back into live bridge notifications for iPhone catch-up.
// Layer: CLI helper
// Exports: createRolloutLiveMirrorController
// Depends on: fs, crypto, path, ./rollout-watch, ./codex-home

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");
const {
  findRecentRolloutFileForContextRead,
  resolveSessionsRoot,
} = require("./rollout-watch");
const { resolveCodexGeneratedImagesRoot } = require("./codex-home");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");
const {
  TERMINAL_TASK_EVENT_TYPES,
  terminalEventClosesTrackedTurn,
} = require("./rollout-turn-semantics");
const { visibleUserPromptFromInputEntries } = require("./desktop-ipc-shared");

// The phone batches each poll tick's notifications and settles its timeline
// ~80ms after the batch ends (CodexService liveMirrorBatchFlushNanoseconds).
// Keep this interval comfortably above that settle window, or lower both
// together, so consecutive ticks never merge into one batch.
const DEFAULT_POLL_INTERVAL_MS = 250;
const DEFAULT_LOOKUP_TIMEOUT_MS = 5_000;
const DEFAULT_IDLE_TIMEOUT_MS = 60_000;
const DEFAULT_ACTIVITY_HEARTBEAT_MS = 5_000;
// Bootstrap replay must not resurrect runs whose rollout stopped growing long ago
// (aborted/killed desktop runs never write task_complete).
const DEFAULT_STALE_ACTIVE_RUN_MAX_AGE_MS = 10 * 60_000;
const DEFAULT_SYNTHETIC_TERMINAL_GRACE_MS = 1_000;
const DESKTOP_RESUME_METHODS = new Set(["thread/read", "thread/resume"]);

// Observes desktop-authored rollout files and replays the currently active run as
// bridge notifications so the phone can render live thinking/tool activity.
function createRolloutLiveMirrorController({
  sendApplicationResponse,
  logPrefix = "[remodex]",
  fsModule = fs,
  now = () => Date.now(),
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  lookupTimeoutMs = DEFAULT_LOOKUP_TIMEOUT_MS,
  idleTimeoutMs = DEFAULT_IDLE_TIMEOUT_MS,
  activityHeartbeatMs = DEFAULT_ACTIVITY_HEARTBEAT_MS,
  staleActiveRunMaxAgeMs = DEFAULT_STALE_ACTIVE_RUN_MAX_AGE_MS,
  syntheticTerminalGraceMs = DEFAULT_SYNTHETIC_TERMINAL_GRACE_MS,
  // Rollout tailing is the fallback mirror; when another live source already
  // streams a thread (IPC follower state or bridge-owned app-server stream),
  // emitting from the file too would double every row on the phone.
  shouldSuppressThread = null,
} = {}) {
  const mirrorsByThreadId = new Map();

  function observeInbound(rawMessage, parsedMessage = null) {
    const request = parsedMessage ?? safeParseJSON(rawMessage);
    const method = readString(request?.method);
    if (!DESKTOP_RESUME_METHODS.has(method)) {
      return;
    }

    const threadId = readThreadId(request?.params);
    if (!threadId) {
      return;
    }

    const existingMirror = mirrorsByThreadId.get(threadId);
    if (existingMirror) {
      existingMirror.bump();
      return;
    }

    let mirror;
    mirror = createThreadRolloutLiveMirror({
      threadId,
      sendApplicationResponse: typeof shouldSuppressThread === "function"
        ? (rawNotification) => {
          if (!shouldSuppressThread(threadId)) {
            sendApplicationResponse(rawNotification);
          }
        }
        : sendApplicationResponse,
      isSuppressed: typeof shouldSuppressThread === "function"
        ? () => Boolean(shouldSuppressThread(threadId))
        : () => false,
      logPrefix,
      fsModule,
      now,
      setIntervalFn,
      clearIntervalFn,
      pollIntervalMs,
      lookupTimeoutMs,
      idleTimeoutMs,
      activityHeartbeatMs,
      staleActiveRunMaxAgeMs,
      syntheticTerminalGraceMs,
      onStop() {
        if (mirrorsByThreadId.get(threadId) === mirror) {
          mirrorsByThreadId.delete(threadId);
        }
      },
    });
    mirrorsByThreadId.set(threadId, mirror);
  }

  function stopAll() {
    for (const mirror of mirrorsByThreadId.values()) {
      mirror.stop();
    }
    mirrorsByThreadId.clear();
  }

  return {
    observeInbound,
    stopAll,
  };
}

// Tails one thread rollout and emits synthetic app-server-like notifications for
// the currently active desktop-origin run only.
function createThreadRolloutLiveMirror({
  threadId,
  sendApplicationResponse,
  isSuppressed = () => false,
  logPrefix,
  fsModule,
  now,
  setIntervalFn,
  clearIntervalFn,
  pollIntervalMs,
  lookupTimeoutMs,
  idleTimeoutMs,
  activityHeartbeatMs,
  staleActiveRunMaxAgeMs,
  syntheticTerminalGraceMs,
  onStop = () => {},
}) {
  const startedAt = now();
  const state = createMirrorState(threadId);

  let isStopped = false;
  let rolloutPath = null;
  let lastSize = 0;
  let partialLine = "";
  let lastActivityAt = startedAt;
  // Rollout growth only: heartbeats deliberately never refresh this clock, so a
  // desktop process that died mid-run (no terminal event, file frozen) cannot
  // keep the mirror heartbeating "running" forever.
  let lastGrowthAt = startedAt;
  let lastHeartbeatAt = 0;
  let didBootstrap = false;
  let wasSuppressed = false;

  const intervalId = setIntervalFn(tick, pollIntervalMs);
  tick();

  function tick() {
    if (isStopped) {
      return;
    }

    try {
      const currentTime = now();

      // While another live source streams this thread the tail keeps consuming
      // rollout lines with its emissions muted. When that source goes quiet and
      // the mute lifts, everything consumed meanwhile was never mirrored: re-run
      // the bootstrap catch-up so the phone backfills the gap instead of
      // resuming from a cursor past content it never saw.
      const suppressed = isSuppressed();
      if (wasSuppressed && !suppressed && didBootstrap) {
        lastSize = 0;
        partialLine = "";
        didBootstrap = false;
        resetRunState(state);
      }
      wasSuppressed = suppressed;

      if (!rolloutPath) {
        if (currentTime - startedAt >= lookupTimeoutMs) {
          stop();
          return;
        }

        rolloutPath = findRecentRolloutFileForContextRead(resolveSessionsRoot(), {
          threadId,
          fsModule,
        });
        if (!rolloutPath) {
          return;
        }
      }

      const fileSize = readFileSize(rolloutPath, fsModule);
      if (!didBootstrap) {
        didBootstrap = true;
        bootstrapFromExistingRollout({
          rolloutPath,
          fileSize,
          state,
          fsModule,
          sendApplicationResponse,
          nowMs: currentTime,
          staleActiveRunMaxAgeMs,
        });
        lastSize = fileSize;
        lastActivityAt = currentTime;
        lastGrowthAt = currentTime;
        lastHeartbeatAt = currentTime;
        if (state.isDesktopOrigin === false) {
          stop();
        }
        return;
      }

      if (fileSize < lastSize) {
        // Rollout files can be rewritten/truncated by desktop recovery. The
        // rewritten contents are a different history, not live growth: reset the
        // cursor and re-run the bootstrap path (tagged catch-up / terminal
        // catch-up) instead of replaying the whole file as untagged live events.
        lastSize = 0;
        partialLine = "";
        didBootstrap = false;
        resetRunState(state);
        lastGrowthAt = currentTime;
        return;
      }

      if (fileSize > lastSize) {
        const chunk = readFileSlice(rolloutPath, lastSize, fileSize, fsModule);
        lastSize = fileSize;
        lastActivityAt = currentTime;
        lastGrowthAt = currentTime;
        lastHeartbeatAt = currentTime;
        // Real growth proves the run is alive again; resume normal mirroring.
        state.suppressLiveActivityUntilGrowth = false;
        if (!chunk) {
          return;
        }

        const combined = partialLine ? `${partialLine}${chunk}` : chunk;
        let searchStart = 0;
        let nlIndex;
        const lines = [];
        while ((nlIndex = combined.indexOf("\n", searchStart)) !== -1) {
          lines.push(combined.substring(searchStart, nlIndex));
          searchStart = nlIndex + 1;
        }
        partialLine = searchStart < combined.length ? combined.substring(searchStart) : "";
        processRolloutLines(lines, state, sendApplicationResponse, { nowMs: currentTime });
        return;
      }

      const syntheticTerminalNotifications = finalizePendingSyntheticTerminalIfReady(
        state,
        currentTime,
        syntheticTerminalGraceMs
      );
      if (syntheticTerminalNotifications.length > 0) {
        for (const notification of syntheticTerminalNotifications) {
          sendApplicationResponse(JSON.stringify(notification));
        }
        lastActivityAt = currentTime;
        lastHeartbeatAt = currentTime;
        return;
      }

      // A frozen rollout with a still-open turn means the desktop process died
      // mid-run (crash / kill: no terminal event will ever arrive). Stop before
      // heartbeating so the phone is not kept in "running" forever.
      if (state.activeTurnId && currentTime - lastGrowthAt >= staleActiveRunMaxAgeMs) {
        stop();
        return;
      }

      if (
        state.isDesktopOrigin !== false
        && state.activeTurnId
        && !state.suppressLiveActivityUntilGrowth
        && currentTime - lastHeartbeatAt >= activityHeartbeatMs
      ) {
        lastHeartbeatAt = currentTime;
        // Heartbeats keep the idle timeout from killing a quiet-but-alive run
        // (long thinking stretches legitimately exceed the 60s idle window);
        // the growth-stale guard above still bounds crashed runs.
        lastActivityAt = currentTime;
        sendApplicationResponse(JSON.stringify(createNotification("turn/activity", {
          threadId: state.threadId,
          turnId: state.activeTurnId,
          id: state.activeTurnId,
        })));
      }

      if (currentTime - lastActivityAt >= idleTimeoutMs) {
        stop();
      }
    } catch (error) {
      console.warn(`${logPrefix} rollout live mirror stopped for ${threadId}: ${error.message}`);
      stop();
    }
  }

  function bump() {
    lastActivityAt = now();
  }

  function stop() {
    if (isStopped) {
      return;
    }

    // Mark stopped and clear the interval first: a throwing send during the
    // final partial-line flush must never leak the poll interval.
    isStopped = true;
    clearIntervalFn(intervalId);
    if (partialLine) {
      const flushLine = partialLine;
      partialLine = "";
      try {
        processRolloutLines([flushLine], state, sendApplicationResponse, { nowMs: now() });
      } catch (error) {
        console.warn(`${logPrefix} rollout live mirror final flush failed for ${threadId}: ${error.message}`);
      }
    }
    onStop();
  }

  return {
    bump,
    stop,
  };
}

function bootstrapFromExistingRollout({
  rolloutPath,
  fileSize,
  state,
  fsModule,
  sendApplicationResponse,
  nowMs = Date.now(),
  staleActiveRunMaxAgeMs = DEFAULT_STALE_ACTIVE_RUN_MAX_AGE_MS,
}) {
  const initialContents = readFileSlice(rolloutPath, 0, fileSize, fsModule);
  if (!initialContents) {
    return;
  }

  const lines = initialContents.split("\n");
  const activeRunLines = [];
  let insideActiveRun = false;
  let activeTurnId = null;
  let pendingUserPreludeLine = null;
  let latestTerminalRun = null;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    const parsed = safeParseJSON(line);
    if (!parsed) {
      continue;
    }

    if (parsed.type === "session_meta") {
      populateSessionMetaState(state, parsed.payload);
    }

    const taskEventType = parsed?.type === "event_msg"
      ? readString(parsed?.payload?.type)
      : "";
    if (taskEventType === "user_message") {
      pendingUserPreludeLine = line;
    }
    if (taskEventType === "task_started") {
      insideActiveRun = true;
      activeTurnId = readString(parsed?.payload?.turn_id)
        || readString(parsed?.payload?.turnId)
        || "";
      latestTerminalRun = null;
      activeRunLines.length = 0;
      if (pendingUserPreludeLine) {
        activeRunLines.push(pendingUserPreludeLine);
      }
      activeRunLines.push(line);
      continue;
    }

    if (!insideActiveRun) {
      continue;
    }

    activeRunLines.push(line);
    if (TERMINAL_TASK_EVENT_TYPES.has(taskEventType)) {
      // A sibling parallel turn's terminal event must not close the newest
      // run's window; its own terminal event is still honored later.
      const terminalTurnId = readString(parsed?.payload?.turn_id)
        || readString(parsed?.payload?.turnId);
      if (terminalEventClosesTrackedTurn(terminalTurnId, activeTurnId)) {
        latestTerminalRun = terminalRunFromEvent(parsed, activeTurnId);
        insideActiveRun = false;
        activeTurnId = "";
        activeRunLines.length = 0;
        pendingUserPreludeLine = null;
      }
    }
  }

  if (!isDesktopRolloutOrigin(state.sessionMeta)) {
    state.isDesktopOrigin = false;
    return;
  }

  state.isDesktopOrigin = true;

  if (activeRunLines.length === 0 && latestTerminalRun) {
    sendApplicationResponse(JSON.stringify(terminalCatchUpNotification(state.threadId, latestTerminalRun)));
    return;
  }

  // A run with no terminal marker whose rollout stopped growing long ago is dead
  // (killed process / lost session); replaying it would fake a live stream and
  // pin the reopened thread in "running" forever. Hydrate the run context
  // silently instead, so heartbeats stay off but a run that resumes writing can
  // still mirror its new activity live.
  if (
    activeRunLines.length > 0
    && isRolloutFileStale(rolloutPath, fsModule, nowMs, staleActiveRunMaxAgeMs)
  ) {
    state.suppressLiveActivityUntilGrowth = true;
    processRolloutLines(activeRunLines, state, () => {});
    return;
  }

  // Bootstrap replay is catch-up history, not live streaming: tag it so the
  // phone can batch-apply it, then close the burst with an explicit marker so
  // the run still reads as active without waiting for the next heartbeat.
  processRolloutLines(activeRunLines, state, sendApplicationResponse, {
    tagBootstrapReplay: true,
  });
  if (activeRunLines.length > 0 && state.activeTurnId) {
    sendApplicationResponse(JSON.stringify(createNotification("turn/activity", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      id: state.activeTurnId,
      remodexRolloutBootstrapComplete: true,
    })));
  }
}

function isRolloutFileStale(rolloutPath, fsModule, nowMs, staleActiveRunMaxAgeMs) {
  try {
    const modifiedAtMs = fsModule.statSync(rolloutPath).mtimeMs;
    return Number.isFinite(modifiedAtMs) && nowMs - modifiedAtMs >= staleActiveRunMaxAgeMs;
  } catch {
    return false;
  }
}

function terminalRunFromEvent(entry, fallbackTurnId = "") {
  const payload = entry?.payload || {};
  const eventType = readString(payload.type);
  if (!TERMINAL_TASK_EVENT_TYPES.has(eventType)) {
    return null;
  }

  const turnId = readString(payload.turn_id)
    || readString(payload.turnId)
    || readString(fallbackTurnId);
  if (!turnId) {
    return null;
  }

  return {
    eventType,
    turnId,
    message: readString(payload.message),
  };
}

function terminalCatchUpNotification(threadId, terminalRun) {
  const params = {
    threadId,
    turnId: terminalRun.turnId,
    id: terminalRun.turnId,
    remodexRolloutTerminalCatchUp: true,
  };
  if (terminalRun.eventType === "turn_aborted") {
    params.status = "aborted";
  } else if (terminalRun.eventType === "error") {
    params.status = "failed";
    if (terminalRun.message) {
      params.error = { message: terminalRun.message };
    }
  }
  return createNotification("turn/completed", params);
}

function processRolloutLines(lines, state, sendApplicationResponse, {
  tagBootstrapReplay = false,
  nowMs = Date.now(),
} = {}) {
  if (!Array.isArray(lines) || lines.length === 0) {
    return;
  }

  const emitNotification = (notification) => {
    if (tagBootstrapReplay && notification.params && typeof notification.params === "object") {
      notification.params.remodexRolloutBootstrapReplay = true;
    }
    sendApplicationResponse(JSON.stringify(notification));
  };

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    const parsed = safeParseJSON(line);
    if (!parsed) {
      continue;
    }

    const notifications = synthesizeNotificationsFromRolloutEntry(parsed, state, { nowMs });
    for (const notification of notifications) {
      emitNotification(notification);
    }
  }
}

function synthesizeNotificationsFromRolloutEntry(entry, state, { nowMs = Date.now() } = {}) {
  if (entry?.type === "session_meta") {
    populateSessionMetaState(state, entry.payload);
    if (!isDesktopRolloutOrigin(state.sessionMeta)) {
      state.isDesktopOrigin = false;
    } else if (state.isDesktopOrigin == null) {
      state.isDesktopOrigin = true;
    }
    return [];
  }

  if (state.isDesktopOrigin === false) {
    return [];
  }

  const notifications = [];

  if (entry?.type === "event_msg") {
    const payload = entry.payload || {};
    const eventType = readString(payload.type);

    if (eventType === "task_started") {
      notifications.push(...finalizePendingSyntheticTerminal(state));
      const explicitTurnId = readString(payload.turn_id) || readString(payload.turnId);
      const turnId = explicitTurnId || buildSyntheticTurnId(state, entry);
      state.activeTurnId = turnId;
      state.activeTurnIdIsSynthetic = !explicitTurnId;
      state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, turnId);
      state.hasThinking = false;
      state.commandCalls.clear();
      state.applyPatchCalls.clear();
      state.emittedPatchApplyEndCalls.clear();

      const startedParams = {
        threadId: state.threadId,
        remodexDesktopMirror: true,
        remodexRolloutLiveMirror: true,
      };
      startedParams.turnId = turnId;
      startedParams.id = turnId;
      notifications.push(createNotification("turn/started", startedParams));
      notifications.push(...flushPendingUserMessageNotifications(state, turnId));
      notifications.push(...ensureThinkingNotifications(state));
      return notifications;
    }

    if (eventType && !TERMINAL_TASK_EVENT_TYPES.has(eventType)) {
      clearPendingSyntheticTerminal(state);
    }

    if (eventType === "user_message") {
      // Rollouts persist injected context (AGENTS.md instructions, IDE prompt
      // wrappers) as user_message events; only the real request is a bubble.
      const message = visibleUserPromptFromInputEntries(
        readString(payload.message) || readString(payload.text)
      );
      if (!message) {
        return [];
      }

      const turnId = resolveRolloutEventTurnId(state, payload);
      if (!turnId) {
        state.pendingUserMessages.push({
          id: readString(payload.id),
          message,
          timestamp: readUserMessageTimestamp(entry, payload),
        });
        return [];
      }

      notifications.push(createNotification("codex/event/user_message", {
        threadId: state.threadId,
        turnId,
        message,
        ...(readString(payload.id) ? { id: readString(payload.id) } : {}),
        ...timestampParams(readUserMessageTimestamp(entry, payload)),
      }));
      return notifications;
    }

    if (eventType === "task_complete") {
      const turnId = resolveRolloutEventTurnId(state, payload, { allowSyntheticPromotion: false });
      if (!turnId) {
        return [];
      }

      // Desktop runs parallel turns in one rollout: a sibling turn finishing
      // must not wipe the tracked state of the turn that is still streaming.
      const closesActiveRun = terminalEventClosesTrackedTurn(turnId, state.activeTurnId);
      if (closesActiveRun) {
        notifications.push(...turnFileChangeSnapshotNotifications(state, turnId));
      }
      notifications.push(createNotification("turn/completed", {
        threadId: state.threadId,
        turnId,
        id: turnId,
      }));
      if (closesActiveRun) {
        resetRunState(state);
      } else if (isSyntheticTerminalMismatch(state, turnId)) {
        markPendingSyntheticTerminal(state, { status: "completed" }, nowMs);
      }
      return notifications;
    }

    // Aborted/failed desktop runs never write task_complete; close the mirrored
    // turn anyway so the phone does not keep the thread pinned as running.
    if (eventType === "turn_aborted" || eventType === "error") {
      const turnId = resolveRolloutEventTurnId(state, payload, { allowSyntheticPromotion: false });
      if (!turnId) {
        return [];
      }

      const terminalParams = {
        threadId: state.threadId,
        turnId,
        id: turnId,
        status: eventType === "error" ? "failed" : "aborted",
      };
      const errorMessage = readString(payload.message);
      if (eventType === "error" && errorMessage) {
        terminalParams.error = { message: errorMessage };
      }
      notifications.push(createNotification("turn/completed", terminalParams));
      if (terminalEventClosesTrackedTurn(turnId, state.activeTurnId)) {
        resetRunState(state);
      } else if (isSyntheticTerminalMismatch(state, turnId)) {
        markPendingSyntheticTerminal(state, terminalParams, nowMs);
      }
      return notifications;
    }

    if (eventType === "item_completed") {
      notifications.push(...itemCompletedNotifications(state, payload));
      return notifications;
    }

    if (eventType === "agent_reasoning") {
      notifications.push(...reasoningNotifications(state, firstNonEmptyString([
        readString(payload.message),
        readString(payload.text),
        readString(payload.summary),
      ])));
      return notifications;
    }

    if (eventType === "agent_message") {
      notifications.push(...agentMessageNotifications(state, entry, payload));
      return notifications;
    }

    if (eventType === "image_generation_end") {
      notifications.push(...imageGenerationNotifications(state, payload, {
        preferCallId: true,
      }));
      return notifications;
    }

    if (eventType === "patch_apply_end") {
      notifications.push(...patchApplyEndNotifications(state, payload));
      return notifications;
    }

    return [];
  }

  if (entry?.type !== "response_item") {
    return [];
  }

  clearPendingSyntheticTerminal(state);

  const payload = entry.payload || {};
  const itemType = normalizeRolloutItemType(payload.type);

  if (itemType === "message") {
    notifications.push(...responseItemMessageNotifications(state, entry, payload));
    return notifications;
  }

  if (itemType === "reasoning") {
    notifications.push(...reasoningNotifications(state, extractReasoningText(payload)));
    return notifications;
  }

  if (itemType === "functioncall") {
    notifications.push(...toolStartNotifications(state, payload));
    return notifications;
  }

  if (itemType === "customtoolcall") {
    notifications.push(...customToolStartNotifications(state, payload));
    return notifications;
  }

  if (itemType === "functioncalloutput") {
    notifications.push(...toolOutputNotifications(state, payload));
    return notifications;
  }

  if (itemType === "imagegeneration" || itemType === "imagegenerationcall" || itemType === "imagegenerationend" || itemType === "imageview") {
    notifications.push(...imageGenerationNotifications(state, payload));
    return notifications;
  }

  return notifications;
}

function reasoningNotifications(state, text) {
  if (!state.activeTurnId) {
    return [];
  }

  const delta = readString(text);
  if (!delta) {
    return ensureThinkingNotifications(state);
  }

  state.hasThinking = true;
  return [
    createNotification("item/reasoning/textDelta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      itemId: state.reasoningItemId || buildSyntheticItemId("thinking", state.threadId, state.activeTurnId),
      delta,
    }),
  ];
}

function responseItemMessageNotifications(state, entry, payload) {
  const role = readString(payload?.role).toLowerCase();
  if (role && role !== "assistant") {
    return [];
  }

  const message = extractResponseItemMessageText(payload);
  if (!message) {
    return [];
  }

  return agentMessageNotifications(state, entry, {
    message,
    phase: payload?.phase,
    itemId: readString(payload?.id),
    turn_id: readString(payload?.turn_id) || readString(payload?.internal_chat_message_metadata_passthrough?.turn_id),
    turnId: readString(payload?.turnId) || readString(payload?.internal_chat_message_metadata_passthrough?.turnId),
  });
}

function agentMessageNotifications(state, entry, payload) {
  const message = readString(payload?.message) || readString(payload?.text);
  if (!message) {
    return [];
  }

  const turnId = resolveRolloutEventTurnId(state, payload);
  const dedupeKey = agentMessageDedupeKey(turnId, message);
  if (state.emittedAgentMessageKeys.has(dedupeKey)) {
    return [];
  }
  state.emittedAgentMessageKeys.add(dedupeKey);

  // Commentary (interleaved progress prose) is mirrored too: desktop renders it
  // between tool calls, and dropping it would glue every tool row into one burst
  // on the phone. The phase rides along so the app can keep commentary rows
  // distinct from the final answer.
  const params = {
    threadId: state.threadId,
    turnId,
    itemId: readString(payload?.itemId) || buildAgentMessageItemId(state.threadId, turnId, entry, message),
    message,
  };
  const phase = readString(payload?.phase);
  if (phase) {
    params.phase = phase;
  }

  return [createNotification("codex/event/agent_message", params)];
}

function extractResponseItemMessageText(payload) {
  if (!payload || typeof payload !== "object") {
    return "";
  }

  const content = Array.isArray(payload.content) ? payload.content : [];
  const parts = content
    .map((part) => readString(part?.text) || readString(part?.content) || readString(part?.message))
    .filter(Boolean);
  return parts.join("\n");
}

function toolStartNotifications(state, payload) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = readString(payload.call_id) || readString(payload.callId);
  const toolName = readString(payload.name);
  if (!callId || !toolName) {
    return [];
  }

  const argumentsObject = parseToolArguments(payload.arguments);
  if (isInternalProgressPlanToolName(toolName)) {
    return [
      ...ensureThinkingNotifications(state),
      ...planUpdateNotifications(state, argumentsObject),
    ];
  }

  if (readString(toolName).toLowerCase() === "apply_patch") {
    const item = buildApplyPatchFileChangeItem({
      callId,
      patch: readString(argumentsObject.patch) || readString(argumentsObject.input) || readString(payload.input),
      status: readString(payload.status) || "completed",
      idFallback: buildSyntheticItemId("file-change", state.threadId, state.activeTurnId, callId),
    });
    const notifications = [...ensureThinkingNotifications(state)];
    if (!item) {
      return [
        ...notifications,
        createNotification("codex/event/background_event", {
          threadId: state.threadId,
          turnId: state.activeTurnId,
          call_id: callId,
          message: genericToolActivityMessage(toolName),
        }),
      ];
    }
    state.applyPatchCalls.set(callId, item);
    return [
      ...notifications,
      createNotification("codex/event/patch_apply_begin", {
        threadId: state.threadId,
        turnId: state.activeTurnId,
        id: state.activeTurnId,
        call_id: callId,
        itemId: item.id,
        status: "inProgress",
        changes: item.changes,
      }),
    ];
  }

  state.commandCalls.set(callId, {
    toolName,
    command: resolveToolCommand(toolName, argumentsObject),
    cwd: resolveToolWorkingDirectory(argumentsObject, state),
  });

  if (isCommandToolName(toolName)) {
    const command = state.commandCalls.get(callId)?.command || toolName;
    return [
      ...ensureThinkingNotifications(state),
      createNotification("codex/event/exec_command_begin", {
        threadId: state.threadId,
        turnId: state.activeTurnId,
        call_id: callId,
        command,
        cwd: state.commandCalls.get(callId)?.cwd || state.sessionMeta?.cwd || "",
        status: "running",
      }),
    ];
  }

  const activityMessage = genericToolActivityMessage(toolName);
  if (!activityMessage) {
    return ensureThinkingNotifications(state);
  }

  return [
    ...ensureThinkingNotifications(state),
    createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      message: activityMessage,
    }),
  ];
}

function customToolStartNotifications(state, payload) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = readString(payload.call_id) || readString(payload.callId);
  const toolName = readString(payload.name);
  if (!callId || !toolName) {
    return [];
  }

  const notifications = [...ensureThinkingNotifications(state)];
  if (toolName === "apply_patch") {
    const item = buildApplyPatchFileChangeItem({
      callId,
      patch: readString(payload.input),
      status: readString(payload.status) || "completed",
      idFallback: buildSyntheticItemId("file-change", state.threadId, state.activeTurnId, callId),
    });
    if (item) {
      state.applyPatchCalls.set(callId, item);
      notifications.push(createNotification("codex/event/patch_apply_begin", {
        threadId: state.threadId,
        turnId: state.activeTurnId,
        id: state.activeTurnId,
        call_id: callId,
        itemId: item.id,
        status: "inProgress",
        changes: item.changes,
      }));
    }
  }

  const activityMessage = genericToolActivityMessage(toolName);
  if (!activityMessage) {
    return notifications;
  }

  return [
    ...notifications,
    createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      message: activityMessage,
    }),
  ];
}

function patchApplyEndNotifications(state, payload) {
  const turnId = resolveRolloutEventTurnId(state, payload);
  const callId = readString(payload.call_id) || readString(payload.callId);
  if (!turnId || !callId || state.emittedPatchApplyEndCalls.has(callId)) {
    return [];
  }

  const fileChangeItem = state.applyPatchCalls.get(callId);
  const changes = Array.isArray(payload.changes)
    ? payload.changes
    : fileChangeItem?.changes || [];
  if (changes.length === 0) {
    return [];
  }

  state.emittedPatchApplyEndCalls.add(callId);
  return [
    ...ensureThinkingNotifications(state),
    createNotification("codex/event/patch_apply_end", {
      threadId: state.threadId,
      turnId,
      id: turnId,
      call_id: callId,
      itemId: fileChangeItem?.id || callId,
      status: readString(payload.status) || fileChangeItem?.status || "completed",
      success: payload.success !== false,
      changes,
    }),
  ];
}

function turnFileChangeSnapshotNotifications(state, turnId) {
  const patchEntries = Array.from(state.applyPatchCalls.entries());
  if (!turnId || patchEntries.length === 0) {
    return [];
  }

  const changes = patchEntries.flatMap(([, item]) => Array.isArray(item?.changes) ? item.changes : []);
  if (changes.length === 0) {
    return [];
  }

  const [lastCallId, lastItem] = patchEntries[patchEntries.length - 1];
  const itemId = readString(lastItem?.id) || readString(lastCallId) || buildSyntheticItemId("file-change", state.threadId, turnId);
  return [
    createNotification("codex/event/patch_apply_end", {
      threadId: state.threadId,
      turnId,
      id: turnId,
      call_id: itemId,
      itemId,
      status: "completed",
      success: true,
      changes,
      remodexTurnFileChangeSnapshot: true,
    }),
  ];
}

function toolOutputNotifications(state, payload) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = readString(payload.call_id) || readString(payload.callId);
  if (!callId) {
    return [];
  }

  const toolCall = state.commandCalls.get(callId);
  if (!toolCall) {
    return [];
  }

  if (!isCommandToolName(toolCall.toolName)) {
    const notifications = [...ensureThinkingNotifications(state)];
    notifications.push(createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      message: genericToolCompletionMessage(toolCall.toolName),
    }));
    state.commandCalls.delete(callId);
    return notifications;
  }

  const output = readString(payload.output);
  const notifications = [...ensureThinkingNotifications(state)];
  if (output) {
    notifications.push(createNotification("codex/event/exec_command_output_delta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      command: toolCall.command,
      cwd: toolCall.cwd || "",
      chunk: output,
    }));
  }

  notifications.push(createNotification("codex/event/exec_command_end", {
    threadId: state.threadId,
    turnId: state.activeTurnId,
    call_id: callId,
    command: toolCall.command,
    cwd: toolCall.cwd || "",
    status: "completed",
    output: output || "",
  }));
  state.commandCalls.delete(callId);
  return notifications;
}

function imageGenerationNotifications(state, payload, { preferCallId = false } = {}) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = preferCallId
    ? firstNonEmptyString([
        readString(payload.call_id),
        readString(payload.callId),
        readString(payload.itemId),
        readString(payload.item_id),
        readString(payload.id),
      ])
    : firstNonEmptyString([
        readString(payload.id),
        readString(payload.call_id),
        readString(payload.callId),
        readString(payload.itemId),
        readString(payload.item_id),
      ]);
  if (!callId) {
    return [];
  }

  const imagePath = firstNonEmptyString([
    readString(payload.saved_path),
    readString(payload.savedPath),
    readString(payload.file_path),
    readString(payload.path),
  ]) || generatedImagePathForRolloutItem(state.threadId, callId);
  if (!imagePath) {
    return [];
  }

  return [
    ...ensureThinkingNotifications(state),
    createNotification("codex/event/image_generation_end", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      itemId: callId,
      saved_path: imagePath,
      file_path: imagePath,
      path: imagePath,
    }),
  ];
}

function itemCompletedNotifications(state, payload) {
  const item = payload && typeof payload.item === "object" && !Array.isArray(payload.item)
    ? payload.item
    : null;
  if (!item || normalizeRolloutItemType(item.type) !== "plan") {
    return [];
  }

  const turnId = resolveRolloutEventTurnId(state, payload);
  if (!turnId) {
    return [];
  }

  return [
    createNotification("item/completed", {
      threadId: state.threadId,
      turnId,
      item,
    }),
  ];
}

// Synthetic turn ids are a temporary stand-in; close them if a terminal event
// had no later activity proving it belonged to a sibling parallel run.
function markPendingSyntheticTerminal(state, terminalParams = {}, nowMs = Date.now()) {
  if (state.activeTurnIdIsSynthetic && state.activeTurnId) {
    state.pendingSyntheticTerminalTurnId = state.activeTurnId;
    state.pendingSyntheticTerminalStartedAt = nowMs;
    state.pendingSyntheticTerminalStatus = readString(terminalParams.status) || "";
    state.pendingSyntheticTerminalErrorMessage = readString(terminalParams.error?.message) || "";
  }
}

function clearPendingSyntheticTerminal(state) {
  state.pendingSyntheticTerminalTurnId = null;
  state.pendingSyntheticTerminalStartedAt = 0;
  state.pendingSyntheticTerminalStatus = "";
  state.pendingSyntheticTerminalErrorMessage = "";
}

function isSyntheticTerminalMismatch(state, terminalTurnId) {
  return Boolean(
    state.activeTurnIdIsSynthetic
    && state.activeTurnId
    && terminalTurnId
    && terminalTurnId !== state.activeTurnId
  );
}

function finalizePendingSyntheticTerminal(state) {
  const turnId = state.pendingSyntheticTerminalTurnId;
  if (!turnId) {
    return [];
  }

  const terminalParams = {
    threadId: state.threadId,
    turnId,
    id: turnId,
  };
  if (state.pendingSyntheticTerminalStatus) {
    terminalParams.status = state.pendingSyntheticTerminalStatus;
  }
  if (state.pendingSyntheticTerminalErrorMessage) {
    terminalParams.error = { message: state.pendingSyntheticTerminalErrorMessage };
  }

  const notifications = [
    ...turnFileChangeSnapshotNotifications(state, turnId),
    createNotification("turn/completed", terminalParams),
  ];
  resetRunState(state);
  return notifications;
}

function finalizePendingSyntheticTerminalIfReady(state, nowMs, graceMs) {
  if (!state.pendingSyntheticTerminalTurnId) {
    return [];
  }
  const startedAt = Number.isFinite(state.pendingSyntheticTerminalStartedAt)
    ? state.pendingSyntheticTerminalStartedAt
    : nowMs;
  const resolvedGraceMs = Number.isFinite(graceMs)
    ? Math.max(0, graceMs)
    : DEFAULT_SYNTHETIC_TERMINAL_GRACE_MS;
  if (nowMs - startedAt < resolvedGraceMs) {
    return [];
  }
  return finalizePendingSyntheticTerminal(state);
}

function ensureThinkingNotifications(state) {
  if (!state.activeTurnId || state.hasThinking) {
    return [];
  }

  state.hasThinking = true;
  if (!state.reasoningItemId) {
    state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, state.activeTurnId);
  }

  return [
    createNotification("item/reasoning/textDelta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      itemId: state.reasoningItemId,
      delta: "Thinking...",
    }),
  ];
}

function createMirrorState(threadId) {
  return {
    threadId,
    sessionMeta: null,
    isDesktopOrigin: null,
    activeTurnId: null,
    reasoningItemId: null,
    hasThinking: false,
    commandCalls: new Map(),
    applyPatchCalls: new Map(),
    emittedPatchApplyEndCalls: new Set(),
    emittedAgentMessageKeys: new Set(),
    pendingUserMessages: [],
    pendingSyntheticTerminalTurnId: null,
    pendingSyntheticTerminalStartedAt: 0,
    pendingSyntheticTerminalStatus: "",
    pendingSyntheticTerminalErrorMessage: "",
    activeTurnIdIsSynthetic: false,
    // True after a stale bootstrap: run context is hydrated but nothing is
    // emitted (including heartbeats) until the rollout file grows again.
    suppressLiveActivityUntilGrowth: false,
  };
}

function populateSessionMetaState(state, payload) {
  if (!payload || typeof payload !== "object") {
    return;
  }

  state.sessionMeta = {
    originator: readString(payload.originator),
    source: readString(payload.source),
    cwd: readString(payload.cwd),
  };
}

function isDesktopRolloutOrigin(sessionMeta) {
  const originator = readString(sessionMeta?.originator).toLowerCase();
  const source = readString(sessionMeta?.source).toLowerCase();
  if (!originator && !source) {
    return false;
  }

  if (originator.includes("mobile") || originator.includes("ios")) {
    return false;
  }

  return originator.includes("desktop")
    || originator.includes("vscode")
    || source.includes("vscode")
    || source.includes("desktop");
}

function extractReasoningText(payload) {
  const summary = Array.isArray(payload?.summary)
    ? payload.summary
        .map((part) => readString(part?.text) || readString(part?.summary))
        .filter(Boolean)
        .join("\n")
    : "";
  return firstNonEmptyString([
    summary,
    readString(payload?.text),
    readString(payload?.content),
  ]);
}

function parseToolArguments(rawArguments) {
  const parsed = safeParseJSON(rawArguments);
  return parsed && typeof parsed === "object" ? parsed : {};
}

function planUpdateNotifications(state, argumentsObject) {
  const plan = normalizeProgressPlanSteps(argumentsObject.plan);
  if (plan.length === 0) {
    return [];
  }

  const params = {
    threadId: state.threadId,
    turnId: state.activeTurnId,
    plan,
  };
  const explanation = readString(argumentsObject.explanation);
  if (explanation) {
    params.explanation = explanation;
  }

  return [createNotification("turn/plan/updated", params)];
}

function normalizeProgressPlanSteps(rawPlan) {
  if (!Array.isArray(rawPlan)) {
    return [];
  }

  return rawPlan.flatMap((rawStep) => {
    if (!rawStep || typeof rawStep !== "object") {
      return [];
    }

    const step = readString(rawStep.step);
    const status = normalizeProgressPlanStatus(rawStep.status);
    if (!step || !status) {
      return [];
    }

    return [{ step, status }];
  });
}

function normalizeProgressPlanStatus(rawStatus) {
  const normalized = readString(rawStatus);
  switch (normalized) {
  case "pending":
  case "in_progress":
  case "inProgress":
  case "completed":
    return normalized;
  default:
    return "";
  }
}

function resolveToolCommand(toolName, argumentsObject) {
  if (isCommandToolName(toolName)) {
    return firstNonEmptyString([
      readString(argumentsObject.cmd),
      readString(argumentsObject.command),
      readString(argumentsObject.raw_command),
      readString(argumentsObject.rawCommand),
    ]) || toolName;
  }

  return toolName;
}

function resolveToolWorkingDirectory(argumentsObject, state) {
  return firstNonEmptyString([
    readString(argumentsObject.workdir),
    readString(argumentsObject.cwd),
    readString(argumentsObject.working_directory),
    readString(state.sessionMeta?.cwd),
  ]) || "";
}

function isCommandToolName(toolName) {
  const normalized = readString(toolName).toLowerCase();
  return normalized === "exec_command" || normalized === "shell_command";
}

function isInternalProgressPlanToolName(toolName) {
  return readString(toolName).toLowerCase() === "update_plan";
}

function genericToolActivityMessage(toolName) {
  switch (readString(toolName).toLowerCase()) {
  case "apply_patch":
    return "Applying patch";
  case "write_stdin":
    return "Writing to terminal";
  case "read_thread_terminal":
    return "Reading terminal output";
  default:
    return `Running ${toolName}`;
  }
}

function genericToolCompletionMessage(toolName) {
  return `Completed ${readString(toolName)}`;
}

function createNotification(method, params = {}) {
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return { method, params };
  }

  return {
    method,
    params: {
      remodexDesktopMirror: true,
      remodexRolloutLiveMirror: true,
      ...params,
    },
  };
}

function flushPendingUserMessageNotifications(state, turnId) {
  const messages = state.pendingUserMessages.splice(0);
  if (messages.length === 0) {
    return [];
  }

  const resolvedTurnId = readString(turnId) || readString(state.activeTurnId);
  return messages
    .map((pending) => ({ ...pending, message: visibleUserPromptFromInputEntries(pending.message) }))
    .filter((pending) => pending.message)
    .map((pending) => createNotification("codex/event/user_message", {
      threadId: state.threadId,
      // An empty turnId reads as "no turn identity" on the phone and blocks
      // dedup against the turn-bound row of the same prompt; omit it instead.
      ...(resolvedTurnId ? { turnId: resolvedTurnId } : {}),
      message: pending.message,
      ...(pending.id ? { id: pending.id } : {}),
      ...timestampParams(pending.timestamp),
    }));
}

function readUserMessageTimestamp(entry, payload = {}) {
  return firstNonEmptyString([
    readString(payload.createdAt),
    readString(payload.created_at),
    readString(payload.timestamp),
    readString(payload.time),
    readString(entry?.timestamp),
  ]);
}

function timestampParams(timestamp) {
  const normalizedTimestamp = readString(timestamp);
  return normalizedTimestamp
    ? { createdAt: normalizedTimestamp, timestamp: normalizedTimestamp }
    : {};
}

function buildSyntheticItemId(kind, threadId, turnId, suffix = "") {
  const suffixPart = suffix ? `:${suffix}` : "";
  return `rollout-${kind}:${threadId}:${turnId}${suffixPart}`;
}

function buildSyntheticTurnId(state, entry) {
  const timestamp = readString(entry?.timestamp) || "unknown";
  return `rollout-turn:${state.threadId}:${timestamp}`;
}

function resolveRolloutEventTurnId(state, payload = {}, { allowSyntheticPromotion = true } = {}) {
  const explicitTurnId = readString(payload.turn_id) || readString(payload.turnId);
  if (state.activeTurnIdIsSynthetic && state.activeTurnId) {
    if (explicitTurnId) {
      // Terminal events must not promote: with parallel turns, a sibling's
      // terminal explicit id would hijack the synthetic run and wipe it. The
      // active run's real id is adopted from its own non-terminal events.
      if (allowSyntheticPromotion) {
        promoteSyntheticTurnId(state, explicitTurnId);
      }
      return explicitTurnId;
    }
    return state.activeTurnId;
  }
  return explicitTurnId || state.activeTurnId || "";
}

function promoteSyntheticTurnId(state, explicitTurnId) {
  const oldTurnId = state.activeTurnId;
  if (!oldTurnId || oldTurnId === explicitTurnId) {
    state.activeTurnId = explicitTurnId;
    state.activeTurnIdIsSynthetic = false;
    return;
  }

  state.activeTurnId = explicitTurnId;
  state.activeTurnIdIsSynthetic = false;
  if (state.reasoningItemId === buildSyntheticItemId("thinking", state.threadId, oldTurnId)) {
    state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, explicitTurnId);
  }
}

function buildAgentMessageItemId(threadId, turnId, entry, message) {
  const timestamp = readString(entry?.timestamp) || "untimed";
  const messageHash = crypto
    .createHash("sha256")
    .update(readString(message))
    .digest("hex")
    .slice(0, 12);
  return buildSyntheticItemId(
    "agent-message",
    threadId,
    turnId || "turnless",
    `${timestamp}:${messageHash}`
  );
}

// Keyed on turn + text only: the same assistant text often arrives twice per
// turn (event_msg agent_message and response_item message), and only one side
// carries `phase`, so phase must stay out of the key for them to collide.
// Legitimately repeated identical prose in one turn is rare and the phone's
// item-scoped dedup covers the remainder.
function agentMessageDedupeKey(turnId, message) {
  const messageHash = crypto
    .createHash("sha256")
    .update(readString(message))
    .digest("hex")
    .slice(0, 16);
  return `${turnId || "turnless"}:${messageHash}`;
}

function generatedImagePathForRolloutItem(threadId, callId) {
  const resolvedThreadId = readString(threadId);
  const resolvedCallId = readString(callId);
  if (!resolvedThreadId || !resolvedCallId) {
    return "";
  }

  return path.join(resolveCodexGeneratedImagesRoot(), resolvedThreadId, `${resolvedCallId}.png`);
}

function normalizeRolloutItemType(value) {
  return readString(value).replace(/[_-]/g, "").toLowerCase();
}

function resetRunState(state) {
  state.activeTurnId = null;
  state.reasoningItemId = null;
  state.hasThinking = false;
  state.commandCalls.clear();
  state.applyPatchCalls.clear();
  state.emittedPatchApplyEndCalls.clear();
  state.emittedAgentMessageKeys.clear();
  state.pendingUserMessages.length = 0;
  state.pendingSyntheticTerminalTurnId = null;
  state.pendingSyntheticTerminalStartedAt = 0;
  state.pendingSyntheticTerminalStatus = "";
  state.pendingSyntheticTerminalErrorMessage = "";
  state.activeTurnIdIsSynthetic = false;
}

function readThreadId(params) {
  return firstNonEmptyString([
    readString(params?.threadId),
    readString(params?.thread_id),
  ]) || "";
}

function readFileSize(filePath, fsModule) {
  return fsModule.statSync(filePath).size;
}

function readFileSlice(filePath, start, endExclusive, fsModule) {
  const length = Math.max(0, endExclusive - start);
  if (length === 0) {
    return "";
  }

  const fileHandle = fsModule.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytesRead = fsModule.readSync(fileHandle, buffer, 0, length, start);
    return buffer.toString("utf8", 0, bytesRead);
  } finally {
    fsModule.closeSync(fileHandle);
  }
}

function safeParseJSON(rawValue) {
  if (typeof rawValue !== "string" || !rawValue.trim()) {
    return null;
  }

  try {
    return JSON.parse(rawValue);
  } catch {
    return null;
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function firstNonEmptyString(values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return "";
}

module.exports = {
  createRolloutLiveMirrorController,
  isDesktopRolloutOrigin,
};
