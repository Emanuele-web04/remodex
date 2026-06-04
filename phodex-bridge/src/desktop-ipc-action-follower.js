// FILE: desktop-ipc-action-follower.js
// Purpose: Mirrors live Codex Desktop IPC pending actions to the phone and routes replies back to the desktop runtime.
// Layer: CLI helper
// Exports: createDesktopIpcActionFollower, projectPendingDesktopActions
// Depends on: net, os, path

const net = require("net");
const os = require("os");
const path = require("path");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");

const FRAME_HEADER_BYTES = 4;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 10_000;
const TURN_COMPLETION_IDLE_MS = 3_500;
const DESKTOP_IPC_ACTION_SOURCE = "desktop-ipc-action-follower";
const DESKTOP_RESUME_METHODS = new Set(["thread/read", "thread/resume"]);
const ACTION_METHODS = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/fileRead/requestApproval",
  "item/permissions/requestApproval",
  "item/tool/requestUserInput",
]);
const REPLY_METHOD_BY_ACTION_METHOD = new Map([
  ["item/commandExecution/requestApproval", "thread-follower-command-approval-decision"],
  ["item/fileChange/requestApproval", "thread-follower-file-approval-decision"],
  ["item/fileRead/requestApproval", "thread-follower-file-approval-decision"],
  ["item/permissions/requestApproval", "thread-follower-file-approval-decision"],
  ["item/tool/requestUserInput", "thread-follower-submit-user-input"],
]);
const METHOD_VERSION_BY_NAME = new Map([
  ["initialize", 1],
  ["thread-follower-command-approval-decision", 1],
  ["thread-follower-file-approval-decision", 1],
  ["thread-follower-submit-user-input", 1],
]);
const APPROVAL_DECISIONS = new Set(["accept", "acceptForSession", "decline", "cancel"]);

