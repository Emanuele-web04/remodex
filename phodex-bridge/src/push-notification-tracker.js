// FILE: push-notification-tracker.js
// Purpose: Tracks per-turn titles and failure context so the bridge can emit completion pushes even after the iPhone disconnects.
// Layer: Bridge helper
// Exports: createPushNotificationTracker
// Depends on: ./push-notification-completion-dedupe

const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  createPushNotificationCompletionDedupe,
} = require("./push-notification-completion-dedupe");

const DEFAULT_GOAL_PUSH_STATE_PATH = path.join(os.homedir(), ".remodex", "goal-push-state.json");

const DEFAULT_PREVIEW_MAX_CHARS = 160;
const MAX_THREAD_TITLE_ENTRIES = 200;
const MAX_TURN_STATE_ENTRIES = 500;
const MAX_THREAD_ID_BY_TURN_ENTRIES = 500;
const MAX_GOAL_STATUS_ENTRIES = 500;

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
  goalPushStatePath = DEFAULT_GOAL_PUSH_STATE_PATH,
} = {}) {
  const threadTitleById = new Map();
  const threadIdByTurnId = new Map();
  const turnStateByKey = new Map();
  // Persisted across bridge restarts so goal transitions that happened while the
  // bridge was down still notify on the first post-restart snapshot.
  const goalStatusByThreadId = loadGoalPushState(goalPushStatePath, logPrefix);
  const completionDedupe = createPushNotificationCompletionDedupe({ now });

  // ─── ENTRY POINT ─────────────────────────────────────────────

  function handleOutbound(rawMessage, parsedMessage = null) {
    const message = parseOutboundMessage(rawMessage, parsedMessage);
    if (!message) {
      return;
    }

    if (message.method === "thread/goal/updated") {
      void handleGoalUpdated(message);
      return;
    }

    if (message.method === "thread/goal/cleared") {
      if (message.threadId && goalStatusByThreadId.delete(message.threadId)) {
        saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
      }
      return;
    }

    rememberMessageContext(message);
    clearFallbackSuppressionForNewRun(message);

    if (isAssistantDeltaMethod(message.method)) {
      recordAssistantDelta(message.threadId, message.turnId, message.params, message.eventObject);
      return;
    }

    if (isAssistantCompletedMethod(message.method, message.params, message.eventObject)) {
      recordAssistantCompletion(message.threadId, message.turnId, message.params, message.eventObject);
      return;
    }

    routeTerminalMessage(message);
  }

  // Keeps the top-level handler focused on orchestration while helpers own terminal edge cases.
  function routeTerminalMessage({ method, params, eventObject, threadId, turnId }) {
    if (method === "turn/failed" || isFailureEnvelope(method, eventObject)) {
      if (shouldIgnoreRetriableFailure(params, eventObject)) {
        return;
      }

      recordFailure(threadId, turnId, params, eventObject);
      void notifyCompletion(threadId, turnId, params, eventObject, { forcedResult: "failed" });
      return;
    }

    if (isTerminalThreadStatusMethod(method)) {
      void notifyCompletion(threadId, turnId, params, eventObject, {
        forcedResult: resolveThreadStatusResult(params, eventObject),
      });
      return;
    }

    if (method === "turn/completed") {
      void notifyCompletion(threadId, turnId, params, eventObject);
    }
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
    }
    const isFirstObservation = previousSnapshot == null;
    const isDuplicate = previousSnapshot?.status === nextSnapshot.status
      && previousSnapshot?.updatedAt === nextSnapshot.updatedAt;
    const body = GOAL_PUSH_BODIES.get(status);
    if (isFirstObservation || isDuplicate || !body || !pushServiceClient?.hasConfiguredBaseUrl) {
      if (!isDuplicate) {
        goalStatusByThreadId.set(resolvedThreadId, nextSnapshot);
        saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
      }
      return;
    }

    const title = normalizePreviewText(threadTitleById.get(resolvedThreadId)) || "New Thread";
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
      // Commit the dedupe cursor only after delivery succeeds so a repeated
      // app-server snapshot can retry a transient push outage.
      goalStatusByThreadId.set(resolvedThreadId, nextSnapshot);
      saveGoalPushState(goalPushStatePath, goalStatusByThreadId, logPrefix);
    } catch (error) {
      console.error(`${logPrefix} goal push notify failed: ${error.message}`);
    }
  }

  // Remembers thread/turn linkage before the terminal event arrives on a different payload shape.
  function rememberMessageContext({ threadId, turnId, params, eventObject }) {
    if (threadId && turnId) {
      if (!threadIdByTurnId.has(turnId) && threadIdByTurnId.size >= MAX_THREAD_ID_BY_TURN_ENTRIES) {
        const oldest = threadIdByTurnId.keys().next().value;
        threadIdByTurnId.delete(oldest);
      }
      threadIdByTurnId.set(turnId, threadId);
      ensureTurnState(threadId, turnId);
    }

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

  // A new run on the same thread must not inherit duplicate-suppression from the previous run.
  function clearFallbackSuppressionForNewRun({ method, threadId, params, eventObject }) {
    if (!threadId) {
      return;
    }

    if (method === "turn/started" || isActiveThreadStatus(method, params, eventObject)) {
      completionDedupe.clearForNewRun(threadId);
    }
  }

  // Buckets turnless completions so repeated terminal events dedupe briefly instead of forever.
  async function notifyCompletion(threadId, turnId, params, eventObject, { forcedResult = null } = {}) {
    const resolvedThreadId = threadId || (turnId ? threadIdByTurnId.get(turnId) : null);
    if (!pushServiceClient?.hasConfiguredBaseUrl || !resolvedThreadId) {
      return;
    }

    const result = forcedResult || resolveCompletionResult(params, eventObject);
    if (!result) {
      cleanupTurnState(resolvedThreadId, turnId);
      return;
    }

    if (completionDedupe.shouldSuppressThreadStatusFallback({
      threadId: resolvedThreadId,
      turnId,
      result,
    })) {
      cleanupTurnState(resolvedThreadId, turnId);
      return;
    }

    const dedupeKey = completionDedupeKey({
      sessionId,
      threadId: resolvedThreadId,
      turnId,
      result,
      now,
    });
    if (completionDedupe.hasActiveDedupeKey(dedupeKey)) {
      cleanupTurnState(resolvedThreadId, turnId);
      return;
    }

    const state = getTurnState(resolvedThreadId, turnId);
    const title = normalizePreviewText(threadTitleById.get(resolvedThreadId)) || "New Thread";
    const body = buildNotificationBody({
      result,
      state,
      params,
      eventObject,
      previewMaxChars,
    });

    try {
      completionDedupe.beginNotification({
        dedupeKey,
        threadId: resolvedThreadId,
        turnId,
        result,
      });
      await pushServiceClient.notifyCompletion({
        threadId: resolvedThreadId,
        turnId,
        result,
        title,
        body,
        dedupeKey,
      });
      completionDedupe.commitNotification({
        dedupeKey,
        threadId: resolvedThreadId,
        turnId,
        result,
      });
    } catch (error) {
      completionDedupe.abortNotification({
        dedupeKey,
        threadId: resolvedThreadId,
        turnId,
        result,
      });
      console.error(`${logPrefix} push notify failed: ${error.message}`);
    } finally {
      cleanupTurnState(resolvedThreadId, turnId);
    }
  }

  function recordAssistantDelta(threadId, turnId, params, eventObject) {
    const resolvedTurnId = turnId || resolveTurnId("assistant", params, eventObject);
    const resolvedThreadId = threadId || (resolvedTurnId ? threadIdByTurnId.get(resolvedTurnId) : null);
    if (!resolvedThreadId || !resolvedTurnId) {
      return;
    }

    const delta = extractAssistantDeltaText(params, eventObject);
    if (!delta) {
      return;
    }

    const state = ensureTurnState(resolvedThreadId, resolvedTurnId);
    state.latestAssistantPreview = truncatePreview(`${state.latestAssistantPreview || ""}${delta}`, previewMaxChars);
  }

  function recordAssistantCompletion(threadId, turnId, params, eventObject) {
    const resolvedTurnId = turnId || resolveTurnId("assistant", params, eventObject);
    const resolvedThreadId = threadId || (resolvedTurnId ? threadIdByTurnId.get(resolvedTurnId) : null);
    if (!resolvedThreadId || !resolvedTurnId) {
      return;
    }

    const completedText = extractAssistantCompletedText(params, eventObject);
    if (!completedText) {
      return;
    }

    const state = ensureTurnState(resolvedThreadId, resolvedTurnId);
    state.latestAssistantPreview = truncatePreview(completedText, previewMaxChars);
  }

  function recordFailure(threadId, turnId, params, eventObject) {
    const resolvedTurnId = turnId || resolveTurnId("failure", params, eventObject);
    const resolvedThreadId = threadId || (resolvedTurnId ? threadIdByTurnId.get(resolvedTurnId) : null);
    if (!resolvedThreadId || !resolvedTurnId) {
      return;
    }

    const failureMessage = extractFailureMessage(params, eventObject);
    const state = ensureTurnState(resolvedThreadId, resolvedTurnId);
    if (failureMessage) {
      state.latestFailurePreview = truncatePreview(failureMessage, previewMaxChars);
    }
  }

  function ensureTurnState(threadId, turnId) {
    const key = turnStateKey(threadId, turnId);
    if (!turnStateByKey.has(key)) {
      if (turnStateByKey.size >= MAX_TURN_STATE_ENTRIES) {
        const oldest = turnStateByKey.keys().next().value;
        turnStateByKey.delete(oldest);
      }
      turnStateByKey.set(key, {
        latestAssistantPreview: "",
        latestFailurePreview: "",
      });
    }

    return turnStateByKey.get(key);
  }

  function getTurnState(threadId, turnId) {
    if (!threadId) {
      return null;
    }
    return turnStateByKey.get(turnStateKey(threadId, turnId)) || null;
  }

  function cleanupTurnState(threadId, turnId) {
    if (!threadId) {
      return;
    }

    const resolvedTurnId = turnId || null;
    if (resolvedTurnId) {
      threadIdByTurnId.delete(resolvedTurnId);
    }
    turnStateByKey.delete(turnStateKey(threadId, resolvedTurnId));
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
  const rawStatus = readString(
    params?.turn?.status
      || params?.status
      || eventObject?.turn?.status
      || eventObject?.status
  ) || "completed";

  const normalizedStatus = rawStatus.toLowerCase();
  if (normalizedStatus.includes("fail") || normalizedStatus.includes("error")) {
    return "failed";
  }
  if (normalizedStatus.includes("interrupt") || normalizedStatus.includes("stop")) {
    return null;
  }

  return "completed";
}

function completionDedupeKey({ sessionId, threadId, turnId, result, now }) {
  if (turnId) {
    return [sessionId || "", threadId, turnId, result].join("|");
  }

  const timeBucket = Math.floor(now() / 30_000);
  return [sessionId || "", threadId, "no-turn", result, `bucket-${timeBucket}`].join("|");
}

// Mirrors the iOS terminal-state mapping so managed pushes fire on the same end states.
function resolveThreadStatusResult(params, eventObject) {
  const statusObject = objectValue(params?.status)
    || objectValue(eventObject?.status)
    || objectValue(params?.event?.status);
  const rawStatus = readString(
    statusObject?.type
      || statusObject?.statusType
      || statusObject?.status_type
      || params?.status
      || eventObject?.status
      || params?.event?.status
  );
  const normalizedStatus = normalizeStatusToken(rawStatus);
  if (!normalizedStatus) {
    return null;
  }

  if (
    normalizedStatus.includes("cancel")
    || normalizedStatus.includes("abort")
    || normalizedStatus.includes("interrupt")
    || normalizedStatus.includes("stopped")
  ) {
    return null;
  }

  if (normalizedStatus.includes("fail") || normalizedStatus.includes("error")) {
    return "failed";
  }

  if (
    normalizedStatus === "idle"
    || normalizedStatus === "notloaded"
    || normalizedStatus === "completed"
    || normalizedStatus === "done"
    || normalizedStatus === "finished"
  ) {
    return "completed";
  }

  return null;
}

function isTerminalThreadStatusMethod(method) {
  return method === "thread/status/changed"
    || method === "thread/status"
    || method === "codex/event/thread_status_changed";
}

function isActiveThreadStatus(method, params, eventObject) {
  if (!isTerminalThreadStatusMethod(method)) {
    return false;
  }

  const statusObject = objectValue(params?.status)
    || objectValue(eventObject?.status)
    || objectValue(params?.event?.status);
  const rawStatus = readString(
    statusObject?.type
      || statusObject?.statusType
      || statusObject?.status_type
      || params?.status
      || eventObject?.status
      || params?.event?.status
  );
  const normalizedStatus = normalizeStatusToken(rawStatus);

  return normalizedStatus === "active"
    || normalizedStatus === "running"
    || normalizedStatus === "processing"
    || normalizedStatus === "inprogress"
    || normalizedStatus === "started"
    || normalizedStatus === "pending";
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

function normalizeStatusToken(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[_-\s]+/g, "")
    : "";
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

function turnStateKey(threadId, turnId) {
  return `${threadId}|${turnId || "no-turn"}`;
}

module.exports = {
  createPushNotificationTracker,
};
