// FILE: thread-activity-projector.js
// Purpose: Reduces observed Codex and Desktop state to bounded Activity metadata.
// Layer: CLI helper
// Exports: createThreadActivityProjector, projectDesktopThreadActivity
// Depends on: ./desktop-ipc-shared

const { normalizeToken, readString } = require("./desktop-ipc-shared");

const APP_SERVER_SOURCE = "app-server";
const DESKTOP_IPC_SOURCE = "desktop-ipc";
const APP_SERVER_GENERATION = 1;
const MAX_APP_SERVER_THREADS = 500;
const MAX_TERMINAL_TURN_IDS = 64;
const MAX_DISPLAY_TEXT_CHARS = 160;

const APPROVAL_METHODS = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/fileRead/requestApproval",
  "item/permissions/requestApproval",
]);
const USER_INPUT_METHODS = new Set([
  "item/tool/requestUserInput",
  "tool/requestUserInput",
  "mcpServer/elicitation/request",
]);
const REMOVAL_METHODS = new Set([
  "thread/archived",
  "thread/deleted",
]);

function createThreadActivityProjector({ maxAppThreads = MAX_APP_SERVER_THREADS } = {}) {
  const appStatesByThreadId = new Map();

  function observeAppServer(message) {
    const method = readString(message?.method);
    const threadId = appServerThreadId(message);
    if (!method || !threadId) {
      return null;
    }
    if (REMOVAL_METHODS.has(method)) {
      appStatesByThreadId.delete(threadId);
      return { removedThreadId: threadId, source: APP_SERVER_SOURCE };
    }

    const state = appStatesByThreadId.get(threadId) || createAppServerState(threadId);
    if (!reduceAppServerMessage(state, message)) {
      return null;
    }
    rememberAppServerState(appStatesByThreadId, state, maxAppThreads);
    return { entry: projectAppServerState(state) };
  }

  function forget(threadId, source) {
    if (source === APP_SERVER_SOURCE) {
      appStatesByThreadId.delete(threadId);
    }
  }

  return {
    forget,
    observeAppServer,
    projectDesktopState(threadId, state, sourceGeneration) {
      return projectDesktopThreadActivity(threadId, state, sourceGeneration);
    },
  };
}

function createAppServerState(threadId) {
  return {
    threadId,
    title: "",
    cwd: "",
    runtimeStatus: "unknown",
    activeFlags: [],
    freshness: "current",
    activeTurnIds: new Set(),
    runningWithoutTurnId: false,
    approvalRequestIds: new Map(),
    userInputRequestIds: new Map(),
    terminalTurnIds: new Set(),
    settledTurnlessWork: false,
    turnOrderById: new Map(),
    turnStartedAtMsById: new Map(),
    fallbackStartedAtMs: null,
    nextTurnOrder: 1,
    lastOutcomeOrder: 0,
    lastOutcome: null,
    latestItem: null,
  };
}

function reduceAppServerMessage(state, message) {
  const method = readString(message.method);
  if (APPROVAL_METHODS.has(method)) {
    return rememberRequest(state, state.approvalRequestIds, message);
  }
  if (USER_INPUT_METHODS.has(method)) {
    return rememberRequest(state, state.userInputRequestIds, message);
  }

  switch (method) {
    case "thread/started":
      return reduceThreadStarted(state, message.params?.thread);
    case "thread/name/updated":
      return replaceTitle(state, message.params);
    case "thread/status/changed":
      return replaceAppServerRuntime(state, message.params?.status);
    case "thread/closed":
      state.freshness = "stale";
      return true;
    case "turn/started":
      return reduceTurnStarted(state, message.params || {});
    case "turn/completed":
      return reduceTurnCompleted(state, message.params || {});
    case "item/started":
    case "item/completed":
      return reduceItemLifecycle(state, message.params || {}, method);
    case "serverRequest/resolved":
      return resolveRequest(state, message.params || {});
    default:
      return false;
  }
}

