// FILE: desktop-ipc-live-owner.js
// Purpose: Exposes bridge-owned Codex app-server streams to Codex Desktop/VSCode over the local IPC bus.
// Layer: CLI helper
// Exports: createDesktopIpcLiveOwner, buildConversationStateFromThread, applyAppServerMessageToConversationState
// Depends on: crypto, fs, net, path, ./desktop-ipc-action-follower

const { randomUUID } = require("crypto");
const fs = require("fs");
const net = require("net");
const path = require("path");

const { resolveDefaultIpcSocketPath } = require("./desktop-ipc-action-follower");

const FRAME_HEADER_BYTES = 4;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
const DEFAULT_RECONNECT_MS = 1_500;
const DEFAULT_SNAPSHOT_DEBOUNCE_MS = 75;
const DEFAULT_MAX_PATCH_COUNT = 2_000;
const DEFAULT_MAX_PATCH_BYTES = 512 * 1024;
const DEFAULT_DISCOVERY_TIMEOUT_MS = 1_000;
const THREAD_STREAM_STATE_CHANGED = "thread-stream-state-changed";
const THREAD_ARCHIVED = "thread-archived";
const THREAD_UNARCHIVED = "thread-unarchived";
const CLIENT_STATUS_CHANGED = "client-status-changed";
const LOCAL_HOST_ID = "local";
const REMODEX_LIVE_OWNER_SOURCE = "desktop-ipc-live-owner";

const METHOD_VERSION_BY_NAME = new Map([
  ["initialize", 1],
  [CLIENT_STATUS_CHANGED, 1],
  [THREAD_STREAM_STATE_CHANGED, 6],
  [THREAD_ARCHIVED, 2],
  [THREAD_UNARCHIVED, 1],
  ["thread-follower-start-turn", 1],
  ["thread-follower-compact-thread", 1],
  ["thread-follower-steer-turn", 1],
  ["thread-follower-interrupt-turn", 1],
  ["thread-follower-set-model-and-reasoning", 1],
  ["thread-follower-set-collaboration-mode", 1],
  ["thread-follower-edit-last-user-turn", 1],
  ["thread-follower-command-approval-decision", 1],
  ["thread-follower-file-approval-decision", 1],
  ["thread-follower-permissions-request-approval-response", 1],
  ["thread-follower-submit-user-input", 1],
  ["thread-follower-submit-mcp-server-elicitation-response", 1],
  ["thread-follower-set-queued-follow-ups-state", 1],
  ["thread-queued-followups-changed", 1],
]);

const SUPPORTED_FOLLOWER_REQUEST_METHODS = new Set([
  "thread-follower-start-turn",
  "thread-follower-compact-thread",
  "thread-follower-steer-turn",
  "thread-follower-interrupt-turn",
  "thread-follower-set-model-and-reasoning",
  "thread-follower-set-collaboration-mode",
  "thread-follower-command-approval-decision",
  "thread-follower-file-approval-decision",
  "thread-follower-permissions-request-approval-response",
  "thread-follower-submit-user-input",
  "thread-follower-submit-mcp-server-elicitation-response",
  "thread-follower-set-queued-follow-ups-state",
]);

const OWNER_INBOUND_METHODS = new Set([
  "thread/start",
  "turn/start",
  "turn/steer",
  "turn/interrupt",
  "thread/compact/start",
  "thread/archive",
  "thread/unsubscribe",
]);

const THREAD_READ_METHODS = new Set(["thread/read", "thread/resume"]);

const REQUEST_METHODS_WITH_THREAD = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/fileRead/requestApproval",
  "item/permissions/requestApproval",
  "item/tool/requestUserInput",
  "mcpServer/elicitation/request",
  "item/tool/call",
]);

const ALLOWED_TURN_START_PARAM_KEYS = new Set([
  "threadId",
  "input",
  "cwd",
  "approvalPolicy",
  "approvalsReviewer",
  "sandboxPolicy",
  "model",
  "serviceTier",
  "effort",
  "summary",
  "personality",
  "outputSchema",
  "collaborationMode",
]);

