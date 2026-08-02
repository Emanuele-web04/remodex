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
  expandExecWrapperToolCall,
  isOrchestrationWaitCall,
} = require("./codex-tool-wrapper");
const {
  TERMINAL_TASK_EVENT_TYPES,
  terminalEventClosesTrackedTurn,
} = require("./rollout-turn-semantics");
const {
  hasVisiblePlanUpdate,
  buildRemodexSourceItemKey,
  visibleUserPromptFromInputEntries,
  visibleUserPromptText,
  responseItemMessageText,
} = require("./desktop-ipc-shared");

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
// Rollouts can be tens of megabytes. They are a live-delta fallback, not the
// durable conversation history, so bootstrap must never synchronously parse
// the entire file just to discover an active turn.
const DEFAULT_BOOTSTRAP_METADATA_HEAD_BYTES = 256 * 1024;
const DEFAULT_BOOTSTRAP_TAIL_BYTES = 4 * 1024 * 1024;
// Keep a hard bound, but match the JSONL history reader's 64MB recovery window
// so a long active turn does not degrade permanently to no live context.
const DEFAULT_BOOTSTRAP_MAX_BYTES = 64 * 1024 * 1024;
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
  setImmediateFn = setImmediate,
  clearImmediateFn = clearImmediate,
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
    let suppressionContext = {};
    const isThreadSuppressed = () => Boolean(shouldSuppressThread?.(threadId, suppressionContext));
    mirror = createThreadRolloutLiveMirror({
      threadId,
      sendApplicationResponse: typeof shouldSuppressThread === "function"
        ? (rawNotification) => {
          if (!isThreadSuppressed()) {
            sendApplicationResponse(rawNotification);
          }
        }
        : sendApplicationResponse,
      isSuppressed: typeof shouldSuppressThread === "function"
        ? (context) => {
          suppressionContext = context || {};
          return isThreadSuppressed();
        }
        : () => false,
      logPrefix,
      fsModule,
      now,
      setIntervalFn,
      clearIntervalFn,
      setImmediateFn,
      clearImmediateFn,
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

  // The real turn id this mirror is actively tailing, or null. Lets the bridge
  // answer the phone's turn-state probe from mirror truth when the bounded
  // canonical page reads a busy run as closed.
  function getActiveTurnId(threadId) {
    return mirrorsByThreadId.get(threadId)?.getActiveTurnId() || null;
  }

  return {
    observeInbound,
    stopAll,
    getActiveTurnId,
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
  setImmediateFn,
  clearImmediateFn,
  pollIntervalMs,
  lookupTimeoutMs,
  idleTimeoutMs,
  activityHeartbeatMs,
  staleActiveRunMaxAgeMs,
  syntheticTerminalGraceMs,
  onStop = () => {},
}) {
  const startedAt = now();
  let lookupStartedAt = startedAt;
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
  let initialTickId = setImmediateFn(() => {
    initialTickId = null;
    tick();
  });

  function tick() {
    if (isStopped) {
      return;
    }

    try {
      const currentTime = now();
      const suppressedBeforeScan = isSuppressed();
      if (suppressedBeforeScan) {
        if (!wasSuppressed) {
          rolloutPath = null;
          lastSize = 0;
          partialLine = "";
          didBootstrap = false;
          resetRunState(state);
        }
        wasSuppressed = true;
        return;
      }
      if (wasSuppressed) {
        rolloutPath = null;
        lastSize = 0;
        partialLine = "";
        didBootstrap = false;
        resetRunState(state);
        lookupStartedAt = currentTime;
        wasSuppressed = false;
      }

      if (!rolloutPath) {
        if (currentTime - lookupStartedAt >= lookupTimeoutMs) {
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

      const rolloutStat = fsModule.statSync(rolloutPath);
      const fileSize = rolloutStat.size;
      // Re-check ownership with the rollout's activity time before bootstrapping.
      // If another source owns the thread, leave the file untouched until that
      // ownership expires.
      const suppressed = isSuppressed({
        fallbackActivityAt: Number(rolloutStat.mtimeMs) || 0,
      });
      if (suppressed) {
        rolloutPath = null;
        lastSize = 0;
        partialLine = "";
        didBootstrap = false;
        resetRunState(state);
        wasSuppressed = true;
        return;
      }
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
        // A capped bootstrap has no verified active-turn opener. Never append
        // arbitrary deltas to that unknown state: wait for growth, then retry
        // a bounded coherent bootstrap. A new task_started+prompt near EOF
        // recovers immediately; an old huge run remains canonical-history only.
        const chunk = readFileSlice(rolloutPath, lastSize, fileSize, fsModule);
        lastSize = fileSize;
        lastActivityAt = currentTime;
        lastGrowthAt = currentTime;
        lastHeartbeatAt = currentTime;
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
        if (state.awaitingCoherentBoundary) {
          if (processAwaitingCoherentBoundary(lines, state, sendApplicationResponse, currentTime)) {
            state.awaitingCoherentBoundary = false;
          }
          return;
        }
        // Real growth proves the run is alive again; resume normal mirroring.
        state.suppressLiveActivityUntilGrowth = false;
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
    if (initialTickId != null) {
      clearImmediateFn(initialTickId);
      initialTickId = null;
    }
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

  // Only a healthy, actively-tailed run with a real id counts: synthetic ids
  // are not actionable app-server turn ids, and suppressed/awaiting states
  // mean the mirror does not actually know what is running. While another live
  // source owns the thread the mirror has no parsed file state, so reporting a
  // turn id would resurrect exactly the state the bridge muted.
  function getActiveTurnId() {
    if (
      isStopped
      || wasSuppressed
      || state.isDesktopOrigin === false
      || state.awaitingCoherentBoundary
      || state.suppressLiveActivityUntilGrowth
      || state.activeTurnIdIsSynthetic
      || state.pendingSyntheticTerminalTurnId
    ) {
      return null;
    }
    return state.activeTurnId || null;
  }

  return {
    bump,
    stop,
    getActiveTurnId,
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
  // Read metadata independently from the tail. session_meta is written at the
  // beginning, while the active run lives at the end. This keeps reopening a
  // 30MB rollout bounded and avoids treating a partial tail as history.
  const metadataContents = readFileSlice(
    rolloutPath,
    0,
    Math.min(fileSize, DEFAULT_BOOTSTRAP_METADATA_HEAD_BYTES),
    fsModule
  );
  for (const rawLine of metadataContents.split("\n")) {
    const parsed = safeParseJSON(rawLine.trim());
    if (parsed?.type === "session_meta") {
      populateSessionMetaState(state, parsed.payload);
      break;
    }
  }
  if (!isDesktopRolloutOrigin(state.sessionMeta)) {
    state.isDesktopOrigin = false;
    return;
  }
  state.isDesktopOrigin = true;

  const bootstrapWindow = readCoherentBootstrapWindow({
    rolloutPath,
    fileSize,
    fsModule,
  });
  if (!bootstrapWindow) {
    state.awaitingCoherentBoundary = true;
    return;
  }
  if (!bootstrapWindow.coherent) {
    // The active run starts outside the bounded bootstrap window. Do not emit
    // a plausible-looking tail: canonical history remains the baseline. But do
    // not go dark either — a long busy run would stop mirroring tool activity
    // until its next turn boundary. Attach to the run in place instead, so
    // growth from here on keeps streaming live.
    const attached = attachToActiveRunFromTruncatedTail({
      contents: bootstrapWindow.alignedContents,
      boundary: bootstrapWindow.boundary,
      state,
      rolloutPath,
      fsModule,
      sendApplicationResponse,
      nowMs,
      staleActiveRunMaxAgeMs,
    });
    if (!attached) {
      state.awaitingCoherentBoundary = true;
    }
    return;
  }
  const { tailStart, contents: bootstrapContents } = bootstrapWindow;
  let initialContents = bootstrapContents;
  if (!initialContents) {
    return;
  }
  // The first bytes may be the end of a JSON record. Drop that fragment rather
  // than guessing, because an incomplete task_started record would lose the
  // user opener and recreate the exact tail-only regression we are fixing.
  if (tailStart > 0) {
    const firstNewline = initialContents.indexOf("\n");
    initialContents = firstNewline >= 0 ? initialContents.slice(firstNewline + 1) : "";
  }
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

    const taskEventType = parsed?.type === "event_msg"
      ? readString(parsed?.payload?.type)
      : "";
    const eventUserMessage = taskEventType === "user_message"
      && Boolean(visibleUserPromptFromInputEntries(
        readString(parsed?.payload?.message) || readString(parsed?.payload?.text)
      ));
    const responseUserMessage = parsed?.type === "response_item"
      && readString(parsed?.payload?.role).toLowerCase() === "user"
      && Boolean(
        visibleUserPromptFromInputEntries(extractResponseItemMessageText(parsed?.payload || {}))
        || responseItemHasUserImage(parsed?.payload)
      );
    if (eventUserMessage || responseUserMessage) {
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
    processRolloutLines(activeRunLines, state, () => {});
    // task_started resets per-run state while hydrating. Apply the stale-run
    // suppression afterwards so it survives until real file growth proves the
    // desktop process is alive again.
    state.suppressLiveActivityUntilGrowth = true;
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

// Expands backwards only until the newest active task has its opening user
// message. Every expansion reads just the newly needed prefix, so a 30MB file
// is read at most once rather than once per retry. The hard cap keeps bootstrap
// work/memory bounded; a capped window without a coherent opener comes back
// with `coherent: false` and must never be replayed as history.
function readCoherentBootstrapWindow({ rolloutPath, fileSize, fsModule }) {
  const maxBytes = Math.min(fileSize, DEFAULT_BOOTSTRAP_MAX_BYTES);
  let windowBytes = Math.min(fileSize, DEFAULT_BOOTSTRAP_TAIL_BYTES);
  let tailStart = Math.max(0, fileSize - windowBytes);
  let contents = readFileSlice(rolloutPath, tailStart, fileSize, fsModule);
  if (!contents) {
    return null;
  }

  while (true) {
    const alignedContents = alignedBootstrapContents(contents, tailStart);
    const boundary = inspectBootstrapRunBoundary(alignedContents);
    // When the window already reaches byte zero it is the complete rollout:
    // some legitimate system/continuation turns have no materialized user row.
    // The opener requirement only protects a truncated tail.
    if (!boundary.hasActiveRun || boundary.hasOpeningUser || tailStart === 0) {
      return { tailStart, contents, coherent: true };
    }
    if (windowBytes >= maxBytes || tailStart === 0) {
      return {
        tailStart,
        contents,
        coherent: false,
        alignedContents,
        boundary,
      };
    }

    const nextWindowBytes = Math.min(maxBytes, windowBytes * 2);
    const nextTailStart = Math.max(0, fileSize - nextWindowBytes);
    const prefix = readFileSlice(rolloutPath, nextTailStart, tailStart, fsModule);
    if (!prefix) {
      return null;
    }
    contents = `${prefix}${contents}`;
    windowBytes = nextWindowBytes;
    tailStart = nextTailStart;
  }
}

function alignedBootstrapContents(contents, tailStart) {
  if (tailStart === 0) {
    return contents;
  }
  const firstNewline = contents.indexOf("\n");
  return firstNewline >= 0 ? contents.slice(firstNewline + 1) : "";
}

function inspectBootstrapRunBoundary(contents) {
  let activeTurnId = "";
  let hasOpeningUser = false;
  let hasTurnOutputSinceStart = false;
  let pendingUserBeforeStart = false;
  // A tail can begin after task_started. In that case activity without a
  // closing terminal is evidence of an unknown active boundary, not permission
  // to replay a partial conversation.
  let unboundedActivitySinceTerminal = false;
  // Attach metadata for the incoherent-window case, so the caller never has to
  // re-parse the (up to 64MB) window a second time.
  let newestTaskStartedLineIndex = -1;
  let lastEntryTimestamp = "";

  const lines = contents.split("\n");
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const parsed = safeParseJSON(lines[lineIndex].trim());
    if (!parsed) {
      continue;
    }
    const entryTimestamp = readString(parsed.timestamp);
    if (entryTimestamp) {
      lastEntryTimestamp = entryTimestamp;
    }
    const taskEventType = parsed?.type === "event_msg"
      ? readString(parsed?.payload?.type)
      : "";
    const isUser = taskEventType === "user_message"
      || (parsed?.type === "response_item" && readString(parsed?.payload?.role).toLowerCase() === "user");
    const isResponseUser = parsed?.type === "response_item"
      && readString(parsed?.payload?.role).toLowerCase() === "user";
    const userText = isResponseUser
      ? extractResponseItemMessageText(parsed?.payload || {})
      : firstNonEmptyString([readString(parsed?.payload?.message), readString(parsed?.payload?.text)]);
    const isVisibleUser = isUser && Boolean(
      visibleUserPromptText(userText).trim()
      || (isResponseUser && responseItemHasUserImage(parsed?.payload))
    );
    if (taskEventType === "task_started") {
      activeTurnId = readString(parsed?.payload?.turn_id)
        || readString(parsed?.payload?.turnId)
        || "synthetic-active-turn";
      hasOpeningUser = pendingUserBeforeStart;
      hasTurnOutputSinceStart = false;
      pendingUserBeforeStart = false;
      newestTaskStartedLineIndex = lineIndex;
      continue;
    }
    if (!activeTurnId) {
      const isNeutral = isBootstrapNeutralRecord(parsed, taskEventType)
        || (isUser && !isVisibleUser);
      if (TERMINAL_TASK_EVENT_TYPES.has(taskEventType)) {
        unboundedActivitySinceTerminal = false;
      } else if (!isNeutral) {
        unboundedActivitySinceTerminal = true;
      }
      if (isVisibleUser) {
        pendingUserBeforeStart = true;
      } else if (!isNeutral) {
        pendingUserBeforeStart = false;
      }
      continue;
    }
    // The only user item that can certify a truncated active run is the one
    // adjacent to task_started, before any assistant/tool output. Later user
    // messages are steering/follow-up input and must never turn a partial tail
    // into a valid bootstrap baseline.
    if (isVisibleUser && !hasTurnOutputSinceStart) {
      hasOpeningUser = true;
    }
    if (TERMINAL_TASK_EVENT_TYPES.has(taskEventType)) {
      const terminalTurnId = readString(parsed?.payload?.turn_id)
        || readString(parsed?.payload?.turnId);
      if (terminalEventClosesTrackedTurn(terminalTurnId, activeTurnId)) {
        activeTurnId = "";
        hasOpeningUser = false;
        hasTurnOutputSinceStart = false;
        pendingUserBeforeStart = false;
        unboundedActivitySinceTerminal = false;
      }
    } else if (!isUser && !isBootstrapNeutralRecord(parsed, taskEventType)) {
      hasTurnOutputSinceStart = true;
    }
  }

  return {
    hasActiveRun: Boolean(activeTurnId) || unboundedActivitySinceTerminal,
    hasOpeningUser,
    newestTaskStartedLineIndex,
    lastEntryTimestamp,
  };
}

// These records describe the runtime envelope around a turn. They are neither
// visible assistant output nor tool activity, so they must not turn the first
// real user prompt into a later steer during a bounded bootstrap scan.
function isBootstrapNeutralRecord(entry, taskEventType = "") {
  const entryType = readString(entry?.type).toLowerCase();
  return entryType === "session_meta"
    || entryType === "world_state"
    || entryType === "turn_context"
    || taskEventType === "context_updated";
}

// Attaches mid-run when the active run's opener is beyond the bounded window:
// nothing already in the tail is emitted (it stays canonical-history
// territory), but run state is hydrated so subsequent growth mirrors live.
// Returns false when the tail proves the visible runs all closed — trailing
// bytes then belong to an unknown older boundary and stay suppressed.
function attachToActiveRunFromTruncatedTail({
  contents,
  boundary,
  state,
  rolloutPath,
  fsModule,
  sendApplicationResponse,
  nowMs,
  staleActiveRunMaxAgeMs,
}) {
  const newestTaskStartedIndex = boundary?.newestTaskStartedLineIndex ?? -1;
  if (newestTaskStartedIndex >= 0) {
    // Hydrate through the shared reducer so parallel-turn and terminal
    // semantics stay authoritative for what is still open at EOF.
    processRolloutLines(contents.split("\n").slice(newestTaskStartedIndex), state, () => {});
    if (!state.activeTurnId) {
      return false;
    }
  } else {
    // Mid-turn tail without its task_started: adopt a synthetic turn. The
    // first non-terminal event carrying the real id promotes it, and a
    // mismatched terminal closes it via the synthetic-terminal path.
    state.activeTurnId = buildSyntheticTurnId(state, { timestamp: boundary?.lastEntryTimestamp || "" });
    state.activeTurnIdIsSynthetic = true;
    state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, state.activeTurnId);
  }

  if (isRolloutFileStale(rolloutPath, fsModule, nowMs, staleActiveRunMaxAgeMs)) {
    // Same contract as the stale coherent bootstrap: stay silent until real
    // growth proves the desktop process is alive again.
    state.suppressLiveActivityUntilGrowth = true;
    return true;
  }

  // A hydrated run that already carries a pending synthetic terminal is
  // closing, not running: announcing it as live would just be followed by the
  // tick's synthetic turn/completed one grace period later.
  if (!state.pendingSyntheticTerminalTurnId) {
    sendApplicationResponse(JSON.stringify(createNotification("turn/activity", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      id: state.activeTurnId,
    })));
  }
  return true;
}

// After a bounded bootstrap cannot reach the old opener, consume only new
// bytes. A later real user+task_started boundary safely starts a new live run;
// everything before it remains canonical-history territory.
function processAwaitingCoherentBoundary(lines, state, sendApplicationResponse, nowMs) {
  for (let index = 0; index < lines.length; index += 1) {
    const rawLine = lines[index];
    const line = rawLine.trim();
    const parsed = safeParseJSON(line);
    if (!parsed) continue;
    const eventType = parsed?.type === "event_msg" ? readString(parsed?.payload?.type) : "";
    const responseUser = parsed?.type === "response_item"
      && readString(parsed?.payload?.role).toLowerCase() === "user";
    const visibleUser = eventType === "user_message"
      ? Boolean(visibleUserPromptFromInputEntries(readString(parsed?.payload?.message) || readString(parsed?.payload?.text)))
      : responseUser && Boolean(visibleUserPromptFromInputEntries(extractResponseItemMessageText(parsed?.payload || {})) || responseItemHasUserImage(parsed?.payload));
    if (visibleUser) state.awaitingBoundaryPreludeLine = line;
    if (eventType !== "task_started" || !state.awaitingBoundaryPreludeLine) continue;
    const boundaryLines = [state.awaitingBoundaryPreludeLine, line];
    state.awaitingBoundaryPreludeLine = "";
    resetRunState(state);
    processRolloutLines(boundaryLines, state, sendApplicationResponse, { nowMs });
    // The boundary and its first output frequently land in the same filesystem
    // read. Replay the remainder immediately so recovery never drops that
    // assistant/tool burst while changing modes.
    processRolloutLines(lines.slice(index + 1), state, sendApplicationResponse, { nowMs });
    return true;
  }
  return false;
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

    if (eventType === "thread_goal_updated") {
      const goal = payload.goal && typeof payload.goal === "object" ? payload.goal : null;
      const threadId = readString(payload.threadId) || readString(goal?.threadId) || state.threadId;
      if (!goal || !threadId) {
        return [];
      }
      return [createNotification("thread/goal/updated", {
        threadId,
        turnId: readString(payload.turnId) || readString(payload.turn_id) || null,
        goal,
      })];
    }

    if (eventType === "thread_goal_cleared") {
      const threadId = readString(payload.threadId) || readString(payload.thread_id) || state.threadId;
      return threadId
        ? [createNotification("thread/goal/cleared", { threadId })]
        : [];
    }

    if (eventType === "task_started") {
      notifications.push(...finalizePendingSyntheticTerminal(state));
      const explicitTurnId = readString(payload.turn_id) || readString(payload.turnId);
      const turnId = explicitTurnId || buildSyntheticTurnId(state, entry);
      state.activeTurnId = turnId;
      state.activeTurnIdIsSynthetic = !explicitTurnId;
      state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, turnId);
      state.hasThinking = false;
      state.hasReasoningContent = false;
      state.emittedReasoningSummaryKeys.clear();
      state.commandCalls.clear();
      state.applyPatchCalls.clear();
      state.emittedPatchApplyEndCalls.clear();
      state.wrappedExecCallIdsByOuterId.clear();

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
      notifications.push(...userMessageNotifications(state, entry, payload));
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
    notifications.push(...projectedToolStartNotifications(state, payload));
    return notifications;
  }

  if (itemType === "customtoolcall") {
    notifications.push(...projectedToolStartNotifications(state, payload));
    return notifications;
  }

  if (itemType === "functioncalloutput" || itemType === "customtoolcalloutput") {
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

  const rawText = readString(text);
  if (!rawText) {
    return ensureThinkingNotifications(state);
  }

  const summaryEntries = summaryOnlyReasoningEntries(rawText);
  let visibleText = rawText;
  if (summaryEntries) {
    const unseenEntries = summaryEntries.filter((entry) => {
      if (state.emittedReasoningSummaryKeys.has(entry.key)) {
        return false;
      }
      state.emittedReasoningSummaryKeys.add(entry.key);
      return true;
    });
    if (unseenEntries.length === 0) {
      return [];
    }
    visibleText = unseenEntries
      .map((entry) => `**${entry.title}**\n\n<!-- -->`)
      .join("\n\n");
  }

  state.hasThinking = true;
  const delta = `${state.hasReasoningContent ? "\n\n" : ""}${visibleText}`;
  state.hasReasoningContent = true;
  return [
    createNotification("item/reasoning/textDelta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      itemId: state.reasoningItemId || buildSyntheticItemId("thinking", state.threadId, state.activeTurnId),
      delta,
    }),
  ];
}

// Newer Codex rollouts write the same cumulative reasoning summaries through
// both event_msg and response_item records. Recognize only title/comment-only
// payloads here; detailed reasoning remains a separate opaque stream.
function summaryOnlyReasoningEntries(text) {
  const entries = [];
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || /^<!--.*-->$/.test(line)) {
      continue;
    }
    const match = /^\*\*(.+?)\*\*$/.exec(line);
    if (!match) {
      return null;
    }
    const title = match[1].trim();
    if (!title) {
      return null;
    }
    entries.push({
      title,
      key: title.replace(/\s+/g, " ").toLowerCase(),
    });
  }
  return entries.length > 0 ? entries : null;
}

function responseItemMessageNotifications(state, entry, payload) {
  const role = readString(payload?.role).toLowerCase();
  if (role === "user") {
    return userMessageNotifications(state, entry, payload, {
      rawMessage: extractResponseItemMessageText(payload),
      isResponseItem: true,
    });
  }
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

function userMessageNotifications(state, entry, payload, {
  rawMessage = "",
  isResponseItem = false,
} = {}) {
  const imagePlaceholder = responseItemHasUserImage(payload) ? "Image attachment" : "";
  const message = visibleUserPromptFromInputEntries(
    rawMessage || readString(payload?.message) || readString(payload?.text) || imagePlaceholder
  );
  if (!message) {
    return [];
  }
  const turnId = resolveRolloutEventTurnId(state, payload);
  const itemId = readString(payload?.id) || readString(payload?.itemId) || readString(payload?.item_id);
  const timestamp = readUserMessageTimestamp(entry, payload);
  if (!turnId) {
    // response_item(user) can precede task_started. Hold it exactly like the
    // event_msg form so task_started flushes the opener before thinking/output.
    const pendingKey = `${itemId || ""}:${message}`;
    if (!state.pendingUserMessages.some((pending) => `${pending.id || ""}:${pending.message}` === pendingKey)) {
      state.pendingUserMessages.push({ id: itemId, message, timestamp, isResponseItem });
    }
    return [];
  }

  const dedupeKey = userMessageOccurrenceKey(state, turnId, message, { isResponseItem });
  if (state.emittedUserMessageKeys.has(dedupeKey)) {
    return [];
  }
  state.emittedUserMessageKeys.add(dedupeKey);
  return [createNotification("codex/event/user_message", {
    threadId: state.threadId,
    turnId,
    message,
    ...(itemId ? { id: itemId } : {}),
    ...timestampParams(timestamp),
  })];
}

// Rollouts commonly persist one user message twice as an event_msg and a
// response_item pair, in either order: desktop-started turns log event_msg
// first, phone/app-server-started turns log response_item first. Pair the two
// shapes by occurrence in both directions instead of collapsing every
// identical text in the turn, because repeated steers are legitimate.
function userMessageOccurrenceKey(state, turnId, message, { isResponseItem = false } = {}) {
  const baseKey = buildRemodexSourceItemKey(turnId, message);
  const unpairedMap = isResponseItem
    ? state.pendingEventUserMessageOccurrencesByBaseKey
    : state.pendingResponseItemUserMessageOccurrencesByBaseKey;
  const ownPendingMap = isResponseItem
    ? state.pendingResponseItemUserMessageOccurrencesByBaseKey
    : state.pendingEventUserMessageOccurrencesByBaseKey;

  const unpaired = unpairedMap.get(baseKey) || [];
  if (unpaired.length > 0) {
    const occurrence = unpaired.shift();
    if (unpaired.length === 0) {
      unpairedMap.delete(baseKey);
    } else {
      unpairedMap.set(baseKey, unpaired);
    }
    return `user:${baseKey}:${occurrence}`;
  }

  const occurrence = (state.userMessageOccurrencesByBaseKey.get(baseKey) || 0) + 1;
  state.userMessageOccurrencesByBaseKey.set(baseKey, occurrence);
  const ownPending = ownPendingMap.get(baseKey) || [];
  ownPending.push(occurrence);
  ownPendingMap.set(baseKey, ownPending);
  return `user:${baseKey}:${occurrence}`;
}

function responseItemHasUserImage(payload) {
  return Array.isArray(payload?.content) && payload.content.some((part) => {
    const type = readString(part?.type).toLowerCase();
    return type === "input_image" || type === "image" || type === "image_url";
  });
}

function agentMessageNotifications(state, entry, payload) {
  const message = readString(payload?.message) || readString(payload?.text);
  if (!message) {
    return [];
  }

  const turnId = resolveRolloutEventTurnId(state, payload);
  const baseKey = agentMessageDedupeKey(turnId, message);
  const providerItemId = readString(payload?.itemId);
  const nextOccurrence = (state.agentMessageOccurrencesByBaseKey.get(baseKey) || 0) + 1;
  const occurrence = providerItemId && state.pendingEventAgentMessageOccurrencesByBaseKey.has(baseKey)
    ? state.pendingEventAgentMessageOccurrencesByBaseKey.get(baseKey)
    : nextOccurrence;
  state.agentMessageOccurrencesByBaseKey.set(baseKey, Math.max(nextOccurrence, occurrence));
  if (providerItemId) {
    state.pendingEventAgentMessageOccurrencesByBaseKey.delete(baseKey);
  } else {
    state.pendingEventAgentMessageOccurrencesByBaseKey.set(baseKey, occurrence);
  }
  const dedupeKey = `${baseKey}:${occurrence}`;
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
    itemId: providerItemId || buildAgentMessageItemId(state.threadId, turnId, entry, message),
    // The same assistant item may first arrive as event_msg (without Codex's
    // item id) and later as response_item/history (with one). Preserve a
    // stable source alias across bootstrap/reconnect so the phone can merge
    // those representations without using unsafe global text deduplication.
    ...(occurrence === 1 ? { remodexSourceItemKey: baseKey } : {}),
    message,
  };
  const phase = readString(payload?.phase);
  if (phase) {
    params.phase = phase;
  }

  return [createNotification("codex/event/agent_message", params)];
}

function extractResponseItemMessageText(payload) {
  return responseItemMessageText(payload);
}

function projectedToolStartNotifications(state, payload) {
  if (isOrchestrationWaitCall(payload)) {
    return [];
  }

  const projectedPayloads = expandExecWrapperToolCall(payload);
  const outerCallId = projectedPayloads[0]?.remodexWrappedExecCallId;
  if (outerCallId && projectedPayloads.length > 1) {
    state.wrappedExecCallIdsByOuterId.set(
      outerCallId,
      projectedPayloads.map((projectedPayload) => (
        readString(projectedPayload.call_id) || readString(projectedPayload.callId)
      )).filter(Boolean)
    );
  }

  return projectedPayloads.flatMap((projectedPayload) => (
    normalizeRolloutItemType(projectedPayload.type) === "customtoolcall"
      ? customToolStartNotifications(state, projectedPayload)
      : toolStartNotifications(state, projectedPayload)
  ));
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
    wrappedExecCall: Boolean(payload.remodexWrappedExecCallId),
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
      itemId: callId,
      status: "inProgress",
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

  // Custom tool calls settle through custom_tool_call_output. Without tracking
  // them the activity row never completes, so it lingers between command groups.
  if (!isCommandToolName(toolName) && !state.applyPatchCalls.has(callId)) {
    state.commandCalls.set(callId, {
      toolName,
      command: toolName,
      cwd: readString(state.sessionMeta?.cwd) || "",
      wrappedExecCall: Boolean(payload.remodexWrappedExecCallId),
    });
  }

  return [
    ...notifications,
    createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      ...(!state.applyPatchCalls.has(callId) ? {
        itemId: callId,
        status: "inProgress",
      } : {}),
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

  const wrappedCallIds = state.wrappedExecCallIdsByOuterId.get(callId);
  if (Array.isArray(wrappedCallIds) && wrappedCallIds.length > 0) {
    state.wrappedExecCallIdsByOuterId.delete(callId);
    const outputRecipientId = wrappedCallIds.find((nestedCallId) => (
      isCommandToolName(state.commandCalls.get(nestedCallId)?.toolName)
    )) || wrappedCallIds[0];
    return wrappedCallIds.flatMap((nestedCallId) => toolOutputNotifications(state, {
      ...payload,
      call_id: nestedCallId,
      callId: nestedCallId,
      output: nestedCallId === outputRecipientId ? payload.output : "",
    }));
  }

  const toolCall = state.commandCalls.get(callId);
  if (!toolCall) {
    if (state.applyPatchCalls.has(callId)) {
      return patchApplyEndNotifications(state, {
        ...payload,
        status: readString(payload.status) || "completed",
      });
    }
    return [];
  }

  if (!isCommandToolName(toolCall.toolName)) {
    const notifications = [...ensureThinkingNotifications(state)];
    notifications.push(createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      itemId: callId,
      status: "completed",
      message: genericToolCompletionMessage(toolCall.toolName),
    }));
    state.commandCalls.delete(callId);
    return notifications;
  }

  const rawOutput = extractToolOutputText(payload.output);
  const output = toolCall.wrappedExecCall ? stripExecOutputEnvelope(rawOutput) : rawOutput;
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

function extractToolOutputText(value) {
  if (typeof value === "string") {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(extractToolOutputText).join("");
  }
  if (!value || typeof value !== "object") {
    return "";
  }

  for (const key of ["text", "output_text", "outputText"]) {
    if (typeof value[key] === "string") {
      return value[key];
    }
  }
  for (const key of ["content", "output", "result"]) {
    const text = extractToolOutputText(value[key]);
    if (text) {
      return text;
    }
  }
  return "";
}

function stripExecOutputEnvelope(output) {
  return readString(output).replace(
    /^Script [^\n]*\nWall time [^\n]*\nOutput:\n?/,
    ""
  );
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
    hasReasoningContent: false,
    emittedReasoningSummaryKeys: new Set(),
    commandCalls: new Map(),
    applyPatchCalls: new Map(),
    emittedPatchApplyEndCalls: new Set(),
    wrappedExecCallIdsByOuterId: new Map(),
    emittedAgentMessageKeys: new Set(),
    agentMessageOccurrencesByBaseKey: new Map(),
    pendingEventAgentMessageOccurrencesByBaseKey: new Map(),
    emittedUserMessageKeys: new Set(),
    userMessageOccurrencesByBaseKey: new Map(),
    pendingEventUserMessageOccurrencesByBaseKey: new Map(),
    pendingResponseItemUserMessageOccurrencesByBaseKey: new Map(),
    pendingUserMessages: [],
    pendingSyntheticTerminalTurnId: null,
    pendingSyntheticTerminalStartedAt: 0,
    pendingSyntheticTerminalStatus: "",
    pendingSyntheticTerminalErrorMessage: "",
    activeTurnIdIsSynthetic: false,
    // True after a stale bootstrap: run context is hydrated but nothing is
    // emitted (including heartbeats) until the rollout file grows again.
    suppressLiveActivityUntilGrowth: false,
    awaitingCoherentBoundary: false,
    awaitingBoundaryPreludeLine: "",
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
  const explanation = readString(argumentsObject.explanation);
  if (!hasVisiblePlanUpdate(explanation, plan)) {
    return [];
  }

  const params = {
    threadId: state.threadId,
    turnId: state.activeTurnId,
    plan,
  };
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

// Mirrors the wording of genericToolActivityMessage so the completion line
// supersedes the start line instead of stacking a second row beside it.
function genericToolCompletionMessage(toolName) {
  switch (readString(toolName).toLowerCase()) {
  case "apply_patch":
    return "Applied patch";
  case "write_stdin":
    return "Wrote to terminal";
  case "read_thread_terminal":
    return "Read terminal output";
  default:
    return `Completed ${readString(toolName)}`;
  }
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
    .filter((pending) => {
      const dedupeKey = userMessageOccurrenceKey(state, resolvedTurnId, pending.message, {
        isResponseItem: pending.isResponseItem === true,
      });
      if (state.emittedUserMessageKeys.has(dedupeKey)) {
        return false;
      }
      state.emittedUserMessageKeys.add(dedupeKey);
      return true;
    })
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
  return buildRemodexSourceItemKey(turnId, message);
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
  state.hasReasoningContent = false;
  state.emittedReasoningSummaryKeys.clear();
  state.commandCalls.clear();
  state.applyPatchCalls.clear();
  state.emittedPatchApplyEndCalls.clear();
  state.wrappedExecCallIdsByOuterId.clear();
  state.emittedAgentMessageKeys.clear();
  state.agentMessageOccurrencesByBaseKey.clear();
  state.pendingEventAgentMessageOccurrencesByBaseKey.clear();
  state.emittedUserMessageKeys.clear();
  state.userMessageOccurrencesByBaseKey.clear();
  state.pendingEventUserMessageOccurrencesByBaseKey.clear();
  state.pendingResponseItemUserMessageOccurrencesByBaseKey.clear();
  state.pendingUserMessages.length = 0;
  state.pendingSyntheticTerminalTurnId = null;
  state.pendingSyntheticTerminalStartedAt = 0;
  state.pendingSyntheticTerminalStatus = "";
  state.pendingSyntheticTerminalErrorMessage = "";
  state.activeTurnIdIsSynthetic = false;
  state.suppressLiveActivityUntilGrowth = false;
  state.awaitingCoherentBoundary = false;
  state.awaitingBoundaryPreludeLine = "";
}

function readThreadId(params) {
  return firstNonEmptyString([
    readString(params?.threadId),
    readString(params?.thread_id),
  ]) || "";
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