function reduceThreadStarted(state, thread) {
  if (!thread || typeof thread !== "object") {
    return false;
  }
  let changed = replaceString(state, "title", thread.name || thread.title || thread.preview);
  changed = replaceString(state, "cwd", thread.cwd) || changed;
  changed = replaceAppServerRuntime(state, thread.status) || changed;
  return changed;
}

function replaceTitle(state, params) {
  return replaceString(
    state,
    "title",
    params?.threadName || params?.thread_name || params?.name || params?.title
  );
}

function replaceAppServerRuntime(state, status) {
  const nextRuntime = normalizeRuntime(status);
  if (nextRuntime === "active"
      && hasKnownTerminalWork(state)
      && !hasRunningWork(state)) {
    return false;
  }
  const flags = runtimeActiveFlags(status);
  const changed = state.runtimeStatus !== nextRuntime
    || !sameJSON(state.activeFlags, flags) || state.freshness !== "current";
  state.runtimeStatus = nextRuntime;
  state.activeFlags = flags;
  state.freshness = "current";
  if (nextRuntime === "active" && !hasRunningWork(state)) {
    state.runningWithoutTurnId = true;
    return true;
  }
  return changed;
}

function reduceTurnStarted(state, params) {
  const turn = params.turn && typeof params.turn === "object" ? params.turn : {};
  const turnId = turnIdentity(params, turn);
  if (turnId && state.terminalTurnIds.has(turnId)) {
    return false;
  }

  let changed = false;
  const startedAtMs = timestampSecondsToMs(turn.startedAt ?? turn.started_at);
  if (!hasRunningWork(state)) {
    state.latestItem = null;
  }
  state.freshness = "current";
  if (turnId) {
    if (!state.activeTurnIds.has(turnId)) {
      state.activeTurnIds.add(turnId);
      state.turnOrderById.set(turnId, state.nextTurnOrder);
      state.nextTurnOrder += 1;
      changed = true;
    }
    const canonicalStart = startedAtMs ?? state.fallbackStartedAtMs;
    if (canonicalStart != null && state.turnStartedAtMsById.get(turnId) !== canonicalStart) {
      state.turnStartedAtMsById.set(turnId, canonicalStart);
      changed = true;
    }
    if (state.runningWithoutTurnId) {
      state.runningWithoutTurnId = false;
      state.fallbackStartedAtMs = null;
      changed = true;
    }
  } else if (!state.runningWithoutTurnId) {
    state.runningWithoutTurnId = true;
    changed = true;
  }
  if (!turnId && startedAtMs != null && state.fallbackStartedAtMs !== startedAtMs) {
    state.fallbackStartedAtMs = startedAtMs;
    changed = true;
  }
  if (state.runtimeStatus !== "active") {
    state.runtimeStatus = "active";
    changed = true;
  }
  return changed;
}

function reduceTurnCompleted(state, params) {
  const turn = params.turn && typeof params.turn === "object" ? params.turn : {};
  const turnId = turnIdentity(params, turn);
  if (turnId && state.terminalTurnIds.has(turnId)) {
    return false;
  }
  if (turnId && !state.activeTurnIds.has(turnId) && state.activeTurnIds.size > 0) {
    rememberTerminalTurn(state, turnId);
    return false;
  }
  if (!turnId && !state.runningWithoutTurnId && hasKnownTerminalWork(state)) {
    return false;
  }

  const startedAtMs = state.turnStartedAtMsById.get(turnId) ?? state.fallbackStartedAtMs;
  let changed = settleTurnRuntime(state, turnId);
  changed = settleRequests(state, turnId) || changed;
  state.freshness = "current";
  if (!turnId) {
    state.settledTurnlessWork = true;
    return changed;
  }
  const order = state.turnOrderById.get(turnId) || state.nextTurnOrder++;
  state.turnOrderById.set(turnId, order);
  rememberTerminalTurn(state, turnId);
  if (order < state.lastOutcomeOrder) {
    return changed;
  }
  const nextOutcome = projectTurnOutcome(turnId, turn, params, startedAtMs);
  if (!sameJSON(state.lastOutcome, nextOutcome)) {
    state.lastOutcome = nextOutcome;
    state.lastOutcomeOrder = order;
    changed = true;
  }
  return changed;
}