function createDesktopIpcLiveOwner({
  enabled = true,
  hostId = LOCAL_HOST_ID,
  sendCodexRequest,
  sendRawCodexMessage,
  normalizeTurnStartParams = (params) => params,
  socketPath = resolveDefaultIpcSocketPath(),
  snapshotDebounceMs = DEFAULT_SNAPSHOT_DEBOUNCE_MS,
  maxPatchCount = DEFAULT_MAX_PATCH_COUNT,
  maxPatchBytes = DEFAULT_MAX_PATCH_BYTES,
  requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  reconnectMs = DEFAULT_RECONNECT_MS,
  netModule = net,
  now = () => Date.now(),
  logPrefix = "[remodex]",
} = {}) {
  if (!enabled || typeof sendCodexRequest !== "function" || typeof sendRawCodexMessage !== "function") {
    return createDisabledDesktopIpcLiveOwner();
  }

  const conversations = new Map();
  const ownedThreadIds = new Set();
  // Pending local thread/start requests in FIFO order, keyed by request id with
  // the requested cwd so notification-only thread/started events pair correctly.
  const pendingThreadStartRequestIds = new Map();
  const pendingThreadReadRequestIds = new Set();
  const pendingThreadHydrationsByThreadId = new Map();
  const cachedThreadsByThreadId = new Map();
  const lastBroadcastStatesByThreadId = new Map();
  const fallbackTurnIdsByThreadId = new Map();
  const pendingTurnStartParamsByThreadId = new Map();
  const pendingTurnStartEntriesByRequestId = new Map();
  const followerRuntimeOverridesByThreadId = new Map();
  const dirtyThreadIds = new Set();
  let snapshotTimer = null;

  const ipc = createDesktopOwnerIpcClient({
    socketPath,
    netModule,
    now,
    requestTimeoutMs,
    reconnectMs,
    logPrefix,
    onConnected() {
      broadcastAllOwnedSnapshots();
    },
    onBroadcast(envelope) {
      handlePeerBroadcast(envelope);
    },
    canHandleRequest(envelope) {
      return canHandleFollowerRequest(envelope);
    },
    handleRequest(envelope) {
      return handleFollowerRequest(envelope);
    },
  });

  function observeInbound(rawMessage) {
    const message = safeParseJSON(rawMessage);
    const method = readString(message?.method);
    if (THREAD_READ_METHODS.has(method)) {
      if (message?.id != null) {
        pendingThreadReadRequestIds.add(String(message.id));
      }
      return;
    }

    if (!method || !OWNER_INBOUND_METHODS.has(method)) {
      return;
    }

    if (method === "thread/start") {
      if (message?.id != null) {
        pendingThreadStartRequestIds.set(String(message.id), readString(message?.params?.cwd));
      }
      ipc.ensureConnected();
      return;
    }

    const threadId = readThreadIdFromParams(message?.params);
    if (!threadId) {
      return;
    }

    if (method === "thread/archive" || method === "thread/unsubscribe") {
      removeOwnedThread(threadId, { broadcastRemoval: true, reason: method });
      return;
    }

    const hadConversation = conversations.has(threadId);
    const hadCachedThread = cachedThreadsByThreadId.has(threadId);
    markOwnedThread(threadId);
    if (method === "turn/start") {
      rememberPendingTurnStart(threadId, message?.params, message?.id);
    }
    seedOwnedConversation(threadId, {
      cwd: readString(message?.params?.cwd),
    });
    if (!hadConversation && !hadCachedThread) {
      hydrateOwnedThreadFromRead(threadId);
    }
    scheduleSnapshot(threadId);
  }

  function observeOutbound(rawMessage) {
    const message = safeParseJSON(rawMessage);
    if (!message || typeof message !== "object") {
      return;
    }

    const responseId = message.id == null ? "" : String(message.id);
    if (responseId && !message.method) {
      resolvePendingTurnStartResponse(responseId, message);
    }
    if (responseId && pendingThreadReadRequestIds.has(responseId)) {
      pendingThreadReadRequestIds.delete(responseId);
      const thread = readThreadFromResponse(message);
      if (thread?.id) {
        cachedThreadsByThreadId.set(thread.id, cloneJSON(thread));
        if (ownedThreadIds.has(thread.id)) {
          upsertConversationFromThread(thread);
          scheduleSnapshot(thread.id);
        }
      }
    }

    if (responseId && pendingThreadStartRequestIds.has(responseId)) {
      pendingThreadStartRequestIds.delete(responseId);
      const thread = readThreadFromResponse(message);
      if (thread?.id) {
        markOwnedThread(thread.id);
        upsertConversationFromThread(thread);
        scheduleSnapshot(thread.id);
      }
    }
    claimStartedThreadForPendingLocalStart(message);

    const update = applyAppServerMessageToConversationState({
      conversations,
      fallbackTurnIdsByThreadId,
      pendingTurnStartParamsByThreadId,
      message,
      hostId,
      now,
      shouldOwnThread(threadId) {
        return ownedThreadIds.has(threadId);
      },
    });

    if (update?.threadId && update.changed) {
      scheduleSnapshot(update.threadId);
    }
  }

  function stopAll() {
    if (snapshotTimer) {
      clearTimeout(snapshotTimer);
      snapshotTimer = null;
    }
    dirtyThreadIds.clear();
    pendingThreadStartRequestIds.clear();
    pendingThreadReadRequestIds.clear();
    pendingThreadHydrationsByThreadId.clear();
    cachedThreadsByThreadId.clear();
    lastBroadcastStatesByThreadId.clear();
    fallbackTurnIdsByThreadId.clear();
    pendingTurnStartParamsByThreadId.clear();
    pendingTurnStartEntriesByRequestId.clear();
    followerRuntimeOverridesByThreadId.clear();
    ownedThreadIds.clear();
    conversations.clear();
    ipc.close();
  }

  // Phone-origin prompts only exist in the inbound turn/start params, so cache
  // them for the matching turn/started snapshot instead of losing the user row.
  // Entries are FIFO per thread so rapid consecutive starts keep their own prompt,
  // and failed starts are discarded so stale input never attaches to a later turn.
  function rememberPendingTurnStart(threadId, params, requestId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return null;
    }
    const normalizedRequestId = requestIdKey(requestId);
    const existingPending = normalizedRequestId ? pendingTurnStartEntriesByRequestId.get(normalizedRequestId) : null;
    if (existingPending?.threadId === normalizedThreadId) {
      return existingPending.entry;
    }
    const input = Array.isArray(params?.input) ? params.input : [];
    if (input.length === 0) {
      return null;
    }
    const entry = { params: sanitizeTurnStartParams(cloneJSON(params)) };
    const queue = pendingTurnStartParamsByThreadId.get(normalizedThreadId) || [];
    queue.push(entry);
    pendingTurnStartParamsByThreadId.set(normalizedThreadId, queue);
    if (normalizedRequestId) {
      pendingTurnStartEntriesByRequestId.set(normalizedRequestId, {
        threadId: normalizedThreadId,
        entry,
      });
    }
    return entry;
  }

  function discardPendingTurnStartEntry(threadId, entry) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !entry) {
      return;
    }
    const queue = pendingTurnStartParamsByThreadId.get(normalizedThreadId);
    if (!queue) {
      return;
    }
    const index = queue.indexOf(entry);
    if (index >= 0) {
      queue.splice(index, 1);
    }
    if (queue.length === 0) {
      pendingTurnStartParamsByThreadId.delete(normalizedThreadId);
    }
  }

  function resolvePendingTurnStartResponse(responseId, message) {
    const pending = pendingTurnStartEntriesByRequestId.get(responseId);
    if (!pending) {
      return;
    }
    pendingTurnStartEntriesByRequestId.delete(responseId);
    if (message.error) {
      discardPendingTurnStartEntry(pending.threadId, pending.entry);
    }
  }

  function markOwnedThread(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return;
    }
    ownedThreadIds.add(normalizedThreadId);
    ipc.ensureConnected();
  }

  // Notification-only thread/start paths do not echo a request id, so consume the
  // oldest pending local start whose cwd matches the started thread. Requiring a
  // cwd match keeps overlapping starts from claiming threads created elsewhere.
  function claimStartedThreadForPendingLocalStart(message) {
    if (readString(message?.method) !== "thread/started" || pendingThreadStartRequestIds.size === 0) {
      return;
    }
    const thread = message?.params?.thread;
    const threadId = readString(thread?.id);
    if (!threadId || ownedThreadIds.has(threadId)) {
      return;
    }
    const threadCwd = readString(thread?.cwd);
    for (const [pendingRequestId, pendingCwd] of pendingThreadStartRequestIds) {
      if (pendingCwd && threadCwd && pendingCwd !== threadCwd) {
        continue;
      }
      pendingThreadStartRequestIds.delete(pendingRequestId);
      markOwnedThread(threadId);
      return;
    }
  }

  function removeOwnedThread(threadId, { broadcastRemoval = false, reason = "" } = {}) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return;
    }
    if (broadcastRemoval && ownedThreadIds.has(normalizedThreadId)) {
      broadcastRemovedConversationState(normalizedThreadId, reason);
    }
    ownedThreadIds.delete(normalizedThreadId);
    conversations.delete(normalizedThreadId);
    cachedThreadsByThreadId.delete(normalizedThreadId);
    pendingThreadHydrationsByThreadId.delete(normalizedThreadId);
    lastBroadcastStatesByThreadId.delete(normalizedThreadId);
    fallbackTurnIdsByThreadId.delete(normalizedThreadId);
    pendingTurnStartParamsByThreadId.delete(normalizedThreadId);
    followerRuntimeOverridesByThreadId.delete(normalizedThreadId);
    for (const [requestId, pending] of Array.from(pendingTurnStartEntriesByRequestId.entries())) {
      if (pending.threadId === normalizedThreadId) {
        pendingTurnStartEntriesByRequestId.delete(requestId);
      }
    }
    dirtyThreadIds.delete(normalizedThreadId);
  }

  function broadcastRemovedConversationState(threadId, reason = "") {
    const previousState = conversations.get(threadId)
      || lastBroadcastStatesByThreadId.get(threadId)
      || createEmptyConversationState(threadId, { hostId, now });
    if (reason === "thread/archive") {
      ipc.sendBroadcast(THREAD_ARCHIVED, {
        hostId,
        conversationId: threadId,
        cwd: readString(previousState?.cwd),
      });
    }
    const removedState = {
      ...cloneJSON(previousState),
      id: threadId,
      hostId,
      turns: [],
      requests: [],
      hasUnreadTurn: false,
      unreadMessageCount: 0,
      updatedAt: now(),
      remodexRemoved: true,
      remodexRemovalReason: reason || null,
      archived: reason === "thread/archive" || Boolean(previousState?.archived),
      unsubscribed: reason === "thread/unsubscribe" || Boolean(previousState?.unsubscribed),
    };
    ipc.sendBroadcast(THREAD_STREAM_STATE_CHANGED, {
      hostId,
      conversationId: threadId,
      version: METHOD_VERSION_BY_NAME.get(THREAD_STREAM_STATE_CHANGED) || 1,
      remodexOwnerSource: REMODEX_LIVE_OWNER_SOURCE,
      remodexOwnerReleased: true,
      change: {
        type: "snapshot",
        conversationState: removedState,
      },
    });
  }

  function upsertConversationFromThread(thread) {
    const threadId = readString(thread?.id);
    if (!threadId) {
      return null;
    }
    const previous = conversations.get(threadId) || null;
    const next = buildConversationStateFromThread(thread, {
      previous,
      hostId,
      now,
    });
    conversations.set(threadId, next);
    return next;
  }

  function ensureConversation(threadId, seed = {}) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return null;
    }
    let conversation = conversations.get(normalizedThreadId);
    if (!conversation) {
      conversation = createEmptyConversationState(normalizedThreadId, {
        hostId,
        now,
        cwd: seed.cwd,
      });
      conversations.set(normalizedThreadId, conversation);
    }
    return conversation;
  }

  function seedOwnedConversation(threadId, seed = {}) {
    const normalizedThreadId = readString(threadId);
    const existingConversation = normalizedThreadId ? conversations.get(normalizedThreadId) : null;
    if (existingConversation) {
      return existingConversation;
    }
    const cachedThread = normalizedThreadId ? cachedThreadsByThreadId.get(normalizedThreadId) : null;
    if (cachedThread) {
      return upsertConversationFromThread(cachedThread);
    }
    return ensureConversation(normalizedThreadId, seed);
  }

  function scheduleSnapshot(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !ownedThreadIds.has(normalizedThreadId)) {
      return;
    }
    dirtyThreadIds.add(normalizedThreadId);
    ipc.ensureConnected();
    if (snapshotTimer) {
      return;
    }
    snapshotTimer = setTimeout(() => {
      snapshotTimer = null;
      flushSnapshots();
    }, Math.max(0, snapshotDebounceMs));
    snapshotTimer.unref?.();
  }

  function flushSnapshots() {
    const pendingThreadIds = Array.from(dirtyThreadIds);
    dirtyThreadIds.clear();
    for (const threadId of pendingThreadIds) {
      if (pendingThreadHydrationsByThreadId.has(threadId)) {
        dirtyThreadIds.add(threadId);
        continue;
      }
      if (!broadcastConversationState(threadId)) {
        // Keep unsent snapshots dirty so the reconnect rebroadcast can retry them.
        dirtyThreadIds.add(threadId);
      }
    }
  }

  function hydrateOwnedThreadFromRead(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || pendingThreadHydrationsByThreadId.has(normalizedThreadId)) {
      return;
    }
    const hydration = Promise.resolve()
      .then(() => sendCodexRequest("thread/read", { threadId: normalizedThreadId }))
      .then((result) => {
        const thread = readThreadFromPayload(result);
        if (!thread?.id) {
          return;
        }
        cachedThreadsByThreadId.set(thread.id, cloneJSON(thread));
        if (ownedThreadIds.has(thread.id)) {
          upsertConversationFromThread(thread);
        }
      })
      .catch((error) => {
        console.warn(`${logPrefix} desktop IPC live owner thread/read hydration failed for ${normalizedThreadId}: ${error?.message || "unknown error"}`);
      })
      .finally(() => {
        pendingThreadHydrationsByThreadId.delete(normalizedThreadId);
        if (dirtyThreadIds.has(normalizedThreadId) && ownedThreadIds.has(normalizedThreadId)) {
          scheduleSnapshot(normalizedThreadId);
        }
      });
    pendingThreadHydrationsByThreadId.set(normalizedThreadId, hydration);
  }

  function broadcastAllOwnedSnapshots() {
    for (const threadId of ownedThreadIds) {
      if (pendingThreadHydrationsByThreadId.has(threadId)) {
        dirtyThreadIds.add(threadId);
        continue;
      }
      if (broadcastConversationState(threadId, { forceSnapshot: true })) {
        dirtyThreadIds.delete(threadId);
      } else {
        dirtyThreadIds.add(threadId);
      }
    }
  }

  // Returns false only when a pending state change could not be delivered yet.
  function broadcastConversationState(threadId, { forceSnapshot = false } = {}) {
    const conversationState = conversations.get(threadId);
    if (!conversationState || !ownedThreadIds.has(threadId)) {
      return true;
    }
    const currentState = cloneJSON(conversationState);
    const previousState = lastBroadcastStatesByThreadId.get(threadId) || null;
    if (!forceSnapshot && previousState) {
      const patches = buildConversationStatePatches(previousState, currentState, {
        maxPatchCount,
        maxPatchBytes,
      });
      if (patches && patches.length === 0) {
        return true;
      }
      if (patches && ipc.sendBroadcast(THREAD_STREAM_STATE_CHANGED, {
        hostId,
        conversationId: threadId,
        version: METHOD_VERSION_BY_NAME.get(THREAD_STREAM_STATE_CHANGED) || 1,
        remodexOwnerSource: REMODEX_LIVE_OWNER_SOURCE,
        change: {
          type: "patches",
          patches,
        },
      })) {
        lastBroadcastStatesByThreadId.set(threadId, currentState);
        return true;
      }
    }

    if (ipc.sendBroadcast(THREAD_STREAM_STATE_CHANGED, {
      hostId,
      conversationId: threadId,
      version: METHOD_VERSION_BY_NAME.get(THREAD_STREAM_STATE_CHANGED) || 1,
      remodexOwnerSource: REMODEX_LIVE_OWNER_SOURCE,
      change: {
        type: "snapshot",
        conversationState: currentState,
      },
    })) {
      lastBroadcastStatesByThreadId.set(threadId, currentState);
      return true;
    }
    return false;
  }

  function handlePeerBroadcast(envelope) {
    if (envelope?.method === CLIENT_STATUS_CHANGED) {
      broadcastAllOwnedSnapshots();
      return;
    }
    if (envelope?.method !== THREAD_STREAM_STATE_CHANGED) {
      return;
    }
    const params = envelope.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    if (!threadId || !ownedThreadIds.has(threadId)) {
      return;
    }
    if (envelope.sourceClientId && envelope.sourceClientId === ipc.clientId) {
      return;
    }
    if (!isPeerOwnershipBroadcast(params)) {
      return;
    }

    // Another Codex frontend is actively owning this stream. Drop bridge ownership
    // and all cached conversation state so a later re-claim rehydrates fresh data
    // instead of republishing stale turns and requests.
    removeOwnedThread(threadId);
  }

  function isPeerOwnershipBroadcast(params) {
    if (readString(params?.remodexOwnerSource) === REMODEX_LIVE_OWNER_SOURCE) {
      return false;
    }
    const changeType = normalizeToken(params?.change?.type);
    return changeType === "snapshot";
  }

  function canHandleFollowerRequest(envelope) {
    const method = readString(envelope?.request?.method || envelope?.method);
    const params = envelope?.request?.params || envelope?.params || {};
    if (!SUPPORTED_FOLLOWER_REQUEST_METHODS.has(method)) {
      return false;
    }
    const threadId = readConversationIdFromFollowerParams(params);
    return Boolean(threadId && ownedThreadIds.has(threadId));
  }

  async function handleFollowerRequest(envelope) {
    const method = readString(envelope?.method);
    const params = envelope?.params && typeof envelope.params === "object" ? envelope.params : {};
    const conversationId = readConversationIdFromFollowerParams(params);
    if (!conversationId || !ownedThreadIds.has(conversationId)) {
      throw new Error("conversation-not-owned");
    }

    switch (method) {
      case "thread-follower-start-turn":
        return await handleFollowerStartTurn(conversationId, params);
      case "thread-follower-compact-thread":
        return await sendCodexRequest("thread/compact/start", { threadId: conversationId });
      case "thread-follower-steer-turn":
        return await handleFollowerSteerTurn(conversationId, params);
      case "thread-follower-interrupt-turn":
        return await handleFollowerInterruptTurn(conversationId, params);
      case "thread-follower-command-approval-decision":
        return sendServerRequestResponse(conversationId, params.requestId, { decision: params.decision });
      case "thread-follower-file-approval-decision":
        return sendServerRequestResponse(
          conversationId,
          params.requestId,
          followerApprovalResultForRequest(conversationId, params)
        );
      case "thread-follower-permissions-request-approval-response":
        return sendServerRequestResponse(conversationId, params.requestId, params.response);
      case "thread-follower-submit-user-input":
        return sendServerRequestResponse(conversationId, params.requestId, params.response);
      case "thread-follower-submit-mcp-server-elicitation-response":
        return sendServerRequestResponse(conversationId, params.requestId, params.response);
      case "thread-follower-set-model-and-reasoning":
        return applyFollowerModelAndReasoning(conversationId, params);
      case "thread-follower-set-collaboration-mode":
        return applyFollowerCollaborationMode(conversationId, params);
      case "thread-follower-set-queued-follow-ups-state":
        // Refuse instead of acknowledging: silently dropping queued follow-ups
        // would make Desktop believe they will run after the current turn.
        throw new Error("thread-follower-set-queued-follow-ups-state is not supported by Remodex yet.");
      case "thread-follower-edit-last-user-turn":
        throw new Error("thread-follower-edit-last-user-turn is not supported by Remodex yet.");
      default:
        throw new Error(`Unsupported follower request: ${method}`);
    }
  }

  async function handleFollowerStartTurn(conversationId, params) {
    const rawTurnStartParams = params.turnStartParams
      || params.turn_start_params
      || params.turnStart
      || params;
    const codexParams = mergeFollowerRuntimeOverrides(conversationId, sanitizeTurnStartParams({
      ...rawTurnStartParams,
      threadId: conversationId,
    }));
    const normalizedParams = await Promise.resolve(normalizeTurnStartParams(cloneJSON(codexParams)));
    const nextCodexParams = normalizedParams && typeof normalizedParams === "object" && !Array.isArray(normalizedParams)
      ? normalizedParams
      : codexParams;
    markOwnedThread(conversationId);
    const pendingEntry = rememberPendingTurnStart(
      conversationId,
      nextCodexParams,
      params.senderRequestId || params.sender_request_id
    );
    try {
      return await sendCodexRequest("turn/start", nextCodexParams);
    } catch (error) {
      discardPendingTurnStartEntry(conversationId, pendingEntry);
      throw error;
    }
  }

  async function handleFollowerSteerTurn(conversationId, params) {
    const rawSteerParams = params.turnSteerParams
      || params.turn_steer_params
      || params;
    const expectedTurnId = readString(rawSteerParams.expectedTurnId)
      || readString(rawSteerParams.expected_turn_id)
      || activeTurnIdForConversation(conversationId);
    if (!expectedTurnId) {
      throw new Error("Missing expectedTurnId for follower steer request.");
    }
    return await sendCodexRequest("turn/steer", {
      threadId: conversationId,
      input: Array.isArray(rawSteerParams.input) ? rawSteerParams.input : [],
      expectedTurnId,
    });
  }

  async function handleFollowerInterruptTurn(conversationId, params) {
    const turnId = readString(params.turnId)
      || readString(params.turn_id)
      || activeTurnIdForConversation(conversationId);
    if (!turnId) {
      throw new Error("Missing turnId for follower interrupt request.");
    }
    return await sendCodexRequest("turn/interrupt", {
      threadId: conversationId,
      turnId,
    });
  }

  // Desktop follower approvals only carry decision-style payloads, but app-server
  // permission prompts expect a grant object, mirroring the phone response path.
  function followerApprovalResultForRequest(conversationId, params) {
    const requestId = requestIdKey(params.requestId);
    const pendingRequest = (conversations.get(conversationId)?.requests || [])
      .find((request) => requestIdKey(request?.id) === requestId);
    if (readString(pendingRequest?.method) !== "item/permissions/requestApproval") {
      return { decision: params.decision };
    }

    const decision = readString(params.decision);
    const grantsRequestedPermissions = decision === "accept" || decision === "acceptForSession";
    const requestedPermissions = pendingRequest?.params?.permissions;
    return {
      permissions: grantsRequestedPermissions && isPlainJSONObject(requestedPermissions)
        ? cloneJSON(requestedPermissions)
        : {},
      scope: decision === "acceptForSession" ? "session" : "turn",
    };
  }

  function sendServerRequestResponse(conversationId, requestId, result) {
    const normalizedRequestId = requestIdKey(requestId);
    if (!normalizedRequestId) {
      throw new Error("Missing requestId for follower server response.");
    }
    // Desktop may echo a coerced (stringified) request id; reply with the exact
    // id the app-server used so the pending server request actually resolves.
    const pendingRequest = (conversations.get(conversationId)?.requests || [])
      .find((request) => requestIdKey(request?.id) === normalizedRequestId);
    sendRawCodexMessage(JSON.stringify({
      id: pendingRequest ? pendingRequest.id : requestId,
      result: result || {},
    }));
    return { ok: true };
  }

  // Desktop runtime option changes are persisted as per-thread overrides and
  // merged into later Desktop-origin turn starts, so acknowledging them is honest
  // instead of a cosmetic broadcast-only update.
  function applyFollowerModelAndReasoning(conversationId, params) {
    const overrides = followerRuntimeOverridesByThreadId.get(conversationId) || {};
    const conversation = conversations.get(conversationId);
    if (Object.prototype.hasOwnProperty.call(params, "model")) {
      overrides.model = readString(params.model);
      if (conversation) {
        conversation.latestModel = overrides.model;
      }
    }
    if (Object.prototype.hasOwnProperty.call(params, "reasoningEffort")) {
      overrides.effort = params.reasoningEffort || null;
      if (conversation) {
        conversation.latestReasoningEffort = overrides.effort;
      }
    }
    followerRuntimeOverridesByThreadId.set(conversationId, overrides);
    if (conversation) {
      scheduleSnapshot(conversationId);
    }
    return { ok: true };
  }

  function applyFollowerCollaborationMode(conversationId, params) {
    if (!params.collaborationMode) {
      return { ok: true };
    }
    const overrides = followerRuntimeOverridesByThreadId.get(conversationId) || {};
    overrides.collaborationMode = cloneJSON(params.collaborationMode);
    followerRuntimeOverridesByThreadId.set(conversationId, overrides);
    const conversation = conversations.get(conversationId);
    if (conversation) {
      conversation.latestCollaborationMode = cloneJSON(params.collaborationMode);
      scheduleSnapshot(conversationId);
    }
    return { ok: true };
  }

  // Fills follower turn-start params with Desktop-selected runtime overrides when
  // the request itself does not specify them. Phone-origin turns are untouched.
  function mergeFollowerRuntimeOverrides(conversationId, params) {
    const overrides = followerRuntimeOverridesByThreadId.get(conversationId);
    if (!overrides) {
      return params;
    }
    const merged = { ...params };
    if (overrides.model && !readString(merged.model)) {
      merged.model = overrides.model;
    }
    if (overrides.effort != null && merged.effort == null) {
      merged.effort = overrides.effort;
    }
    if (overrides.collaborationMode && merged.collaborationMode == null) {
      merged.collaborationMode = cloneJSON(overrides.collaborationMode);
    }
    return merged;
  }

  function activeTurnIdForConversation(conversationId) {
    const turns = conversations.get(conversationId)?.turns || [];
    for (let index = turns.length - 1; index >= 0; index -= 1) {
      const turn = turns[index];
      const status = normalizeToken(turn?.status);
      const turnId = readString(turn?.turnId) || readString(turn?.id);
      if (turnId && (!status || status === "inprogress" || status === "running" || status === "active")) {
        return turnId;
      }
    }
    const latestTurn = turns[turns.length - 1];
    return readString(latestTurn?.turnId) || readString(latestTurn?.id);
  }

  return {
    observeInbound,
    observeOutbound,
    stopAll,
    _debugSnapshot(threadId) {
      return cloneJSON(conversations.get(threadId) || null);
    },
  };
}

