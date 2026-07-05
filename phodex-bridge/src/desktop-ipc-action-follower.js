// FILE: desktop-ipc-action-follower.js
// Purpose: Mirrors live Codex Desktop IPC pending actions to the phone and routes replies back to the desktop runtime.
// Layer: CLI helper
// Exports: createDesktopIpcActionFollower, projectPendingDesktopActions
// Depends on: net, ./desktop-ipc-conversation-projector, ./desktop-ipc-shared

const net = require("net");

const {
  createDesktopConversationProjector,
  projectDesktopConversationStateToThread,
} = require("./desktop-ipc-conversation-projector");
const {
  FRAME_HEADER_BYTES,
  MAX_FRAME_BYTES,
  cloneJSON,
  normalizeToken,
  readString,
  requestIdKey,
  resolveDefaultIpcSocketPath,
  safeParseJSON,
  writeFrame,
} = require("./desktop-ipc-shared");

const REQUEST_TIMEOUT_MS = 10_000;
const OWNERSHIP_PROBE_TIMEOUT_MS = 1_500;
const DESKTOP_IPC_ACTION_SOURCE = "desktop-ipc-action-follower";
const REMODEX_LIVE_OWNER_SOURCE = "desktop-ipc-live-owner";
const DESKTOP_STATE_READ_METHODS = new Set(["thread/read", "thread/resume", "thread/turns/list"]);
const DESKTOP_FOLLOWER_REQUEST_METHODS = new Set([
  "turn/start",
  "turn/steer",
  "turn/interrupt",
  "thread/compact/start",
]);
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
  ["thread-follower-start-turn", 1],
  ["thread-follower-compact-thread", 1],
  ["thread-follower-steer-turn", 1],
  ["thread-follower-interrupt-turn", 1],
  ["thread-follower-command-approval-decision", 1],
  ["thread-follower-file-approval-decision", 1],
  ["thread-follower-submit-user-input", 1],
]);
const APPROVAL_DECISIONS = new Set(["accept", "acceptForSession", "decline", "cancel"]);