// Opens the Desktop IPC bus on demand and exposes Mac-owned pending actions as normal app-server requests.
function createDesktopIpcActionFollower({
  sendApplicationResponse,
  readConversationState = null,
  logPrefix = "[remodex]",
  socketPath = resolveDefaultIpcSocketPath(),
  netModule = net,
  now = () => Date.now(),
  requestTimeoutMs = REQUEST_TIMEOUT_MS,
  turnCompletionIdleMs = TURN_COMPLETION_IDLE_MS,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
} = {}) {
  const ipc = createDesktopIpcClient({
    socketPath,
    netModule,
    now,
    requestTimeoutMs,
    logPrefix,
    onEnvelope,
    onDisconnect,
  });
  const rawStatesByThreadId = new Map();
  const assistantMessageTextsByThreadId = new Map();
  const mirroredActivityKeysByThreadId = new Map();
  const mirroredUserMessageKeysByThreadId = new Map();
  const activeDesktopTurnsByThreadId = new Map();
  const pendingRoutesByRequestId = new Map();
  const activeThreadIds = new Set();
  const recoveringThreadIds = new Set();
  const queuedChangesByThreadId = new Map();

  function observeInbound(rawMessage) {
    const message = safeParseJSON(rawMessage);
    const responseRoute = desktopRouteForResponse(message);
    if (responseRoute) {
      submitDesktopActionResponse(responseRoute, message);
      return true;
    }

    const method = readString(message?.method);
    if (!DESKTOP_RESUME_METHODS.has(method)) {
      return false;
    }

    const threadId = readThreadId(message?.params);
    if (!threadId) {
      return false;
    }

    activeThreadIds.add(threadId);
    ipc.ensureConnected();
    return false;
  }

  function stopAll() {
    rawStatesByThreadId.clear();
    assistantMessageTextsByThreadId.clear();
    mirroredActivityKeysByThreadId.clear();
    mirroredUserMessageKeysByThreadId.clear();
    clearAllDesktopTurnCompletionTimers();
    pendingRoutesByRequestId.clear();
    activeThreadIds.clear();
    recoveringThreadIds.clear();
    queuedChangesByThreadId.clear();
    ipc.close();
  }

  // Desktop broadcasts carry the live conversation state Litter projects from.
  function onEnvelope(envelope) {
    if (envelope?.type !== "broadcast" || envelope.method !== "thread-stream-state-changed") {
      return;
    }

    const params = envelope.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    if (!threadId || !activeThreadIds.has(threadId)) {
      return;
    }

    if (recoveringThreadIds.has(threadId)) {
      queueThreadChange(threadId, params.change);
      return;
    }

    const previousState = rawStatesByThreadId.get(threadId) || null;
    const nextState = applyConversationStateChange(previousState, params.change);
    if (!nextState) {
      if (isPatchChange(params.change)) {
        const emptyState = createEmptyConversationState();
        const speculativeState = applyConversationStateChange(emptyState, params.change);
        const speculativeActions = projectPendingDesktopActions(threadId, speculativeState);
        if (speculativeActions.length > 0) {
          rawStatesByThreadId.set(threadId, speculativeState);
          syncProjectedActions(threadId, speculativeActions);
          return;
        }

        if (typeof readConversationState !== "function") {
          return;
        }

        queueThreadChange(threadId, params.change);
        recoverThreadBaseline(threadId);
      }
      return;
    }

    rawStatesByThreadId.set(threadId, nextState);
    syncProjectedLiveState(threadId, previousState, nextState);
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
  }

  function onDisconnect() {
    rawStatesByThreadId.clear();
    assistantMessageTextsByThreadId.clear();
    mirroredActivityKeysByThreadId.clear();
    mirroredUserMessageKeysByThreadId.clear();
    clearAllDesktopTurnCompletionTimers();
    pendingRoutesByRequestId.clear();
    recoveringThreadIds.clear();
    queuedChangesByThreadId.clear();
  }

  function syncProjectedActions(threadId, actions) {
    const nextRequestIds = new Set(actions.map((action) => action.id));
    for (const [requestId, route] of Array.from(pendingRoutesByRequestId.entries())) {
      if (route.threadId !== threadId || nextRequestIds.has(requestId)) {
        continue;
      }

      pendingRoutesByRequestId.delete(requestId);
      sendApplicationResponse(JSON.stringify({
        method: "serverRequest/resolved",
        params: {
          threadId,
          requestId,
        },
      }));
    }

    for (const action of actions) {
      if (pendingRoutesByRequestId.has(action.id)) {
        continue;
      }

      pendingRoutesByRequestId.set(action.id, {
        requestId: action.id,
        method: action.method,
        threadId,
      });
      sendApplicationResponse(JSON.stringify({
        id: action.id,
        method: action.method,
        params: action.params,
      }));
    }
  }

  function desktopRouteForResponse(message) {
    if (!message || typeof message !== "object" || message.method) {
      return null;
    }

    const requestId = requestIdKey(message.id);
    return requestId ? pendingRoutesByRequestId.get(requestId) || null : null;
  }

  function submitDesktopActionResponse(route, responseMessage) {
    const payload = desktopFollowerPayloadForResponse(route, responseMessage);
    if (!payload) {
      sendApplicationResponse(JSON.stringify({
        id: responseMessage?.id ?? route.requestId,
        error: {
          code: -32602,
          message: "Invalid desktop action response.",
        },
      }));
      return;
    }

    ipc.sendRequest(payload.method, payload.params)
      .then(() => {
        pendingRoutesByRequestId.delete(route.requestId);
        sendApplicationResponse(JSON.stringify({
          method: "serverRequest/resolved",
          params: {
            threadId: route.threadId,
            requestId: route.requestId,
          },
        }));
      })
      .catch((error) => {
        console.warn(`${logPrefix} desktop action reply failed for ${route.threadId}: ${error.message}`);
        sendApplicationResponse(JSON.stringify({
          id: responseMessage.id,
          error: {
            code: -32000,
            message: "Could not send this action to Codex on the Mac.",
          },
        }));
      });
  }

  function queueThreadChange(threadId, change) {
    if (!change || typeof change !== "object") {
      return;
    }

    const queuedChanges = queuedChangesByThreadId.get(threadId) || [];
    queuedChanges.push(change);
    queuedChangesByThreadId.set(threadId, queuedChanges);
  }

  function recoverThreadBaseline(threadId) {
    if (recoveringThreadIds.has(threadId)
      || rawStatesByThreadId.has(threadId)) {
      return;
    }

    recoveringThreadIds.add(threadId);
    Promise.resolve()
      .then(() => readConversationState(threadId))
      .then((baselineState) => {
        if (!baselineState || typeof baselineState !== "object") {
          recoverThreadBaselineFromQueuedChanges(threadId, null);
          return;
        }

        recoverThreadBaselineFromQueuedChanges(threadId, baselineState);
      })
      .catch((error) => {
        console.warn(`${logPrefix} desktop IPC baseline recovery failed for ${threadId}: ${error.message}`);
        recoverThreadBaselineFromQueuedChanges(threadId, null);
      })
      .finally(() => {
        recoveringThreadIds.delete(threadId);
      });
  }

  function recoverThreadBaselineFromQueuedChanges(threadId, baselineState) {
    const queuedChanges = queuedChangesByThreadId.get(threadId) || [];
    if (queuedChanges.length === 0) {
      return;
    }

    queuedChangesByThreadId.delete(threadId);
    let nextState = baselineState && typeof baselineState === "object"
      ? cloneJSON(baselineState)
      : createEmptyConversationState();
    for (const change of queuedChanges) {
      nextState = applyConversationStateChange(nextState, change) || nextState;
    }

    rawStatesByThreadId.set(threadId, nextState);
    syncProjectedLiveState(threadId, baselineState, nextState);
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
  }

  function syncProjectedLiveState(threadId, previousState, nextState) {
    syncProjectedAssistantDeltas(threadId, previousState, nextState);
    syncProjectedDesktopActivities(threadId, nextState);
  }

  function syncProjectedAssistantDeltas(threadId, previousState, nextState) {
    refreshTrackedDesktopTurnState(threadId, nextState);
    const previousTexts = assistantMessageTextsByThreadId.get(threadId);
    if (!previousTexts && !previousState) {
      assistantMessageTextsByThreadId.set(threadId, snapshotAssistantMessageTexts(nextState));
      syncProjectedDesktopTurnCompletions(threadId, nextState);
      return;
    }

    const notifications = projectDesktopAssistantDeltaNotifications(
      threadId,
      previousState,
      nextState,
      previousTexts || snapshotAssistantMessageTexts(previousState)
    );
    if (notifications.length === 0) {
      assistantMessageTextsByThreadId.set(threadId, snapshotAssistantMessageTexts(nextState));
      syncProjectedDesktopTurnCompletions(threadId, nextState);
      return;
    }

    const activeDeltaTurnIds = new Set(
      notifications
        .map((notification) => readString(notification?.params?.turnId) || readString(notification?.params?.turn_id))
        .filter(Boolean)
    );
    const userNotifications = projectDesktopUserMessageNotifications(
      threadId,
      nextState,
      mirroredUserMessageKeysForThread(threadId),
      activeDeltaTurnIds
    );

    // Desktop IPC state can report assistant text growth before rollout replay catches
    // up with the user prelude. Emit the opening prompt first to avoid mobile row jumps.
    for (const notification of [...userNotifications, ...notifications]) {
      sendApplicationResponse(JSON.stringify(notification));
    }
    for (const turnId of activeDeltaTurnIds) {
      noteDesktopIpcTurnActivity(threadId, turnId, nextState);
    }
    assistantMessageTextsByThreadId.set(threadId, snapshotAssistantMessageTexts(nextState));
    syncProjectedDesktopTurnCompletions(threadId, nextState);
  }

  function syncProjectedDesktopActivities(threadId, nextState) {
    refreshTrackedDesktopTurnState(threadId, nextState);
    const activityKeys = mirroredActivityKeysForThread(threadId);
    const notifications = projectDesktopActivityNotifications(threadId, nextState, activityKeys);
    if (notifications.length === 0) {
      syncProjectedDesktopTurnCompletions(threadId, nextState);
      return;
    }

    const activeActivityTurnIds = new Set(
      notifications
        .map((notification) => readString(notification?.params?.turnId) || readString(notification?.params?.turn_id))
        .filter(Boolean)
    );
    const userNotifications = projectDesktopUserMessageNotifications(
      threadId,
      nextState,
      mirroredUserMessageKeysForThread(threadId),
      activeActivityTurnIds
    );

    // Tool-call snapshots are independent from assistant text deltas. Emit them
    // through the same app-server event names rollout mirroring uses so iOS keeps
    // showing active tool rows while the Mac-owned run is still executing.
    for (const notification of [...userNotifications, ...notifications]) {
      sendApplicationResponse(JSON.stringify(notification));
    }
    for (const turnId of activeActivityTurnIds) {
      noteDesktopIpcTurnActivity(threadId, turnId, nextState);
    }
    syncProjectedDesktopTurnCompletions(threadId, nextState);
  }

  function mirroredUserMessageKeysForThread(threadId) {
    let keys = mirroredUserMessageKeysByThreadId.get(threadId);
    if (!keys) {
      keys = new Set();
      mirroredUserMessageKeysByThreadId.set(threadId, keys);
    }
    return keys;
  }

  function mirroredActivityKeysForThread(threadId) {
    let keys = mirroredActivityKeysByThreadId.get(threadId);
    if (!keys) {
      keys = new Set();
      mirroredActivityKeysByThreadId.set(threadId, keys);
    }
    return keys;
  }

  function noteDesktopIpcTurnActivity(threadId, turnId, latestState) {
    if (!turnId || turnCompletionIdleMs <= 0) {
      return;
    }

    let turns = activeDesktopTurnsByThreadId.get(threadId);
    if (!turns) {
      turns = new Map();
      activeDesktopTurnsByThreadId.set(threadId, turns);
    }

    const existing = turns.get(turnId);
    if (existing?.timer) {
      clearTimeoutFn(existing.timer);
    }

    const entry = { latestState, timer: null };
    turns.set(turnId, entry);
    scheduleDesktopIpcTurnIdleCompletion(threadId, turnId, entry);
  }

  function scheduleDesktopIpcTurnIdleCompletion(threadId, turnId, entry) {
    entry.timer = setTimeoutFn(() => {
      const currentTurns = activeDesktopTurnsByThreadId.get(threadId);
      const currentEntry = currentTurns?.get(turnId);
      if (!currentEntry) {
        return;
      }

      if (hasOpenDesktopRequestForTurn(currentEntry.latestState, turnId)
        || hasActiveDesktopActivityForTurn(currentEntry.latestState, turnId)) {
        scheduleDesktopIpcTurnIdleCompletion(threadId, turnId, currentEntry);
        return;
      }

      completeDesktopIpcTurn(threadId, turnId);
    }, turnCompletionIdleMs);
    entry.timer.unref?.();
  }

  function refreshTrackedDesktopTurnState(threadId, latestState) {
    const turns = activeDesktopTurnsByThreadId.get(threadId);
    if (!turns) {
      return;
    }

    for (const entry of turns.values()) {
      entry.latestState = latestState;
    }
  }

  function syncProjectedDesktopTurnCompletions(threadId, nextState) {
    const turns = activeDesktopTurnsByThreadId.get(threadId);
    if (!turns || turns.size === 0) {
      return;
    }

    const completions = projectDesktopTurnCompletedNotifications(
      threadId,
      nextState,
      new Set(turns.keys())
    );
    for (const notification of completions) {
      completeDesktopIpcTurn(threadId, notification.params.turnId, notification.params.status || "completed");
    }
  }

  function completeDesktopIpcTurn(threadId, turnId, status = "completed") {
    const turns = activeDesktopTurnsByThreadId.get(threadId);
    const entry = turns?.get(turnId);
    if (!entry) {
      return;
    }

    if (entry.timer) {
      clearTimeoutFn(entry.timer);
    }
    turns.delete(turnId);
    if (turns.size === 0) {
      activeDesktopTurnsByThreadId.delete(threadId);
    }

    sendApplicationResponse(JSON.stringify(createDesktopIpcTurnCompletedNotification(threadId, turnId, status)));
  }

  function clearAllDesktopTurnCompletionTimers() {
    for (const turns of activeDesktopTurnsByThreadId.values()) {
      for (const entry of turns.values()) {
        if (entry.timer) {
          clearTimeoutFn(entry.timer);
        }
      }
    }
    activeDesktopTurnsByThreadId.clear();
  }

  return {
    observeInbound,
    stopAll,
  };
}