function createDisabledDesktopIpcLiveOwner() {
  return {
    observeInbound() {},
    observeOutbound() {},
    stopAll() {},
  };
}

function resolveTurnForConversation({
  conversation,
  turn,
  method,
  fallbackTurnIdsByThreadId,
  now = () => Date.now(),
} = {}) {
  const explicitTurnId = readTurnIdFromTurn(turn);
  if (explicitTurnId) {
    promoteFallbackTurnId(conversation, fallbackTurnIdsByThreadId, explicitTurnId);
    return turn;
  }

  const fallbackTurnId = readFallbackTurnId(conversation?.id, fallbackTurnIdsByThreadId)
    || (method === "turn/started" ? createSyntheticTurnId(conversation?.id, now) : "");
  if (!fallbackTurnId) {
    return turn;
  }
  fallbackTurnIdsByThreadId?.set(conversation.id, fallbackTurnId);
  if (method === "turn/completed") {
    fallbackTurnIdsByThreadId?.delete(conversation.id);
  }

  // Some app-server builds start turns before they know the canonical turn id.
  // Keep one stable row alive until a later event can promote it to the real id.
  return {
    ...turn,
    id: fallbackTurnId,
    turnId: fallbackTurnId,
    remodexSyntheticTurnId: true,
  };
}

