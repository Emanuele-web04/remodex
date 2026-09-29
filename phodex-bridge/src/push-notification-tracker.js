// FILE: push-notification-tracker.js
// Purpose: Tracks per-turn titles and failure context so the bridge can emit completion pushes even after the iPhone disconnects.
// Layer: Bridge helper
// Exports: createPushNotificationTracker
// Depends on: ./push-notification-completion-dedupe

const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomUUID } = require("crypto");

const {
  createPushNotificationCompletionDedupe,
} = require("./push-notification-completion-dedupe");

const DEFAULT_GOAL_PUSH_STATE_PATH = path.join(os.homedir(), ".remodex", "goal-push-state.json");

const DEFAULT_PREVIEW_MAX_CHARS = 160;
const MAX_THREAD_TITLE_ENTRIES = 200;
const MAX_LIVE_RUN_ENTRIES = 500;
const MAX_GOAL_STATUS_ENTRIES = 500;
const MAX_COMPLETION_AGE_MS = 5 * 60 * 1000;

// Goal states worth waking the phone for: terminal or needs-user-attention.
const GOAL_PUSH_BODIES = new Map([
  ["complete", "Goal complete"],
  ["blocked", "Goal blocked — Codex needs your input"],
  ["usageLimited", "Goal stopped — usage limit reached"],
  ["budgetLimited", "Goal stopped — token budget reached"],
]);