function settleTurnRuntime(state, turnId) {
  let changed = false;
  if (turnId && state.activeTurnIds.delete(turnId)) {
    changed = true;
  }
  if (state.runningWithoutTurnId && (!turnId || state.activeTurnIds.size === 0)) {
    state.runningWithoutTurnId = false;
    state.fallbackStartedAtMs = null;
    changed = true;
  }
  if (!hasRunningWork(state) && state.runtimeStatus === "active") {
    state.runtimeStatus = "idle";
    changed = true;
  }
  if (!hasRunningWork(state)) {
    state.activeFlags = [];
  }
  return changed;
}

function settleRequests(state, turnId) {
  let changed = false;
  for (const requests of [state.approvalRequestIds, state.userInputRequestIds]) {
    for (const [requestId, requestTurnId] of requests) {
      if ((turnId && requestTurnId === turnId) || !hasRunningWork(state)) {
        requests.delete(requestId);
        changed = true;
      }
    }
  }
  return changed;
}

function reduceItemLifecycle(state, params, method) {
  const item = params.item && typeof params.item === "object" ? params.item : {};
  const turnId = readString(params.turnId) || readString(params.turn_id);
  if (turnId && state.terminalTurnIds.has(turnId)) {
    return false;
  }
  if (!turnId && hasKnownTerminalWork(state) && !hasRunningWork(state)) {
    return false;
  }
  let nextItem = projectSemanticItem(item, {
    turnId,
    lifecycleAtMs: method === "item/started"
      ? finiteNumber(params.startedAtMs ?? params.started_at_ms)
      : finiteNumber(params.completedAtMs ?? params.completed_at_ms),
    lifecycle: method === "item/started" ? "started" : "completed",
  });
  if (method === "item/completed" && state.latestItem && nextItem) {
    if (state.latestItem.itemId !== nextItem.itemId || state.latestItem.turnId !== nextItem.turnId) {
      return false;
    }
    nextItem = { ...state.latestItem, ...nextItem };
  }
  if (!nextItem || sameJSON(state.latestItem, nextItem)) {
    return false;
  }
  state.latestItem = nextItem;
  return true;
}

function rememberRequest(state, requestIds, message) {
  if (message.id == null || requestIds.has(message.id)) {
    return false;
  }
  const turnId = turnIdentity(message.params, message.params?.turn);
  if ((turnId && state.terminalTurnIds.has(turnId))
      || (!turnId && hasKnownTerminalWork(state) && !hasRunningWork(state))) {
    return false;
  }
  requestIds.set(message.id, turnId);
  return true;
}

function resolveRequest(state, params) {
  const requestId = params.requestId ?? params.request_id;
  if (requestId == null) {
    return false;
  }
  const removedApproval = state.approvalRequestIds.delete(requestId);
  const removedUserInput = state.userInputRequestIds.delete(requestId);
  return removedApproval || removedUserInput;
}

function projectAppServerState(state) {
  return compactEntry({
    threadId: state.threadId,
    source: APP_SERVER_SOURCE,
    title: state.title,
    cwd: state.cwd,
    runtime: runtimeForAppServerState(state),
    activeTurnIds: [...state.activeTurnIds],
    runningWithoutTurnId: state.runningWithoutTurnId,
    activeTurns: [...state.activeTurnIds].map((turnId) => compactObject({
      turnId,
      startedAtMs: state.turnStartedAtMsById.get(turnId),
    })),
    runningStartedAtMs: state.runningWithoutTurnId ? state.fallbackStartedAtMs : null,
    ...attentionFields(state.approvalRequestIds.size, state.userInputRequestIds.size, state.activeFlags),
    lastOutcome: state.lastOutcome,
    latestItem: state.latestItem,
    freshness: state.freshness,
    sourceGeneration: APP_SERVER_GENERATION,
  });
}