function resolveTurnIdForParams({
  conversation,
  params,
  fallbackTurnIdsByThreadId,
} = {}) {
  const explicitTurnId = readTurnIdFromParams(params);
  if (explicitTurnId) {
    promoteFallbackTurnId(conversation, fallbackTurnIdsByThreadId, explicitTurnId);
    return explicitTurnId;
  }
  const fallbackTurnId = readFallbackTurnId(conversation?.id, fallbackTurnIdsByThreadId);
  if (fallbackTurnId) {
    return fallbackTurnId;
  }
  return "";
}

function promoteFallbackTurnId(conversation, fallbackTurnIdsByThreadId, explicitTurnId) {
  const conversationId = readString(conversation?.id);
  const fallbackTurnId = readFallbackTurnId(conversationId, fallbackTurnIdsByThreadId);
  if (!conversationId || !fallbackTurnId || !explicitTurnId || fallbackTurnId === explicitTurnId) {
    fallbackTurnIdsByThreadId?.delete(conversationId);
    return;
  }

  const fallbackTurn = conversation.turns.find((candidate) => (
    readString(candidate?.turnId) || readString(candidate?.id)
  ) === fallbackTurnId);
  if (fallbackTurn) {
    fallbackTurn.id = explicitTurnId;
    fallbackTurn.turnId = explicitTurnId;
    delete fallbackTurn.remodexSyntheticTurnId;
  }
  fallbackTurnIdsByThreadId?.delete(conversationId);
}

function readFallbackTurnId(threadId, fallbackTurnIdsByThreadId) {
  const normalizedThreadId = readString(threadId);
  return normalizedThreadId && fallbackTurnIdsByThreadId instanceof Map
    ? readString(fallbackTurnIdsByThreadId.get(normalizedThreadId))
    : "";
}

function createSyntheticTurnId(threadId, now = () => Date.now()) {
  const normalizedThreadId = readString(threadId) || "thread";
  return `remodex-live-turn:${normalizedThreadId}:${now()}:${randomUUID()}`;
}

