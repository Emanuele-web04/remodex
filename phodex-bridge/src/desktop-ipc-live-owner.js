// FILE: desktop-ipc-live-owner.js
// Purpose: Exposes bridge-owned Codex app-server streams to Codex Desktop/VSCode over the local IPC bus.
// Layer: CLI helper
// Exports: createDesktopIpcLiveOwner (plus adapter/patch re-exports for compatibility)
// Depends on: net, ./desktop-ipc-conversation-adapter, ./desktop-ipc-owner-transport, ./desktop-ipc-state-patches, ./desktop-ipc-shared

const net = require("net");

const {
  CLIENT_STATUS_CHANGED,
  DESKTOP_IPC_METHOD_VERSIONS: METHOD_VERSION_BY_NAME,
  buildCompleteThreadReadParams,
  cloneJSON,
  conversationSnapshotShowsActiveTurn,
  isPlainJSONObject,
  normalizeToken,
  readString,
  requestIdKey,
  resolveDefaultIpcSocketPath,
  resolveIpcSocketPathCandidates,
  safeParseJSON,
  visibleUserPromptFromInputEntries,
} = require("./desktop-ipc-shared");
const {
  LOCAL_HOST_ID,
  applyAppServerMessageToConversationState,
  buildConversationStateFromThread,
  createEmptyConversationState,
  readThreadIdFromParams,
} = require("./desktop-ipc-conversation-adapter");
const {
  DEFAULT_MAX_PATCH_BYTES,
  DEFAULT_MAX_PATCH_COUNT,
  applyPatchesToBaselineState,
  buildConversationStatePatches,
} = require("./desktop-ipc-state-patches");
const {
  createDesktopOwnerIpcClient,
} = require("./desktop-ipc-owner-transport");

const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
const DEFAULT_RECONNECT_MS = 1_500;
const DEFAULT_SNAPSHOT_DEBOUNCE_MS = 75;
const DEFAULT_INITIAL_HISTORY_RETRY_MS = 1_000;
const DEFAULT_INITIAL_HISTORY_MAX_ATTEMPTS = 5;
// Ownership is only authoritative while the Desktop stream keeps updating.
// A reconnect can otherwise leave a thread in ownedThreadIds indefinitely and
// suppress the rollout mirror that is carrying the real live activity.
const DEFAULT_LIVE_OWNERSHIP_FRESHNESS_MS = 20_000;
// Desktop's webview refreshes its recent-conversations list when it receives a
// thread-unarchived broadcast for its host. Give the rollout writer a moment to
// persist session_meta + the first user event so the refreshed thread/list scan
// can actually see the thread.
const DEFAULT_SIDEBAR_REFRESH_DELAY_MS = 1_200;
const THREAD_STREAM_STATE_CHANGED = "thread-stream-state-changed";
const THREAD_STREAM_FOLLOWING_CHANGED = "thread-stream-following-changed";
const THREAD_STREAM_FOLLOWING_STATUS_REQUESTED = "thread-stream-following-status-requested";
// Cached thread/read responses are only a hydration convenience; owned threads
// are never evicted, so a small cap keeps long browsing sessions bounded.
const MAX_CACHED_THREADS = 30;
const THREAD_ARCHIVED = "thread-archived";
const THREAD_UNARCHIVED = "thread-unarchived";
const THREAD_READ_STATE_CHANGED = "thread-read-state-changed";
const THREAD_QUEUED_FOLLOWUPS_CHANGED = "thread-queued-followups-changed";
const REMODEX_LIVE_OWNER_SOURCE = "desktop-ipc-live-owner";

const SUPPORTED_FOLLOWER_REQUEST_METHODS = new Set([
  "thread-follower-start-turn",
  "thread-follower-load-complete-history",
  "thread-follower-update-thread-settings",
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
  "thread/unarchive",
  "thread/unsubscribe",
]);