// Minimal IPC client for Litter's length-prefixed Codex desktop bus.
function createDesktopIpcClient({
  socketPath,
  netModule,
  now,
  requestTimeoutMs,
  logPrefix,
  onEnvelope,
  onDisconnect,
}) {
  let socket = null;
  let clientId = "";
  let isConnecting = false;
  let readBuffer = Buffer.alloc(0);
  const pendingRequests = new Map();

  function ensureConnected() {
    if (socket || isConnecting) {
      return;
    }

    isConnecting = true;
    const nextSocket = netModule.createConnection(socketPath);
    socket = nextSocket;

    nextSocket.on("connect", () => {
      isConnecting = false;
      sendRequest("initialize", { clientType: "remodex-bridge" })
        .then((result) => {
          clientId = readString(result?.clientId) || clientId;
        })
        .catch((error) => {
          console.warn(`${logPrefix} desktop IPC initialize failed: ${error.message}`);
          close();
        });
    });
    nextSocket.on("data", handleData);
    nextSocket.on("close", handleClose);
    nextSocket.on("error", (error) => {
      if (error?.code !== "ENOENT" && error?.code !== "ECONNREFUSED") {
        console.warn(`${logPrefix} desktop IPC connection failed: ${error.message}`);
      }
    });
  }

  function sendRequest(method, params) {
    ensureConnected();
    if (!socket || socket.destroyed) {
      return Promise.reject(new Error("Desktop IPC is not connected."));
    }

    const requestId = `remodex-${now().toString(36)}-${Math.random().toString(16).slice(2)}`;
    const envelope = {
      type: "request",
      requestId,
      sourceClientId: method === "initialize" ? "initializing-client" : clientId || "remodex-bridge",
      version: METHOD_VERSION_BY_NAME.get(method) || 1,
      method,
      params: params || {},
    };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        pendingRequests.delete(requestId);
        reject(new Error(`Desktop IPC request timed out: ${method}`));
      }, requestTimeoutMs);
      timeout.unref?.();

      pendingRequests.set(requestId, {
        method,
        resolve,
        reject,
        timeout,
      });
      writeFrame(socket, JSON.stringify(envelope), (error) => {
        if (!error) {
          return;
        }

        clearTimeout(timeout);
        pendingRequests.delete(requestId);
        reject(error);
      });
    });
  }

  function handleData(chunk) {
    readBuffer = Buffer.concat([readBuffer, chunk]);
    while (readBuffer.length >= FRAME_HEADER_BYTES) {
      const frameLength = readBuffer.readUInt32LE(0);
      if (frameLength > MAX_FRAME_BYTES) {
        close();
        return;
      }
      if (readBuffer.length < FRAME_HEADER_BYTES + frameLength) {
        return;
      }

      const payload = readBuffer.slice(FRAME_HEADER_BYTES, FRAME_HEADER_BYTES + frameLength).toString("utf8");
      readBuffer = readBuffer.slice(FRAME_HEADER_BYTES + frameLength);
      const envelope = safeParseJSON(payload);
      if (envelope) {
        dispatchEnvelope(envelope);
      }
    }
  }

  function dispatchEnvelope(envelope) {
    if (envelope.type === "client-discovery-request") {
      writeEnvelope({
        type: "client-discovery-response",
        requestId: envelope.requestId,
        response: {
          canHandle: false,
        },
      });
      return;
    }

    if (envelope.type === "response") {
      const requestId = requestIdKey(envelope.requestId);
      const waiter = requestId ? pendingRequests.get(requestId) : null;
      if (!waiter) {
        return;
      }

      pendingRequests.delete(requestId);
      clearTimeout(waiter.timeout);
      if (envelope.resultType === "error") {
        waiter.reject(new Error(envelope.error || `Desktop IPC request failed: ${waiter.method}`));
        return;
      }

      waiter.resolve(envelope.result ?? null);
      return;
    }

    onEnvelope(envelope);
  }

  function handleClose() {
    socket = null;
    clientId = "";
    isConnecting = false;
    readBuffer = Buffer.alloc(0);
    for (const waiter of pendingRequests.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error("Desktop IPC connection closed."));
    }
    pendingRequests.clear();
    onDisconnect();
  }

  function close() {
    if (!socket) {
      return;
    }

    const nextSocket = socket;
    socket = null;
    nextSocket.destroy();
  }

  function writeEnvelope(envelope, callback = () => {}) {
    if (!socket || socket.destroyed) {
      callback(new Error("Desktop IPC is not connected."));
      return;
    }

    writeFrame(socket, JSON.stringify(envelope), callback);
  }

  return {
    ensureConnected,
    sendRequest,
    close,
  };
}