function applyAppServerMessageToConversationState({
  conversations,
  fallbackTurnIdsByThreadId = null,
  pendingTurnStartParamsByThreadId = null,
  message,
  hostId = LOCAL_HOST_ID,
  now = () => Date.now(),
  shouldOwnThread = () => false,
} = {}) {
  const method = readString(message?.method);
  if (!method) {
    return null;
  }

  if (REQUEST_METHODS_WITH_THREAD.has(method) && message.id != null) {
    const threadId = readThreadIdFromParams(message.params);
    if (!threadId || !shouldOwnThread(threadId)) {
      return null;
    }
    const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
    upsertRequest(conversation, {
      id: message.id,
      method,
      params: cloneJSON(message.params || {}),
    });
    conversation.hasUnreadTurn = true;
    conversation.updatedAt = now();
    return { threadId, changed: true };
  }

  switch (method) {
    case "thread/started": {
      const thread = message.params?.thread;
      const threadId = readString(thread?.id);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const previous = conversations.get(threadId) || null;
      conversations.set(threadId, buildConversationStateFromThread(thread, {
        previous,
        hostId,
        now,
      }));
      return { threadId, changed: true };
    }
    case "thread/name/updated": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      conversation.title = readString(message.params?.threadName)
        || readString(message.params?.thread_name)
        || conversation.title;
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "thread/status/changed": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      conversation.threadRuntimeStatus = cloneJSON(message.params?.status || null);
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "thread/tokenUsage/updated": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      conversation.latestTokenUsageInfo = cloneJSON(
        message.params?.tokenUsage || message.params?.usage || null
      );
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "turn/started":
    case "turn/completed": {
      const threadId = readThreadIdFromParams(message.params);
      const turn = message.params?.turn;
      if (!threadId || !shouldOwnThread(threadId) || !turn) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      const upsertedTurn = upsertTurn(conversation, resolveTurnForConversation({
        conversation,
        turn,
        method,
        fallbackTurnIdsByThreadId,
        now,
      }), { now });
      if (method === "turn/started") {
        applyPendingTurnStartParams(conversation, upsertedTurn, pendingTurnStartParamsByThreadId);
      }
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "turn/diff/updated": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      const turn = ensureTurn(conversation, resolveTurnIdForParams({
        conversation,
        params: message.params,
        fallbackTurnIdsByThreadId,
        now,
      }), { now });
      if (turn) {
        turn.diff = readString(message.params?.diff) || "";
      }
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "turn/plan/updated": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      const turn = ensureTurn(conversation, resolveTurnIdForParams({
        conversation,
        params: message.params,
        fallbackTurnIdsByThreadId,
        now,
      }), { now });
      if (turn) {
        upsertItem(turn, {
          id: `todo-list-${message.params?.turnId || now()}`,
          type: "todo-list",
          explanation: message.params?.explanation ?? null,
          plan: Array.isArray(message.params?.plan) ? cloneJSON(message.params.plan) : [],
        });
      }
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "item/started":
    case "item/completed": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      const turn = ensureTurn(conversation, resolveTurnIdForParams({
        conversation,
        params: message.params,
        fallbackTurnIdsByThreadId,
        now,
      }), { now });
      if (turn && message.params?.item) {
        upsertItem(turn, cloneJSON(message.params.item));
        if (message.params.item.type === "agentMessage" && method === "item/started") {
          turn.finalAssistantStartedAtMs = turn.finalAssistantStartedAtMs || now();
        }
        if (message.params.item.type && message.params.item.type !== "userMessage") {
          turn.firstTurnWorkItemStartedAtMs = turn.firstTurnWorkItemStartedAtMs || now();
        }
      }
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "item/agentMessage/delta":
    case "item/plan/delta":
    case "item/reasoning/summaryTextDelta":
    case "item/reasoning/textDelta":
    case "item/fileChange/outputDelta":
    case "item/commandExecution/outputDelta":
    case "command/exec/outputDelta": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      applyDeltaNotification(conversation, method, message.params || {}, {
        fallbackTurnIdsByThreadId,
        now,
      });
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "serverRequest/resolved": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      const requestId = requestIdKey(message.params?.requestId || message.params?.request_id);
      conversation.requests = conversation.requests.filter((request) => requestIdKey(request.id) !== requestId);
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    case "error": {
      const threadId = readThreadIdFromParams(message.params);
      if (!threadId || !shouldOwnThread(threadId)) {
        return null;
      }
      const conversation = ensureConversationInMap(conversations, threadId, { hostId, now });
      const turn = ensureTurn(conversation, resolveTurnIdForParams({
        conversation,
        params: message.params,
        fallbackTurnIdsByThreadId,
        now,
      }), { now });
      if (turn) {
        turn.items.push({
          id: `error-${now()}`,
          type: "error",
          message: readString(message.params?.error?.message) || "Codex error",
          willRetry: Boolean(message.params?.willRetry),
          errorInfo: message.params?.error?.codexErrorInfo || null,
          additionalDetails: message.params?.error?.additionalDetails || null,
        });
        turn.error = cloneJSON(message.params?.error || null);
      }
      conversation.updatedAt = now();
      return { threadId, changed: true };
    }
    default:
      return null;
  }
}

function buildConversationStateFromThread(thread, {
  previous = null,
  hostId = LOCAL_HOST_ID,
  now = () => Date.now(),
} = {}) {
  const threadId = readString(thread?.id);
  const createdAtMs = timestampSecondsToMs(thread?.createdAt) || previous?.createdAt || now();
  const updatedAtMs = timestampSecondsToMs(thread?.updatedAt) || now();
  const cwd = readString(thread?.cwd) || previous?.cwd || "";
  const latestModel = readString(thread?.model) || readString(thread?.modelProvider) || previous?.latestModel || "";
  const turns = mergeConversationTurnsFromThread(thread?.turns, {
    previousTurns: previous?.turns,
    threadId,
    cwd,
    now,
  });

  return {
    id: threadId,
    hostId,
    turns,
    requests: cloneJSON(previous?.requests || []),
    createdAt: createdAtMs,
    updatedAt: updatedAtMs,
    title: readString(thread?.name) || previous?.title || null,
    latestModel,
    latestReasoningEffort: previous?.latestReasoningEffort || null,
    previousTurnModel: previous?.previousTurnModel || null,
    latestCollaborationMode: previous?.latestCollaborationMode || {
      mode: "default",
      settings: {
        reasoning_effort: null,
        model: latestModel,
        developer_instructions: null,
      },
    },
    hasUnreadTurn: Boolean(previous?.hasUnreadTurn),
    unreadMessageCount: Number.isFinite(previous?.unreadMessageCount) ? previous.unreadMessageCount : 0,
    threadGoal: previous?.threadGoal || null,
    completedThreadGoal: previous?.completedThreadGoal || null,
    threadRuntimeStatus: cloneJSON(thread?.status || previous?.threadRuntimeStatus || null),
    rolloutPath: readString(thread?.path) || previous?.rolloutPath || "",
    cwd,
    gitInfo: cloneJSON(thread?.gitInfo || previous?.gitInfo || null),
    resumeState: "resumed",
    latestTokenUsageInfo: cloneJSON(previous?.latestTokenUsageInfo || null),
    workspaceKind: previous?.workspaceKind || "project",
    workspaceBrowserRoot: previous?.workspaceBrowserRoot || null,
    projectlessOutputDirectory: previous?.projectlessOutputDirectory || null,
    currentPermissions: cloneJSON(previous?.currentPermissions || null),
  };
}

function mergeConversationTurnsFromThread(threadTurns, {
  previousTurns = [],
  threadId = "",
  cwd = "",
  now = () => Date.now(),
} = {}) {
  const previousList = Array.isArray(previousTurns) ? previousTurns : [];
  if (!Array.isArray(threadTurns) || threadTurns.length === 0) {
    return cloneJSON(previousList);
  }

  const mergedById = new Map();
  previousList.forEach((turn, index) => {
    const turnId = readString(turn?.turnId) || readString(turn?.id);
    if (!turnId) {
      return;
    }
    mergedById.set(turnId, {
      turn: cloneJSON(turn),
      order: index,
    });
  });

  threadTurns.forEach((turn, index) => {
    const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
    if (!turnId) {
      return;
    }
    const previous = mergedById.get(turnId);
    const previousTurn = previous?.turn || null;
    mergedById.set(turnId, {
      turn: buildConversationTurn(turn, {
        threadId,
        cwd,
        previousTurn,
        now,
      }),
      order: previous?.order ?? previousList.length + index,
    });
  });

  return Array.from(mergedById.values())
    .sort((left, right) => {
      const leftStartedAt = Number(left.turn?.turnStartedAtMs);
      const rightStartedAt = Number(right.turn?.turnStartedAtMs);
      if (Number.isFinite(leftStartedAt)
        && Number.isFinite(rightStartedAt)
        && leftStartedAt !== rightStartedAt) {
        return leftStartedAt - rightStartedAt;
      }
      return left.order - right.order;
    })
    .map((entry) => entry.turn);
}

function createEmptyConversationState(threadId, {
  hostId = LOCAL_HOST_ID,
  now = () => Date.now(),
  cwd = "",
} = {}) {
  const timestamp = now();
  return {
    id: threadId,
    hostId,
    turns: [],
    requests: [],
    createdAt: timestamp,
    updatedAt: timestamp,
    title: null,
    latestModel: "",
    latestReasoningEffort: null,
    previousTurnModel: null,
    latestCollaborationMode: {
      mode: "default",
      settings: {
        reasoning_effort: null,
        model: "",
        developer_instructions: null,
      },
    },
    hasUnreadTurn: false,
    unreadMessageCount: 0,
    threadGoal: null,
    completedThreadGoal: null,
    threadRuntimeStatus: null,
    rolloutPath: "",
    cwd: readString(cwd) || "",
    gitInfo: null,
    resumeState: "resumed",
    latestTokenUsageInfo: null,
    workspaceKind: "project",
    workspaceBrowserRoot: null,
    projectlessOutputDirectory: null,
    currentPermissions: null,
  };
}

function buildConversationTurn(turn, {
  threadId = "",
  cwd = "",
  previousTurn = null,
  now = () => Date.now(),
} = {}) {
  const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
  const params = cloneJSON(previousTurn?.params || {
    threadId,
    input: [],
    cwd: cwd || null,
    approvalPolicy: null,
    approvalsReviewer: null,
    sandboxPolicy: null,
    model: null,
    serviceTier: null,
    effort: null,
    summary: "none",
    personality: null,
    outputSchema: null,
    collaborationMode: null,
    attachments: [],
  });
  return {
    id: turnId,
    turnId,
    params,
    turnStartedAtMs: timestampSecondsToMs(turn?.startedAt) || previousTurn?.turnStartedAtMs || now(),
    durationMs: turn?.durationMs ?? previousTurn?.durationMs ?? null,
    firstTurnWorkItemStartedAtMs: previousTurn?.firstTurnWorkItemStartedAtMs || null,
    finalAssistantStartedAtMs: previousTurn?.finalAssistantStartedAtMs || null,
    status: turn?.status || previousTurn?.status || "inProgress",
    error: cloneJSON(turn?.error || previousTurn?.error || null),
    diff: previousTurn?.diff || null,
    hookRuns: cloneJSON(previousTurn?.hookRuns || []),
    commandExecutionStartedAtMsById: cloneJSON(previousTurn?.commandExecutionStartedAtMsById || {}),
    items: Array.isArray(turn?.items) && turn.items.length > 0
      ? cloneJSON(turn.items)
      : cloneJSON(previousTurn?.items || []),
  };
}

// Reattaches the cached turn/start prompt to a just-started turn so Desktop
// followers still see the user message when turn/started arrives with no items.
// Pending prompts are consumed FIFO so rapid consecutive starts stay matched.
function applyPendingTurnStartParams(conversation, turn, pendingTurnStartParamsByThreadId) {
  if (!turn || !(pendingTurnStartParamsByThreadId instanceof Map)) {
    return;
  }
  const threadId = readString(conversation?.id);
  const queue = threadId ? pendingTurnStartParamsByThreadId.get(threadId) : null;
  const pendingEntry = Array.isArray(queue) ? queue.shift() : null;
  if (Array.isArray(queue) && queue.length === 0) {
    pendingTurnStartParamsByThreadId.delete(threadId);
  }
  const pendingParams = pendingEntry?.params;
  if (!pendingParams) {
    return;
  }

  const input = Array.isArray(pendingParams.input) ? cloneJSON(pendingParams.input) : [];
  if (input.length === 0) {
    return;
  }

  turn.params = {
    ...turn.params,
    ...cloneJSON(pendingParams),
  };
  if (turnHasUserMessageItem(turn)) {
    return;
  }
  const turnId = readString(turn.turnId) || readString(turn.id) || "turn";
  turn.items.unshift({
    id: `user-message-${turnId}`,
    type: "userMessage",
    remodexSyntheticUserMessage: true,
    content: input.map(userMessageContentFromTurnInput).filter(Boolean),
  });
}

function turnHasUserMessageItem(turn) {
  return turn.items.some((item) => isUserMessageItem(item));
}

function isUserMessageItem(item) {
  const type = normalizeToken(item?.type);
  return type === "usermessage"
    || (type === "message" && normalizeToken(item?.role) === "user");
}

// Matched via an explicit marker instead of the item id so the synthetic row is
// still recognized after a fallback turn id gets promoted to the real turn id.
function isSyntheticUserMessageItem(item) {
  return isUserMessageItem(item) && item?.remodexSyntheticUserMessage === true;
}

function userMessageContentFromTurnInput(entry) {
  if (!entry || typeof entry !== "object") {
    return null;
  }
  const type = normalizeToken(entry.type);
  if (type === "inputtext" || type === "text") {
    return { type: "text", text: readString(entry.text) };
  }
  return cloneJSON(entry);
}

function ensureConversationInMap(conversations, threadId, options = {}) {
  let conversation = conversations.get(threadId);
  if (!conversation) {
    conversation = createEmptyConversationState(threadId, options);
    conversations.set(threadId, conversation);
  }
  return conversation;
}

function upsertTurn(conversation, turn, { now = () => Date.now() } = {}) {
  const turnId = readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
  if (!turnId) {
    return null;
  }
  const index = conversation.turns.findIndex((candidate) => (
    readString(candidate?.turnId) || readString(candidate?.id)
  ) === turnId);
  const previousTurn = index >= 0 ? conversation.turns[index] : null;
  const nextTurn = buildConversationTurn(turn, {
    threadId: conversation.id,
    cwd: conversation.cwd,
    previousTurn,
    now,
  });
  if (index >= 0) {
    conversation.turns[index] = nextTurn;
  } else {
    conversation.turns.push(nextTurn);
  }
  return nextTurn;
}

function ensureTurn(conversation, turnId, { now = () => Date.now() } = {}) {
  const normalizedTurnId = readString(turnId);
  if (!normalizedTurnId) {
    return conversation.turns[conversation.turns.length - 1] || null;
  }
  let turn = conversation.turns.find((candidate) => (
    readString(candidate?.turnId) || readString(candidate?.id)
  ) === normalizedTurnId);
  if (!turn) {
    turn = buildConversationTurn({
      id: normalizedTurnId,
      status: "inProgress",
      items: [],
      startedAt: null,
      completedAt: null,
      durationMs: null,
      error: null,
    }, {
      threadId: conversation.id,
      cwd: conversation.cwd,
      now,
    });
    conversation.turns.push(turn);
  }
  return turn;
}

function upsertItem(turn, item) {
  const itemId = readString(item?.id);
  if (!itemId) {
    return;
  }
  const index = turn.items.findIndex((candidate) => readString(candidate?.id) === itemId);
  if (index >= 0) {
    turn.items[index] = {
      ...turn.items[index],
      ...cloneJSON(item),
    };
    return;
  }
  if (isUserMessageItem(item)) {
    // Replace the synthetic prompt row in place so the canonical user message
    // keeps its position instead of jumping below already-streamed items.
    const syntheticIndex = turn.items.findIndex((candidate) => isSyntheticUserMessageItem(candidate));
    if (syntheticIndex >= 0) {
      turn.items[syntheticIndex] = cloneJSON(item);
      return;
    }
  }
  turn.items.push(cloneJSON(item));
}

function upsertRequest(conversation, request) {
  const requestId = requestIdKey(request?.id);
  if (!requestId) {
    return;
  }
  const index = conversation.requests.findIndex((candidate) => requestIdKey(candidate?.id) === requestId);
  const nextRequest = cloneJSON({
    id: request.id,
    method: request.method,
    params: request.params || {},
  });
  if (index >= 0) {
    conversation.requests[index] = nextRequest;
  } else {
    conversation.requests.push(nextRequest);
  }
}

function applyDeltaNotification(conversation, method, params, {
  fallbackTurnIdsByThreadId = null,
  now = () => Date.now(),
} = {}) {
  const turn = ensureTurn(conversation, resolveTurnIdForParams({
    conversation,
    params,
    fallbackTurnIdsByThreadId,
    now,
  }), { now });
  if (!turn) {
    return;
  }
  const itemId = readString(params.itemId) || readString(params.item_id);
  if (!itemId) {
    return;
  }
  const delta = typeof params.delta === "string" ? params.delta : "";
  if (!delta) {
    return;
  }

  if (method === "item/agentMessage/delta") {
    const item = ensureItemOfType(turn, itemId, () => ({
      type: "agentMessage",
      id: itemId,
      text: "",
      phase: null,
      memoryCitation: null,
    }));
    item.text = `${item.text || ""}${delta}`;
    turn.finalAssistantStartedAtMs = turn.finalAssistantStartedAtMs || now();
    return;
  }

  if (method === "item/plan/delta") {
    const item = ensureItemOfType(turn, itemId, () => ({
      type: "plan",
      id: itemId,
      text: "",
    }));
    item.text = `${item.text || ""}${delta}`;
    return;
  }

  if (method === "item/reasoning/summaryTextDelta" || method === "item/reasoning/textDelta") {
    const item = ensureItemOfType(turn, itemId, () => ({
      type: "reasoning",
      id: itemId,
      summary: [],
      content: [],
    }));
    if (method === "item/reasoning/summaryTextDelta") {
      const index = Number.isInteger(params.summaryIndex) ? params.summaryIndex : 0;
      item.summary = growArray(item.summary, index, "");
      item.summary[index] = `${item.summary[index] || ""}${delta}`;
    } else {
      const index = Number.isInteger(params.contentIndex) ? params.contentIndex : 0;
      item.content = growArray(item.content, index, "");
      item.content[index] = `${item.content[index] || ""}${delta}`;
    }
    return;
  }

  if (method === "item/fileChange/outputDelta") {
    const item = ensureItemOfType(turn, itemId, () => ({
      type: "fileChange",
      id: itemId,
      changes: [],
      status: "inProgress",
      aggregatedOutput: "",
    }));
    item.aggregatedOutput = `${item.aggregatedOutput || ""}${delta}`;
    return;
  }

  const item = ensureItemOfType(turn, itemId, () => ({
    type: "commandExecution",
    id: itemId,
    command: "",
    cwd: conversation.cwd || "/",
    processId: null,
    source: "exec",
    status: "inProgress",
    commandActions: [],
    aggregatedOutput: "",
    exitCode: null,
    durationMs: null,
  }));
  item.aggregatedOutput = `${item.aggregatedOutput || ""}${delta}`;
}

function ensureItemOfType(turn, itemId, createItem) {
  let item = turn.items.find((candidate) => readString(candidate?.id) === itemId);
  if (!item) {
    item = createItem();
    turn.items.push(item);
  }
  return item;
}

function growArray(value, index, fillValue) {
  const next = Array.isArray(value) ? value : [];
  while (next.length <= index) {
    next.push(fillValue);
  }
  return next;
}

function buildConversationStatePatches(previousState, currentState, {
  maxPatchCount = DEFAULT_MAX_PATCH_COUNT,
  maxPatchBytes = DEFAULT_MAX_PATCH_BYTES,
} = {}) {
  if (!previousState || typeof previousState !== "object" || !currentState || typeof currentState !== "object") {
    return null;
  }
  const patches = [];
  const ok = collectJSONPatches(previousState, currentState, [], patches, maxPatchCount);
  if (!ok) {
    return null;
  }
  if (patches.length === 0) {
    return patches;
  }
  const patchBytes = Buffer.byteLength(JSON.stringify(patches), "utf8");
  if (patchBytes > maxPatchBytes) {
    return null;
  }
  return patches;
}

function collectJSONPatches(previousValue, currentValue, pathParts, patches, maxPatchCount) {
  if (jsonValuesEqual(previousValue, currentValue)) {
    return true;
  }
  if (patches.length > maxPatchCount) {
    return false;
  }

  if (Array.isArray(previousValue) || Array.isArray(currentValue)) {
    if (!Array.isArray(previousValue) || !Array.isArray(currentValue)) {
      return pushPatch(patches, maxPatchCount, {
        op: "replace",
        path: pathParts,
        value: cloneJSON(currentValue),
      });
    }
    return collectArrayPatches(previousValue, currentValue, pathParts, patches, maxPatchCount);
  }

  if (isPlainJSONObject(previousValue) || isPlainJSONObject(currentValue)) {
    if (!isPlainJSONObject(previousValue) || !isPlainJSONObject(currentValue)) {
      return pushPatch(patches, maxPatchCount, {
        op: "replace",
        path: pathParts,
        value: cloneJSON(currentValue),
      });
    }
    return collectObjectPatches(previousValue, currentValue, pathParts, patches, maxPatchCount);
  }

  return pushPatch(patches, maxPatchCount, {
    op: "replace",
    path: pathParts,
    value: cloneJSON(currentValue),
  });
}

function collectArrayPatches(previousArray, currentArray, pathParts, patches, maxPatchCount) {
  const sharedLength = Math.min(previousArray.length, currentArray.length);
  for (let index = 0; index < sharedLength; index += 1) {
    if (!collectJSONPatches(previousArray[index], currentArray[index], [...pathParts, index], patches, maxPatchCount)) {
      return false;
    }
  }
  for (let index = previousArray.length - 1; index >= currentArray.length; index -= 1) {
    if (!pushPatch(patches, maxPatchCount, {
      op: "remove",
      path: [...pathParts, index],
    })) {
      return false;
    }
  }
  for (let index = sharedLength; index < currentArray.length; index += 1) {
    if (!pushPatch(patches, maxPatchCount, {
      op: "add",
      path: [...pathParts, index],
      value: cloneJSON(currentArray[index]),
    })) {
      return false;
    }
  }
  return true;
}

function collectObjectPatches(previousObject, currentObject, pathParts, patches, maxPatchCount) {
  for (const key of Object.keys(previousObject)) {
    if (Object.prototype.hasOwnProperty.call(currentObject, key)) {
      continue;
    }
    if (!pushPatch(patches, maxPatchCount, {
      op: "remove",
      path: [...pathParts, key],
    })) {
      return false;
    }
  }

  for (const key of Object.keys(currentObject)) {
    if (!Object.prototype.hasOwnProperty.call(previousObject, key)) {
      if (!pushPatch(patches, maxPatchCount, {
        op: "add",
        path: [...pathParts, key],
        value: cloneJSON(currentObject[key]),
      })) {
        return false;
      }
      continue;
    }
    if (!collectJSONPatches(previousObject[key], currentObject[key], [...pathParts, key], patches, maxPatchCount)) {
      return false;
    }
  }
  return true;
}

function pushPatch(patches, maxPatchCount, patch) {
  if (patch.path.length === 0) {
    return false;
  }
  patches.push(patch);
  return patches.length <= maxPatchCount;
}

function isPlainJSONObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function jsonValuesEqual(left, right) {
  if (left === right) {
    return true;
  }
  if (left == null || right == null) {
    return left === right;
  }
  if (typeof left !== "object" || typeof right !== "object") {
    return false;
  }
  return false;
}

function createDesktopOwnerIpcClient({
  socketPath,
  netModule,
  now,
  requestTimeoutMs,
  reconnectMs,
  logPrefix,
  startRouterWhenMissing = true,
  onConnected,
  onBroadcast,
  canHandleRequest,
  handleRequest,
}) {
  let socket = null;
  let isConnecting = false;
  let isInitialized = false;
  let clientId = "";
  let readBuffer = Buffer.alloc(0);
  let reconnectTimer = null;
  let shouldReconnect = false;
  const localRouter = startRouterWhenMissing
    ? createDesktopIpcRouterServer({
      socketPath,
      netModule,
      now,
      requestTimeoutMs,
      discoveryTimeoutMs: Math.min(requestTimeoutMs, DEFAULT_DISCOVERY_TIMEOUT_MS),
      logPrefix,
    })
    : null;
  const pendingResponses = new Map();

  function ensureConnected() {
    shouldReconnect = true;
    if (socket || isConnecting) {
      return;
    }
    clearReconnectTimer();
    isConnecting = true;
    const nextSocket = netModule.createConnection(socketPath);
    socket = nextSocket;

    nextSocket.on("connect", () => {
      isConnecting = false;
      sendRequest("initialize", { clientType: "remodex-bridge" }, { initializing: true })
        .then((result) => {
          clientId = readString(result?.clientId) || clientId;
          isInitialized = true;
          onConnected?.(clientId);
        })
        .catch((error) => {
          console.warn(`${logPrefix} desktop IPC live owner initialize failed: ${error.message}`);
          closeSocket();
        });
    });
    nextSocket.on("data", handleData);
    nextSocket.on("close", () => handleClose(nextSocket));
    nextSocket.on("error", (error) => {
      if (error?.code === "ENOENT" || error?.code === "ECONNREFUSED") {
        startLocalRouterAfterMissingSocket(error.code);
        return;
      }
      if (error?.code !== "ENOENT" && error?.code !== "ECONNREFUSED") {
        console.warn(`${logPrefix} desktop IPC live owner connection failed: ${error.message}`);
      }
    });
  }

  function startLocalRouterAfterMissingSocket(reasonCode) {
    if (!localRouter || localRouter.isStarted) {
      return;
    }
    localRouter.start({ removeStaleSocket: reasonCode === "ECONNREFUSED" })
      .then(() => {
        if (!shouldReconnect) {
          return;
        }
        closeSocket();
        isConnecting = false;
        clearReconnectTimer();
        ensureConnected();
      })
      .catch((error) => {
        if (error?.code !== "EADDRINUSE") {
          console.warn(`${logPrefix} desktop IPC router fallback failed: ${error.message}`);
        }
      });
  }

  function sendBroadcast(method, params) {
    ensureConnected();
    if (!socket || socket.destroyed || !isInitialized) {
      return false;
    }
    const envelope = {
      type: "broadcast",
      method,
      sourceClientId: clientId,
      params: params || {},
      version: METHOD_VERSION_BY_NAME.get(method) || 1,
    };
    return writeEnvelope(envelope);
  }

  function sendRequest(method, params, { initializing = false } = {}) {
    ensureConnected();
    if (!socket || socket.destroyed) {
      return Promise.reject(new Error("Desktop IPC is not connected."));
    }
    const requestId = `remodex-owner-${now().toString(36)}-${randomUUID()}`;
    const envelope = {
      type: "request",
      requestId,
      sourceClientId: initializing ? "initializing-client" : clientId || "remodex-bridge",
      version: METHOD_VERSION_BY_NAME.get(method) || 1,
      method,
      params: params || {},
    };
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        pendingResponses.delete(requestId);
        reject(new Error(`Desktop IPC request timed out: ${method}`));
      }, requestTimeoutMs);
      timeout.unref?.();
      pendingResponses.set(requestId, {
        method,
        resolve,
        reject,
        timeout,
      });
      if (!writeEnvelope(envelope)) {
        clearTimeout(timeout);
        pendingResponses.delete(requestId);
        reject(new Error("Desktop IPC write failed."));
      }
    });
  }

  function handleData(chunk) {
    readBuffer = Buffer.concat([readBuffer, chunk]);
    while (readBuffer.length >= FRAME_HEADER_BYTES) {
      const frameLength = readBuffer.readUInt32LE(0);
      if (frameLength > MAX_FRAME_BYTES) {
        closeSocket();
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
    if (envelope.type === "response") {
      handleResponse(envelope);
      return;
    }
    if (envelope.type === "broadcast") {
      onBroadcast?.(envelope);
      return;
    }
    if (envelope.type === "client-discovery-request") {
      const canHandle = Boolean(canHandleRequest?.(envelope));
      writeEnvelope({
        type: "client-discovery-response",
        requestId: envelope.requestId,
        response: { canHandle },
      });
      return;
    }
    if (envelope.type === "request") {
      handleIncomingRequest(envelope);
    }
  }

  function handleResponse(envelope) {
    const requestId = requestIdKey(envelope.requestId);
    const waiter = requestId ? pendingResponses.get(requestId) : null;
    if (!waiter) {
      return;
    }
    pendingResponses.delete(requestId);
    clearTimeout(waiter.timeout);
    if (envelope.resultType === "error") {
      waiter.reject(new Error(envelope.error || `Desktop IPC request failed: ${waiter.method}`));
      return;
    }
    waiter.resolve(envelope.result ?? null);
  }

  function handleIncomingRequest(envelope) {
    Promise.resolve()
      .then(() => handleRequest(envelope))
      .then((result) => {
        writeEnvelope({
          type: "response",
          requestId: envelope.requestId,
          resultType: "success",
          method: envelope.method,
          handledByClientId: clientId,
          result: result ?? null,
        });
      })
      .catch((error) => {
        writeEnvelope({
          type: "response",
          requestId: envelope.requestId,
          resultType: "error",
          method: envelope.method,
          handledByClientId: clientId,
          error: error?.message || "Remodex IPC owner request failed.",
        });
      });
  }

  function handleClose(closedSocket) {
    if (socket && socket !== closedSocket) {
      return;
    }
    socket = null;
    isConnecting = false;
    isInitialized = false;
    clientId = "";
    readBuffer = Buffer.alloc(0);
    for (const waiter of pendingResponses.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error("Desktop IPC connection closed."));
    }
    pendingResponses.clear();
    scheduleReconnect();
  }

  function scheduleReconnect() {
    if (!shouldReconnect || reconnectTimer) {
      return;
    }
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      ensureConnected();
    }, reconnectMs);
    reconnectTimer.unref?.();
  }

  function clearReconnectTimer() {
    if (!reconnectTimer) {
      return;
    }
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  function closeSocket() {
    if (!socket) {
      return;
    }
    const closingSocket = socket;
    socket = null;
    closingSocket.destroy();
  }

  function close() {
    shouldReconnect = false;
    clearReconnectTimer();
    closeSocket();
    localRouter?.close();
    for (const waiter of pendingResponses.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error("Desktop IPC live owner stopped."));
    }
    pendingResponses.clear();
  }

  function writeEnvelope(envelope) {
    if (!socket || socket.destroyed) {
      return false;
    }
    try {
      writeFrame(socket, JSON.stringify(envelope));
      return true;
    } catch {
      closeSocket();
      return false;
    }
  }

  return {
    ensureConnected,
    sendBroadcast,
    close,
    get clientId() {
      return clientId;
    },
  };
}