const THREAD_READ_METHODS = new Set(["thread/read", "thread/resume"]);

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
  sendApplicationResponse = null,
  sendCodexRequest,
  sendRawCodexMessage,
  normalizeTurnStartParams = (params) => params,
  runtimeSettingsStore = null,
  // Resolved per connect: Codex Desktop can start, stop, or move its bus while
  // the bridge stays up.
  socketPath = resolveIpcSocketPathCandidates,
  sidebarRefreshDelayMs = DEFAULT_SIDEBAR_REFRESH_DELAY_MS,
  snapshotDebounceMs = DEFAULT_SNAPSHOT_DEBOUNCE_MS,
  maxPatchCount = DEFAULT_MAX_PATCH_COUNT,
  maxPatchBytes = DEFAULT_MAX_PATCH_BYTES,
  requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  reconnectMs = DEFAULT_RECONNECT_MS,
  initialHistoryRetryMs = DEFAULT_INITIAL_HISTORY_RETRY_MS,
  initialHistoryMaxAttempts = DEFAULT_INITIAL_HISTORY_MAX_ATTEMPTS,
  liveOwnershipFreshnessMs = DEFAULT_LIVE_OWNERSHIP_FRESHNESS_MS,
  onFollowerStateChanged = null,
  netModule = net,
  now = () => Date.now(),
  logPrefix = "[remodex]",
} = {}) {
  if (!enabled || typeof sendCodexRequest !== "function" || typeof sendRawCodexMessage !== "function") {
    return createDisabledDesktopIpcLiveOwner();
  }
  const sendPhoneNotification = typeof sendApplicationResponse === "function"
    ? sendApplicationResponse
    : () => {};

  const conversations = new Map();
  const ownedThreadIds = new Set();
  // Pending local thread/start requests in FIFO order, keyed by request id with
  // the requested cwd so notification-only thread/started events pair correctly.
  const pendingThreadStartRequestIds = new Map();
  const pendingThreadReadRequestIds = new Set();
  const pendingThreadHydrationsByThreadId = new Map();
  // Unknown existing threads need a real history baseline before the first
  // Desktop snapshot; any seeded partial state can replace all desktop rows.
  const threadsAwaitingInitialHistoryByThreadId = new Set();
  const initialHistoryRetryAfterByThreadId = new Map();
  const initialHistoryRetryTimersByThreadId = new Map();
  const initialHistoryAttemptCountByThreadId = new Map();
  const cachedThreadsByThreadId = new Map();
  const lastBroadcastStatesByThreadId = new Map();
  const fallbackTurnIdsByThreadId = new Map();
  // Desktop followers track monotonic stream revisions: patches apply only when
  // baseRevision matches their last-seen revision, and load-complete-history
  // waits for the snapshot carrying the returned revision.
  const streamRevisionsByThreadId = new Map();
  const followerClientIdsByThreadId = new Map();
  const announcedSidebarThreadIds = new Set();
  const sidebarRefreshTimersByThreadId = new Map();
  // A new rollout can exist as a thread id before Desktop's separate app-server
  // can return it from thread/list. Keep a bounded materialization replay alive
  // until the first user item and turn completion prove the rollout was written.
  const pendingSidebarMaterializationThreadIds = new Set();
  const replayedSidebarMaterializationThreadIds = new Set();
  const pendingTurnStartParamsByThreadId = new Map();
  const pendingTurnStartEntriesByRequestId = new Map();
  const followerRuntimeOverridesByThreadId = new Map();
  // Desktop delegates queued follow-ups to the stream owner: followers push the
  // whole queue state here and expect the owner to run entries between turns.
  const queuedFollowUpsByThreadId = new Map();
  const runningQueuedFollowUpThreadIds = new Set();
  const announcedReadStateThreadIds = new Set();
  const pendingThreadArchiveMetadataByThreadId = new Map();
  const dirtyThreadIds = new Set();
  let snapshotTimer = null;
  let optimisticTurnSerial = 0;

  const ipc = createDesktopOwnerIpcClient({
    socketPath,
    netModule,
    now,
    requestTimeoutMs,
    reconnectMs,
    logPrefix,
    onConnected() {
      flushPendingThreadArchiveMetadataBroadcasts();
      requestFollowerStatusForAllOwnedThreads();
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

  function observeInbound(rawMessage, parsedMessage = null) {
    const message = parsedMessage ?? safeParseJSON(rawMessage);
    const method = readString(message?.method);
    if (THREAD_READ_METHODS.has(method)) {
      if (message?.id != null) {
        pendingThreadReadRequestIds.add(String(message.id));
      }
      markThreadReadByPhone(readThreadIdFromParams(message?.params));
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

    if (method === "thread/archive") {
      broadcastThreadArchived(threadId, readArchiveCwd(threadId, message?.params));
      removeOwnedThread(threadId, {
        broadcastRemoval: true,
        reason: method,
        skipArchiveMetadataBroadcast: true,
      });
      return;
    }
    if (method === "thread/unsubscribe") {
      // The phone leaving the screen releases idle threads, but a thread whose
      // local turn is still executing stays owned: dropping it mid-run lets
      // fallback mirrors and Desktop routing corrupt the timeline on reopen.
      if (!hasActiveLocalTurn(threadId)) {
        removeOwnedThread(threadId, { broadcastRemoval: true, reason: method });
      }
      return;
    }
    if (method === "thread/unarchive") {
      broadcastThreadUnarchived(threadId);
      return;
    }

    const hadConversation = conversations.has(threadId);
    const hadCachedThread = cachedThreadsByThreadId.has(threadId);
    markOwnedThread(threadId);
    if (!hadConversation && !hadCachedThread) {
      threadsAwaitingInitialHistoryByThreadId.add(threadId);
    }
    let pendingTurnStartEntry = null;
    if (method === "turn/start") {
      pendingTurnStartEntry = rememberPendingTurnStart(threadId, message?.params, message?.id);
      scheduleSidebarAnnouncement(threadId);
    }
    if (method === "turn/interrupt") {
      markTurnInterruptedOptimistically(threadId, message?.params);
    }
    seedOwnedConversation(threadId, {
      cwd: readString(message?.params?.cwd),
    });
    if (pendingTurnStartEntry) {
      insertOptimisticPendingTurn(threadId, pendingTurnStartEntry);
    }
    if (!hadConversation && !hadCachedThread) {
      requestInitialHistoryBaselineIfDue(threadId);
    }
    scheduleSnapshot(threadId);
  }

  function observeOutbound(rawMessage, parsedMessage = null) {
    const message = parsedMessage ?? safeParseJSON(rawMessage);
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
        rememberCachedThread(thread.id, thread);
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
      // thread/started already carries the authoritative thread baseline, including
      // new-thread cases where turn/start reached the bridge first.
      if (readString(message.method) === "thread/started") {
        stopAwaitingInitialHistory(update.threadId);
      }
      refreshOptimisticFallbackForThread(update.threadId);
      scheduleSnapshot(update.threadId);
      replaySidebarAnnouncementAfterMaterialization(message, update.threadId);
    }

    if (readString(message.method) === "turn/completed") {
      const completedThreadId = readThreadIdFromParams(message.params);
      const completedStatus = normalizeToken(message.params?.turn?.status);
      // Mirror Desktop's pause-after-interrupt semantics: a stopped turn means
      // the user wants things halted, so queued follow-ups wait for the next
      // explicit trigger (queue edit or a normally completed turn).
      if (completedThreadId
        && ownedThreadIds.has(completedThreadId)
        && completedStatus !== "interrupted"
        && completedStatus !== "cancelled"
        && completedStatus !== "canceled") {
        runNextQueuedFollowUp(completedThreadId);
      }
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
    threadsAwaitingInitialHistoryByThreadId.clear();
    initialHistoryRetryAfterByThreadId.clear();
    initialHistoryAttemptCountByThreadId.clear();
    for (const timer of initialHistoryRetryTimersByThreadId.values()) {
      clearTimeout(timer);
    }
    initialHistoryRetryTimersByThreadId.clear();
    cachedThreadsByThreadId.clear();
    lastBroadcastStatesByThreadId.clear();
    fallbackTurnIdsByThreadId.clear();
    streamRevisionsByThreadId.clear();
    followerClientIdsByThreadId.clear();
    for (const timer of sidebarRefreshTimersByThreadId.values()) {
      clearTimeout(timer);
    }
    sidebarRefreshTimersByThreadId.clear();
    announcedSidebarThreadIds.clear();
    pendingSidebarMaterializationThreadIds.clear();
    replayedSidebarMaterializationThreadIds.clear();
    pendingTurnStartParamsByThreadId.clear();
    pendingTurnStartEntriesByRequestId.clear();
    followerRuntimeOverridesByThreadId.clear();
    pendingThreadArchiveMetadataByThreadId.clear();
    queuedFollowUpsByThreadId.clear();
    runningQueuedFollowUpThreadIds.clear();
    announcedReadStateThreadIds.clear();
    ownedThreadIds.clear();
    conversations.clear();
    ipc.close();
  }

  // Desktop's sidebar tracks unread markers via thread-read-state-changed; tell
  // it when the phone opens an owned thread so badges clear on both devices.
  // Repeated reads of an already-clean thread stay silent to avoid IPC noise.
  function markThreadReadByPhone(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !ownedThreadIds.has(normalizedThreadId)) {
      return;
    }
    const conversation = conversations.get(normalizedThreadId);
    const hadUnread = Boolean(conversation
      && (conversation.hasUnreadTurn || conversation.unreadMessageCount > 0));
    if (hadUnread) {
      conversation.hasUnreadTurn = false;
      conversation.unreadMessageCount = 0;
      scheduleSnapshot(normalizedThreadId);
    } else if (announcedReadStateThreadIds.has(normalizedThreadId)) {
      return;
    }
    if (ipc.sendBroadcast(THREAD_READ_STATE_CHANGED, {
      conversationId: normalizedThreadId,
      hasUnreadTurn: false,
    })) {
      announcedReadStateThreadIds.add(normalizedThreadId);
    }
  }

  // Snappier Stop UX on Desktop: flip the active turn to interrupted right away;
  // authoritative app-server events overwrite this if the interrupt fails.
  function markTurnInterruptedOptimistically(threadId, params) {
    const conversation = conversations.get(readString(threadId));
    if (!conversation) {
      return;
    }
    const requestedTurnId = readString(params?.turnId) || readString(params?.turn_id);
    for (let index = conversation.turns.length - 1; index >= 0; index -= 1) {
      const turn = conversation.turns[index];
      const turnId = readString(turn?.turnId) || readString(turn?.id);
      const matchesRequest = requestedTurnId ? turnId === requestedTurnId : true;
      if (matchesRequest && normalizeToken(turn?.status) === "inprogress") {
        turn.status = "interrupted";
        conversation.threadRuntimeStatus = { type: "idle" };
        conversation.updatedAt = now();
        return;
      }
      if (requestedTurnId && turnId === requestedTurnId) {
        return;
      }
    }
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
      return existingPending.entry?.consumed ? null : existingPending.entry;
    }
    const input = Array.isArray(params?.input) ? params.input : [];
    if (input.length === 0) {
      return null;
    }
    const sanitizedParams = sanitizeTurnStartParams(cloneJSON(params));
    sanitizedParams.input = normalizeInputEntriesForDesktop(sanitizedParams.input);
    const entry = { params: sanitizedParams, requestId: normalizedRequestId || null };
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
    const didRemoveOptimisticTurn = removeOptimisticPendingTurn(normalizedThreadId, entry);
    const queue = pendingTurnStartParamsByThreadId.get(normalizedThreadId);
    if (!queue) {
      if (didRemoveOptimisticTurn) {
        scheduleSnapshot(normalizedThreadId);
      }
      return;
    }
    const index = queue.indexOf(entry);
    if (index >= 0) {
      queue.splice(index, 1);
    }
    if (queue.length === 0) {
      pendingTurnStartParamsByThreadId.delete(normalizedThreadId);
    }
    refreshOptimisticFallbackForThread(normalizedThreadId);
    if (didRemoveOptimisticTurn) {
      scheduleSnapshot(normalizedThreadId);
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
      const remainingStarts = pendingTurnStartParamsByThreadId.get(pending.threadId) || [];
      if (remainingStarts.length === 0
        && threadsAwaitingInitialHistoryByThreadId.has(pending.threadId)) {
        // A rejected first turn cannot produce a usable baseline. Relinquish
        // ownership instead of polling a thread that may never have existed.
        removeOwnedThread(pending.threadId);
      }
      return;
    }
    commitAcceptedRuntimeSettings(
      pending.threadId,
      pending.entry?.params,
      "phone",
      readTurnIdFromResult(message.result)
    );
    scheduleSnapshot(pending.threadId);
  }

  // Publishes phone-origin turns as soon as the bridge sees turn/start, instead
  // of waiting for image-heavy turn/started events to come back from the runtime.
  function insertOptimisticPendingTurn(threadId, entry) {
    const normalizedThreadId = readString(threadId);
    const params = entry?.params;
    const input = Array.isArray(params?.input) ? params.input : [];
    if (!normalizedThreadId || entry?.consumed || !params || input.length === 0) {
      return null;
    }

    const conversation = ensureConversation(normalizedThreadId, {
      cwd: readString(params.cwd),
    });
    if (!conversation) {
      return null;
    }

    const optimisticTurnId = ensureOptimisticTurnId(normalizedThreadId, entry);
    if (!readString(fallbackTurnIdsByThreadId.get(normalizedThreadId))) {
      fallbackTurnIdsByThreadId.set(normalizedThreadId, optimisticTurnId);
    }
    if (conversation.turns.some((turn) => (
      (readString(turn?.turnId) || readString(turn?.id)) === optimisticTurnId
    ))) {
      return optimisticTurnId;
    }

    const timestamp = now();
    const turnParams = cloneJSON(params);
    turnParams.threadId = normalizedThreadId;
    turnParams.cwd = readString(params.cwd) || conversation.cwd || null;

    conversation.turns.push({
      id: optimisticTurnId,
      turnId: optimisticTurnId,
      params: turnParams,
      turnStartedAtMs: timestamp,
      durationMs: null,
      firstTurnWorkItemStartedAtMs: null,
      finalAssistantStartedAtMs: null,
      status: "inProgress",
      error: null,
      diff: null,
      hookRuns: [],
      commandExecutionStartedAtMsById: {},
      items: [],
      remodexOptimisticPendingTurn: true,
    });
    conversation.hasUnreadTurn = true;
    conversation.updatedAt = timestamp;
    return optimisticTurnId;
  }

  function refreshOptimisticFallbackForThread(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || readString(fallbackTurnIdsByThreadId.get(normalizedThreadId))) {
      return;
    }
    const queue = pendingTurnStartParamsByThreadId.get(normalizedThreadId);
    const nextEntry = Array.isArray(queue)
      ? queue.find((entry) => readString(entry?.optimisticTurnId))
      : null;
    const nextOptimisticTurnId = readString(nextEntry?.optimisticTurnId);
    if (nextOptimisticTurnId) {
      fallbackTurnIdsByThreadId.set(normalizedThreadId, nextOptimisticTurnId);
    }
  }

  function ensureOptimisticTurnId(threadId, entry) {
    if (entry.optimisticTurnId) {
      return entry.optimisticTurnId;
    }
    optimisticTurnSerial += 1;
    const requestSegment = readString(entry.requestId) || `local-${optimisticTurnSerial}`;
    entry.optimisticTurnId = `remodex-pending-turn:${threadId}:${requestSegment}`;
    return entry.optimisticTurnId;
  }

  function removeOptimisticPendingTurn(threadId, entry) {
    const optimisticTurnId = readString(entry?.optimisticTurnId);
    const conversation = optimisticTurnId ? conversations.get(threadId) : null;
    if (!conversation || !Array.isArray(conversation.turns)) {
      return false;
    }
    const index = conversation.turns.findIndex((turn) => (
      turn?.remodexOptimisticPendingTurn
        && (readString(turn.turnId) || readString(turn.id)) === optimisticTurnId
    ));
    if (index < 0) {
      return false;
    }
    conversation.turns.splice(index, 1);
    if (readString(fallbackTurnIdsByThreadId.get(threadId)) === optimisticTurnId) {
      fallbackTurnIdsByThreadId.delete(threadId);
    }
    conversation.updatedAt = now();
    return true;
  }

  function markOwnedThread(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return;
    }
    const isNewOwner = !ownedThreadIds.has(normalizedThreadId);
    ownedThreadIds.add(normalizedThreadId);
    ipc.ensureConnected();
    if (isNewOwner) {
      requestFollowerStatus(normalizedThreadId);
    }
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

  function removeOwnedThread(threadId, { broadcastRemoval = false, reason = "", skipArchiveMetadataBroadcast = false } = {}) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return;
    }
    if (broadcastRemoval && ownedThreadIds.has(normalizedThreadId)) {
      broadcastRemovedConversationState(normalizedThreadId, {
        reason,
        skipArchiveMetadataBroadcast,
      });
    }
    ownedThreadIds.delete(normalizedThreadId);
    conversations.delete(normalizedThreadId);
    cachedThreadsByThreadId.delete(normalizedThreadId);
    pendingThreadHydrationsByThreadId.delete(normalizedThreadId);
    stopAwaitingInitialHistory(normalizedThreadId);
    lastBroadcastStatesByThreadId.delete(normalizedThreadId);
    fallbackTurnIdsByThreadId.delete(normalizedThreadId);
    streamRevisionsByThreadId.delete(normalizedThreadId);
    if (followerClientIdsByThreadId.delete(normalizedThreadId)) {
      onFollowerStateChanged?.(normalizedThreadId, false);
    }
    // An active-peer takeover can still drop a non-empty queue (hasActiveLocalTurn
    // only shields idle yields); announce the emptied queue instead of letting
    // clients keep rendering drafts the bridge will never run.
    const droppedQueuedFollowUps = (queuedFollowUpsByThreadId.get(normalizedThreadId) || []).length > 0;
    queuedFollowUpsByThreadId.delete(normalizedThreadId);
    if (droppedQueuedFollowUps) {
      broadcastQueuedFollowUps(normalizedThreadId);
    }
    runningQueuedFollowUpThreadIds.delete(normalizedThreadId);
    announcedReadStateThreadIds.delete(normalizedThreadId);
    cancelSidebarAnnouncement(normalizedThreadId);
    announcedSidebarThreadIds.delete(normalizedThreadId);
    pendingSidebarMaterializationThreadIds.delete(normalizedThreadId);
    replayedSidebarMaterializationThreadIds.delete(normalizedThreadId);
    pendingTurnStartParamsByThreadId.delete(normalizedThreadId);
    followerRuntimeOverridesByThreadId.delete(normalizedThreadId);
    for (const [requestId, pending] of Array.from(pendingTurnStartEntriesByRequestId.entries())) {
      if (pending.threadId === normalizedThreadId) {
        pendingTurnStartEntriesByRequestId.delete(requestId);
      }
    }
    dirtyThreadIds.delete(normalizedThreadId);
  }

  function broadcastRemovedConversationState(threadId, { reason = "", skipArchiveMetadataBroadcast = false } = {}) {
    const previousState = conversations.get(threadId)
      || lastBroadcastStatesByThreadId.get(threadId)
      || createEmptyConversationState(threadId, { hostId, now });
    if (reason === "thread/archive" && !skipArchiveMetadataBroadcast) {
      broadcastThreadArchived(threadId, readString(previousState?.cwd));
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

  function broadcastThreadArchived(threadId, cwd) {
    queueThreadArchiveMetadataBroadcast(THREAD_ARCHIVED, threadId, { cwd });
  }

  function broadcastThreadUnarchived(threadId) {
    queueThreadArchiveMetadataBroadcast(THREAD_UNARCHIVED, threadId);
  }

  // Desktop has no watcher on the shared session store, but its webview reacts
  // to thread-unarchived broadcasts by re-running thread/list. The first timed
  // announcement keeps the common path responsive; materialization events below
  // replay it because a new rollout id can precede Desktop's thread/list entry.
  function scheduleSidebarAnnouncement(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId
      || announcedSidebarThreadIds.has(normalizedThreadId)
      || sidebarRefreshTimersByThreadId.has(normalizedThreadId)) {
      return;
    }
    pendingSidebarMaterializationThreadIds.add(normalizedThreadId);
    const timer = setTimeout(() => {
      sidebarRefreshTimersByThreadId.delete(normalizedThreadId);
      if (!ownedThreadIds.has(normalizedThreadId)) {
        return;
      }
      announcedSidebarThreadIds.add(normalizedThreadId);
      broadcastThreadUnarchived(normalizedThreadId);
    }, Math.max(0, sidebarRefreshDelayMs));
    timer.unref?.();
    sidebarRefreshTimersByThreadId.set(normalizedThreadId, timer);
  }

  function replaySidebarAnnouncementAfterMaterialization(message, threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId
      || !ownedThreadIds.has(normalizedThreadId)
      || !pendingSidebarMaterializationThreadIds.has(normalizedThreadId)) {
      return;
    }

    const method = readString(message?.method);
    const itemType = readString(message?.params?.item?.type);
    const turnItems = Array.isArray(message?.params?.turn?.items)
      ? message.params.turn.items
      : [];
    const includesPersistedUserMessage = (
      (method === "item/started" || method === "item/completed")
        && itemType === "userMessage"
    ) || turnItems.some((item) => readString(item?.type) === "userMessage");
    const turnCompleted = method === "turn/completed";
    if (!includesPersistedUserMessage && !turnCompleted) {
      return;
    }

    cancelSidebarAnnouncement(normalizedThreadId);
    announcedSidebarThreadIds.add(normalizedThreadId);
    if (!replayedSidebarMaterializationThreadIds.has(normalizedThreadId) || turnCompleted) {
      broadcastThreadUnarchived(normalizedThreadId);
    }

    if (turnCompleted) {
      pendingSidebarMaterializationThreadIds.delete(normalizedThreadId);
      replayedSidebarMaterializationThreadIds.delete(normalizedThreadId);
      return;
    }
    replayedSidebarMaterializationThreadIds.add(normalizedThreadId);
  }

  function cancelSidebarAnnouncement(threadId) {
    const timer = sidebarRefreshTimersByThreadId.get(threadId);
    if (timer) {
      clearTimeout(timer);
      sidebarRefreshTimersByThreadId.delete(threadId);
    }
  }

  // Archive/unarchive are list metadata updates; keep only the final per-thread
  // state while IPC reconnects so rapid toggles cannot flush out of order.
  function queueThreadArchiveMetadataBroadcast(method, threadId, { cwd } = {}) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return;
    }
    pendingThreadArchiveMetadataByThreadId.set(normalizedThreadId, {
      method,
      cwd: readString(cwd),
    });
    ipc.ensureConnected();
    flushPendingThreadArchiveMetadataBroadcasts();
  }

  function flushPendingThreadArchiveMetadataBroadcasts() {
    for (const [threadId, pending] of pendingThreadArchiveMetadataByThreadId) {
      const params = {
        hostId,
        conversationId: threadId,
      };
      if (pending.method === THREAD_ARCHIVED) {
        params.cwd = pending.cwd;
      }
      if (!ipc.sendBroadcast(pending.method, params)) {
        return;
      }
      pendingThreadArchiveMetadataByThreadId.delete(threadId);
    }
  }

  function readArchiveCwd(threadId, params) {
    return readString(params?.cwd)
      || readString(conversations.get(threadId)?.cwd)
      || readString(lastBroadcastStatesByThreadId.get(threadId)?.cwd);
  }

  function maybeYieldOwnedThreadForPeerArchive(envelope) {
    if (envelope?.method !== THREAD_ARCHIVED) {
      return false;
    }
    if (envelope.sourceClientId && envelope.sourceClientId === ipc.clientId) {
      return true;
    }
    const params = envelope.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    if (!threadId || !ownedThreadIds.has(threadId)) {
      return true;
    }

    // Desktop archive is a list-level ownership signal; stop publishing snapshots
    // so archived threads do not immediately reappear from bridge-owned state.
    removeOwnedThread(threadId);
    return true;
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
    runtimeSettingsStore?.attachToConversation?.(threadId, next);
    conversations.set(threadId, next);
    stopAwaitingInitialHistory(threadId);
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
      runtimeSettingsStore?.attachToConversation?.(normalizedThreadId, conversation);
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
      if (shouldDelayInitialSnapshotForHistory(threadId)) {
        dirtyThreadIds.add(threadId);
        continue;
      }
      if (!broadcastConversationState(threadId)) {
        // Keep unsent snapshots dirty so the reconnect rebroadcast can retry them.
        dirtyThreadIds.add(threadId);
      }
    }
  }

  // Blocks only the first Desktop snapshot for a newly-owned, unhydrated thread.
  // Once a baseline was broadcast, later patches may stream normally.
  function shouldDelayInitialSnapshotForHistory(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !threadsAwaitingInitialHistoryByThreadId.has(normalizedThreadId)) {
      return false;
    }
    if (lastBroadcastStatesByThreadId.has(normalizedThreadId)) {
      stopAwaitingInitialHistory(normalizedThreadId);
      return false;
    }
    requestInitialHistoryBaselineIfDue(normalizedThreadId);
    return ownedThreadIds.has(normalizedThreadId)
      && threadsAwaitingInitialHistoryByThreadId.has(normalizedThreadId);
  }

  // Re-requests the thread/read baseline with bounded backoff while the first
  // snapshot stays blocked. Permanent failures release ownership to other mirrors.
  function requestInitialHistoryBaselineIfDue(threadId) {
    if (pendingThreadHydrationsByThreadId.has(threadId)) {
      return;
    }
    const maxAttempts = Number.isFinite(initialHistoryMaxAttempts)
      ? Math.max(1, Math.floor(initialHistoryMaxAttempts))
      : DEFAULT_INITIAL_HISTORY_MAX_ATTEMPTS;
    const attemptCount = initialHistoryAttemptCountByThreadId.get(threadId) || 0;
    if (attemptCount >= maxAttempts) {
      removeOwnedThread(threadId);
      return;
    }
    const currentTime = now();
    const retryAfter = initialHistoryRetryAfterByThreadId.get(threadId) || 0;
    if (currentTime < retryAfter) {
      scheduleInitialHistoryRetryWakeup(threadId, retryAfter - currentTime);
      return;
    }
    clearInitialHistoryRetryWakeup(threadId);
    const retryBaseMs = Number.isFinite(initialHistoryRetryMs)
      ? Math.max(0, initialHistoryRetryMs)
      : DEFAULT_INITIAL_HISTORY_RETRY_MS;
    const retryDelayMs = retryBaseMs * (2 ** Math.min(attemptCount, 5));
    initialHistoryAttemptCountByThreadId.set(threadId, attemptCount + 1);
    initialHistoryRetryAfterByThreadId.set(threadId, currentTime + retryDelayMs);
    hydrateOwnedThreadFromRead(threadId);
  }

  function stopAwaitingInitialHistory(threadId) {
    threadsAwaitingInitialHistoryByThreadId.delete(threadId);
    initialHistoryRetryAfterByThreadId.delete(threadId);
    initialHistoryAttemptCountByThreadId.delete(threadId);
    clearInitialHistoryRetryWakeup(threadId);
  }

  // Wakes blocked first-snapshot flushes once the thread/read retry window opens.
  function scheduleInitialHistoryRetryWakeup(threadId, delayMs) {
    if (initialHistoryRetryTimersByThreadId.has(threadId)) {
      return;
    }
    const timer = setTimeout(() => {
      initialHistoryRetryTimersByThreadId.delete(threadId);
      if (ownedThreadIds.has(threadId) && threadsAwaitingInitialHistoryByThreadId.has(threadId)) {
        scheduleSnapshot(threadId);
      }
    }, Math.max(0, delayMs));
    timer.unref?.();
    initialHistoryRetryTimersByThreadId.set(threadId, timer);
  }

  function clearInitialHistoryRetryWakeup(threadId) {
    const timer = initialHistoryRetryTimersByThreadId.get(threadId);
    if (!timer) {
      return;
    }
    clearTimeout(timer);
    initialHistoryRetryTimersByThreadId.delete(threadId);
  }

  // Refreshing insertion order makes the Map behave as an LRU; owned threads
  // are exempt from eviction because their cache backs live snapshot rebuilds.
  function rememberCachedThread(threadId, thread) {
    cachedThreadsByThreadId.delete(threadId);
    cachedThreadsByThreadId.set(threadId, cloneJSON(thread));
    if (cachedThreadsByThreadId.size <= MAX_CACHED_THREADS) {
      return;
    }
    for (const cachedThreadId of cachedThreadsByThreadId.keys()) {
      if (cachedThreadsByThreadId.size <= MAX_CACHED_THREADS) {
        return;
      }
      if (!ownedThreadIds.has(cachedThreadId)) {
        cachedThreadsByThreadId.delete(cachedThreadId);
      }
    }
  }

  function hydrateOwnedThreadFromRead(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || pendingThreadHydrationsByThreadId.has(normalizedThreadId)) {
      return;
    }
    const hydration = Promise.resolve()
      .then(() => sendCodexRequest(
        "thread/read",
        buildCompleteThreadReadParams(normalizedThreadId)
      ))
      .then((result) => {
        const thread = readThreadFromPayload(result);
        if (!thread?.id) {
          return;
        }
        rememberCachedThread(thread.id, thread);
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
      if (shouldDelayInitialSnapshotForHistory(threadId)) {
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
    runtimeSettingsStore?.attachToConversation?.(threadId, conversationState);
    if (shouldDelayInitialSnapshotForHistory(threadId)) {
      return false;
    }
    const currentRevision = streamRevisionsByThreadId.get(threadId) ?? 0;
    const previousState = lastBroadcastStatesByThreadId.get(threadId) || null;
    if (!forceSnapshot && previousState) {
      // Diff straight against the live state: every patch value is deep-cloned
      // as it is collected, so the per-flush O(state) snapshot clone is not
      // needed on the streaming path.
      const patches = buildConversationStatePatches(previousState, conversationState, {
        maxPatchCount,
        maxPatchBytes,
      });
      if (patches && patches.length === 0) {
        return true;
      }
      if (patches && ipc.sendBroadcast(THREAD_STREAM_STATE_CHANGED, {
        conversationId: threadId,
        hostId,
        version: METHOD_VERSION_BY_NAME.get(THREAD_STREAM_STATE_CHANGED) || 1,
        remodexOwnerSource: REMODEX_LIVE_OWNER_SOURCE,
        change: {
          type: "patches",
          baseRevision: currentRevision,
          revision: currentRevision + 1,
          patches,
        },
      })) {
        streamRevisionsByThreadId.set(threadId, currentRevision + 1);
        // The baseline advances by replaying the emitted patches (their values
        // are already private clones); a full clone happens only if that fails.
        if (!applyPatchesToBaselineState(previousState, patches)) {
          lastBroadcastStatesByThreadId.set(threadId, cloneJSON(conversationState));
        }
        return true;
      }
    }

    // Snapshot broadcasts serialize synchronously, so the live state can be
    // passed through; only the retained baseline needs its own copy.
    if (ipc.sendBroadcast(THREAD_STREAM_STATE_CHANGED, {
      conversationId: threadId,
      hostId,
      version: METHOD_VERSION_BY_NAME.get(THREAD_STREAM_STATE_CHANGED) || 1,
      remodexOwnerSource: REMODEX_LIVE_OWNER_SOURCE,
      change: {
        type: "snapshot",
        revision: currentRevision + 1,
        conversationState,
      },
    })) {
      streamRevisionsByThreadId.set(threadId, currentRevision + 1);
      lastBroadcastStatesByThreadId.set(threadId, cloneJSON(conversationState));
      return true;
    }
    return false;
  }

  function handlePeerBroadcast(envelope) {
    if (envelope?.method === CLIENT_STATUS_CHANGED) {
      // The fallback router can accept the owner's connection before any
      // Desktop client exists. Metadata broadcasts remain queued in that state;
      // retry them whenever peer membership changes so a newly connected
      // Desktop immediately refreshes its sidebar.
      flushPendingThreadArchiveMetadataBroadcasts();
      broadcastAllOwnedSnapshots();
      if (normalizeToken(envelope.params?.status) === "disconnected") {
        removeFollowerClient(envelope.params?.clientId || envelope.sourceClientId);
      }
      return;
    }
    if (envelope?.method === THREAD_STREAM_FOLLOWING_CHANGED) {
      updateFollowerState(envelope);
      return;
    }
    if (maybeYieldOwnedThreadForPeerArchive(envelope)) {
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
    if (hasActiveLocalTurn(threadId) && !conversationSnapshotShowsActiveTurn(params.change)) {
      // Desktop re-broadcasts idle snapshots for threads the user merely viewed
      // (and replays them on reconnect). Those may claim an idle thread, but a
      // thread whose local turn is still running yields only to a peer snapshot
      // proving the peer runtime is executing it.
      return;
    }

    // Another Codex frontend is actively owning this stream. Drop bridge ownership
    // and all cached conversation state so a later re-claim rehydrates fresh data
    // instead of republishing stale turns and requests.
    removeOwnedThread(threadId);
  }

  function updateFollowerState(envelope) {
    const params = envelope?.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    const clientId = readString(envelope?.sourceClientId);
    if (!threadId || !clientId || !ownedThreadIds.has(threadId)) {
      return;
    }

    const followers = followerClientIdsByThreadId.get(threadId) || new Set();
    if (params.following === true) {
      const wasUnfollowed = followers.size === 0;
      followers.add(clientId);
      followerClientIdsByThreadId.set(threadId, followers);
      if (wasUnfollowed) {
        onFollowerStateChanged?.(threadId, true);
      }
      // Match Codex's owner behavior: a newly mounted follower receives an
      // immediate full baseline instead of waiting for the next model delta.
      broadcastConversationState(threadId, { forceSnapshot: true });
      return;
    }

    if (!followers.delete(clientId)) {
      return;
    }
    if (followers.size === 0) {
      followerClientIdsByThreadId.delete(threadId);
      onFollowerStateChanged?.(threadId, false);
    }
  }

  function removeFollowerClient(clientId) {
    const normalizedClientId = readString(clientId);
    if (!normalizedClientId) {
      return;
    }
    for (const [threadId, followers] of followerClientIdsByThreadId) {
      if (!followers.delete(normalizedClientId)) {
        continue;
      }
      if (followers.size === 0) {
        followerClientIdsByThreadId.delete(threadId);
        onFollowerStateChanged?.(threadId, false);
      }
    }
  }

  function requestFollowerStatusForAllOwnedThreads() {
    for (const threadId of ownedThreadIds) {
      requestFollowerStatus(threadId);
    }
  }

  function requestFollowerStatus(threadId) {
    ipc.sendBroadcast(THREAD_STREAM_FOLLOWING_STATUS_REQUESTED, {
      hostId,
      conversationId: threadId,
    });
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
      case "thread-follower-load-complete-history":
        return await handleFollowerLoadCompleteHistory(conversationId);
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
      case "thread-follower-update-thread-settings":
        return applyFollowerThreadSettings(conversationId, params.threadSettings);
      case "thread-follower-set-queued-follow-ups-state":
        return applyFollowerQueuedFollowUps(conversationId, params.state);
      case "thread-follower-edit-last-user-turn":
        throw new Error("thread-follower-edit-last-user-turn is not supported by Remodex yet.");
      default:
        throw new Error(`Unsupported follower request: ${method}`);
    }
  }

  // Desktop calls this when it opens a followed conversation: it wants the
  // owner's complete history in the stream, then waits for a snapshot carrying
  // the returned revision before rendering. Rehydrate from the app-server so
  // history is complete, then force-broadcast a fresh snapshot.
  async function handleFollowerLoadCompleteHistory(conversationId) {
    try {
      const result = await sendCodexRequest(
        "thread/read",
        buildCompleteThreadReadParams(conversationId)
      );
      const thread = readThreadFromPayload(result);
      if (thread?.id) {
        rememberCachedThread(thread.id, thread);
        if (ownedThreadIds.has(thread.id)) {
          upsertConversationFromThread(thread);
        }
      }
    } catch {
      // Not materialized yet: the live conversation state is still authoritative.
    }
    if (!broadcastConversationState(conversationId, { forceSnapshot: true })) {
      throw new Error("no-client-found: thread stream owner became unavailable");
    }
    const revision = streamRevisionsByThreadId.get(conversationId);
    if (revision == null) {
      throw new Error("no-client-found: thread stream owner became unavailable");
    }
    return { revision };
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
    const senderRequestId = params.senderRequestId || params.sender_request_id;
    const isKnownHeldPhoneStart = Boolean(
      requestIdKey(senderRequestId)
      && pendingTurnStartEntriesByRequestId.has(requestIdKey(senderRequestId))
    );
    const pendingEntry = rememberPendingTurnStart(
      conversationId,
      nextCodexParams,
      senderRequestId
    );
    if (pendingEntry) {
      insertOptimisticPendingTurn(conversationId, pendingEntry);
      scheduleSnapshot(conversationId);
    }
    try {
      const turnStartResult = await sendCodexRequest("turn/start", nextCodexParams);
      commitAcceptedRuntimeSettings(
        conversationId,
        nextCodexParams,
        isKnownHeldPhoneStart ? "phone" : "desktop",
        readTurnIdFromResult(turnStartResult)
      );
      scheduleSnapshot(conversationId);
      if (!isKnownHeldPhoneStart) {
        mirrorFollowerUserPromptToPhone(conversationId, nextCodexParams, turnStartResult);
      }
      // Codex Desktop's own thread-follower-start-turn-for-host handler replies
      // with { result: <turnStartResult> }; a follower reads response.result.turn
      // off that wrapper. Returning the raw result made Desktop read `.turn` on
      // undefined ("Error creating task"), even though the turn did start.
      return { result: turnStartResult ?? null };
    } catch (error) {
      discardPendingTurnStartEntry(conversationId, pendingEntry);
      throw error;
    }
  }

  function mirrorFollowerUserPromptToPhone(threadId, turnStartParams, turnStartResult = null) {
    const text = visibleUserPromptFromInputEntries(turnStartParams?.input);
    if (!text) {
      return;
    }
    const turnId = readString(turnStartResult?.turn?.id)
      || readString(turnStartResult?.turnId)
      || readString(turnStartResult?.turn_id);
    sendPhoneNotification(JSON.stringify({
      method: "codex/event/user_message",
      params: {
        threadId,
        // Mirror the conversation projector's synthetic prompt identity
        // ("<turnId>:input") so later projected snapshots and history reads
        // reconcile into this row instead of appending a duplicate bubble.
        ...(turnId ? { turnId, id: `${turnId}:input` } : {}),
        message: text,
        text,
        remodexDesktopMirror: true,
        remodexDesktopIpcMirror: true,
        remodexActionSource: REMODEX_LIVE_OWNER_SOURCE,
        createdAt: now(),
      },
    }));
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
    if (Object.prototype.hasOwnProperty.call(params, "serviceTier")) {
      overrides.serviceTier = readString(params.serviceTier) || null;
      if (conversation) {
        conversation.latestServiceTier = overrides.serviceTier;
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

  // Current Desktop sends the whole thread-settings object; persist it so the
  // composer fields stay accurate and future Desktop-origin turns pick it up.
  function applyFollowerThreadSettings(conversationId, threadSettings) {
    if (!threadSettings || typeof threadSettings !== "object" || Array.isArray(threadSettings)) {
      return { ok: true };
    }
    const overrides = followerRuntimeOverridesByThreadId.get(conversationId) || {};
    const model = readString(threadSettings.model)
      || readString(threadSettings.collaborationMode?.settings?.model);
    const effort = threadSettings.effort;
    const hasServiceTier = Object.prototype.hasOwnProperty.call(threadSettings, "serviceTier");
    if (model) {
      overrides.model = model;
    }
    if (effort !== undefined) {
      overrides.effort = effort ?? null;
    }
    if (hasServiceTier) {
      overrides.serviceTier = readString(threadSettings.serviceTier) || null;
    }
    if (threadSettings.collaborationMode && typeof threadSettings.collaborationMode === "object") {
      overrides.collaborationMode = cloneJSON(threadSettings.collaborationMode);
    }
    followerRuntimeOverridesByThreadId.set(conversationId, overrides);

    const conversation = conversations.get(conversationId);
    if (conversation) {
      conversation.latestThreadSettings = {
        ...(conversation.latestThreadSettings && typeof conversation.latestThreadSettings === "object"
          ? conversation.latestThreadSettings
          : {}),
        ...cloneJSON(threadSettings),
      };
      if (model) {
        conversation.latestModel = model;
      }
      if (effort !== undefined) {
        conversation.latestReasoningEffort = effort ?? null;
      }
      if (hasServiceTier) {
        conversation.latestServiceTier = overrides.serviceTier;
      }
      if (overrides.collaborationMode) {
        conversation.latestCollaborationMode = cloneJSON(overrides.collaborationMode);
      }
      scheduleSnapshot(conversationId);
    }
    return { ok: true };
  }

  // Desktop followers hand the owner the full queue map and expect it to run
  // entries between turns; store it, mirror it to every window, and let the
  // turn/completed hook drain it.
  function applyFollowerQueuedFollowUps(conversationId, state) {
    const messages = state && typeof state === "object" && !Array.isArray(state)
      ? cloneJSON(state[conversationId] ?? [])
      : [];
    if (Array.isArray(messages) && messages.length > 0) {
      queuedFollowUpsByThreadId.set(conversationId, messages);
    } else {
      queuedFollowUpsByThreadId.delete(conversationId);
    }
    broadcastQueuedFollowUps(conversationId);
    const conversation = conversations.get(conversationId);
    const hasActiveTurn = conversation
      ? conversation.turns.some((turn) => normalizeToken(turn?.status) === "inprogress")
      : false;
    if (!hasActiveTurn) {
      runNextQueuedFollowUp(conversationId);
    }
    return { ok: true };
  }

  function broadcastQueuedFollowUps(conversationId) {
    ipc.sendBroadcast(THREAD_QUEUED_FOLLOWUPS_CHANGED, {
      conversationId,
      messages: cloneJSON(queuedFollowUpsByThreadId.get(conversationId) ?? []),
    });
  }

  function runNextQueuedFollowUp(threadId) {
    const queue = queuedFollowUpsByThreadId.get(threadId);
    if (!Array.isArray(queue) || queue.length === 0 || runningQueuedFollowUpThreadIds.has(threadId)) {
      return;
    }
    const entry = queue[0];
    if (entry?.pausedReason) {
      return;
    }
    const text = readString(entry?.context?.text)
      || readString(entry?.text)
      || readString(entry?.prompt);
    if (!text) {
      // Unrecognized entry shape: pause it visibly instead of discarding the
      // user's draft. The queue stays blocked (matching Desktop's first-entry
      // semantics) and the user can edit or resend it from any window.
      if (!entry || typeof entry !== "object") {
        queue.shift();
        if (queue.length === 0) {
          queuedFollowUpsByThreadId.delete(threadId);
        }
        broadcastQueuedFollowUps(threadId);
        return;
      }
      console.warn(`${logPrefix} desktop queued follow-up entry has no extractable text; pausing it for ${threadId}`);
      entry.pausedReason = "remodex-unsupported-entry";
      broadcastQueuedFollowUps(threadId);
      return;
    }

    runningQueuedFollowUpThreadIds.add(threadId);
    const conversation = conversations.get(threadId);
    const startParams = mergeFollowerRuntimeOverrides(threadId, sanitizeTurnStartParams({
      threadId,
      input: [{ type: "text", text }],
      cwd: readString(entry?.cwd) || readString(conversation?.cwd) || undefined,
    }));
    let queuedTurnParams = startParams;
    Promise.resolve()
      .then(() => normalizeTurnStartParams(cloneJSON(startParams)))
      .then((normalized) => {
        const params = normalized && typeof normalized === "object" && !Array.isArray(normalized)
          ? normalized
          : startParams;
        queuedTurnParams = params;
        const pendingEntry = rememberPendingTurnStart(threadId, params);
        if (pendingEntry) {
          insertOptimisticPendingTurn(threadId, pendingEntry);
          scheduleSnapshot(threadId);
        }
        return sendCodexRequest("turn/start", params);
      })
      .then((turnStartResult) => {
        commitAcceptedRuntimeSettings(
          threadId,
          queuedTurnParams,
          "desktop",
          readTurnIdFromResult(turnStartResult)
        );
        scheduleSnapshot(threadId);
        queue.shift();
        if (queue.length === 0) {
          queuedFollowUpsByThreadId.delete(threadId);
        }
        broadcastQueuedFollowUps(threadId);
      })
      .catch((error) => {
        console.warn(`${logPrefix} desktop queued follow-up failed for ${threadId}: ${error?.message || "unknown error"}`);
      })
      .finally(() => {
        runningQueuedFollowUpThreadIds.delete(threadId);
      });
  }

  // Fills follower turn-start params with Desktop-selected runtime overrides when
  // the request itself does not specify them. Phone-origin turns are untouched.
  function mergeFollowerRuntimeOverrides(conversationId, params) {
    const persisted = runtimeSettingsStore?.get?.(conversationId) || null;
    const persistedOverrides = persisted ? {
      model: persisted.model,
      effort: persisted.reasoningEffort,
      serviceTier: persisted.serviceTier,
    } : null;
    const liveOverrides = followerRuntimeOverridesByThreadId.get(conversationId) || null;
    const overrides = persistedOverrides || liveOverrides
      ? { ...(persistedOverrides || {}), ...(liveOverrides || {}) }
      : null;
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
    if (overrides.serviceTier && merged.serviceTier == null) {
      merged.serviceTier = overrides.serviceTier;
    }
    if (overrides.collaborationMode && merged.collaborationMode == null) {
      merged.collaborationMode = cloneJSON(overrides.collaborationMode);
    }
    return merged;
  }

  function commitAcceptedRuntimeSettings(threadId, params, source, turnId) {
    try {
      const settings = runtimeSettingsStore?.commit?.(threadId, params, { source, turnId });
      const conversation = conversations.get(threadId);
      if (settings && conversation) {
        runtimeSettingsStore.attachToConversation(threadId, conversation);
      }
      return settings;
    } catch (error) {
      console.warn(`[remodex] runtime settings persistence failed: ${error.message}`);
      return null;
    }
  }

  // True while the bridge's app-server is executing a turn for this thread, or
  // has just been asked to start one (pending starts clear on error or on the
  // matching turn/started snapshot). Queued follow-ups count as active work
  // too: releasing ownership deletes the queue, so yielding an "idle" thread
  // that still holds drafts would silently discard them. Such threads must not
  // be handed to peers or released on unsubscribe.
  function hasActiveLocalTurn(threadId) {
    if (pendingTurnStartParamsByThreadId.has(threadId)) {
      return true;
    }
    if ((queuedFollowUpsByThreadId.get(threadId) || []).length > 0) {
      return true;
    }
    const turns = conversations.get(threadId)?.turns || [];
    return turns.some((turn) => {
      const status = normalizeToken(turn?.status);
      return status === "inprogress" || status === "running" || status === "active";
    });
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
    // True while the bridge's app-server stream is authoritative for this
    // thread; used to keep fallback mirrors (rollout tail) silent.
    isThreadOwned(threadId) {
      return ownedThreadIds.has(readString(threadId));
    },
    isFreshThreadOwned(threadId) {
      const normalizedThreadId = readString(threadId);
      if (!ownedThreadIds.has(normalizedThreadId)) {
        return false;
      }
      // This bridge owns the local app-server turn directly. A quiet active
      // turn remains authoritative; releasing it solely because no patch
      // arrived for 20 seconds starts the rollout mirror as a second source.
      if (hasActiveLocalTurn(normalizedThreadId)) {
        return true;
      }
      const updatedAt = Number(conversations.get(normalizedThreadId)?.updatedAt) || 0;
      return now() - updatedAt <= liveOwnershipFreshnessMs;
    },
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
    isThreadOwned() {
      return false;
    },
    isFreshThreadOwned() {
      return false;
    },
  };
}

// Attaches the cached turn/start prompt to a just-started turn as
// turn.params.input. Desktop builds the user bubble from params.input and
// treats any userMessage item that does not dedupe against it as a mid-turn
// steer ("Steered conversation"), so the prompt must live ONLY in params.
// Pending prompts are consumed FIFO so rapid consecutive starts stay matched.
// Desktop's composer reads the followed thread's model/effort from the
// conversation-level fields; without them it falls back to showing "Custom".
// Desktop's prompt dedupe allows only these item types to precede the initial
// user message; anything else makes a userMessage item render as a steer.
// Joins the human-readable text of user input/content entries so the initial
// prompt can be matched by meaning instead of exact entry shape (the phone
// sends input_text entries while the app-server echoes text entries).
// Desktop renders the turn's user bubble from turn.params.input and labels any
// userMessage item that fails its dedupe as "Steered conversation". Keep the
// initial prompt ONLY in params: drop the first user item that duplicates it,
// or adopt it into params.input for hydrated turns that arrived item-only.
// Later userMessage items are genuine mid-turn steers and stay untouched.
// Replays just-emitted patches onto the retained broadcast baseline. The
// baseline is a private copy and patch values are already private clones, so
// in-place mutation is safe and avoids re-cloning the whole state per flush.
// Desktop's user-bubble renderer extracts images from input entries shaped
// {type: "image", url}; runtimes sometimes fall back to the image_url shape,
// which Desktop would silently skip.
function normalizeInputEntriesForDesktop(input) {
  if (!Array.isArray(input)) {
    return [];
  }
  return input.map((entry) => {
    if (!entry || typeof entry !== "object") {
      return entry;
    }
    if (normalizeToken(entry.type) === "imageurl") {
      const url = readString(entry.url)
        || readString(entry.image_url?.url)
        || readString(entry.imageUrl?.url)
        || readString(entry.image_url)
        || readString(entry.imageUrl);
      if (url) {
        return { type: "image", url };
      }
    }
    return entry;
  });
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

function readTurnIdFromResult(result) {
  return readString(result?.turn?.id)
    || readString(result?.turnId)
    || readString(result?.turn_id)
    || readString(result?.result?.turn?.id)
    || readString(result?.result?.turnId)
    || readString(result?.result?.turn_id);
}

function readThreadFromPayload(result) {
  if (!result || typeof result !== "object") {
    return null;
  }
  return result.thread && typeof result.thread === "object"
    ? result.thread
    : result;
}

function readConversationIdFromFollowerParams(params) {
  return readString(params?.conversationId)
    || readString(params?.conversation_id)
    || readString(params?.threadId)
    || readString(params?.thread_id)
    || readString(params?.turnStartParams?.threadId)
    || readString(params?.turn_start_params?.threadId);
}

module.exports = {
  applyAppServerMessageToConversationState,
  buildConversationStatePatches,
  buildConversationStateFromThread,
  createDesktopIpcLiveOwner,
  resolveDefaultIpcSocketPath,
};