function projectDesktopThreadActivity(threadId, state, sourceGeneration) {
  const rawState = state && typeof state === "object" ? state : {};
  const turns = Array.isArray(rawState.turns) ? rawState.turns : [];
  const requests = Array.isArray(rawState.requests) ? rawState.requests : [];
  const activeTurnIds = [];
  const activeTurns = [];
  let runningWithoutTurnId = false;
  for (const turn of turns) {
    if (!isActiveStatus(turn?.status)) {
      continue;
    }
    const turnId = desktopTurnId(turn);
    if (turnId) {
      activeTurnIds.push(turnId);
      activeTurns.push(compactObject({ turnId, startedAtMs: desktopTimestampMs(turn, "started") }));
    } else {
      runningWithoutTurnId = true;
    }
  }
  const approvalCount = requests.filter(isPendingApprovalRequest).length;
  const userInputCount = requests.filter(isPendingUserInputRequest).length;
  const runtimeStatus = rawState.threadRuntimeStatus || rawState.status;
  // Explicit runtime idle can invalidate stale inProgress history, but cannot
  // turn that history into evidence of successful completion.
  const explicitIdle = normalizeRuntime(runtimeStatus) === "idle";
  if (explicitIdle) {
    activeTurnIds.length = 0;
    activeTurns.length = 0;
    runningWithoutTurnId = false;
  }
  const runtime = activeTurnIds.length > 0 || runningWithoutTurnId
    ? "active"
    : normalizeRuntime(runtimeStatus);
  runningWithoutTurnId ||= runtime === "active" && activeTurnIds.length === 0;
  return compactEntry({
    threadId,
    source: DESKTOP_IPC_SOURCE,
    title: readString(rawState.title) || readString(rawState.name),
    cwd: readString(rawState.cwd) || readString(rawState.current_working_directory),
    runtime,
    activeTurnIds,
    activeTurns,
    runningWithoutTurnId,
    ...attentionFields(approvalCount, userInputCount, runtimeActiveFlags(runtimeStatus)),
    desktopUnread: projectDesktopUnread(rawState),
    lastOutcome: projectLatestDesktopOutcome(turns),
    latestItem: projectLatestDesktopItem(turns, runtime),
    freshness: "current",
    sourceGeneration: positiveInteger(sourceGeneration),
  });
}

function projectLatestDesktopOutcome(turns) {
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = turns[index];
    const turnId = desktopTurnId(turn);
    const outcome = normalizeOutcome(turn?.status, turn?.error);
    if (!turnId || !outcome) {
      continue;
    }
    return compactObject({
      turnId,
      outcome,
      startedAtMs: desktopTimestampMs(turn, "started"),
      completedAtMs: desktopTimestampMs(turn, "completed"),
    });
  }
  return null;
}

function projectLatestDesktopItem(turns, runtime) {
  const turn = (runtime === "active" && turns.findLast((candidate) => isActiveStatus(candidate?.status)))
    || turns.at(-1);
  const items = Array.isArray(turn?.items) ? turn.items : [];
  for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
    const item = projectSemanticItem(items[itemIndex], {
      turnId: desktopTurnId(turn),
    });
    if (item) {
      return item;
    }
  }
  return null;
}

function projectSemanticItem(item, { turnId = "", lifecycle = "", lifecycleAtMs = null } = {}) {
  const itemId = readString(item?.id) || readString(item?.itemId) || readString(item?.item_id);
  const descriptor = semanticItemDescriptor(item?.type);
  if (!itemId || !descriptor) {
    return null;
  }
  const timingKey = lifecycle === "started"
    ? "startedAtMs"
    : lifecycle === "completed" ? "completedAtMs" : "";
  return compactObject({
    itemId,
    turnId,
    kind: descriptor.kind,
    label: descriptor.label,
    ...(timingKey && lifecycleAtMs != null ? { [timingKey]: lifecycleAtMs } : {}),
  });
}