function desktopFollowerPayloadForResponse(route, responseMessage) {
  const method = REPLY_METHOD_BY_ACTION_METHOD.get(route.method);
  if (!method || responseMessage?.error) {
    return null;
  }

  if (route.method === "item/tool/requestUserInput") {
    const answers = responseMessage?.result?.answers;
    if (!answers || typeof answers !== "object" || Array.isArray(answers)) {
      return null;
    }

    return {
      method,
      params: {
        conversationId: route.threadId,
        requestId: route.requestId,
        response: {
          answers,
        },
      },
    };
  }

  const decision = desktopApprovalDecisionForResponse(route.method, responseMessage?.result);
  if (!APPROVAL_DECISIONS.has(decision)) {
    return null;
  }

  return {
    method,
    params: {
      conversationId: route.threadId,
      requestId: route.requestId,
      decision,
    },
  };
}

function desktopApprovalDecisionForResponse(method, result) {
  const explicitDecision = readString(result?.decision);
  if (explicitDecision) {
    return explicitDecision;
  }

  if (method !== "item/permissions/requestApproval") {
    return "";
  }

  // Permission approvals use a grant payload on app-server, while Desktop IPC
  // currently exposes only decision-style follower replies.
  return hasGrantedPermission(result?.permissions) ? "accept" : "decline";
}

function hasGrantedPermission(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  if (Object.keys(value).length === 0) {
    return false;
  }

  return Object.values(value).some((entry) => {
    if (entry == null) {
      return false;
    }
    if (typeof entry === "boolean") {
      return entry;
    }
    if (Array.isArray(entry)) {
      return entry.length > 0;
    }
    if (typeof entry === "object") {
      return Object.keys(entry).length > 0;
    }
    return true;
  });
}

function projectPendingDesktopActions(threadId, conversationState) {
  const requests = Array.isArray(conversationState?.requests) ? conversationState.requests : [];
  return requests
    .filter((request) => request && request.completed !== true)
    .filter((request) => ACTION_METHODS.has(readString(request.method)))
    .map((request) => projectPendingDesktopAction(threadId, request))
    .filter(Boolean);
}