function createDesktopIpcRouterServer({
  socketPath,
  netModule,
  now,
  requestTimeoutMs,
  discoveryTimeoutMs,
  logPrefix,
}) {
  let server = null;
  let started = false;
  let starting = null;
  let closed = false;
  let nextClientSeq = 1;
  const clientsById = new Map();
  const pendingDiscoveryResponses = new Map();
  const pendingRoutedResponses = new Map();

  function start({ removeStaleSocket = false } = {}) {
    if (started) {
      return Promise.resolve();
    }
    if (starting) {
      return starting;
    }
    closed = false;
    starting = new Promise((resolve, reject) => {
      try {
        prepareSocketPathForListen(socketPath, { removeStaleSocket });
      } catch (error) {
        starting = null;
        reject(error);
        return;
      }

      const nextServer = netModule.createServer((socket) => attachClient(socket));
      server = nextServer;
      nextServer.on("error", (error) => {
        starting = null;
        server = null;
        reject(error);
      });
      nextServer.listen(socketPath, () => {
        started = true;
        starting = null;
        nextServer.removeAllListeners("error");
        nextServer.on("error", (error) => {
          console.warn(`${logPrefix} desktop IPC router fallback error: ${error.message}`);
        });
        resolve();
      });
      nextServer.unref?.();
    });
    return starting;
  }

  function attachClient(socket) {
    const client = {
      id: "",
      type: "",
      socket,
      buffer: Buffer.alloc(0),
      initialized: false,
    };
    socket.on("data", (chunk) => handleClientData(client, chunk));
    socket.on("close", () => removeClient(client));
    socket.on("error", () => removeClient(client));
  }

  function handleClientData(client, chunk) {
    client.buffer = Buffer.concat([client.buffer, chunk]);
    while (client.buffer.length >= FRAME_HEADER_BYTES) {
      const frameLength = client.buffer.readUInt32LE(0);
      if (frameLength > MAX_FRAME_BYTES) {
        client.socket.destroy();
        return;
      }
      if (client.buffer.length < FRAME_HEADER_BYTES + frameLength) {
        return;
      }

      const payload = client.buffer.slice(FRAME_HEADER_BYTES, FRAME_HEADER_BYTES + frameLength).toString("utf8");
      client.buffer = client.buffer.slice(FRAME_HEADER_BYTES + frameLength);
      const envelope = safeParseJSON(payload);
      if (envelope) {
        dispatchClientEnvelope(client, envelope);
      }
    }
  }

  function dispatchClientEnvelope(client, envelope) {
    if (envelope.type === "request" && envelope.method === "initialize") {
      initializeClient(client, envelope);
      return;
    }
    if (envelope.type === "broadcast") {
      relayBroadcast(client, envelope);
      return;
    }
    if (envelope.type === "request") {
      routeClientRequest(client, envelope);
      return;
    }
    if (envelope.type === "response") {
      routeClientResponse(client, envelope);
      return;
    }
    if (envelope.type === "client-discovery-request") {
      answerClientDiscoveryRequest(client, envelope);
      return;
    }
    if (envelope.type === "client-discovery-response") {
      resolveDiscoveryResponse(envelope);
    }
  }

  function initializeClient(client, envelope) {
    if (!client.id) {
      client.id = `remodex-router-${now().toString(36)}-${nextClientSeq}`;
      nextClientSeq += 1;
      clientsById.set(client.id, client);
    }
    client.initialized = true;
    client.type = readString(envelope.params?.clientType) || readString(envelope.params?.client_type);
    writeEnvelopeToClient(client, {
      type: "response",
      requestId: envelope.requestId,
      resultType: "success",
      method: "initialize",
      handledByClientId: "remodex-ipc-router",
      result: { clientId: client.id },
    });
    relayBroadcast(client, {
      type: "broadcast",
      method: CLIENT_STATUS_CHANGED,
      sourceClientId: client.id,
      version: METHOD_VERSION_BY_NAME.get(CLIENT_STATUS_CHANGED) || 1,
      params: {
        clientId: client.id,
        clientType: client.type,
        status: "connected",
      },
    });
  }

  function relayBroadcast(sender, envelope) {
    const normalizedEnvelope = {
      ...envelope,
      sourceClientId: readString(envelope.sourceClientId) || sender.id,
      version: envelope.version || METHOD_VERSION_BY_NAME.get(envelope.method) || 1,
    };
    for (const client of clientsById.values()) {
      if (!client.initialized || client === sender) {
        continue;
      }
      writeEnvelopeToClient(client, normalizedEnvelope);
    }
  }

  async function routeClientRequest(sender, envelope) {
    const target = await discoverTargetForRequest(sender, envelope);
    if (!target) {
      writeEnvelopeToClient(sender, {
        type: "response",
        requestId: envelope.requestId,
        resultType: "error",
        method: envelope.method,
        handledByClientId: "",
        error: `No Codex IPC client can handle ${envelope.method}.`,
      });
      return;
    }
    const requestId = requestIdKey(envelope.requestId);
    if (!requestId) {
      writeEnvelopeToClient(sender, {
        type: "response",
        requestId: envelope.requestId,
        resultType: "error",
        method: envelope.method,
        handledByClientId: target.id,
        error: "Missing requestId.",
      });
      return;
    }

    // JSON-RPC request ids are only unique per connection, so forward a rewritten
    // router-scoped id to keep concurrent same-id requests from colliding.
    const routedRequestId = `remodex-routed-${now().toString(36)}-${randomUUID()}`;
    const routeKey = routedResponseKey(target.id, routedRequestId);
    const timeout = setTimeout(() => {
      pendingRoutedResponses.delete(routeKey);
      writeEnvelopeToClient(sender, {
        type: "response",
        requestId: envelope.requestId,
        resultType: "error",
        method: envelope.method,
        handledByClientId: target.id,
        error: `Codex IPC routed request timed out: ${envelope.method}`,
      });
    }, requestTimeoutMs);
    timeout.unref?.();
    pendingRoutedResponses.set(routeKey, {
      sender,
      senderRequestId: envelope.requestId,
      timeout,
    });
    if (!writeEnvelopeToClient(target, {
      ...envelope,
      requestId: routedRequestId,
      sourceClientId: sender.id,
    })) {
      clearTimeout(timeout);
      pendingRoutedResponses.delete(routeKey);
      writeEnvelopeToClient(sender, {
        type: "response",
        requestId: envelope.requestId,
        resultType: "error",
        method: envelope.method,
        handledByClientId: target.id,
        error: "Codex IPC routed request write failed.",
      });
    }
  }

  function routeClientResponse(client, envelope) {
    const routeKey = routedResponseKey(client.id, requestIdKey(envelope.requestId));
    const route = pendingRoutedResponses.get(routeKey);
    if (!route) {
      return;
    }
    pendingRoutedResponses.delete(routeKey);
    clearTimeout(route.timeout);
    writeEnvelopeToClient(route.sender, {
      ...envelope,
      requestId: route.senderRequestId,
    });
  }

  async function answerClientDiscoveryRequest(sender, envelope) {
    const target = await discoverTargetForRequest(sender, envelope.request || envelope);
    writeEnvelopeToClient(sender, {
      type: "client-discovery-response",
      requestId: envelope.requestId,
      response: {
        canHandle: Boolean(target),
      },
    });
  }

  async function discoverTargetForRequest(sender, request) {
    const candidates = Array.from(clientsById.values()).filter((client) => (
      client.initialized && client !== sender && !client.socket.destroyed
    ));
    const results = await Promise.all(candidates.map(async (candidate, index) => {
      const canHandle = await askClientCanHandle(candidate, request);
      return canHandle ? { client: candidate, index } : null;
    }));
    return results
      .filter(Boolean)
      .sort(compareDiscoveryTargets)[0]?.client || null;
  }

  function compareDiscoveryTargets(left, right) {
    const priorityDelta = discoveryTargetPriority(left.client) - discoveryTargetPriority(right.client);
    return priorityDelta || left.index - right.index;
  }

  function discoveryTargetPriority(client) {
    // If both sides claim a follower request, the bridge's tagged live owner wins
    // over stale Desktop state to keep phone-owned streams on the local runtime.
    return normalizeToken(client?.type) === "remodexbridge" ? 0 : 1;
  }

  function askClientCanHandle(client, request) {
    const requestId = `remodex-router-discovery-${now().toString(36)}-${randomUUID()}`;
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        pendingDiscoveryResponses.delete(requestId);
        resolve(false);
      }, discoveryTimeoutMs);
      timeout.unref?.();
      pendingDiscoveryResponses.set(requestId, {
        resolve,
        timeout,
      });
      if (!writeEnvelopeToClient(client, {
        type: "client-discovery-request",
        requestId,
        request,
      })) {
        clearTimeout(timeout);
        pendingDiscoveryResponses.delete(requestId);
        resolve(false);
      }
    });
  }

  function resolveDiscoveryResponse(envelope) {
    const requestId = requestIdKey(envelope.requestId);
    const pending = requestId ? pendingDiscoveryResponses.get(requestId) : null;
    if (!pending) {
      return;
    }
    pendingDiscoveryResponses.delete(requestId);
    clearTimeout(pending.timeout);
    pending.resolve(Boolean(envelope.response?.canHandle));
  }

  function removeClient(client) {
    if (client.id) {
      clientsById.delete(client.id);
      relayBroadcast(client, {
        type: "broadcast",
        method: CLIENT_STATUS_CHANGED,
        sourceClientId: client.id,
        version: METHOD_VERSION_BY_NAME.get(CLIENT_STATUS_CHANGED) || 1,
        params: {
          clientId: client.id,
          clientType: client.type,
          status: "disconnected",
        },
      });
    }
    for (const [routeKey, route] of Array.from(pendingRoutedResponses.entries())) {
      if (!routeKey.startsWith(`${client.id}:`)) {
        continue;
      }
      pendingRoutedResponses.delete(routeKey);
      clearTimeout(route.timeout);
      writeEnvelopeToClient(route.sender, {
        type: "response",
        requestId: route.senderRequestId,
        resultType: "error",
        method: "",
        handledByClientId: client.id,
        error: "Codex IPC target disconnected.",
      });
    }
  }

  function close() {
    const shouldRemoveSocketPath = started || server;
    closed = true;
    started = false;
    starting = null;
    for (const pending of pendingDiscoveryResponses.values()) {
      clearTimeout(pending.timeout);
      pending.resolve(false);
    }
    pendingDiscoveryResponses.clear();
    for (const route of pendingRoutedResponses.values()) {
      clearTimeout(route.timeout);
    }
    pendingRoutedResponses.clear();
    for (const client of clientsById.values()) {
      client.socket.destroy();
    }
    clientsById.clear();
    if (server) {
      server.close();
      server = null;
    }
    if (shouldRemoveSocketPath) {
      removeSocketPathAfterClose(socketPath);
    }
  }

  function writeEnvelopeToClient(client, envelope) {
    if (!client?.socket || client.socket.destroyed) {
      return false;
    }
    try {
      writeFrame(client.socket, JSON.stringify(envelope));
      return true;
    } catch {
      client.socket.destroy();
      return false;
    }
  }

  return {
    start,
    close,
    get isStarted() {
      return started && !closed;
    },
  };
}