function semanticItemDescriptor(type) {
  const token = normalizeToken(type);
  if (!token || token === "usermessage" || token === "hookprompt") {
    return null;
  }
  if (token === "reasoning" || token === "plan" || token === "todolist") {
    return { kind: "thinking", label: "Thinking" };
  }
  if (token.includes("command") || token.includes("exec")) {
    return { kind: "command", label: "Running command" };
  }
  if (token.includes("filechange") || token.includes("patch") || token.includes("apply")) {
    return { kind: "fileChange", label: "Editing files" };
  }
  if (token === "agentmessage" || token === "assistantmessage" || token === "message") {
    return { kind: "response", label: "Writing response" };
  }
  return { kind: "tool", label: "Using a tool" };
}

function projectTurnOutcome(turnId, turn, params, startedAtMs = null) {
  return compactObject({
    turnId,
    outcome: normalizeOutcome(turn.status || params.status, turn.error || params.error) || "completed",
    startedAtMs: timestampSecondsToMs(turn.startedAt ?? turn.started_at) ?? startedAtMs,
    completedAtMs: timestampSecondsToMs(turn.completedAt ?? turn.completed_at),
  });
}

function projectDesktopUnread(state) {
  const hasUnreadField = typeof state.hasUnreadTurn === "boolean"
    || typeof state.has_unread_turn === "boolean";
  const rawCount = state.unreadMessageCount ?? state.unread_message_count;
  const normalizedCount = finiteNumber(rawCount);
  const hasCountField = normalizedCount != null;
  if (!hasUnreadField && !hasCountField) {
    return null;
  }
  const unreadMessageCount = hasCountField ? Math.max(0, Math.floor(normalizedCount)) : 0;
  return {
    hasUnreadTurn: Boolean(state.hasUnreadTurn ?? state.has_unread_turn) || unreadMessageCount > 0,
    unreadMessageCount,
  };
}

function runtimeForAppServerState(state) {
  if (hasRunningWork(state)) {
    return "active";
  }
  return state.runtimeStatus === "active" ? "unknown" : state.runtimeStatus;
}

function normalizeRuntime(status) {
  const token = normalizeToken(typeof status === "object" ? status?.type : status);
  if (token === "active" || token === "running" || token === "inprogress" || token === "processing") {
    return "active";
  }
  if (token === "idle") {
    return "idle";
  }
  if (token === "systemerror" || token === "error" || token === "failed") {
    return "systemError";
  }
  return "unknown";
}

function normalizeOutcome(status, error) {
  const token = normalizeToken(status);
  if (token === "failed" || token === "error" || error) {
    return "failed";
  }
  if (["interrupted", "cancelled", "canceled", "stopped"].includes(token)) {
    return "interrupted";
  }
  if (token === "completed" || token === "complete" || token === "success" || token === "succeeded") {
    return "completed";
  }
  return "";
}

function isActiveStatus(status) {
  return normalizeRuntime(status) === "active";
}

function isPendingApprovalRequest(request) {
  return request?.completed !== true && APPROVAL_METHODS.has(readString(request?.method));
}

function isPendingUserInputRequest(request) {
  return request?.completed !== true && USER_INPUT_METHODS.has(readString(request?.method));
}

function runtimeActiveFlags(status) {
  if (normalizeRuntime(status) !== "active" || !Array.isArray(status?.activeFlags)) {
    return [];
  }
  return status.activeFlags.map(normalizeToken).filter((flag) => (
    flag === "waitingonapproval" || flag === "waitingonuserinput"
  )).sort();
}