// Desktop IPC exposes full conversation snapshots/patches, not app-server assistant delta events.
// Mirror only suffix growth for assistant rows so phones can render the same live text progression.
function projectDesktopAssistantDeltaNotifications(
  threadId,
  previousState,
  nextState,
  previousTexts = snapshotAssistantMessageTexts(previousState)
) {
  const nextMessages = collectAssistantMessages(nextState);
  const notifications = [];

  for (const message of nextMessages) {
    const previousText = previousTexts.get(message.key) || "";
    if (!message.text || !message.text.startsWith(previousText) || message.text.length <= previousText.length) {
      continue;
    }

    const delta = message.text.slice(previousText.length);
    notifications.push({
      method: "item/agentMessage/delta",
      params: {
        threadId,
        turnId: message.turnId,
        itemId: message.itemId,
        delta,
      },
    });
  }

  return notifications;
}

function projectDesktopUserMessageNotifications(
  threadId,
  conversationState,
  mirroredKeys = new Set(),
  turnIdFilter = null
) {
  const messages = collectUserMessages(conversationState);
  const notifications = [];

  for (const message of messages) {
    if (turnIdFilter && turnIdFilter.size > 0 && !turnIdFilter.has(message.turnId)) {
      continue;
    }
    if (mirroredKeys.has(message.key)) {
      continue;
    }

    mirroredKeys.add(message.key);
    notifications.push({
      method: "codex/event/user_message",
      params: {
        threadId,
        turnId: message.turnId,
        message: message.text,
        ...(message.itemId ? { id: message.itemId } : {}),
        ...(message.timestamp ? { timestamp: message.timestamp } : {}),
        remodexDesktopMirror: true,
        remodexDesktopIpcMirror: true,
      },
    });
  }

  return notifications;
}

function projectDesktopActivityNotifications(threadId, conversationState, mirroredKeys = new Set()) {
  const turns = Array.isArray(conversationState?.turns) ? conversationState.turns : [];
  const notifications = [];

  for (const turn of turns) {
    const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
    if (!turnId || (
      !hasActiveDesktopActivityForTurn(conversationState, turnId)
      && !isDesktopTurnLive(turn, conversationState)
      && !hasMirroredActivityOutputPending(turn, mirroredKeys)
    )) {
      continue;
    }

    const items = Array.isArray(turn?.items) ? turn.items : [];
    const callsById = new Map();
    for (const item of items) {
      if (isDesktopActivityCallItem(item)) {
        const callId = desktopActivityCallId(item);
        if (callId) {
          callsById.set(callId, item);
        }
      }
    }

    for (const item of items) {
      if (isDesktopActivityCallItem(item)) {
        notifications.push(...projectDesktopActivityBeginNotifications(threadId, turnId, item, mirroredKeys));
      } else if (isDesktopActivityOutputItem(item)) {
        const callId = desktopActivityCallId(item);
        notifications.push(...projectDesktopActivityOutputNotifications(
          threadId,
          turnId,
          item,
          callsById.get(callId),
          mirroredKeys
        ));
      }
    }
  }

  return notifications;
}

function projectDesktopActivityBeginNotifications(threadId, turnId, item, mirroredKeys) {
  const callId = desktopActivityCallId(item);
  const toolName = readString(item?.name) || readString(item?.toolName) || readString(item?.tool_name);
  if (!callId || !toolName || !markMirroredActivityKey(mirroredKeys, turnId, callId, "begin")) {
    return [];
  }

  if (isCommandToolName(toolName)) {
    const argumentsObject = parseToolArguments(item?.arguments);
    return [createDesktopIpcNotification("codex/event/exec_command_begin", {
      threadId,
      turnId,
      call_id: callId,
      command: resolveToolCommand(toolName, argumentsObject),
      cwd: resolveToolWorkingDirectory(argumentsObject, item),
      status: "running",
    })];
  }

  if (toolName === "apply_patch") {
    const isCompletedPatch = Boolean(terminalStatusFromObject(item));
    const fileChange = buildApplyPatchFileChangeItem({
      callId,
      patch: readString(item?.input) || readString(item?.arguments),
      status: readString(item?.status) || (isCompletedPatch ? "completed" : "inProgress"),
      idFallback: buildSyntheticActivityItemId("file-change", threadId, turnId, callId),
      cwd: readString(item?.cwd) || readString(item?.workdir),
    });
    if (fileChange) {
      return [createDesktopIpcNotification(
        isCompletedPatch ? "codex/event/patch_apply_end" : "codex/event/patch_apply_begin",
        {
          threadId,
          turnId,
          id: turnId,
          call_id: callId,
          itemId: fileChange.id,
          status: fileChange.status,
          ...(isCompletedPatch ? { success: true } : {}),
          changes: fileChange.changes,
        }
      )];
    }
  }

  return [createDesktopIpcNotification("codex/event/background_event", {
    threadId,
    turnId,
    call_id: callId,
    message: genericToolActivityMessage(toolName),
  })];
}

function projectDesktopActivityOutputNotifications(threadId, turnId, item, callItem, mirroredKeys) {
  const callId = desktopActivityCallId(item);
  const toolName = readString(callItem?.name) || readString(callItem?.toolName) || readString(callItem?.tool_name);
  if (!callId || !toolName || !mirroredKeys.has(activityMirrorKey(turnId, callId, "begin"))) {
    return [];
  }
  if (!markMirroredActivityKey(mirroredKeys, turnId, callId, "output")) {
    return [];
  }

  if (!isCommandToolName(toolName)) {
    return [];
  }

  const argumentsObject = parseToolArguments(callItem?.arguments);
  const command = resolveToolCommand(toolName, argumentsObject);
  const cwd = resolveToolWorkingDirectory(argumentsObject, callItem);
  const output = readString(item?.output) || readString(item?.text) || readString(item?.content);
  const notifications = [];
  if (output) {
    notifications.push(createDesktopIpcNotification("codex/event/exec_command_output_delta", {
      threadId,
      turnId,
      call_id: callId,
      command,
      cwd,
      chunk: output,
    }));
  }
  notifications.push(createDesktopIpcNotification("codex/event/exec_command_end", {
    threadId,
    turnId,
    call_id: callId,
    command,
    cwd,
    status: "completed",
    output: output || "",
  }));
  return notifications;
}