function createPushNotificationTracker({
  sessionId,
  pushServiceClient,
  previewMaxChars = DEFAULT_PREVIEW_MAX_CHARS,
  logPrefix = "[remodex]",
  now = () => Date.now(),
  completionStatePath,
  goalPushStatePath = DEFAULT_GOAL_PUSH_STATE_PATH,
  readThread,
} = {}) {
  const threadTitleById = new Map();
  const liveRunsByIdentity = new Map();
  const runIdentitiesByThreadId = new Map();
  const runIdentitiesByTurnId = new Map();
  const threadsWithAnonymousCompletions = new Set();
  const historicalTurnKeys = new Set();
  const observedGoalThreadIds = new Set();
  const goalPushInFlightByThreadId = new Map();
  // Persisted status is a baseline, never a reason to wake the phone on restart.
  const goalStatusByThreadId = loadGoalPushState(goalPushStatePath, logPrefix);
  const completionDedupe = createPushNotificationCompletionDedupe({
    statePath: completionStatePath,
    logPrefix,
  });

  // ─── ENTRY POINT ─────────────────────────────────────────────

  function handleOutbound(rawMessage, parsedMessage = null) {
    const message = parseOutboundMessage(rawMessage, parsedMessage);
    if (!message || shouldIgnoreHistoricalMessage(message)) {
      return;
    }
    rememberThreadTitle(message);
    if (message.method === "thread/goal/updated") {
      void handleGoalUpdated(message);
      return;
    }

    if (message.method === "thread/goal/cleared") {
      observedGoalThreadIds.delete(message.threadId);
      if (message.threadId && goalStatusByThreadId.delete(message.threadId)) {
        saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
      }
      return;
    }

    if (message.turnId && historicalTurnKeys.has(completionReceiptKey(message))) return;
    // Delivery can finish before a delayed canonical ID arrives. Never use HTTP
    // timing to decide which of two observed anonymous runs owns that ID.
    const anonymousRun = message.turnId && !findExactLiveRun(message)
      ? uniqueAnonymousRun(message.threadId)
      : null;
    if (anonymousRun?.requiresIdentityConfirmation) {
      const isFailure = message.method === "turn/failed" || isFailureEnvelope(message.method, message.eventObject);
      if (message.method !== "turn/started" && message.method !== "turn/completed" && !isFailure) return;
      if (isFailure && shouldIgnoreRetriableFailure(message.params, message.eventObject)) return;
      if (!anonymousRun.superseded || message.method === "turn/started"
        || anonymousRun.identityConfirmation) {
        void readLatestTurnId(anonymousRun).then((turnId) => {
          if (turnId !== message.turnId
            || liveRunsByIdentity.get(anonymousRun.identity) !== anonymousRun
            || (anonymousRun.turnId && anonymousRun.turnId !== turnId)) return;
          if (findExactLiveRun(message)) {
            handleRunMessage(message);
            return;
          }
          if (anonymousRun.superseded) {
            // A subsequent identified start is independent of the old receipt.
            if (message.method !== "turn/started"
              || uniqueLiveRun(message.threadId) !== anonymousRun) return;
            addLiveRun(createLiveRun(message.threadId, turnId));
          } else {
            promoteRun(anonymousRun, turnId);
          }
          handleRunMessage(message);
        });
      }
      return;
    }
    handleRunMessage(message);
  }

  function handleRunMessage(message) {
    if (message.method === "turn/started") {
      observeRunStart(message);
      return;
    }

    if (isAssistantDeltaMethod(message.method)) {
      recordAssistantDelta(message);
      return;
    }

    if (isAssistantCompletedMethod(message.method, message.params, message.eventObject)) {
      recordAssistantCompletion(message);
      return;
    }

    routeTerminalMessage(message);
  }

  function routeTerminalMessage(message) {
    const { method, params, eventObject } = message;
    if (method === "turn/failed" || isFailureEnvelope(method, eventObject)) {
      if (shouldIgnoreRetriableFailure(params, eventObject)) {
        return;
      }
      const run = findLiveRun(message);
      if (!run) {
        return;
      }
      recordFailure(run, params, eventObject);
      void notifyCompletion(run, "failed", params, eventObject);
      return;
    }

    if (method !== "turn/completed") {
      return;
    }

    const run = findLiveRun(message);
    if (!run) {
      return;
    }
    const result = resolveCompletionResult(params, eventObject);
    if (!result) {
      retireRun(run);
      return;
    }
    if (result === "failed") {
      recordFailure(run, params, eventObject);
    }
    void notifyCompletion(run, result, params, eventObject);
  }

  // Pushes goal lifecycle transitions into terminal/attention states so hours-long
  // background goals still reach the user. Resume snapshots (first observation of a
  // status) never notify; only live status changes do.
  async function handleGoalUpdated({ threadId, params }) {
    const goal = objectValue(params?.goal);
    const status = readString(goal?.status);
    const resolvedThreadId = threadId || readString(goal?.threadId);
    if (!resolvedThreadId || !status) {
      return;
    }

    const previousSnapshot = normalizeGoalPushSnapshot(goalStatusByThreadId.get(resolvedThreadId));
    const nextSnapshot = {
      status,
      updatedAt: goal?.updatedAt ?? goal?.updated_at ?? null,
    };
    if (!goalStatusByThreadId.has(resolvedThreadId) && goalStatusByThreadId.size >= MAX_GOAL_STATUS_ENTRIES) {
      const oldest = goalStatusByThreadId.keys().next().value;
      goalStatusByThreadId.delete(oldest);
      observedGoalThreadIds.delete(oldest);
    }
    const isFirstObservation = !observedGoalThreadIds.has(resolvedThreadId);
    observedGoalThreadIds.add(resolvedThreadId);
    const isDuplicate = previousSnapshot?.status === nextSnapshot.status
      && previousSnapshot?.updatedAt === nextSnapshot.updatedAt;
    const body = GOAL_PUSH_BODIES.get(status);
    if (isFirstObservation || previousSnapshot?.status === status || !body || !pushServiceClient?.hasConfiguredBaseUrl) {
      if (previousSnapshot?.status === status
        && goalPushInFlightByThreadId.get(resolvedThreadId) === goalStatusByThreadId.get(resolvedThreadId)
        && goalPushInFlightByThreadId.has(resolvedThreadId)) {
        return;
      }
      if (!isDuplicate) {
        goalStatusByThreadId.set(resolvedThreadId, nextSnapshot);
        saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
      }
      return;
    }

    const title = normalizePreviewText(threadTitleById.get(resolvedThreadId)) || "New Thread";
    // Reserve the transition while HTTP is pending; timestamp-only updates must
    // not enqueue another notification for the same goal state.
    goalStatusByThreadId.set(resolvedThreadId, nextSnapshot);
    goalPushInFlightByThreadId.set(resolvedThreadId, nextSnapshot);
    // The goal objective intentionally stays out of push payloads and logs.
    try {
      await pushServiceClient.notifyCompletion({
        threadId: resolvedThreadId,
        turnId: null,
        result: status === "complete" ? "completed" : "failed",
        title,
        body,
        // updatedAt keeps repeated legitimate transitions (blocked -> active -> blocked) notifiable.
        dedupeKey: [sessionId || "", resolvedThreadId, "goal", status, goal?.updatedAt ?? ""].join("|"),
      });
      saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
    } catch (error) {
      // Restore eligibility on failure, without overwriting a newer transition.
      if (goalStatusByThreadId.get(resolvedThreadId) === nextSnapshot) {
        goalStatusByThreadId.set(resolvedThreadId, previousSnapshot);
        saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
      }
      console.error(`${logPrefix} goal push notify failed: ${error.message}`);
    } finally {
      if (goalPushInFlightByThreadId.get(resolvedThreadId) === nextSnapshot) {
        goalPushInFlightByThreadId.delete(resolvedThreadId);
      }
    }
  }

  function rememberThreadTitle({ threadId, params, eventObject }) {
    if (!threadId) {
      return;
    }

    const nextTitle = extractThreadTitle(params, eventObject);
    if (nextTitle) {
      if (!threadTitleById.has(threadId) && threadTitleById.size >= MAX_THREAD_TITLE_ENTRIES) {
        const oldest = threadTitleById.keys().next().value;
        threadTitleById.delete(oldest);
      }
      threadTitleById.set(threadId, nextTitle);
    }
  }

  function observeRunStart(message) {
    const { threadId, turnId, params, eventObject } = message;
    if (!threadId || !canStartLiveRun(params, eventObject)) {
      return;
    }

    if (turnId) {
      const existing = findExactLiveRun(message);
      if (existing) {
        return;
      }
      const anonymousRun = uniqueAnonymousRun(threadId);
      if (anonymousRun && uniqueLiveRun(threadId) === anonymousRun) {
        promoteRun(anonymousRun, turnId);
        return;
      }
    } else {
      const anonymousRun = uniqueAnonymousRun(threadId);
      if (anonymousRun && anonymousRun.terminalObservedAt == null) {
        return;
      }
    }

    addLiveRun(createLiveRun(threadId, turnId));
  }

  async function notifyCompletion(run, result, params, eventObject) {
    run.terminalObservedAt ??= now();
    if (!run.turnId) {
      threadsWithAnonymousCompletions.delete(run.threadId);
      threadsWithAnonymousCompletions.add(run.threadId);
      while (threadsWithAnonymousCompletions.size > MAX_LIVE_RUN_ENTRIES) {
        threadsWithAnonymousCompletions.delete(threadsWithAnonymousCompletions.values().next().value);
      }
    }
    const completedAt = readCompletionTimestamp(params, eventObject);
    if (now() - run.terminalObservedAt > MAX_COMPLETION_AGE_MS
      || (completedAt !== null && Math.abs(now() - completedAt) > MAX_COMPLETION_AGE_MS)) {
      retireRun(run);
      return;
    }
    if (!pushServiceClient?.hasConfiguredBaseUrl) {
      retireRun(run);
      return;
    }

    // Canonical IDs can arrive while a send is awaiting HTTP. Freeze its delivery
    // identity so promotion cannot start a second request for the same run.
    const receiptKey = run.notificationReceiptKey ?? completionReceiptKey(run);
    run.notificationReceiptKey = receiptKey;
    if (completionDedupe.hasSuccessfulNotification(receiptKey)) {
      retireRun(run);
      return;
    }
    if (!completionDedupe.beginNotification(receiptKey)) {
      return;
    }

    const title = normalizePreviewText(threadTitleById.get(run.threadId)) || "New Thread";
    const body = buildNotificationBody({
      result,
      state: run,
      params,
      eventObject,
      previewMaxChars,
    });

    try {
      const delivery = await pushServiceClient.notifyCompletion({
        threadId: run.threadId,
        turnId: run.turnId,
        result,
        title,
        body,
        // Relay delivery stays session-scoped; the local receipt must survive
        // resolveBridgeRelaySession rotating that session on every launch.
        dedupeKey: JSON.stringify([sessionId || "", receiptKey]),
      });
      if (delivery?.ok !== true) {
        throw new Error("Push service did not accept the completion notification.");
      }
      completionDedupe.commitNotification(receiptKey);
      const canonicalKey = completionReceiptKey(run);
      if (canonicalKey !== receiptKey) {
        completionDedupe.commitNotification(canonicalKey);
      }
      retireRun(run);
    } catch (error) {
      completionDedupe.abortNotification(receiptKey);
      console.error(`${logPrefix} push notify failed: ${error.message}`);
    }
  }

  function recordAssistantDelta(message) {
    const run = findLiveRun(message);
    if (!run) {
      return;
    }

    const delta = extractAssistantDeltaText(message.params, message.eventObject);
    if (!delta) {
      return;
    }
    run.latestAssistantPreview = truncatePreview(
      `${run.latestAssistantPreview}${delta}`,
      previewMaxChars
    );
  }

  function recordAssistantCompletion(message) {
    const run = findLiveRun(message);
    if (!run) {
      return;
    }

    const completedText = extractAssistantCompletedText(message.params, message.eventObject);
    if (!completedText) {
      return;
    }
    run.latestAssistantPreview = truncatePreview(completedText, previewMaxChars);
  }

  function recordFailure(run, params, eventObject) {
    const failureMessage = extractFailureMessage(params, eventObject);
    if (failureMessage) {
      run.latestFailurePreview = truncatePreview(failureMessage, previewMaxChars);
    }
  }

  function createLiveRun(threadId, turnId) {
    return {
      identity: randomUUID(),
      threadId,
      turnId: turnId || null,
      latestAssistantPreview: "",
      latestFailurePreview: "",
    };
  }

  function addLiveRun(run) {
    while (liveRunsByIdentity.size >= MAX_LIVE_RUN_ENTRIES) {
      retireRun(liveRunsByIdentity.values().next().value);
    }
    const previousAnonymousRuns = runsForThread(run.threadId)
      .filter((previous) => !previous.turnId && previous.terminalObservedAt != null);
    run.requiresIdentityConfirmation = !run.turnId
      && threadsWithAnonymousCompletions.has(run.threadId);
    for (const previous of previousAnonymousRuns) {
      previous.requiresIdentityConfirmation = true;
      previous.superseded = true;
    }
    liveRunsByIdentity.set(run.identity, run);
    addIndexEntry(runIdentitiesByThreadId, run.threadId, run.identity);
    addIndexEntry(runIdentitiesByTurnId, run.turnId, run.identity);
  }

  function promoteRun(run, turnId) {
    if (!run || run.turnId || !turnId) {
      return run;
    }
    run.turnId = turnId;
    addIndexEntry(runIdentitiesByTurnId, turnId, run.identity);
    return run;
  }

  function readLatestTurnId(run) {
    if (run.identityConfirmation) return run.identityConfirmation;
    if (!pushServiceClient?.hasConfiguredBaseUrl || typeof readThread !== "function") {
      return Promise.resolve(null);
    }
    const confirmation = (async () => {
      try {
        const snapshot = await readThread(run.threadId);
        const thread = snapshot?.thread;
        if (thread?.id !== run.threadId || !Array.isArray(thread.turns)) return null;
        // Remember authoritative terminal history so a later re-announcement
        // cannot re-arm an older anonymous completion after the new run ends.
        for (const turn of thread.turns.slice(-MAX_LIVE_RUN_ENTRIES, -1)) {
          const turnId = readString(turn?.id);
          if (!turnId || canStartLiveRun({ turn })
            || findExactLiveRun({ threadId: run.threadId, turnId })) continue;
          const key = completionReceiptKey({ threadId: run.threadId, turnId });
          historicalTurnKeys.delete(key);
          historicalTurnKeys.add(key);
        }
        while (historicalTurnKeys.size > MAX_LIVE_RUN_ENTRIES) {
          historicalTurnKeys.delete(historicalTurnKeys.values().next().value);
        }
        // thread/read returns turns oldest first. Only the newest turn can
        // identify the latest observed run; older IDs remain historical.
        const latestTurn = thread.turns.at(-1);
        return readString(latestTurn?.id) || null;
      } catch {
        // A later live event can retry the read. Unavailable history is not
        // evidence that an unmatched terminal belongs to the current run.
        return null;
      }
    })();
    run.identityConfirmation = confirmation;
    void confirmation.finally(() => {
      if (run.identityConfirmation === confirmation) run.identityConfirmation = null;
    });
    return confirmation;
  }

  function findLiveRun(message) {
    const { threadId, turnId } = message;
    const exactRun = findExactLiveRun(message);
    if (exactRun) {
      return exactRun;
    }
    if (!threadId) {
      return null;
    }
    if (turnId) {
      const anonymousRun = uniqueAnonymousRun(threadId);
      return uniqueLiveRun(threadId) === anonymousRun
        ? promoteRun(anonymousRun, turnId)
        : null;
    }
    return uniqueLiveRun(threadId);
  }

  function findExactLiveRun({ threadId, turnId }) {
    return findIndexedRun(runIdentitiesByTurnId, turnId, threadId);
  }

  function findIndexedRun(index, value, threadId = null) {
    const identities = value ? index.get(value) : null;
    if (!identities) {
      return null;
    }
    const matches = [...identities]
      .map((identity) => liveRunsByIdentity.get(identity))
      .filter((run) => run && (!threadId || run.threadId === threadId));
    return matches.length === 1 ? matches[0] : null;
  }

  function uniqueLiveRun(threadId) {
    const runs = runsForThreadLookup(threadId);
    return runs.length === 1 ? runs[0] : null;
  }

  function uniqueAnonymousRun(threadId) {
    const anonymousRuns = runsForThreadLookup(threadId).filter((run) => !run.turnId);
    return anonymousRuns.length === 1 ? anonymousRuns[0] : null;
  }

  function runsForThreadLookup(threadId) {
    const runs = runsForThread(threadId);
    const activeRuns = runs.filter((run) => run.terminalObservedAt == null);
    return activeRuns.length > 0 ? activeRuns : runs;
  }

  function runsForThread(threadId) {
    const identities = runIdentitiesByThreadId.get(threadId) || [];
    return [...identities]
      .map((identity) => liveRunsByIdentity.get(identity))
      .filter(Boolean);
  }

  function retireRun(run) {
    if (!run || !liveRunsByIdentity.delete(run.identity)) {
      return;
    }
    removeIndexEntry(runIdentitiesByThreadId, run.threadId, run.identity);
    removeIndexEntry(runIdentitiesByTurnId, run.turnId, run.identity);
  }

  function addIndexEntry(index, key, identity) {
    if (!key) {
      return;
    }
    const identities = index.get(key) || new Set();
    identities.add(identity);
    index.set(key, identities);
  }

  function removeIndexEntry(index, key, identity) {
    const identities = key ? index.get(key) : null;
    if (!identities) {
      return;
    }
    identities.delete(identity);
    if (identities.size === 0) {
      index.delete(key);
    }
  }

  return {
    handleOutbound,
  };
}