// Opens the Desktop IPC bus on demand and exposes Mac-owned pending actions as normal app-server requests.
function createDesktopIpcActionFollower({
  sendApplicationResponse,
  readConversationState = null,
  forwardToLocalCodex = null,
  normalizeTurnStartParams = (params) => params,
  logPrefix = "[remodex]",
  socketPath = resolveDefaultIpcSocketPath(),
  netModule = net,
  now = () => Date.now(),
  requestTimeoutMs = REQUEST_TIMEOUT_MS,
  ownershipProbeTimeoutMs = OWNERSHIP_PROBE_TIMEOUT_MS,
} = {}) {
  const ipc = createDesktopIpcClient({
    socketPath,
    netModule,
    now,
    requestTimeoutMs,
    logPrefix,
    onEnvelope,
    onConnected() {
      probeHeldFollowerRequests();
    },
    onDisconnect,
  });
  const rawStatesByThreadId = new Map();
  const conversationProjector = createDesktopConversationProjector({ now });
  const pendingRoutesByRequestId = new Map();
  const activeThreadIds = new Set();
  const recoveringThreadIds = new Set();
  const queuedChangesByThreadId = new Map();
  const liveOwnerThreadIds = new Set();
  const heldFollowerRequestsByThreadId = new Map();
  const ownershipProbeDeadlinesByThreadId = new Map();
  const pendingOwnershipProbeTokensByThreadId = new Map();
  const desktopOwnedByProbeThreadIds = new Set();
  let nextOwnershipProbeToken = 0;

  function observeInbound(rawMessage, parsedMessage = null) {
    const message = parsedMessage ?? safeParseJSON(rawMessage);
    const responseRoute = desktopRouteForResponse(message);
    if (responseRoute) {
      submitDesktopActionResponse(responseRoute, message);
      return true;
    }

    const method = readString(message?.method);
    if (DESKTOP_FOLLOWER_REQUEST_METHODS.has(method)) {
      const route = buildDesktopFollowerRoute(message);
      if (route && isDesktopRoutableThread(route.threadId)) {
        submitDesktopFollowerRequest(route, message);
        return true;
      }
      if (route && shouldHoldFollowerRequest(message, route.threadId)) {
        holdFollowerRequest(route.threadId, rawMessage);
        probeDesktopOwnership(route);
        return true;
      }
    }

    if (tryServeDesktopOwnedRead(message)) {
      return true;
    }

    if (!DESKTOP_STATE_READ_METHODS.has(method)) {
      return false;
    }

    const threadId = readThreadId(message?.params);
    if (!threadId) {
      return false;
    }

    activeThreadIds.add(threadId);
    if (!rawStatesByThreadId.has(threadId) && !liveOwnerThreadIds.has(threadId)) {
      ownershipProbeDeadlinesByThreadId.set(threadId, now() + ownershipProbeTimeoutMs);
    }
    ipc.ensureConnected();
    return false;
  }

  function stopAll() {
    rawStatesByThreadId.clear();
    conversationProjector.reset();
    pendingRoutesByRequestId.clear();
    activeThreadIds.clear();
    recoveringThreadIds.clear();
    queuedChangesByThreadId.clear();
    liveOwnerThreadIds.clear();
    ownershipProbeDeadlinesByThreadId.clear();
    pendingOwnershipProbeTokensByThreadId.clear();
    desktopOwnedByProbeThreadIds.clear();
    for (const queue of heldFollowerRequestsByThreadId.values()) {
      for (const entry of queue) {
        clearTimeout(entry.timer);
      }
    }
    heldFollowerRequestsByThreadId.clear();
    ipc.close();
  }

  // Desktop broadcasts carry the live conversation state Litter projects from.
  function onEnvelope(envelope) {
    if (envelope?.type === "broadcast"
      && (envelope.method === "thread-archived" || envelope.method === "thread-unarchived")) {
      syncThreadArchiveBroadcast(envelope);
      return;
    }
    if (envelope?.type !== "broadcast" || envelope.method !== "thread-stream-state-changed") {
      return;
    }

    const params = envelope.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    if (isRemodexLiveOwnerBroadcast(params)) {
      if (threadId) {
        if (params.remodexOwnerReleased === true) {
          removeDesktopThreadState(threadId);
        } else {
          releaseDesktopThreadState(threadId);
        }
      }
      return;
    }
    if (!threadId) {
      return;
    }
    const peerOwnershipSnapshot = isPeerOwnershipSnapshot(params);
    if (peerOwnershipSnapshot) {
      liveOwnerThreadIds.delete(threadId);
      ownershipProbeDeadlinesByThreadId.delete(threadId);
      desktopOwnedByProbeThreadIds.delete(threadId);
    } else if (liveOwnerThreadIds.has(threadId)) {
      return;
    }
    if (!activeThreadIds.has(threadId)) {
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
          conversationProjector.seed(threadId, speculativeState);
          syncProjectedActions(threadId, speculativeActions);
          releaseHeldFollowerRequests(threadId, { toDesktop: true });
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
    syncProjectedConversationState(threadId, nextState);
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
    releaseHeldFollowerRequests(threadId, { toDesktop: true });
  }

  function onDisconnect() {
    // Patch baselines are connection-scoped (Desktop re-sends a snapshot after
    // reconnect), but the projector cache is not: keeping it lets the reconnect
    // snapshot diff against already-mirrored content instead of replaying it.
    rawStatesByThreadId.clear();
    recoveringThreadIds.clear();
    queuedChangesByThreadId.clear();
    pendingOwnershipProbeTokensByThreadId.clear();
    desktopOwnedByProbeThreadIds.clear();
    // Keep pending approval routes too: a transient disconnect proves nothing
    // about the prompt's outcome, and falsely resolving it would dismiss a
    // still-blocking approval on the phone. Reconnect snapshots reconcile them.
    // Keep held turns queued: a disconnect proves nothing about ownership. Their
    // hold timers route them through the bus (with a reconnect attempt), and only
    // a proven delivery failure falls back to the local app-server.
  }

  // The bridge's own live owner just claimed this thread's stream, so drop stale
  // Desktop state instead of hijacking future phone requests into Desktop IPC.
  function releaseDesktopThreadState(threadId) {
    liveOwnerThreadIds.add(threadId);
    ownershipProbeDeadlinesByThreadId.delete(threadId);
    pendingOwnershipProbeTokensByThreadId.delete(threadId);
    desktopOwnedByProbeThreadIds.delete(threadId);
    syncProjectedActions(threadId, []);
    rawStatesByThreadId.delete(threadId);
    conversationProjector.remove(threadId);
    queuedChangesByThreadId.delete(threadId);
    releaseHeldFollowerRequests(threadId, { toDesktop: false });
  }

  // The live owner is releasing/removing its stream, not claiming it; cancel any
  // speculative phone request instead of routing it to either runtime.
  function removeDesktopThreadState(threadId) {
    liveOwnerThreadIds.delete(threadId);
    activeThreadIds.delete(threadId);
    ownershipProbeDeadlinesByThreadId.delete(threadId);
    pendingOwnershipProbeTokensByThreadId.delete(threadId);
    desktopOwnedByProbeThreadIds.delete(threadId);
    syncProjectedActions(threadId, []);
    rawStatesByThreadId.delete(threadId);
    conversationProjector.remove(threadId);
    queuedChangesByThreadId.delete(threadId);
    rejectHeldFollowerRequests(threadId, "This thread is no longer available for Desktop routing.");
  }

  // A just-resumed Desktop-owned thread has no snapshot yet, so hold phone turn
  // requests briefly instead of racing them into the local app-server. Holding is
  // bounded to a short window after resume so purely local threads stay fast.
  function shouldHoldFollowerRequest(message, threadId) {
    if (typeof forwardToLocalCodex !== "function" || message?.id == null) {
      return false;
    }
    if (!threadId
      || !activeThreadIds.has(threadId)
      || rawStatesByThreadId.has(threadId)
      || liveOwnerThreadIds.has(threadId)) {
      return false;
    }
    const probeDeadline = ownershipProbeDeadlinesByThreadId.get(threadId);
    if (!probeDeadline || now() > probeDeadline) {
      ownershipProbeDeadlinesByThreadId.delete(threadId);
      return false;
    }
    return true;
  }

  // Asks the IPC bus whether any client owns this thread so held requests resolve
  // as soon as possible instead of waiting out the full post-resume window.
  function probeDesktopOwnership(route) {
    const threadId = route.threadId;
    if (pendingOwnershipProbeTokensByThreadId.has(threadId)) {
      return;
    }
    const probeToken = ++nextOwnershipProbeToken;
    pendingOwnershipProbeTokensByThreadId.set(threadId, probeToken);
    ipc.sendDiscoveryRequest({
      type: "request",
      method: route.method,
      // Codex Desktop rejects discovery unless the nested request version matches
      // the method version, so mirror the normal request envelope here.
      version: METHOD_VERSION_BY_NAME.get(route.method) || 1,
      params: route.params,
    }, ownershipProbeTimeoutMs)
      .then((canHandle) => {
        if (pendingOwnershipProbeTokensByThreadId.get(threadId) !== probeToken) {
          return;
        }
        pendingOwnershipProbeTokensByThreadId.delete(threadId);
        if (liveOwnerThreadIds.has(threadId)) {
          return;
        }
        if (canHandle === true) {
          desktopOwnedByProbeThreadIds.add(threadId);
          releaseHeldFollowerRequests(threadId, { toDesktop: true });
          return;
        }
        // A negative discovery answer only means no currently connected client
        // claimed the request. Keep holding so the bounded timer can route the
        // request through the bus and only fall back locally after no-client-found.
      });
  }

  // IPC may finish connecting after the first probe returned no answer; retry
  // still-held phone turns once the bus can actually discover peer owners.
  function probeHeldFollowerRequests() {
    for (const [threadId, queue] of heldFollowerRequestsByThreadId.entries()) {
      if (!queue || queue.length === 0 || liveOwnerThreadIds.has(threadId)) {
        continue;
      }
      const message = safeParseJSON(queue[0].rawMessage);
      const route = message ? buildDesktopFollowerRoute(message) : null;
      if (route && shouldHoldFollowerRequest(message, threadId)) {
        probeDesktopOwnership(route);
      }
    }
  }

  function isDesktopRoutableThread(threadId) {
    return !liveOwnerThreadIds.has(threadId)
      && (rawStatesByThreadId.has(threadId) || desktopOwnedByProbeThreadIds.has(threadId));
  }

  function holdFollowerRequest(threadId, rawMessage) {
    const probeDeadline = ownershipProbeDeadlinesByThreadId.get(threadId) || 0;
    const message = safeParseJSON(rawMessage);
    const method = readString(message?.method);
    const entry = {
      rawMessage,
      timer: setTimeout(() => {
        const queue = heldFollowerRequestsByThreadId.get(threadId) || [];
        const index = queue.indexOf(entry);
        if (index < 0) {
          return;
        }
        queue.splice(index, 1);
        if (queue.length === 0) {
          heldFollowerRequestsByThreadId.delete(threadId);
        }
        routeExpiredHeldRequestThroughBus(rawMessage);
      }, Math.max(0, probeDeadline - now())),
    };
    entry.timer.unref?.();
    const queue = heldFollowerRequestsByThreadId.get(threadId) || [];
    if (method === "turn/start") {
      rejectQueuedHeldTurnStarts(queue);
    }
    queue.push(entry);
    heldFollowerRequestsByThreadId.set(threadId, queue);
  }

  function rejectQueuedHeldTurnStarts(queue) {
    for (let index = queue.length - 1; index >= 0; index -= 1) {
      const entry = queue[index];
      const message = safeParseJSON(entry.rawMessage);
      if (readString(message?.method) !== "turn/start") {
        continue;
      }
      queue.splice(index, 1);
      clearTimeout(entry.timer);
      rejectHeldFollowerRequest(message, "Superseded by a newer held turn/start request.");
    }
  }

  // Codex Desktop's real IPC router ignores client-origin discovery probes, so an
  // unanswered probe proves nothing. Route the expired request through the bus as
  // a normal request: the router discovers a Desktop owner itself, and a proven
  // no-handler error falls back to the local app-server via the delivery-failure
  // path instead of double-running the turn on both runtimes.
  function routeExpiredHeldRequestThroughBus(rawMessage) {
    const message = safeParseJSON(rawMessage);
    const route = message ? buildDesktopFollowerRoute(message) : null;
    if (route) {
      // The request is being routed definitively now, so a late discovery answer
      // must not retroactively mark the thread Desktop-owned.
      pendingOwnershipProbeTokensByThreadId.delete(route.threadId);
    }
    if (!route || liveOwnerThreadIds.has(route.threadId)) {
      forwardToLocalCodex(rawMessage);
      return;
    }
    submitDesktopFollowerRequest(route, message);
  }

  function releaseHeldFollowerRequests(threadId, { toDesktop } = {}) {
    const queue = heldFollowerRequestsByThreadId.get(threadId);
    if (!queue || queue.length === 0) {
      heldFollowerRequestsByThreadId.delete(threadId);
      return;
    }

    heldFollowerRequestsByThreadId.delete(threadId);
    let releasedTurnStart = false;
    for (const entry of queue) {
      clearTimeout(entry.timer);
      const originalMessage = safeParseJSON(entry.rawMessage);
      if (readString(originalMessage?.method) === "turn/start") {
        if (releasedTurnStart) {
          rejectHeldFollowerRequest(originalMessage, "Superseded by another held turn/start request.");
          continue;
        }
        releasedTurnStart = true;
      }
      const message = toDesktop ? originalMessage : null;
      const route = message ? buildDesktopFollowerRoute(message) : null;
      if (route && isDesktopRoutableThread(route.threadId)) {
        submitDesktopFollowerRequest(route, message);
      } else {
        forwardToLocalCodex?.(entry.rawMessage);
      }
    }
  }

  function rejectHeldFollowerRequests(threadId, reason) {
    const queue = heldFollowerRequestsByThreadId.get(threadId);
    if (!queue || queue.length === 0) {
      heldFollowerRequestsByThreadId.delete(threadId);
      return;
    }
    heldFollowerRequestsByThreadId.delete(threadId);
    for (const entry of queue) {
      clearTimeout(entry.timer);
      rejectHeldFollowerRequest(safeParseJSON(entry.rawMessage), reason);
    }
  }

  function rejectHeldFollowerRequest(message, reason) {
    if (message?.id == null) {
      return;
    }
    sendApplicationResponse(JSON.stringify({
      id: message.id,
      error: {
        code: -32000,
        message: reason,
      },
    }));
  }

  function syncProjectedActions(threadId, actions) {
    const nextRequestIds = new Set(actions.map((action) => action.id));
    for (const [requestId, route] of Array.from(pendingRoutesByRequestId.entries())) {
      if (route.threadId !== threadId || nextRequestIds.has(requestId)) {
        continue;
      }

      pendingRoutesByRequestId.delete(requestId);
      sendApplicationResponse(JSON.stringify(projectedResolvedNotification(threadId, requestId)));
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

  // Serves Desktop-owned history/read requests from the cached IPC snapshot so
  // mobile can backfill threads that only exist in Codex Desktop.
  function tryServeDesktopOwnedRead(message) {
    const method = readString(message?.method);
    if (!DESKTOP_STATE_READ_METHODS.has(method) || message?.id == null) {
      return false;
    }
    const threadId = readThreadId(message.params);
    if (!threadId || liveOwnerThreadIds.has(threadId)) {
      return false;
    }
    const rawState = rawStatesByThreadId.get(threadId);
    if (!rawState) {
      return false;
    }

    activeThreadIds.add(threadId);
    const thread = projectDesktopConversationStateToThread(threadId, rawState, { now });
    const result = method === "thread/turns/list"
      ? {
          data: cloneJSON(thread.turns || []),
          turns: cloneJSON(thread.turns || []),
          nextCursor: null,
          hasMore: false,
        }
      : {
          thread,
          conversationState: cloneJSON(rawState),
        };
    sendApplicationResponse(JSON.stringify({
      id: message.id,
      result,
    }));
    return true;
  }

  function syncProjectedConversationState(threadId, nextState) {
    const output = conversationProjector.project(threadId, nextState);
    if (output.type === "fullReplace" || output.type === "baseline") {
      // fullReplace: synthesized turn ids just became real, stale rows must go.
      // baseline: the projector cache was evicted, so updates that arrived while
      // unobserved were never mirrored. Both cases need the phone to rebuild the
      // thread from canonical history instead of trusting incremental rows.
      sendApplicationResponse(JSON.stringify({
        method: "thread/replaced",
        params: {
          threadId,
          thread: cloneJSON(output.thread || null),
          remodexDesktopMirror: true,
          remodexDesktopIpcMirror: true,
          remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
        },
      }));
    }
    for (const notification of output.notifications || []) {
      sendApplicationResponse(JSON.stringify(notification));
    }
  }

  function syncThreadArchiveBroadcast(envelope) {
    const params = envelope.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    if (!threadId) {
      return;
    }
    if (envelope.method === "thread-archived") {
      rawStatesByThreadId.delete(threadId);
      conversationProjector.remove(threadId);
      syncProjectedActions(threadId, []);
    }
    sendApplicationResponse(JSON.stringify({
      method: envelope.method === "thread-archived" ? "thread/archived" : "thread/unarchived",
      params: {
        threadId,
        conversationId: threadId,
        cwd: readString(params.cwd),
        remodexDesktopMirror: true,
        remodexDesktopIpcMirror: true,
        remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
      },
    }));
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
        sendApplicationResponse(JSON.stringify(
          projectedResolvedNotification(route.threadId, route.requestId)
        ));
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

  function buildDesktopFollowerRoute(message) {
    const requestId = requestIdKey(message?.id);
    if (!requestId) {
      return null;
    }
    const method = readString(message?.method);
    const params = message?.params && typeof message.params === "object" && !Array.isArray(message.params)
      ? message.params
      : {};
    const threadId = readThreadId(params);
    if (!threadId) {
      return null;
    }

    if (method === "turn/start") {
      return {
        threadId,
        method: "thread-follower-start-turn",
        params: {
          conversationId: threadId,
          senderRequestId: requestId,
          turnStartParams: params,
        },
      };
    }
    if (method === "turn/steer") {
      return {
        threadId,
        method: "thread-follower-steer-turn",
        params: {
          conversationId: threadId,
          input: Array.isArray(params.input) ? params.input : [],
          expectedTurnId: readString(params.expectedTurnId) || readString(params.expected_turn_id),
        },
      };
    }
    if (method === "turn/interrupt") {
      return {
        threadId,
        method: "thread-follower-interrupt-turn",
        params: {
          conversationId: threadId,
          turnId: readString(params.turnId) || readString(params.turn_id),
        },
      };
    }
    if (method === "thread/compact/start") {
      return {
        threadId,
        method: "thread-follower-compact-thread",
        params: {
          conversationId: threadId,
        },
      };
    }

    return null;
  }

  function submitDesktopFollowerRequest(route, originalMessage) {
    Promise.resolve()
      .then(() => resolveFollowerRequestParams(route))
      .then((params) => ipc.sendRequest(route.method, params))
      .then((result) => {
        sendApplicationResponse(JSON.stringify({
          id: originalMessage.id,
          result: result ?? null,
        }));
      })
      .catch((error) => {
        console.warn(`${logPrefix} desktop follower request failed: ${error.message}`);
        // Only rerun the request locally when we know Desktop never received it.
        // Timeouts and explicit remote errors stay errors: the turn may already be
        // running on Desktop, and executing it again locally would duplicate it.
        if (typeof forwardToLocalCodex === "function" && isDeliveryFailureError(error)) {
          const threadId = readString(route.threadId) || readString(route.params?.conversationId);
          if (threadId) {
            releaseDesktopThreadState(threadId);
          }
          forwardToLocalCodex(JSON.stringify(originalMessage));
          return;
        }
        sendApplicationResponse(JSON.stringify({
          id: originalMessage.id,
          error: {
            code: -32000,
            message: "Could not continue this Codex Desktop-owned thread from the phone.",
          },
        }));
      });
  }

  // Desktop-followed turn starts must apply the same param normalization as
  // requests forwarded straight to the local app-server.
  async function resolveFollowerRequestParams(route) {
    if (route.method !== "thread-follower-start-turn") {
      return route.params;
    }

    const normalized = await Promise.resolve(
      normalizeTurnStartParams(cloneJSON(route.params.turnStartParams))
    );
    const turnStartParams = normalized && typeof normalized === "object" && !Array.isArray(normalized)
      ? normalized
      : route.params.turnStartParams;
    return {
      ...route.params,
      turnStartParams,
    };
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
    if (baselineState && typeof baselineState === "object") {
      conversationProjector.seed(threadId, baselineState);
    }
    syncProjectedConversationState(threadId, nextState);
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
    releaseHeldFollowerRequests(threadId, { toDesktop: true });
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
  onConnected,
  onDisconnect,
}) {
  let socket = null;
  let clientId = "";
  let isConnecting = false;
  let readBuffer = Buffer.alloc(0);
  const pendingRequests = new Map();
  const pendingDiscoveries = new Map();

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
          onConnected?.(clientId);
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
      return Promise.reject(markDeliveryFailureError(new Error("Desktop IPC is not connected.")));
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
        reject(markDeliveryFailureError(error));
      });
    });
  }

  // Resolves true/false from a discovery answer, or null when nobody answers in
  // time, so callers can fall back to their own timers.
  function sendDiscoveryRequest(request, timeoutMs) {
    ensureConnected();
    if (!socket || socket.destroyed) {
      return Promise.resolve(null);
    }

    const requestId = `remodex-discovery-${now().toString(36)}-${Math.random().toString(16).slice(2)}`;
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        pendingDiscoveries.delete(requestId);
        resolve(null);
      }, timeoutMs);
      timeout.unref?.();

      pendingDiscoveries.set(requestId, {
        resolve,
        timeout,
      });
      writeEnvelope({
        type: "client-discovery-request",
        requestId,
        request,
      }, (error) => {
        if (!error) {
          return;
        }
        clearTimeout(timeout);
        pendingDiscoveries.delete(requestId);
        resolve(null);
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

    if (envelope.type === "client-discovery-response") {
      const requestId = requestIdKey(envelope.requestId);
      const pendingDiscovery = requestId ? pendingDiscoveries.get(requestId) : null;
      if (pendingDiscovery) {
        pendingDiscoveries.delete(requestId);
        clearTimeout(pendingDiscovery.timeout);
        pendingDiscovery.resolve(Boolean(envelope.response?.canHandle));
      }
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
        const error = new Error(envelope.error || `Desktop IPC request failed: ${waiter.method}`);
        // A no-handler routing error means the request never reached any client,
        // so callers may safely retry it against the local app-server. Codex
        // Desktop's router reports this case as "no-client-found".
        if (/no codex ipc client can handle|no-client-found/i.test(error.message)) {
          markDeliveryFailureError(error);
        }
        waiter.reject(error);
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
    for (const pendingDiscovery of pendingDiscoveries.values()) {
      clearTimeout(pendingDiscovery.timeout);
      pendingDiscovery.resolve(null);
    }
    pendingDiscoveries.clear();
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
    sendDiscoveryRequest,
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

function snapshotAssistantMessageTexts(conversationState) {
  return new Map(collectAssistantMessages(conversationState).map((message) => [message.key, message.text]));
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

function isAssistantMessageItem(item) {
  const type = normalizeToken(item?.type);
  if (type === "agentmessage" || type === "assistantmessage") {
    return true;
  }
  return type === "message" && normalizeToken(item?.role) === "assistant";
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
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
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

  // Copy-on-write: clone only the nodes along each patch path and share the
  // rest with the previous state. Besides skipping an O(state) deep clone per
  // broadcast, preserving the identity of untouched turns lets the projector
  // reuse their cached projection instead of re-diffing them.
  let nextState = shallowCloneNode(previousState);
  const clonedNodes = new Set([nextState]);
  for (const patch of patches) {
    if (Array.isArray(patch?.path) && patch.path.length === 0) {
      const op = readString(patch?.op).toLowerCase();
      if (op === "add" || op === "replace") {
        nextState = cloneJSON(patch.value);
        clonedNodes.clear();
        clonedNodes.add(nextState);
        continue;
      }
      return null;
    }
    if (!applyImmerPatchCopyOnWrite(nextState, patch, clonedNodes)) {
      return null;
    }
  }
  return nextState;
}

function shallowCloneNode(value) {
  return Array.isArray(value) ? value.slice() : { ...value };
}

function isPatchChange(change) {
  return change?.type === "patches" || change?.type === "Patches";
}

function isRemodexLiveOwnerBroadcast(params) {
  return readString(params?.remodexOwnerSource) === REMODEX_LIVE_OWNER_SOURCE;
}

// Resolutions of Desktop-owned prompts are mirror events too; the tags let iOS
// reconcile them without treating them as local runtime work.
function projectedResolvedNotification(threadId, requestId) {
  return {
    method: "serverRequest/resolved",
    params: {
      threadId,
      requestId,
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
      remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
    },
  };
}

function isPeerOwnershipSnapshot(params) {
  return !isRemodexLiveOwnerBroadcast(params) && normalizeToken(params?.change?.type) === "snapshot";
}

function markDeliveryFailureError(error) {
  error.remodexDeliveryFailed = true;
  return error;
}

function isDeliveryFailureError(error) {
  return error?.remodexDeliveryFailed === true;
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

function applyImmerPatchCopyOnWrite(target, patch, clonedNodes) {
  const patchPath = Array.isArray(patch?.path) ? patch.path : [];
  const op = readString(patch?.op).toLowerCase();
  if (!op || patchPath.length === 0) {
    return false;
  }

  let parent = target;
  for (let index = 0; index < patchPath.length - 1; index += 1) {
    const key = patchPath[index];
    const child = parent?.[key];
    if (child == null || typeof child !== "object") {
      return false;
    }
    if (clonedNodes.has(child)) {
      parent = child;
      continue;
    }
    const clonedChild = shallowCloneNode(child);
    clonedNodes.add(clonedChild);
    parent[key] = clonedChild;
    parent = clonedChild;
  }

  const key = patchPath[patchPath.length - 1];
  if (op === "remove") {
    if (Array.isArray(parent) && Number.isInteger(key)) {
      if (key < 0 || key >= parent.length) {
        return false;
      }
      parent.splice(key, 1);
      return true;
    } else if (parent && typeof parent === "object") {
      if (!Object.prototype.hasOwnProperty.call(parent, key)) {
        return false;
      }
      delete parent[key];
      return true;
    }
    return false;
  }

  if (op === "add" || op === "replace") {
    if (Array.isArray(parent) && Number.isInteger(key)) {
      if (op === "add") {
        if (key < 0 || key > parent.length) {
          return false;
        }
        parent.splice(key, 0, patch.value);
      } else {
        if (key < 0 || key >= parent.length) {
          return false;
        }
        parent[key] = patch.value;
      }
      return true;
    } else if (parent && typeof parent === "object") {
      parent[key] = patch.value;
      return true;
    }
  }
  return false;
}

function readThreadId(params) {
  return readString(params?.threadId)
    || readString(params?.thread_id)
    || readString(params?.conversationId)
    || readString(params?.conversation_id);
}

module.exports = {
  applyConversationStateChange,
  createDesktopIpcActionFollower,
  desktopFollowerPayloadForResponse,
  projectDesktopAssistantDeltaNotifications,
  projectPendingDesktopActions,
  resolveDefaultIpcSocketPath,
  seedConversationStateFromThreadRead,
};