function projectDesktopTurnCompletedNotifications(
  threadId,
  conversationState,
  trackedTurnIds = new Set()
) {
  if (!trackedTurnIds || trackedTurnIds.size === 0) {
    return [];
  }

  const turns = Array.isArray(conversationState?.turns) ? conversationState.turns : [];
  const notifications = [];
  for (const turn of turns) {
    const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
    if (!turnId || !trackedTurnIds.has(turnId)) {
      continue;
    }
    // Terminal snapshots can race active tool rows. Keep tracking the turn until
    // the activity itself closes, otherwise the phone may stay running forever.
    if (hasActiveDesktopActivityForTurn(conversationState, turnId)) {
      continue;
    }
    if (!isDesktopTurnTerminal(turn, conversationState)) {
      continue;
    }

    notifications.push(createDesktopIpcTurnCompletedNotification(
      threadId,
      turnId,
      desktopTerminalStatus(turn, conversationState) || "completed"
    ));
  }
  return notifications;
}

function createDesktopIpcTurnCompletedNotification(threadId, turnId, status = "completed") {
  return {
    method: "turn/completed",
    params: {
      threadId,
      turnId,
      id: turnId,
      status,
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
    },
  };
}

function snapshotAssistantMessageTexts(conversationState) {
  return new Map(collectAssistantMessages(conversationState).map((message) => [message.key, message.text]));
}

function collectUserMessages(conversationState) {
  const turns = Array.isArray(conversationState?.turns) ? conversationState.turns : [];
  const messages = [];
  for (const turn of turns) {
    const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
    const items = Array.isArray(turn?.items) ? turn.items : [];
    for (const item of items) {
      if (!isUserMessageItem(item)) {
        continue;
      }

      const text = userMessageText(item);
      if (!turnId || !text) {
        continue;
      }

      const itemId = readString(item?.id) || readString(item?.itemId) || readString(item?.item_id);
      messages.push({
        key: userMessageKey(turnId, itemId, text),
        turnId,
        itemId,
        text,
        timestamp: readString(item?.createdAt)
          || readString(item?.created_at)
          || readString(item?.timestamp)
          || readString(item?.time),
      });
    }
  }
  return messages;
}

function collectAssistantMessages(conversationState) {
  const turns = Array.isArray(conversationState?.turns) ? conversationState.turns : [];
  const messages = [];
  for (const turn of turns) {
    const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
    const items = Array.isArray(turn?.items) ? turn.items : [];
    for (const item of items) {
      if (!isAssistantMessageItem(item)) {
        continue;
      }

      const itemId = readString(item?.id) || readString(item?.itemId) || readString(item?.item_id);
      const text = assistantMessageText(item);
      if (!turnId || !itemId) {
        continue;
      }

      messages.push({
        key: `${turnId}:${itemId}`,
        turnId,
        itemId,
        text,
      });
    }
  }
  return messages;
}

function userMessageKey(turnId, itemId, text) {
  if (itemId) {
    return `${turnId}:${itemId}`;
  }
  return `${turnId}:text:${crypto
    .createHash("sha256")
    .update(text)
    .digest("hex")
    .slice(0, 16)}`;
}

function markMirroredActivityKey(mirroredKeys, turnId, callId, phase) {
  const key = activityMirrorKey(turnId, callId, phase);
  if (mirroredKeys.has(key)) {
    return false;
  }
  mirroredKeys.add(key);
  return true;
}

function activityMirrorKey(turnId, callId, phase) {
  return `${turnId}:${callId}:${phase}`;
}

function hasMirroredActivityOutputPending(turn, mirroredKeys) {
  const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
  const items = Array.isArray(turn?.items) ? turn.items : [];
  return items.some((item) => {
    if (!isDesktopActivityOutputItem(item)) {
      return false;
    }
    const callId = desktopActivityCallId(item);
    return callId
      && mirroredKeys.has(activityMirrorKey(turnId, callId, "begin"))
      && !mirroredKeys.has(activityMirrorKey(turnId, callId, "output"));
  });
}

function isDesktopTurnTerminal(turn, conversationState) {
  if (desktopTerminalStatus(turn, conversationState)) {
    return true;
  }

  return hasExplicitFalseFlag(turn, ["running", "isRunning", "streaming", "isStreaming"])
    || (
      hasExplicitFalseFlag(conversationState, ["running", "isRunning", "streaming", "isStreaming"])
      && !hasOpenDesktopRequestForTurn(conversationState, readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id))
    );
}

function isDesktopTurnLive(turn, conversationState) {
  return hasExplicitTrueFlag(turn, ["running", "isRunning", "streaming", "isStreaming"])
    || hasExplicitTrueFlag(conversationState, ["running", "isRunning", "streaming", "isStreaming"])
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(turn?.status)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(turn?.state)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(turn?.phase)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(conversationState?.status)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(conversationState?.state)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(conversationState?.phase)));
}

function desktopTerminalStatus(turn, conversationState) {
  const terminal = terminalStatusFromObject(turn)
    || terminalStatusFromObject(turn?.turn)
    || terminalStatusFromObject(conversationState);
  return terminal || "";
}

function terminalStatusFromObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "";
  }

  const booleanStatus = terminalStatusFromBooleans(value);
  if (booleanStatus) {
    return booleanStatus;
  }

  const candidates = [
    value.status,
    value.state,
    value.phase,
    value.lifecycle,
    value.lifecycleStatus,
    value.lifecycle_status,
    value.runStatus,
    value.run_status,
    value.turnStatus,
    value.turn_status,
  ];
  for (const candidate of candidates) {
    const token = normalizeToken(readString(candidate));
    if (TERMINAL_STATUS_TOKENS.has(token)) {
      return canonicalTerminalStatus(token);
    }
  }
  return "";
}