// Best-effort disk persistence for goal statuses; failures must never break the bridge.
function loadGoalPushState(filePath, logPrefix) {
  if (!filePath) {
    return new Map();
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return new Map();
    }
    const entries = Object.entries(parsed)
      .map(([threadId, snapshot]) => [threadId, normalizeGoalPushSnapshot(snapshot)])
      .filter(([threadId, snapshot]) => typeof threadId === "string" && snapshot != null)
      .slice(-MAX_GOAL_STATUS_ENTRIES);
    return new Map(entries);
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.error(`${logPrefix} failed to load goal push state: ${error.message}`);
    }
    return new Map();
  }
}

function normalizeGoalPushSnapshot(value) {
  if (typeof value === "string") {
    return { status: value, updatedAt: null };
  }
  if (!value || typeof value !== "object" || typeof value.status !== "string") {
    return null;
  }
  return {
    status: value.status,
    updatedAt: value.updatedAt ?? null,
  };
}

function saveGoalPushState(filePath, goalStatusByThreadId, logPrefix) {
  if (!filePath) {
    return;
  }

  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(Object.fromEntries(goalStatusByThreadId)));
  } catch (error) {
    console.error(`${logPrefix} failed to save goal push state: ${error.message}`);
  }
}

// Normalizes the message envelope once so downstream helpers can share the same parsed view.
function parseOutboundMessage(rawMessage, parsedMessage = null) {
  const parsed = parsedMessage ?? safeParseJSON(rawMessage);
  if (!parsed || typeof parsed.method !== "string") {
    return null;
  }

  const method = parsed.method.trim();
  const params = objectValue(parsed.params) || {};
  const eventObject = envelopeEventObject(params);

  return {
    method,
    params,
    eventObject,
    threadId: resolveThreadId(method, params, eventObject),
    turnId: resolveTurnId(method, params, eventObject),
  };
}