function attentionFields(approvalCount, userInputCount, flags = []) {
  return {
    approvalRequired: approvalCount > 0 || flags.includes("waitingonapproval"),
    approvalRequestCount: approvalCount,
    userInputRequired: userInputCount > 0 || flags.includes("waitingonuserinput"),
    userInputRequestCount: userInputCount,
  };
}

function appServerThreadId(message) {
  const params = message?.params || {};
  return readString(params.threadId)
    || readString(params.thread_id)
    || readString(params.conversationId)
    || readString(params.conversation_id)
    || readString(params.thread?.id);
}

function turnIdentity(params, turn) {
  return readString(turn?.id)
    || readString(turn?.turnId)
    || readString(turn?.turn_id)
    || readString(params?.turnId)
    || readString(params?.turn_id);
}

function desktopTurnId(turn) {
  return readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
}

function desktopTimestampMs(turn, phase) {
  const prefix = phase === "started" ? "started" : "completed";
  return finiteNumber(
    turn?.[`${prefix}AtMs`]
      ?? turn?.[`turn${prefix[0].toUpperCase()}${prefix.slice(1)}AtMs`]
      ?? turn?.[`${prefix}_at_ms`]
      ?? turn?.[`turn_${prefix}_at_ms`]
  ) ?? timestampSecondsToMs(turn?.[`${prefix}At`] ?? turn?.[`${prefix}_at`]);
}

function timestampSecondsToMs(value) {
  const timestamp = finiteNumber(value);
  return timestamp == null ? null : timestamp * 1000;
}

function finiteNumber(value) {
  if (value == null || value === "") {
    return null;
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 1;
}

function rememberTerminalTurn(state, turnId) {
  state.terminalTurnIds.delete(turnId);
  state.terminalTurnIds.add(turnId);
  while (state.terminalTurnIds.size > MAX_TERMINAL_TURN_IDS) {
    const oldestTurnId = state.terminalTurnIds.keys().next().value;
    state.terminalTurnIds.delete(oldestTurnId);
    state.turnOrderById.delete(oldestTurnId);
    state.turnStartedAtMsById.delete(oldestTurnId);
  }
}

function rememberAppServerState(states, state, maxThreads) {
  states.delete(state.threadId);
  states.set(state.threadId, state);
  while (states.size > maxThreads) {
    const evictable = [...states.values()].find((candidate) => !isProtectedAppState(candidate));
    if (!evictable) {
      return;
    }
    states.delete(evictable.threadId);
  }
}

function isProtectedAppState(state) {
  return hasRunningWork(state)
    || state.activeFlags.length > 0
    || state.approvalRequestIds.size > 0
    || state.userInputRequestIds.size > 0;
}

function hasRunningWork(state) {
  return state.activeTurnIds.size > 0 || state.runningWithoutTurnId;
}

function hasKnownTerminalWork(state) {
  return state.settledTurnlessWork
    || state.terminalTurnIds.size > 0
    || state.lastOutcome != null;
}

function replaceString(target, key, value) {
  const nextValue = key === "title" ? truncateDisplayText(readString(value)) : readString(value);
  if (!nextValue || target[key] === nextValue) {
    return false;
  }
  target[key] = nextValue;
  return true;
}

function truncateDisplayText(value) {
  if (value.length <= MAX_DISPLAY_TEXT_CHARS) {
    return value;
  }
  return `${value.slice(0, MAX_DISPLAY_TEXT_CHARS - 1).trimEnd()}…`;
}

function compactEntry(entry) {
  return compactObject({
    ...entry,
    title: truncateDisplayText(readString(entry.title)),
  });
}

function compactObject(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== null && entry !== undefined && entry !== "")
  );
}

function sameJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

module.exports = {
  APP_SERVER_SOURCE,
  DESKTOP_IPC_SOURCE,
  createThreadActivityProjector,
  projectDesktopThreadActivity,
  projectSemanticItem,
};