function terminalStatusFromBooleans(value) {
  if (value.completed === true || value.complete === true || value.done === true || value.finished === true) {
    return "completed";
  }
  if (value.failed === true || value.error === true) {
    return "failed";
  }
  if (value.cancelled === true || value.canceled === true || value.interrupted === true) {
    return "canceled";
  }
  return "";
}

const TERMINAL_STATUS_TOKENS = new Set([
  "completed",
  "complete",
  "finished",
  "succeeded",
  "success",
  "failed",
  "failure",
  "error",
  "cancelled",
  "canceled",
  "interrupted",
]);

function canonicalTerminalStatus(token) {
  if (token === "failed" || token === "failure" || token === "error") {
    return "failed";
  }
  if (token === "cancelled" || token === "canceled" || token === "interrupted") {
    return "canceled";
  }
  return "completed";
}

function hasExplicitFalseFlag(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  return keys.some((key) => Object.prototype.hasOwnProperty.call(value, key) && value[key] === false);
}

function hasExplicitTrueFlag(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  return keys.some((key) => Object.prototype.hasOwnProperty.call(value, key) && value[key] === true);
}

const ACTIVE_STATUS_TOKENS = new Set([
  "running",
  "streaming",
  "inprogress",
  "inflight",
  "started",
  "pending",
  "active",
]);

function hasOpenDesktopRequestForTurn(conversationState, turnId) {
  if (!turnId) {
    return false;
  }

  const requests = Array.isArray(conversationState?.requests) ? conversationState.requests : [];
  return requests.some((request) => {
    if (!request || request.completed === true) {
      return false;
    }

    const params = request.params && typeof request.params === "object" && !Array.isArray(request.params)
      ? request.params
      : {};
    const requestTurnId = readString(params.turnId)
      || readString(params.turn_id)
      || readString(request.turnId)
      || readString(request.turn_id);
    return requestTurnId === turnId;
  });
}

function hasActiveDesktopActivityForTurn(conversationState, turnId) {
  const turn = desktopTurnById(conversationState, turnId);
  const items = Array.isArray(turn?.items) ? turn.items : [];
  const completedActivityIds = completedDesktopActivityIds(items);
  return items.some((item) => isActiveDesktopActivityItem(item, completedActivityIds));
}

function desktopTurnById(conversationState, turnId) {
  if (!turnId) {
    return null;
  }

  const turns = Array.isArray(conversationState?.turns) ? conversationState.turns : [];
  return turns.find((turn) => {
    const candidateTurnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
    return candidateTurnId === turnId;
  }) || null;
}

function isActiveDesktopActivityItem(item, completedActivityIds = new Set()) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return false;
  }
  if (!isDesktopActivityItem(item) || isDesktopActivityOutputItem(item) || terminalStatusFromObject(item)) {
    return false;
  }
  if (hasExplicitTrueFlag(item, ["running", "isRunning", "streaming", "isStreaming"])
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(item.status)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(item.state)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(item.phase)))
    || ACTIVE_STATUS_TOKENS.has(normalizeToken(readString(item.lifecycle)))) {
    return true;
  }

  // Codex Desktop often represents a live tool as a bare function_call/custom_tool_call
  // with only call_id, then appends a separate *_output item. Treat the call as active
  // until that output appears, even when no explicit "running" status is present.
  const activityId = desktopActivityCallId(item);
  return isDesktopActivityCallItem(item) && activityId && !completedActivityIds.has(activityId);
}

function isDesktopActivityItem(item) {
  const type = normalizeToken(item?.type);
  return type.includes("tool")
    || type.includes("command")
    || type.includes("exec")
    || type.includes("mcp")
    || type.includes("function");
}

function isDesktopActivityCallItem(item) {
  const type = normalizeToken(item?.type);
  if (isDesktopActivityOutputItem(item)) {
    return false;
  }
  return type.endsWith("call")
    || type.includes("toolcall")
    || type.includes("functioncall")
    || type.includes("commandexecution")
    || type.includes("localshellcall");
}

function isDesktopActivityOutputItem(item) {
  const type = normalizeToken(item?.type);
  return type.includes("output")
    || type.includes("result")
    || type.endsWith("end")
    || type.includes("completed");
}

function completedDesktopActivityIds(items) {
  const ids = new Set();
  for (const item of items) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      continue;
    }
    if (!isDesktopActivityOutputItem(item) && !terminalStatusFromObject(item)) {
      continue;
    }
    const id = desktopActivityCallId(item);
    if (id) {
      ids.add(id);
    }
  }
  return ids;
}

function desktopActivityCallId(item) {
  return readString(item?.call_id)
    || readString(item?.callId)
    || readString(item?.tool_call_id)
    || readString(item?.toolCallId)
    || readString(item?.requestId)
    || readString(item?.request_id)
    || readString(item?.id);
}

function isUserMessageItem(item) {
  const type = normalizeToken(item?.type);
  if (type === "usermessage") {
    return true;
  }
  return type === "message" && normalizeToken(item?.role) === "user";
}

function isAssistantMessageItem(item) {
  const type = normalizeToken(item?.type);
  if (type === "agentmessage" || type === "assistantmessage") {
    return true;
  }
  return type === "message" && normalizeToken(item?.role) === "assistant";
}

function userMessageText(item) {
  const directText = readString(item?.text) || readString(item?.message);
  if (directText) {
    return directText;
  }

  const content = Array.isArray(item?.content) ? item.content : [];
  return content
    .map((entry) => entry && typeof entry === "object" ? entry : null)
    .filter(Boolean)
    .map((entry) => readString(entry.text) || readString(entry?.data?.text))
    .filter(Boolean)
    .join("");
}