function shouldIgnoreHistoricalMessage({ method, params, eventObject }) {
  if (hasTrueFlag(params, eventObject, "remodexReplayedEvent")) {
    return true;
  }
  if (hasTrueFlag(params, eventObject, "remodexRolloutTerminalCatchUp")) {
    return true;
  }
  return hasTrueFlag(params, eventObject, "remodexRolloutBootstrapReplay")
    && method !== "turn/started";
}

function hasTrueFlag(params, eventObject, key) {
  return parseBooleanFlag(params?.[key]) === true
    || parseBooleanFlag(eventObject?.[key]) === true
    || parseBooleanFlag(params?.event?.[key]) === true;
}

function envelopeEventObject(params) {
  if (params?.event && typeof params.event === "object") {
    return params.event;
  }
  if (params?.msg && typeof params.msg === "object") {
    return params.msg;
  }
  return null;
}

function resolveThreadId(method, params, eventObject) {
  const candidates = [
    params?.threadId,
    params?.thread_id,
    params?.conversationId,
    params?.conversation_id,
    params?.thread?.id,
    params?.thread?.threadId,
    params?.thread?.thread_id,
    params?.turn?.threadId,
    params?.turn?.thread_id,
    eventObject?.threadId,
    eventObject?.thread_id,
    eventObject?.conversationId,
    eventObject?.conversation_id,
  ];

  for (const candidate of candidates) {
    const value = readString(candidate);
    if (value) {
      return value;
    }
  }

  const turnId = resolveTurnId(method, params, eventObject);
  if (turnId) {
    return null;
  }

  return null;
}