function routedResponseKey(clientId, requestId) {
  return `${clientId}:${requestId}`;
}

function prepareSocketPathForListen(socketPath, { removeStaleSocket = false } = {}) {
  if (process.platform === "win32") {
    return;
  }
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
  if (removeStaleSocket && fs.existsSync(socketPath)) {
    const socketStat = fs.lstatSync(socketPath);
    if (!socketStat.isSocket()) {
      throw new Error(`Refusing to replace non-socket Codex IPC path: ${socketPath}`);
    }
    fs.unlinkSync(socketPath);
  }
}

function removeSocketPathAfterClose(socketPath) {
  if (process.platform === "win32") {
    return;
  }
  try {
    if (fs.existsSync(socketPath)) {
      fs.unlinkSync(socketPath);
    }
  } catch {
    // Best-effort cleanup only; the next fallback start can remove stale sockets.
  }
}

function sanitizeTurnStartParams(params) {
  const sanitized = {};
  for (const [key, value] of Object.entries(params || {})) {
    if (ALLOWED_TURN_START_PARAM_KEYS.has(key)) {
      sanitized[key] = value;
    }
  }
  if (!Array.isArray(sanitized.input)) {
    sanitized.input = [];
  }
  return sanitized;
}

function readThreadFromResponse(message) {
  const result = message?.result || message?.payload || {};
  return readThreadFromPayload(result);
}