function assistantMessageText(item) {
  const directText = readString(item?.text) || readString(item?.message);
  if (directText) {
    return directText;
  }

  const content = Array.isArray(item?.content) ? item.content : [];
  return content
    .map((entry) => entry && typeof entry === "object" ? entry : null)
    .filter(Boolean)
    .map((entry) => readString(entry.text) || readString(entry?.data?.text))
    .filter(Boolean)
    .join("");
}

function projectPendingDesktopAction(threadId, request) {
  const requestId = requestIdKey(request.id);
  const method = readString(request.method);
  const params = request.params && typeof request.params === "object" && !Array.isArray(request.params)
    ? request.params
    : {};
  if (!requestId || !method) {
    return null;
  }

  if (method === "item/tool/requestUserInput") {
    const questions = Array.isArray(params.questions) ? params.questions : [];
    if (questions.length === 0) {
      return null;
    }
  }

  return {
    id: requestId,
    method,
    params: {
      ...params,
      remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
      threadId: readString(params.threadId) || readString(params.thread_id) || threadId,
    },
  };
}

function applyConversationStateChange(previousState, change) {
  if (!change || typeof change !== "object") {
    return null;
  }

  if (change.type === "snapshot" || change.type === "Snapshot") {
    return cloneJSON(change.conversationState || change.conversation_state || {});
  }

  if (change.type !== "patches" && change.type !== "Patches") {
    return previousState || null;
  }

  const patches = Array.isArray(change.patches) ? change.patches : [];
  if (!previousState || patches.length === 0) {
    return previousState || null;
  }

  const nextState = cloneJSON(previousState);
  for (const patch of patches) {
    applyImmerPatch(nextState, patch);
  }
  return nextState;
}

function isPatchChange(change) {
  return change?.type === "patches" || change?.type === "Patches";
}

function seedConversationStateFromThreadRead(response) {
  const conversationState = response?.conversationState || response?.conversation_state;
  if (conversationState && typeof conversationState === "object" && !Array.isArray(conversationState)) {
    return cloneJSON(conversationState);
  }

  const thread = response?.thread && typeof response.thread === "object" && !Array.isArray(response.thread)
    ? response.thread
    : {};
  return {
    turns: Array.isArray(thread.turns) ? cloneJSON(thread.turns) : [],
    requests: Array.isArray(thread.requests) ? cloneJSON(thread.requests) : [],
  };
}

function createEmptyConversationState() {
  return {
    turns: [],
    requests: [],
  };
}

function applyImmerPatch(target, patch) {
  const patchPath = Array.isArray(patch?.path) ? patch.path : [];
  const op = readString(patch?.op).toLowerCase();
  if (!op || patchPath.length === 0) {
    return;
  }

  let parent = target;
  for (let index = 0; index < patchPath.length - 1; index += 1) {
    parent = parent?.[patchPath[index]];
    if (parent == null) {
      return;
    }
  }

  const key = patchPath[patchPath.length - 1];
  if (op === "remove") {
    if (Array.isArray(parent) && Number.isInteger(key)) {
      parent.splice(key, 1);
    } else if (parent && typeof parent === "object") {
      delete parent[key];
    }
    return;
  }

  if (op === "add" || op === "replace") {
    if (Array.isArray(parent) && Number.isInteger(key)) {
      if (op === "add") {
        parent.splice(key, 0, patch.value);
      } else {
        parent[key] = patch.value;
      }
    } else if (parent && typeof parent === "object") {
      parent[key] = patch.value;
    }
  }
}

function writeFrame(socket, payload, callback) {
  const body = Buffer.from(payload, "utf8");
  const header = Buffer.alloc(FRAME_HEADER_BYTES);
  header.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([header, body]), callback);
}

function resolveDefaultIpcSocketPath() {
  if (process.platform === "win32") {
    return "\\\\.\\pipe\\codex-ipc";
  }

  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  return path.join(os.tmpdir(), "codex-ipc", `ipc-${uid}.sock`);
}

function readThreadId(params) {
  return readString(params?.threadId)
    || readString(params?.thread_id)
    || readString(params?.conversationId)
    || readString(params?.conversation_id);
}

function requestIdKey(value) {
  if (typeof value === "string" && value) {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  return "";
}

function parseToolArguments(rawArguments) {
  const parsed = safeParseJSON(rawArguments);
  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
}

function resolveToolCommand(toolName, argumentsObject) {
  if (!isCommandToolName(toolName)) {
    return toolName;
  }

  return readString(argumentsObject.cmd)
    || readString(argumentsObject.command)
    || readString(argumentsObject.raw_command)
    || readString(argumentsObject.rawCommand)
    || toolName;
}

function resolveToolWorkingDirectory(argumentsObject, item = {}) {
  return readString(argumentsObject.workdir)
    || readString(argumentsObject.cwd)
    || readString(argumentsObject.working_directory)
    || readString(item?.cwd)
    || readString(item?.workdir)
    || "";
}

function isCommandToolName(toolName) {
  const normalized = readString(toolName).toLowerCase();
  return normalized === "exec_command"
    || normalized === "shell_command"
    || normalized.endsWith(".exec_command")
    || normalized.endsWith(".shell_command");
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

function buildSyntheticActivityItemId(kind, threadId, turnId, callId) {
  return `${kind}:${threadId}:${turnId}:${callId}`;
}

function createDesktopIpcNotification(method, params = {}) {
  return {
    method,
    params: {
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
      ...params,
    },
  };
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function normalizeToken(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[_-\s]+/g, "")
    : "";
}

function cloneJSON(value) {
  return JSON.parse(JSON.stringify(value));
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

module.exports = {
  applyConversationStateChange,
  createDesktopIpcActionFollower,
  desktopFollowerPayloadForResponse,
  hasActiveDesktopActivityForTurn,
  projectDesktopAssistantDeltaNotifications,
  projectDesktopActivityNotifications,
  projectDesktopTurnCompletedNotifications,
  projectDesktopUserMessageNotifications,
  projectPendingDesktopActions,
  resolveDefaultIpcSocketPath,
  seedConversationStateFromThreadRead,
};