function resolveTurnId(_method, params, eventObject) {
  const itemObject = incomingItemObject(params, eventObject);
  const candidates = [
    params?.turnId,
    params?.turn_id,
    params?.id,
    params?.turn?.id,
    params?.turn?.turnId,
    params?.turn?.turn_id,
    eventObject?.id,
    eventObject?.turnId,
    eventObject?.turn_id,
    itemObject?.turnId,
    itemObject?.turn_id,
  ];

  for (const candidate of candidates) {
    const value = readString(candidate);
    if (value) {
      return value;
    }
  }

  return null;
}

function incomingItemObject(params, eventObject) {
  if (params?.item && typeof params.item === "object") {
    return params.item;
  }
  if (eventObject?.item && typeof eventObject.item === "object") {
    return eventObject.item;
  }
  if (eventObject && typeof eventObject === "object" && typeof eventObject.type === "string") {
    return eventObject;
  }
  return null;
}

function extractThreadTitle(params, eventObject) {
  const threadObject = (params?.thread && typeof params.thread === "object") ? params.thread : null;
  const candidates = [
    params?.threadName,
    params?.thread_name,
    params?.name,
    params?.title,
    threadObject?.name,
    threadObject?.title,
    eventObject?.threadName,
    eventObject?.thread_name,
    eventObject?.name,
    eventObject?.title,
  ];

  for (const candidate of candidates) {
    const value = normalizePreviewText(candidate);
    if (value) {
      return value;
    }
  }

  return null;
}