function readThreadFromPayload(result) {
  if (!result || typeof result !== "object") {
    return null;
  }
  return result.thread && typeof result.thread === "object"
    ? result.thread
    : result;
}

function readThreadIdFromParams(params) {
  return readString(params?.threadId)
    || readString(params?.thread_id)
    || readString(params?.conversationId)
    || readString(params?.conversation_id)
    || readString(params?.turn?.threadId)
    || readString(params?.turn?.thread_id)
    || readString(params?.thread?.id);
}

function readTurnIdFromParams(params) {
  return readString(params?.turnId)
    || readString(params?.turn_id)
    || readString(params?.turn?.id)
    || readString(params?.turn?.turnId)
    || readString(params?.turn?.turn_id);
}

function readTurnIdFromTurn(turn) {
  return readString(turn?.id)
    || readString(turn?.turnId)
    || readString(turn?.turn_id);
}

function readConversationIdFromFollowerParams(params) {
  return readString(params?.conversationId)
    || readString(params?.conversation_id)
    || readString(params?.threadId)
    || readString(params?.thread_id)
    || readString(params?.turnStartParams?.threadId)
    || readString(params?.turn_start_params?.threadId);
}

function timestampSecondsToMs(value) {
  return Number.isFinite(value) && value > 0 ? Math.round(value * 1000) : 0;
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

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function normalizeToken(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[_-\s]+/g, "")
    : "";
}

function cloneJSON(value) {
  if (value == null) {
    return value;
  }
  return JSON.parse(JSON.stringify(value));
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function writeFrame(socket, payload) {
  const body = Buffer.from(payload, "utf8");
  const header = Buffer.alloc(FRAME_HEADER_BYTES);
  header.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([header, body]));
}

module.exports = {
  applyAppServerMessageToConversationState,
  buildConversationStatePatches,
  buildConversationStateFromThread,
  createDesktopIpcLiveOwner,
  resolveDefaultIpcSocketPath,
};