function isAssistantDeltaMethod(method) {
  return method === "item/agentMessage/delta"
    || method === "codex/event/agent_message_content_delta"
    || method === "codex/event/agent_message_delta";
}

function isAssistantCompletedMethod(method, params, eventObject) {
  if (method === "codex/event/agent_message") {
    return true;
  }

  if (method !== "item/completed" && method !== "codex/event/item_completed") {
    return false;
  }

  return isAssistantMessageItem(incomingItemObject(params, eventObject));
}

function isFailureEnvelope(method, eventObject) {
  if (method === "error" || method === "codex/event/error") {
    return true;
  }

  return readString(eventObject?.type) === "error";
}

function extractAssistantDeltaText(params, eventObject) {
  const candidates = [
    params?.delta,
    params?.textDelta,
    params?.text_delta,
    eventObject?.delta,
    eventObject?.text,
    params?.event?.delta,
    params?.event?.text,
  ];

  for (const candidate of candidates) {
    const value = readString(candidate);
    if (value) {
      return value;
    }
  }

  return "";
}

function extractAssistantCompletedText(params, eventObject) {
  const itemObject = incomingItemObject(params, eventObject);
  const candidates = [
    itemObject?.message,
    itemObject?.text,
    itemObject?.summary,
    params?.message,
    eventObject?.message,
    eventObject?.text,
  ];

  for (const candidate of candidates) {
    const value = normalizePreviewText(candidate);
    if (value) {
      return value;
    }
  }

  return "";
}

function extractFailureMessage(params, eventObject) {
  const candidates = [
    params?.message,
    params?.error?.message,
    params?.turn?.error?.message,
    eventObject?.message,
    eventObject?.error?.message,
    eventObject?.turn?.error?.message,
  ];

  for (const candidate of candidates) {
    const value = normalizePreviewText(candidate);
    if (value) {
      return value;
    }
  }

  return "";
}

function resolveCompletionResult(params, eventObject) {
  const rawStatus = readTurnStatus(params, eventObject);
  if (!rawStatus) {
    return extractFailureMessage(params, eventObject) ? "failed" : "completed";
  }

  const normalizedStatus = normalizeToken(rawStatus);
  if (normalizedStatus.includes("fail") || normalizedStatus.includes("error")) {
    return "failed";
  }
  if (["completed", "complete", "done", "finished", "succeeded", "success"].includes(
    normalizedStatus
  )) {
    return "completed";
  }
  return null;
}

function canStartLiveRun(params, eventObject) {
  const status = normalizeToken(readTurnStatus(params, eventObject));
  return !status || ![
    "completed",
    "complete",
    "done",
    "finished",
    "succeeded",
    "success",
    "failed",
    "failure",
    "error",
    "stopped",
    "interrupted",
    "cancelled",
    "canceled",
    "aborted",
  ].includes(status);
}

function readTurnStatus(params, eventObject) {
  const statusObject = objectValue(params?.status)
    || objectValue(eventObject?.status)
    || objectValue(params?.event?.status);
  return readString(
    params?.turn?.status
      || eventObject?.turn?.status
      || statusObject?.type
      || statusObject?.statusType
      || statusObject?.status_type
      || params?.status
      || eventObject?.status
      || params?.event?.status
  );
}

function completionReceiptKey(run) {
  const stableTurnIdentity = run.turnId
    ? `turn:${run.turnId}`
    : `generated:${run.identity}`;
  return JSON.stringify([run.threadId, stableTurnIdentity]);
}

function readCompletionTimestamp(params, eventObject) {
  const sources = [params?.turn, params, eventObject?.turn, eventObject];
  for (const source of sources) {
    for (const key of ["completedAt", "completed_at", "completedAtMs", "completed_at_ms"]) {
      const value = source?.[key];
      if (value == null || value === "") continue;
      if (typeof value !== "number" && typeof value !== "string") continue;
      const numeric = Number(value);
      if (Number.isFinite(numeric)) {
        return numeric > 10_000_000_000 ? numeric : numeric * 1000;
      }
      const parsed = Date.parse(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return null;
}

function shouldIgnoreRetriableFailure(params, eventObject) {
  const retryCandidates = [
    params?.willRetry,
    params?.will_retry,
    eventObject?.willRetry,
    eventObject?.will_retry,
    params?.event?.willRetry,
    params?.event?.will_retry,
  ];

  return retryCandidates.some((candidate) => parseBooleanFlag(candidate) === true);
}

function buildNotificationBody({ result, state, params, eventObject, previewMaxChars }) {
  if (result === "failed") {
    return truncatePreview(
      state?.latestFailurePreview
        || extractFailureMessage(params, eventObject)
        || "Run failed",
      previewMaxChars
    ) || "Run failed";
  }

  return "Response ready";
}

function truncatePreview(value, limit) {
  const normalized = normalizePreviewText(value);
  if (!normalized) {
    return "";
  }

  if (normalized.length <= limit) {
    return normalized;
  }

  return `${normalized.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

function normalizePreviewText(value) {
  if (typeof value !== "string") {
    return "";
  }

  return value.replace(/\s+/g, " ").trim();
}

function objectValue(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function parseBooleanFlag(value) {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    const normalizedValue = value.trim().toLowerCase();
    if (normalizedValue === "true" || normalizedValue === "1") {
      return true;
    }
    if (normalizedValue === "false" || normalizedValue === "0") {
      return false;
    }
  }
  return null;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function isAssistantMessageItem(itemObject) {
  if (!itemObject || typeof itemObject !== "object") {
    return false;
  }

  const normalizedType = normalizeToken(itemObject.type);
  const normalizedRole = normalizeToken(itemObject.role);
  return normalizedType === "agentmessage"
    || normalizedType === "assistantmessage"
    || normalizedRole === "assistant";
}

function normalizeToken(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[_-\s]+/g, "")
    : "";
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

module.exports = {
  createPushNotificationTracker,
};
