// FILE: desktop-ipc-action-follower.js
// Purpose: Mirrors live Codex Desktop IPC pending actions to the phone and routes replies back to the desktop runtime.
// Layer: CLI helper
// Exports: createDesktopIpcActionFollower, projectPendingDesktopActions
// Depends on: net, ./desktop-ipc-conversation-projector, ./desktop-ipc-shared

const { createHash } = require("crypto");
const net = require("net");

const {
  createDesktopConversationProjector,
  projectDesktopConversationStateToThread,
} = require("./desktop-ipc-conversation-projector");
const {
  DESKTOP_IPC_METHOD_VERSIONS: METHOD_VERSION_BY_NAME,
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
// Fresh Desktop threads are not materialized in the local thread store yet, so
// baseline reads fail until the rollout flushes; retry with backoff instead of
// hammering thread/read on every patch broadcast.
const MAX_BASELINE_RECOVERY_ATTEMPTS = 5;
const BASELINE_RECOVERY_BASE_DELAY_MS = 1_000;
const BASELINE_RECOVERY_MAX_DELAY_MS = 15_000;
const MAX_QUEUED_CHANGES_PER_THREAD = 300;
const BACKGROUND_DISCONNECT_GRACE_MS = 30_000;
// Phone interest survives per-thread release by design, so cap the set to keep a
// marathon single Desktop connection from accumulating every thread id forever.
const MAX_ACTIVE_THREAD_IDS = 512;
const DESKTOP_IPC_ACTION_SOURCE = "desktop-ipc-action-follower";
const REMODEX_LIVE_OWNER_SOURCE = "desktop-ipc-live-owner";
const DESKTOP_STATE_READ_METHODS = new Set(["thread/read", "thread/resume", "thread/turns/list"]);
// Sidebar refreshes should also keep the Litter subscription alive. Without
// this, a phone with no selected chat never connects to the Desktop bus and
// cannot discover runs that started on the Mac.
const DESKTOP_BACKGROUND_DISCOVERY_METHODS = new Set(["thread/list"]);
const DESKTOP_TURNS_CURSOR_PREFIX = "remodex-desktop-turns:";
// A cached Desktop state that claims an active turn is only trustworthy while
// Desktop keeps streaming updates for it. Live runs broadcast deltas far more
// often than this window; a silent "active" cache is a stale reconnect echo
// (e.g. Desktop never saw the turn finish) and must not answer phone reads, or
// the phone shows a phantom running indicator until real history loads.
const STALE_ACTIVE_READ_MAX_AGE_MS = 20_000;
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
const APPROVAL_DECISIONS = new Set(["accept", "acceptForSession", "decline", "cancel"]);

// The app-server turns/list contract is newest-first by default. Keep the
// projected Desktop snapshot in that contract so iOS can reverse each page
// exactly once when rebuilding chronological history.
function buildDesktopTurnsListResult(turns, params = {}) {
  const chronologicalTurns = Array.isArray(turns) ? turns : [];
  const snapshotRevision = desktopTurnsSnapshotRevision(chronologicalTurns);
  const direction = normalizeToken(readString(params?.sortDirection) || "desc") === "asc"
    ? "asc"
    : "desc";
  const orderedTurns = direction === "asc"
    ? chronologicalTurns.slice()
    : chronologicalTurns.slice().reverse();

  let startIndex = 0;
  const cursor = readString(params?.cursor);
  if (cursor) {
    const parsedCursor = parseDesktopTurnsCursor(
      cursor,
      direction,
      snapshotRevision,
      orderedTurns
    );
    if (parsedCursor == null) {
      return null;
    }
    startIndex = parsedCursor;
  }

  const requestedLimit = Number(params?.limit);
  const limit = Number.isFinite(requestedLimit) && requestedLimit > 0
    ? Math.floor(requestedLimit)
    : orderedTurns.length;
  const page = orderedTurns.slice(startIndex, startIndex + limit);
  const hasMore = startIndex + page.length < orderedTurns.length;
  const nextCursor = hasMore && page.length > 0
    ? desktopTurnsCursor(
      direction,
      snapshotRevision,
      page[page.length - 1],
      startIndex + page.length
    )
    : null;
  const clonedPage = cloneJSON(page);
  return {
    data: clonedPage,
    nextCursor,
    hasMore,
  };
}

function isDesktopTurnsCursor(value) {
  return readString(value).startsWith(DESKTOP_TURNS_CURSOR_PREFIX);
}

function desktopTurnsCursor(direction, snapshotRevision, turn, nextIndex) {
  const turnId = readString(turn?.id)
    || readString(turn?.turnId)
    || readString(turn?.turn_id);
  const anchor = turnId ? `id:${encodeURIComponent(turnId)}` : `index:${nextIndex}`;
  return `${DESKTOP_TURNS_CURSOR_PREFIX}${direction}:${snapshotRevision}:${anchor}`;
}

function parseDesktopTurnsCursor(cursor, direction, snapshotRevision, orderedTurns) {
  const prefix = `${DESKTOP_TURNS_CURSOR_PREFIX}${direction}:${snapshotRevision}:`;
  if (!cursor.startsWith(prefix)) {
    return null;
  }
  const anchor = cursor.slice(prefix.length);
  if (anchor.startsWith("id:")) {
    let turnId = "";
    try {
      turnId = decodeURIComponent(anchor.slice(3));
    } catch {
      return null;
    }
    const anchorIndex = orderedTurns.findIndex((turn) => (
      readString(turn?.id) === turnId
      || readString(turn?.turnId) === turnId
      || readString(turn?.turn_id) === turnId
    ));
    return anchorIndex === -1 ? null : anchorIndex + 1;
  }
  if (anchor.startsWith("index:")) {
    const parsedIndex = Number(anchor.slice(6));
    return Number.isInteger(parsedIndex) && parsedIndex >= 0 && parsedIndex <= orderedTurns.length
      ? parsedIndex
      : null;
  }
  return null;
}

function desktopTurnsSnapshotRevision(turns) {
  const hash = createHash("sha256");
  const paginationStructure = (Array.isArray(turns) ? turns : []).map((turn) => ({
    id: readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id),
    input: turn?.input ?? turn?.prompt ?? null,
    userItems: (Array.isArray(turn?.items) ? turn.items : []).flatMap((item) => {
      const role = readString(item?.role).toLowerCase();
      const type = normalizeToken(readString(item?.type));
      const isUserItem = role === "user" || type === "usermessage";
      if (!isUserItem) {
        return [];
      }
      return [{
        id: readString(item?.id) || readString(item?.itemId) || readString(item?.item_id),
        role,
        type,
        // Prompt text disambiguates index-derived turn ids after insertion or
        // reorder. Non-user item lifecycles do not change turn pagination.
        userContent: item?.text ?? item?.content ?? null,
      }];
    }),
  }));
  hash.update(JSON.stringify(paginationStructure));
  return hash.digest("hex").slice(0, 24);
}

// Opens the Desktop IPC bus on demand and exposes Mac-owned pending actions as normal app-server requests.
function createDesktopIpcActionFollower({
  sendApplicationResponse,
  readConversationState = null,
  forwardToLocalCodex = null,
  // Synchronous authority check against the bridge's own live owner: threads
  // streamed by the local app-server must never be held, served, or routed as
  // Desktop-owned. Broadcast-driven liveOwnerThreadIds lags this check, so it
  // alone cannot close the race between a local claim and a Desktop echo.
  isLocallyOwnedThread = () => false,
  normalizeTurnStartParams = (params) => params,
  logPrefix = "[remodex]",
  socketPath = resolveDefaultIpcSocketPath(),
  netModule = net,
  now = () => Date.now(),
  snapshotDebounceMs = 0,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
  onNormalizedHistoryIndexRebuilt = () => {},
  requestTimeoutMs = REQUEST_TIMEOUT_MS,
  ownershipProbeTimeoutMs = OWNERSHIP_PROBE_TIMEOUT_MS,
  backgroundDisconnectGraceMs = BACKGROUND_DISCONNECT_GRACE_MS,
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
  const rawStateUpdatedAtByThreadId = new Map();
  const pendingSnapshotsByThreadId = new Map();
  // History and live updates have different authorities. Once Desktop exposes
  // normalized history that the legacy turns array does not fully cover, keep
  // canonical paging on app-server/JSONL for this Desktop source epoch while
  // still allowing a bounded Desktop tail to own live deltas.
  const canonicalHistoryThreadIds = new Set();
  const canonicalHistoryReplacementSentThreadIds = new Set();
  const projectedLiveActiveTurnIdsByThreadId = new Map();
  const desktopLiveLifecycleByThreadId = new Map();
  const normalizedLiveIndexesByThreadId = new Map();
  const staleYieldedThreadIds = new Set();
  const conversationProjector = createDesktopConversationProjector({ now });
  const pendingRoutesByRequestId = new Map();
  const activeThreadIds = new Set();
  // Threads discovered from Litter snapshots before the phone reads them.
  // Their raw state is retained for lifecycle detection, but their transcript
  // stays off the relay until the user actually opens the chat.
  const backgroundOnlyThreadIds = new Set();
  // Lifecycle already announced to the phone must outlive the raw Litter
  // baseline. Otherwise a disconnect/eviction can erase the only evidence
  // needed to send the matching completion and leave a phantom running badge.
  const announcedBackgroundTurnsByThreadId = new Map();
  const backgroundDisconnectTimersByThreadId = new Map();
  // JS Set preserves insertion order; delete-before-add refreshes recency, and
  // cap eviction skips threads with pending prompts so approvals are not lost.
  function rememberActiveThread(threadId) {
    activeThreadIds.delete(threadId);
    activeThreadIds.add(threadId);
    while (activeThreadIds.size > MAX_ACTIVE_THREAD_IDS) {
      const oldest = oldestEvictableActiveThreadId();
      if (oldest === undefined) {
        break;
      }
      activeThreadIds.delete(oldest);
      forgetEvictedThreadState(oldest);
    }
  }

  function oldestEvictableActiveThreadId() {
    for (const threadId of activeThreadIds) {
      if (!hasPendingProjectedActions(threadId)
        && !announcedBackgroundTurnsByThreadId.has(threadId)) {
        return threadId;
      }
    }
    return undefined;
  }

  function hasPendingProjectedActions(threadId) {
    for (const route of pendingRoutesByRequestId.values()) {
      if (route.threadId === threadId) {
        return true;
      }
    }
    return false;
  }

  // Cleanup for cap-evicted threads only: clears follower caches without touching
  // liveOwnerThreadIds (still-owned local streams must not become hijackable) and
  // without rejecting held requests (removeDesktopThreadState handles real removal).
  function forgetEvictedThreadState(threadId) {
    cancelPendingSnapshot(threadId);
    settleAnnouncedBackgroundTurn(threadId, "interrupted");
    backgroundOnlyThreadIds.delete(threadId);
    rawStatesByThreadId.delete(threadId);
    rawStateUpdatedAtByThreadId.delete(threadId);
    canonicalHistoryThreadIds.delete(threadId);
    canonicalHistoryReplacementSentThreadIds.delete(threadId);
    projectedLiveActiveTurnIdsByThreadId.delete(threadId);
    desktopLiveLifecycleByThreadId.delete(threadId);
    normalizedLiveIndexesByThreadId.delete(threadId);
    conversationProjector.remove(threadId);
    queuedChangesByThreadId.delete(threadId);
    baselineRecoveryStateByThreadId.delete(threadId);
    recoveringThreadIds.delete(threadId);
    ownershipProbeDeadlinesByThreadId.delete(threadId);
    pendingOwnershipProbeTokensByThreadId.delete(threadId);
    desktopOwnedByProbeThreadIds.delete(threadId);
  }
  const recoveringThreadIds = new Set();
  const queuedChangesByThreadId = new Map();
  const baselineRecoveryStateByThreadId = new Map();
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
    if (DESKTOP_BACKGROUND_DISCOVERY_METHODS.has(method)) {
      ipc.ensureConnected();
    }
    if (DESKTOP_STATE_READ_METHODS.has(method)) {
      const threadId = readThreadId(message?.params);
      if (threadId && backgroundOnlyThreadIds.delete(threadId)) {
        const rawState = rawStatesByThreadId.get(threadId);
        // Reconcile any lifecycle that may have completed while the raw
        // baseline was unavailable before handing full ownership to the
        // projector. From this point normal projected events own completion.
        if (rawState) {
          syncBackgroundThreadLifecycle(threadId, null, rawState);
        } else {
          settleAnnouncedBackgroundTurn(threadId, "interrupted");
        }
        clearBackgroundDisconnectTimer(threadId);
        announcedBackgroundTurnsByThreadId.delete(threadId);
        if (rawState) {
          // The read response below carries the full baseline. Seed the
          // projector so the next patch becomes a delta instead of replaying
          // that baseline a second time.
          const liveState = boundedDesktopLiveStateForThread(threadId, rawState);
          conversationProjector.seed(threadId, liveState);
          rememberDesktopLiveProjection(threadId, liveState);
        }
      }
    }
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

    rememberActiveThread(threadId);
    if (!rawStatesByThreadId.has(threadId)
      && !liveOwnerThreadIds.has(threadId)
      && !isLocallyOwnedThread(threadId)) {
      ownershipProbeDeadlinesByThreadId.set(threadId, now() + ownershipProbeTimeoutMs);
    }
    ipc.ensureConnected();
    return false;
  }

  function stopAll() {
    for (const threadId of pendingSnapshotsByThreadId.keys()) {
      cancelPendingSnapshot(threadId);
    }
    rawStatesByThreadId.clear();
    rawStateUpdatedAtByThreadId.clear();
    canonicalHistoryThreadIds.clear();
    canonicalHistoryReplacementSentThreadIds.clear();
    projectedLiveActiveTurnIdsByThreadId.clear();
    desktopLiveLifecycleByThreadId.clear();
    normalizedLiveIndexesByThreadId.clear();
    conversationProjector.reset();
    pendingRoutesByRequestId.clear();
    activeThreadIds.clear();
    backgroundOnlyThreadIds.clear();
    announcedBackgroundTurnsByThreadId.clear();
    for (const timer of backgroundDisconnectTimersByThreadId.values()) {
      clearTimeout(timer);
    }
    backgroundDisconnectTimersByThreadId.clear();
    recoveringThreadIds.clear();
    baselineRecoveryStateByThreadId.clear();
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
    if (isSnapshotChange(params.change)) {
      clearBackgroundDisconnectTimer(threadId);
    }
    const peerOwnershipSnapshot = isPeerOwnershipSnapshot(params);
    if (peerOwnershipSnapshot && !isLocallyOwnedThread(threadId)) {
      liveOwnerThreadIds.delete(threadId);
      ownershipProbeDeadlinesByThreadId.delete(threadId);
      desktopOwnedByProbeThreadIds.delete(threadId);
    } else if (liveOwnerThreadIds.has(threadId) || isLocallyOwnedThread(threadId)) {
      // Desktop echoes of a locally-streamed thread must not become follower
      // state: they would shadow the app-server as the source for reads and
      // mirror ghost rows the phone already has.
      return;
    }
    // Litter sends one snapshot for every loaded conversation when this client
    // connects. Keep those baselines locally so a later idle -> running patch
    // can update the sidebar even if the phone never opened that chat. The
    // background-only path below emits lifecycle only, never transcript rows.
    if (!activeThreadIds.has(threadId) && isSnapshotChange(params.change)) {
      rememberActiveThread(threadId);
      backgroundOnlyThreadIds.add(threadId);
    }
    if (!activeThreadIds.has(threadId)) {
      return;
    }

    if (recoveringThreadIds.has(threadId)) {
      queueThreadChange(threadId, params.change);
      return;
    }

    const pendingSnapshot = pendingSnapshotsByThreadId.get(threadId);
    if (pendingSnapshot && isPatchChange(params.change)) {
      const patchedSnapshot = applyConversationStateChange(pendingSnapshot.state, params.change);
      if (patchedSnapshot) {
        pendingSnapshot.state = patchedSnapshot;
        return;
      }
      flushPendingSnapshot(threadId);
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
          rawStateUpdatedAtByThreadId.set(threadId, now());
          if (!backgroundOnlyThreadIds.has(threadId)) {
            conversationProjector.seed(threadId, speculativeState);
          }
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

    if (isSnapshotChange(params.change) && snapshotDebounceMs > 0) {
      schedulePendingSnapshot(threadId, nextState);
      return;
    }

    commitConversationState(threadId, nextState, {
      isFullSnapshot: isSnapshotChange(params.change),
      change: params.change,
    });
  }

  function schedulePendingSnapshot(threadId, state) {
    cancelPendingSnapshot(threadId);
    const timer = setTimeoutFn(() => {
      const pending = pendingSnapshotsByThreadId.get(threadId);
      if (!pending || pending.timer !== timer) {
        return;
      }
      pendingSnapshotsByThreadId.delete(threadId);
      commitConversationState(threadId, pending.state, { isFullSnapshot: true });
    }, Math.max(0, snapshotDebounceMs));
    timer?.unref?.();
    pendingSnapshotsByThreadId.set(threadId, { state, timer });
  }

  function flushPendingSnapshot(threadId) {
    const pending = pendingSnapshotsByThreadId.get(threadId);
    if (!pending) {
      return false;
    }
    clearTimeoutFn(pending.timer);
    pendingSnapshotsByThreadId.delete(threadId);
    commitConversationState(threadId, pending.state, { isFullSnapshot: true });
    return true;
  }

  function cancelPendingSnapshot(threadId) {
    const pending = pendingSnapshotsByThreadId.get(threadId);
    if (!pending) {
      return false;
    }
    clearTimeoutFn(pending.timer);
    pendingSnapshotsByThreadId.delete(threadId);
    return true;
  }

  function commitConversationState(threadId, nextState, {
    isFullSnapshot = false,
    change = null,
  } = {}) {
    if (liveOwnerThreadIds.has(threadId) || isLocallyOwnedThread(threadId)) {
      releaseDesktopThreadState(threadId);
      return false;
    }
    if (isFullSnapshot) {
      rebuildNormalizedLiveIndex(threadId, nextState);
    } else {
      updateNormalizedLiveIndex(threadId, nextState, change);
    }
    const previousState = rawStatesByThreadId.get(threadId) || null;
    rawStatesByThreadId.set(threadId, nextState);
    rawStateUpdatedAtByThreadId.set(threadId, now());
    // A usable state arrived: recovery bookkeeping and pre-baseline queued
    // patches are obsolete (snapshots replace state wholesale).
    baselineRecoveryStateByThreadId.delete(threadId);
    if (isFullSnapshot) {
      queuedChangesByThreadId.delete(threadId);
    }
    if (backgroundOnlyThreadIds.has(threadId)) {
      syncBackgroundThreadLifecycle(threadId, previousState, nextState);
    } else {
      syncProjectedConversationState(threadId, nextState, {
        isFullSnapshot,
      });
    }
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
    releaseHeldFollowerRequests(threadId, { toDesktop: true });
    return true;
  }

  function rebuildNormalizedLiveIndex(threadId, state) {
    const index = createNormalizedLiveIndex(state);
    if (index) {
      normalizedLiveIndexesByThreadId.set(threadId, index);
      onNormalizedHistoryIndexRebuilt(threadId);
    } else {
      normalizedLiveIndexesByThreadId.delete(threadId);
    }
  }

  function updateNormalizedLiveIndex(threadId, state, change) {
    const index = normalizedLiveIndexesByThreadId.get(threadId);
    if (!index) {
      if (hasNormalizedTurnStore(state)) {
        rebuildNormalizedLiveIndex(threadId, state);
      }
      return;
    }
    if (normalizedLiveIndexNeedsRebuild(change)) {
      rebuildNormalizedLiveIndex(threadId, state);
      return;
    }
    refreshTouchedNormalizedActiveTurns(index, state, change);
  }

  function onDisconnect() {
    // Patch baselines are connection-scoped (Desktop re-sends a snapshot after
    // reconnect), but the projector cache is not: keeping it lets the reconnect
    // snapshot diff against already-mirrored content instead of replaying it.
    for (const threadId of pendingSnapshotsByThreadId.keys()) {
      cancelPendingSnapshot(threadId);
    }
    rawStatesByThreadId.clear();
    rawStateUpdatedAtByThreadId.clear();
    // A reconnect is a new Desktop source epoch. The first normalized snapshot
    // must repair canonical history instead of silently seeding content that may
    // have changed while IPC was down.
    canonicalHistoryReplacementSentThreadIds.clear();
    projectedLiveActiveTurnIdsByThreadId.clear();
    desktopLiveLifecycleByThreadId.clear();
    normalizedLiveIndexesByThreadId.clear();
    recoveringThreadIds.clear();
    baselineRecoveryStateByThreadId.clear();
    queuedChangesByThreadId.clear();
    pendingOwnershipProbeTokensByThreadId.clear();
    desktopOwnedByProbeThreadIds.clear();
    for (const threadId of announcedBackgroundTurnsByThreadId.keys()) {
      scheduleBackgroundDisconnectSettlement(threadId);
    }
    // Keep activeThreadIds: phone interest is phone-scoped, not connection-scoped.
    // Clearing it here would make reconnect snapshots for a thread the phone is
    // still viewing fail the activeThreadIds.has() guard until the phone happens
    // to issue a fresh read. Growth is bounded by the LRU cap instead.
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
    cancelPendingSnapshot(threadId);
    settleAnnouncedBackgroundTurn(threadId, "interrupted");
    if (backgroundOnlyThreadIds.delete(threadId)) {
      activeThreadIds.delete(threadId);
    }
    liveOwnerThreadIds.add(threadId);
    ownershipProbeDeadlinesByThreadId.delete(threadId);
    pendingOwnershipProbeTokensByThreadId.delete(threadId);
    desktopOwnedByProbeThreadIds.delete(threadId);
    syncProjectedActions(threadId, []);
    rawStatesByThreadId.delete(threadId);
    rawStateUpdatedAtByThreadId.delete(threadId);
    canonicalHistoryThreadIds.delete(threadId);
    canonicalHistoryReplacementSentThreadIds.delete(threadId);
    projectedLiveActiveTurnIdsByThreadId.delete(threadId);
    desktopLiveLifecycleByThreadId.delete(threadId);
    normalizedLiveIndexesByThreadId.delete(threadId);
    conversationProjector.remove(threadId);
    queuedChangesByThreadId.delete(threadId);
    baselineRecoveryStateByThreadId.delete(threadId);
    releaseHeldFollowerRequests(threadId, { toDesktop: false });
  }

  // The live owner is releasing/removing its stream, not claiming it; cancel any
  // speculative phone request instead of routing it to either runtime. Phone
  // interest (activeThreadIds) deliberately survives the release: if Desktop
  // picks the thread up next, its broadcasts must be processed immediately
  // instead of being dropped until the phone happens to issue another read.
  function removeDesktopThreadState(threadId) {
    cancelPendingSnapshot(threadId);
    settleAnnouncedBackgroundTurn(threadId, "interrupted");
    if (backgroundOnlyThreadIds.delete(threadId)) {
      activeThreadIds.delete(threadId);
    }
    liveOwnerThreadIds.delete(threadId);
    ownershipProbeDeadlinesByThreadId.delete(threadId);
    pendingOwnershipProbeTokensByThreadId.delete(threadId);
    desktopOwnedByProbeThreadIds.delete(threadId);
    syncProjectedActions(threadId, []);
    rawStatesByThreadId.delete(threadId);
    rawStateUpdatedAtByThreadId.delete(threadId);
    canonicalHistoryThreadIds.delete(threadId);
    canonicalHistoryReplacementSentThreadIds.delete(threadId);
    projectedLiveActiveTurnIdsByThreadId.delete(threadId);
    desktopLiveLifecycleByThreadId.delete(threadId);
    normalizedLiveIndexesByThreadId.delete(threadId);
    conversationProjector.remove(threadId);
    queuedChangesByThreadId.delete(threadId);
    baselineRecoveryStateByThreadId.delete(threadId);
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
      || liveOwnerThreadIds.has(threadId)
      || isLocallyOwnedThread(threadId)) {
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
        if (liveOwnerThreadIds.has(threadId) || isLocallyOwnedThread(threadId)) {
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
      && !isLocallyOwnedThread(threadId)
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
    if (!route || liveOwnerThreadIds.has(route.threadId) || isLocallyOwnedThread(route.threadId)) {
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

  // Legacy Desktop snapshots can still serve reads, but normalized history is
  // permanently canonical for this Desktop source epoch. A later snapshot that
  // happens to refill raw turns must not reclaim paging and flap live sources.
  function tryServeDesktopOwnedRead(message) {
    const method = readString(message?.method);
    if (!DESKTOP_STATE_READ_METHODS.has(method) || message?.id == null) {
      return false;
    }
    const threadId = readThreadId(message.params);
    const ownsDesktopCursor = method === "thread/turns/list"
      && isDesktopTurnsCursor(message.params?.cursor);
    if (!threadId) {
      return false;
    }
    if (liveOwnerThreadIds.has(threadId) || isLocallyOwnedThread(threadId)) {
      return ownsDesktopCursor ? rejectDesktopTurnsCursor(message) : false;
    }
    const rawState = rawStatesByThreadId.get(threadId);
    if (pendingSnapshotsByThreadId.has(threadId)) {
      return ownsDesktopCursor ? rejectDesktopTurnsCursor(message) : false;
    }
    if (!rawState) {
      return ownsDesktopCursor ? rejectDesktopTurnsCursor(message) : false;
    }

    rememberActiveThread(threadId);
    // Newer Litter snapshots keep materialized history in
    // turnHistory.history.entitiesByKey while leaving the legacy top-level
    // turns array empty or limited to only the current turn. The Desktop
    // projector cannot decode the remaining normalized store, so a partial
    // legacy projection is not authoritative. Yield before answering with
    // truncated history and let app-server/JSONL paging reconstruct it.
    if (hasNormalizedHistoryOutsideRawTurns(
      rawState,
      normalizedLiveIndexesByThreadId.get(threadId)
    )) {
      canonicalHistoryThreadIds.add(threadId);
    }
    if (canonicalHistoryThreadIds.has(threadId)) {
      if (isDesktopLiveTurnStateSnapshotRequest(message)) {
        const liveState = boundedDesktopLiveStateForThread(threadId, rawState);
        sendApplicationResponse(JSON.stringify({
          id: message.id,
          result: buildDesktopLiveTurnStateResult(liveState.turns),
        }));
        return true;
      }
      // Falling through only starts a canonical request. It may be a metadata-
      // only resume or may fail before history arrives, so keep the repair
      // signal armed until a live update can force a verified reload.
      return ownsDesktopCursor ? rejectDesktopTurnsCursor(message) : false;
    }
    const thread = projectDesktopConversationStateToThread(threadId, rawState, { now });
    // A run that Desktop stopped streaming updates for is not a live run: serving
    // it from cache would answer thread-list refreshes with a phantom "running"
    // turn until real history loads. Let the local app-server answer instead.
    if (hasActiveProjectedTurn(thread)
      && isRawStateStaleForActiveRead(threadId)
      && !ownsDesktopCursor) {
      staleYieldedThreadIds.add(threadId);
      return false;
    }
    const result = method === "thread/turns/list"
      ? buildDesktopTurnsListResult(thread.turns, message.params)
      : {
          // The projected thread is the entire payload the phone decodes;
          // echoing the raw Desktop conversationState alongside it doubled
          // heavy threads past the relay frame limit for nothing.
          thread,
        };
    if (!result) {
      return ownsDesktopCursor ? rejectDesktopTurnsCursor(message) : false;
    }
    sendApplicationResponse(JSON.stringify({
      id: message.id,
      result,
    }));
    return true;
  }

  function rejectDesktopTurnsCursor(message) {
    sendApplicationResponse(JSON.stringify({
      id: message.id,
      error: {
        code: -32602,
        message: "Desktop history changed while paging. Reload this thread to restart history pagination.",
      },
    }));
    return true;
  }

  function isDesktopLiveTurnStateSnapshotRequest(message) {
    if (readString(message?.method) !== "thread/turns/list"
      || readString(message?.params?.cursor)
      || message?.params?.remodexRequireCanonical === true) {
      return false;
    }
    if (message?.params?.remodexTurnStateOnly === true) {
      return true;
    }
    // Remodex iPhone 2.1 predates the explicit marker. Its running-state probe
    // has this unique request shape; actual history pages use limits 1 and 5.
    return Number(message?.params?.limit) === 8
      && normalizeToken(readString(message?.params?.sortDirection) || "desc") === "desc";
  }

  function buildDesktopLiveTurnStateResult(turns) {
    const data = (Array.isArray(turns) ? turns : [])
      .slice()
      .reverse()
      .map((turn) => {
        const id = readString(turn?.id)
          || readString(turn?.turnId)
          || readString(turn?.turn_id);
        return {
          ...(id ? { id } : {}),
          // Unknown status must never invent an interruptible turn. Live
          // activity still carries explicit inProgress/running statuses.
          status: readString(turn?.status) || "completed",
        };
      });
    return {
      data,
      nextCursor: null,
      hasMore: false,
      remodexDesktopLiveState: true,
    };
  }

  function hasActiveProjectedTurn(thread) {
    return (thread?.turns || []).some((turn) => turn?.status === "inProgress")
      || readString(thread?.status?.type) === "active";
  }

  function hasNormalizedHistoryOutsideRawTurns(rawState, normalizedIndex = null) {
    if (normalizedIndex) {
      return normalizedIndex.hasHistoryOutsideRawTurns;
    }
    const turnHistory = rawState?.turnHistory ?? rawState?.turn_history;
    const history = turnHistory?.history;
    const entities = history?.entitiesByKey ?? history?.entities_by_key;
    if (!entities || typeof entities !== "object" || Array.isArray(entities)) {
      return false;
    }
    const rawTurnIds = new Set((Array.isArray(rawState?.turns) ? rawState.turns : [])
      .map((turn) => (
        readString(turn?.id)
        || readString(turn?.turnId)
        || readString(turn?.turn_id)
      ))
      .filter(Boolean));
    for (const [key, entity] of Object.entries(entities)) {
      const normalizedTurnId = key.startsWith("turn:")
        ? readString(key.slice("turn:".length))
        : readString(entity?.turnId) || readString(entity?.turn_id);
      if (normalizedTurnId && !rawTurnIds.has(normalizedTurnId)) {
        return true;
      }
    }
    return false;
  }

  function isRawStateStaleForActiveRead(threadId) {
    const updatedAt = rawStateUpdatedAtByThreadId.get(threadId) || 0;
    return now() - updatedAt > STALE_ACTIVE_READ_MAX_AGE_MS;
  }

  function boundedDesktopLiveStateForThread(threadId, state) {
    return boundedDesktopLiveState(
      state,
      now(),
      projectedLiveActiveTurnIdsByThreadId.get(threadId) || new Set(),
      normalizedLiveIndexesByThreadId.get(threadId) || null
    );
  }

  function rememberDesktopLiveProjection(threadId, liveState) {
    const activeTurns = activeDesktopTurnDescriptors(liveState);
    const activeTurnIds = new Set(activeTurns.map((turn) => turn.id));
    if (activeTurnIds.size > 0) {
      projectedLiveActiveTurnIdsByThreadId.set(threadId, activeTurnIds);
    } else {
      projectedLiveActiveTurnIdsByThreadId.delete(threadId);
    }
    desktopLiveLifecycleByThreadId.set(
      threadId,
      new Map(activeTurns.map((turn) => [turn.id, turn]))
    );
  }

  function emitDesktopSnapshotLifecycleTransition(threadId, liveState) {
    const previousById = desktopLiveLifecycleByThreadId.get(threadId) || new Map();
    const nextTurns = activeDesktopTurnDescriptors(liveState);
    const nextById = new Map(nextTurns.map((turn) => [turn.id, turn]));
    for (const previous of previousById.values()) {
      if (nextById.has(previous.id)) {
        continue;
      }
      const terminalTurn = (liveState.turns || []).find((turn) => turnIdOf(turn) === previous.id);
      const terminalStatus = readString(terminalTurn?.status) || "completed";
      sendApplicationResponse(JSON.stringify(desktopLiveTurnLifecycleNotification(
        "turn/completed",
        threadId,
        { id: previous.id, status: terminalStatus }
      )));
    }
    for (const next of nextTurns) {
      if (previousById.has(next.id)) {
        continue;
      }
      sendApplicationResponse(JSON.stringify(desktopLiveTurnLifecycleNotification(
        "turn/started",
        threadId,
        next
      )));
    }
  }

  function syncProjectedConversationState(threadId, nextState, { isFullSnapshot = false } = {}) {
    const resumedAfterStaleYield = staleYieldedThreadIds.delete(threadId);
    if (!canonicalHistoryThreadIds.has(threadId)
      && hasNormalizedHistoryOutsideRawTurns(
        nextState,
        normalizedLiveIndexesByThreadId.get(threadId)
      )) {
      canonicalHistoryThreadIds.add(threadId);
    }
    const liveState = boundedDesktopLiveStateForThread(threadId, nextState);
    if (canonicalHistoryThreadIds.has(threadId)
      && !canonicalHistoryReplacementSentThreadIds.has(threadId)) {
      canonicalHistoryReplacementSentThreadIds.add(threadId);
      conversationProjector.remove(threadId);
      // Seed the bounded live tail before asking the phone for canonical
      // history. Subsequent 8-50ms Desktop patches then become small deltas
      // instead of replaying hundreds of current-turn items as a baseline.
      conversationProjector.seed(threadId, liveState);
      sendApplicationResponse(JSON.stringify({
        method: "thread/replaced",
        params: {
          threadId,
          remodexDesktopMirror: true,
          remodexDesktopIpcMirror: true,
          remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
        },
      }));
      emitDesktopSnapshotLifecycleTransition(threadId, liveState);
      rememberDesktopLiveProjection(threadId, liveState);
      return;
    }
    if (isFullSnapshot && canonicalHistoryThreadIds.has(threadId)) {
      // Litter can immediately rehydrate the same normalized snapshot with a
      // completely different set of item IDs. Treat full snapshots as source
      // baselines: preserve only turn lifecycle, then seed. Item diffs resume
      // on subsequent patches and cannot replay hundreds of old rows.
      emitDesktopSnapshotLifecycleTransition(threadId, liveState);
      conversationProjector.seed(threadId, liveState);
      rememberDesktopLiveProjection(threadId, liveState);
      return;
    }
    if (resumedAfterStaleYield) {
      // Switching back from rollout/app-server history to fresh Desktop state
      // is a source epoch change. Force a baseline + thread/replaced repair.
      conversationProjector.remove(threadId);
    }
    const output = conversationProjector.project(threadId, liveState);
    if (resumedAfterStaleYield || output.type === "fullReplace" || output.type === "baseline") {
      // fullReplace: synthesized turn ids just became real, stale rows must go.
      // baseline: the projector cache was evicted, so updates that arrived while
      // unobserved were never mirrored. Both cases need the phone to rebuild the
      // thread from canonical history instead of trusting incremental rows.
      // The phone reacts to thread/replaced by re-reading canonical history;
      // it never decodes an embedded thread, and heavy threads would blow the
      // relay frame limit if we shipped one.
      sendApplicationResponse(JSON.stringify({
        method: "thread/replaced",
        params: {
          threadId,
          remodexDesktopMirror: true,
          remodexDesktopIpcMirror: true,
          remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
        },
      }));
    }
    for (const notification of output.notifications || []) {
      sendApplicationResponse(JSON.stringify(notification));
    }
    rememberDesktopLiveProjection(threadId, liveState);
  }

  // Unopened chats only need run-state signals for the sidebar. Sending the
  // projector's full bootstrap here would replay every historical item from
  // every running Desktop chat onto the phone during a sidebar refresh.
  function syncBackgroundThreadLifecycle(threadId, _previousState, nextState) {
    const announcedTurn = announcedBackgroundTurnsByThreadId.get(threadId) || null;
    const previousTurnId = readString(announcedTurn?.id);
    const retainedTurnIds = previousTurnId ? new Set([previousTurnId]) : new Set();
    const liveState = boundedDesktopLiveState(
      nextState,
      now(),
      retainedTurnIds,
      normalizedLiveIndexesByThreadId.get(threadId) || null
    );
    const nextActiveTurn = latestActiveRawTurn(liveState);
    const nextTurnId = readString(nextActiveTurn?.id);

    if (previousTurnId && previousTurnId !== nextTurnId) {
      const settledTurn = backgroundRawTurnById(liveState, previousTurnId)
        || announcedTurn;
      const settledStatus = readString(settledTurn?.status);
      settleAnnouncedBackgroundTurn(
        threadId,
        settledStatus === "failed" || settledStatus === "interrupted"
          ? settledStatus
          : "completed",
        settledTurn
      );
    }

    if (nextTurnId && nextTurnId !== previousTurnId) {
      sendApplicationResponse(JSON.stringify(backgroundTurnLifecycleNotification(
        "turn/started",
        threadId,
        nextActiveTurn
      )));
      announcedBackgroundTurnsByThreadId.set(threadId, nextActiveTurn);
      clearBackgroundDisconnectTimer(threadId);
    }
  }

  function settleAnnouncedBackgroundTurn(threadId, status = "interrupted", turn = null) {
    const announcedTurn = announcedBackgroundTurnsByThreadId.get(threadId);
    if (!announcedTurn) {
      clearBackgroundDisconnectTimer(threadId);
      return false;
    }
    const settledTurn = {
      ...announcedTurn,
      ...(turn && typeof turn === "object" ? turn : {}),
      id: announcedTurn.id,
      status,
    };
    sendApplicationResponse(JSON.stringify(backgroundTurnLifecycleNotification(
      "turn/completed",
      threadId,
      settledTurn
    )));
    announcedBackgroundTurnsByThreadId.delete(threadId);
    clearBackgroundDisconnectTimer(threadId);
    return true;
  }

  function scheduleBackgroundDisconnectSettlement(threadId) {
    if (!announcedBackgroundTurnsByThreadId.has(threadId)
      || backgroundDisconnectTimersByThreadId.has(threadId)) {
      return;
    }
    const expectedTurnId = announcedBackgroundTurnsByThreadId.get(threadId)?.id;
    const timer = setTimeout(() => {
      backgroundDisconnectTimersByThreadId.delete(threadId);
      if (announcedBackgroundTurnsByThreadId.get(threadId)?.id !== expectedTurnId) {
        return;
      }
      settleAnnouncedBackgroundTurn(threadId, "interrupted");
    }, Math.max(0, backgroundDisconnectGraceMs));
    timer.unref?.();
    backgroundDisconnectTimersByThreadId.set(threadId, timer);
  }

  function clearBackgroundDisconnectTimer(threadId) {
    const timer = backgroundDisconnectTimersByThreadId.get(threadId);
    if (!timer) {
      return;
    }
    clearTimeout(timer);
    backgroundDisconnectTimersByThreadId.delete(threadId);
  }

  function syncThreadArchiveBroadcast(envelope) {
    const params = envelope.params || {};
    const threadId = readString(params.conversationId) || readString(params.conversation_id);
    if (!threadId) {
      return;
    }
    if (envelope.method === "thread-archived") {
      cancelPendingSnapshot(threadId);
      settleAnnouncedBackgroundTurn(threadId, "interrupted");
      if (backgroundOnlyThreadIds.delete(threadId)) {
        activeThreadIds.delete(threadId);
      }
      rawStatesByThreadId.delete(threadId);
      rawStateUpdatedAtByThreadId.delete(threadId);
      canonicalHistoryThreadIds.delete(threadId);
      canonicalHistoryReplacementSentThreadIds.delete(threadId);
      projectedLiveActiveTurnIdsByThreadId.delete(threadId);
      desktopLiveLifecycleByThreadId.delete(threadId);
      normalizedLiveIndexesByThreadId.delete(threadId);
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
          result: appServerResultForFollowerRequest(route.method, result),
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

  function appServerResultForFollowerRequest(method, result) {
    if (method === "thread-follower-start-turn"
      && result
      && typeof result === "object"
      && !Array.isArray(result)
      && Object.prototype.hasOwnProperty.call(result, "result")) {
      return result.result ?? null;
    }
    return result ?? null;
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
    // Patches without a baseline are useless beyond a bound; keep the tail so
    // memory stays flat while recovery waits for the thread to materialize.
    if (queuedChanges.length > MAX_QUEUED_CHANGES_PER_THREAD) {
      queuedChanges.splice(0, queuedChanges.length - MAX_QUEUED_CHANGES_PER_THREAD);
    }
    queuedChangesByThreadId.set(threadId, queuedChanges);
  }

  function recoverThreadBaseline(threadId) {
    if (recoveringThreadIds.has(threadId)
      || rawStatesByThreadId.has(threadId)) {
      return;
    }
    const recoveryState = baselineRecoveryStateByThreadId.get(threadId) || {
      attempts: 0,
      nextAttemptAt: 0,
    };
    if (recoveryState.attempts >= MAX_BASELINE_RECOVERY_ATTEMPTS) {
      // Give up until a snapshot arrives; a fresh snapshot resets this state.
      return;
    }
    if (now() < recoveryState.nextAttemptAt) {
      return;
    }
    recoveryState.attempts += 1;
    recoveryState.nextAttemptAt = now() + Math.min(
      BASELINE_RECOVERY_MAX_DELAY_MS,
      BASELINE_RECOVERY_BASE_DELAY_MS * (2 ** (recoveryState.attempts - 1))
    );
    baselineRecoveryStateByThreadId.set(threadId, recoveryState);

    recoveringThreadIds.add(threadId);
    Promise.resolve()
      .then(() => readConversationState(threadId))
      .then((baselineState) => {
        if (!baselineState || typeof baselineState !== "object") {
          return;
        }

        baselineRecoveryStateByThreadId.delete(threadId);
        recoverThreadBaselineFromQueuedChanges(threadId, baselineState);
      })
      .catch((error) => {
        if (recoveryState.attempts === 1
          || recoveryState.attempts === MAX_BASELINE_RECOVERY_ATTEMPTS) {
          console.warn(`${logPrefix} desktop IPC baseline recovery failed for ${threadId} (attempt ${recoveryState.attempts}/${MAX_BASELINE_RECOVERY_ATTEMPTS}): ${error.message}`);
        }
        // Keep queued changes: a later attempt or snapshot may still recover.
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
    rawStateUpdatedAtByThreadId.set(threadId, now());
    rebuildNormalizedLiveIndex(threadId, nextState);
    if (baselineState && typeof baselineState === "object"
      && !backgroundOnlyThreadIds.has(threadId)) {
      const liveState = boundedDesktopLiveState(
        baselineState,
        now(),
        projectedLiveActiveTurnIdsByThreadId.get(threadId) || new Set(),
        createNormalizedLiveIndex(baselineState)
      );
      conversationProjector.seed(threadId, liveState);
      rememberDesktopLiveProjection(threadId, liveState);
    }
    if (backgroundOnlyThreadIds.has(threadId)) {
      syncBackgroundThreadLifecycle(threadId, baselineState, nextState);
    } else {
      syncProjectedConversationState(threadId, nextState);
    }
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
    releaseHeldFollowerRequests(threadId, { toDesktop: true });
  }

  return {
    observeInbound,
    stopAll,
    // True while this thread has live Desktop-owned IPC state mirrored to the
    // phone; used to keep fallback mirrors (rollout tail) silent.
    hasLiveThreadState(threadId) {
      const normalizedThreadId = readString(threadId);
      if (pendingSnapshotsByThreadId.has(normalizedThreadId)) {
        return false;
      }
      const rawState = rawStatesByThreadId.get(normalizedThreadId);
      if (!rawState) {
        return false;
      }
      const liveState = boundedDesktopLiveStateForThread(normalizedThreadId, rawState);
      if (!Array.isArray(liveState.turns) || liveState.turns.length === 0) {
        return false;
      }
      const thread = projectDesktopConversationStateToThread(normalizedThreadId, liveState, { now });
      if (hasActiveProjectedTurn(thread) && isRawStateStaleForActiveRead(normalizedThreadId)) {
        staleYieldedThreadIds.add(normalizedThreadId);
        return false;
      }
      return true;
    },
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

function isSnapshotChange(change) {
  return change?.type === "snapshot" || change?.type === "Snapshot";
}

function normalizedTurnStore(state) {
  const turnHistory = state?.turnHistory ?? state?.turn_history;
  const history = turnHistory?.history;
  const entities = history?.entitiesByKey ?? history?.entities_by_key;
  if (!entities || typeof entities !== "object" || Array.isArray(entities)) {
    return null;
  }
  return { history, entities };
}

function hasNormalizedTurnStore(state) {
  return Boolean(normalizedTurnStore(state));
}

function normalizedTurnIdForEntity(entityKey, entity) {
  const keyedTurnId = entityKey.startsWith("turn:")
    ? readString(entityKey.slice("turn:".length))
    : "";
  const entityTurnId = readString(entity?.turnId) || readString(entity?.turn_id);
  const looksLikeTurn = Boolean(keyedTurnId)
    || (Boolean(entityTurnId) && (entity?.status != null || Array.isArray(entity?.items)));
  return looksLikeTurn ? keyedTurnId || entityTurnId : "";
}

function createNormalizedLiveIndex(state) {
  const store = normalizedTurnStore(state);
  if (!store) {
    return null;
  }
  const rawTurns = Array.isArray(state?.turns) ? state.turns : [];
  const rawTurnIds = new Set();
  const rawIndexByTurnId = new Map();
  for (let rawIndex = 0; rawIndex < rawTurns.length; rawIndex += 1) {
    const rawTurnId = turnIdOf(rawTurns[rawIndex]);
    if (rawTurnId) {
      rawTurnIds.add(rawTurnId);
      rawIndexByTurnId.set(rawTurnId, rawIndex);
    }
  }
  const turnIdByEntityKey = new Map();
  const normalizedTurnIds = new Set();
  for (const [entityKey, entity] of Object.entries(store.entities)) {
    if (!entity || typeof entity !== "object") {
      continue;
    }
    const turnId = normalizedTurnIdForEntity(entityKey, entity);
    if (!turnId) {
      continue;
    }
    turnIdByEntityKey.set(entityKey, turnId);
    normalizedTurnIds.add(turnId);
  }

  const entries = [];
  const entryIndexByTurnId = new Map();
  const appendEntityKey = (key) => {
    const entityKey = readString(key);
    const turnId = entityKey ? turnIdByEntityKey.get(entityKey) : "";
    if (!turnId || entryIndexByTurnId.has(turnId)) {
      return;
    }
    entryIndexByTurnId.set(turnId, entries.length);
    entries.push({ id: turnId, entityKey, rawIndex: rawIndexByTurnId.get(turnId) ?? null });
  };
  for (const island of Array.isArray(store.history?.islands) ? store.history.islands : []) {
    for (const entry of Array.isArray(island?.entries) ? island.entries : []) {
      appendEntityKey(readString(entry?.value) || readString(entry?.key));
    }
  }
  if (entries.length === 0) {
    for (const entityKey of turnIdByEntityKey.keys()) {
      appendEntityKey(entityKey);
    }
  }
  for (let rawIndex = 0; rawIndex < rawTurns.length; rawIndex += 1) {
    const rawTurn = rawTurns[rawIndex];
    if (!rawTurn || typeof rawTurn !== "object") {
      continue;
    }
    const rawTurnId = turnIdOf(rawTurn) || `ipc-turn-${entries.length}`;
    if (entryIndexByTurnId.has(rawTurnId)) {
      continue;
    }
    entryIndexByTurnId.set(rawTurnId, entries.length);
    entries.push({
      id: rawTurnId,
      entityKey: null,
      rawIndex: rawIndexByTurnId.get(rawTurnId) ?? rawIndex,
    });
  }

  const index = {
    entries,
    entryIndexByTurnId,
    turnIdByEntityKey,
    activeTurnIds: new Set(),
    hasHistoryOutsideRawTurns: Array.from(normalizedTurnIds).some(
      (turnId) => !rawTurnIds.has(turnId)
    ),
  };
  for (const entry of entries) {
    const turn = resolveIndexedTurn(state, entry);
    if (turn && isActiveRawTurn(turn)) {
      index.activeTurnIds.add(entry.id);
    }
  }
  return index;
}

function normalizedLiveIndexNeedsRebuild(change) {
  for (const patch of Array.isArray(change?.patches) ? change.patches : []) {
    const path = Array.isArray(patch?.path) ? patch.path : [];
    if (path.length === 0) {
      return true;
    }
    if (path[0] === "turns") {
      if (path.length <= 2 || path[2] === "id" || path[2] === "turnId" || path[2] === "turn_id") {
        return true;
      }
      continue;
    }
    if (path[0] !== "turnHistory" && path[0] !== "turn_history") {
      continue;
    }
    if (path.length <= 3 || path[1] !== "history") {
      return true;
    }
    if (path[2] === "islands") {
      return true;
    }
    if (path[2] !== "entitiesByKey" && path[2] !== "entities_by_key") {
      continue;
    }
    if (path.length <= 4 || path[4] === "turnId" || path[4] === "turn_id" || path[4] === "id") {
      return true;
    }
  }
  return false;
}

function refreshTouchedNormalizedActiveTurns(index, state, change) {
  const touchedTurnIds = new Set();
  for (const patch of Array.isArray(change?.patches) ? change.patches : []) {
    const path = Array.isArray(patch?.path) ? patch.path : [];
    if (path[0] === "turns" && Number.isInteger(path[1]) && path[2] === "status") {
      const rawTurn = Array.isArray(state?.turns) ? state.turns[path[1]] : null;
      const turnId = turnIdOf(rawTurn);
      if (turnId) {
        touchedTurnIds.add(turnId);
      }
      continue;
    }
    if ((path[0] === "turnHistory" || path[0] === "turn_history")
      && path[1] === "history"
      && (path[2] === "entitiesByKey" || path[2] === "entities_by_key")
      && path[4] === "status") {
      const turnId = index.turnIdByEntityKey.get(readString(path[3]));
      if (turnId) {
        touchedTurnIds.add(turnId);
      }
    }
  }
  if (touchedTurnIds.size === 0) {
    return;
  }
  for (const turnId of touchedTurnIds) {
    const entryIndex = index.entryIndexByTurnId.get(turnId);
    const entry = entryIndex == null ? null : index.entries[entryIndex];
    const turn = entry ? resolveIndexedTurn(state, entry) : null;
    if (turn && isActiveRawTurn(turn)) {
      index.activeTurnIds.add(turnId);
    } else {
      index.activeTurnIds.delete(turnId);
    }
  }
}

function latestActiveRawTurn(state) {
  const turns = Array.isArray(state?.turns) ? state.turns : [];
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const status = normalizeToken(turns[index]?.status);
    if (status === "inprogress"
      || status === "running"
      || status === "active"
      || status === "processing") {
      return backgroundRawTurn(turns[index], index);
    }
  }
  return null;
}

function boundedDesktopLiveState(
  state,
  nowValue = Date.now(),
  retainedTurnIds = new Set(),
  normalizedIndex = null
) {
  return {
    ...(state && typeof state === "object" ? state : {}),
    turns: boundedDesktopLiveTurns(state, nowValue, retainedTurnIds, normalizedIndex),
  };
}

function boundedDesktopLiveTurns(
  state,
  nowValue = Date.now(),
  retainedTurnIds = new Set(),
  normalizedIndex = null
) {
  if (normalizedIndex) {
    return boundedIndexedDesktopLiveTurns(
      state,
      normalizedIndex,
      nowValue,
      retainedTurnIds
    );
  }
  const orderedTurns = backgroundHistoryTurns(state);
  if (orderedTurns.length <= 1) {
    return normalizeBoundedTurnsForRuntime(
      orderedTurns.map((turn, index) => withStableProjectedTurnId(turn, index)),
      state
    );
  }

  // History is canonical elsewhere. Live projection needs only the newest turn,
  // fresh parallel work, and turns retained for one terminal diff.
  const selectedIndexes = new Set([orderedTurns.length - 1]);
  const freshActiveIndexes = [];
  for (let index = 0; index < orderedTurns.length; index += 1) {
    const turn = orderedTurns[index];
    if (isActiveRawTurn(turn) && isRawTurnActivityFresh(turn, nowValue)) {
      freshActiveIndexes.push(index);
    }
    const turnId = turnIdOf(turn);
    if (turnId && retainedTurnIds.has(turnId)) {
      selectedIndexes.add(index);
    }
  }
  // Preserve parallel live work without letting an ancient stale inProgress
  // entity resurrect itself. Two active turns plus the canonical tail keeps
  // projection bounded even for multi-gigabyte histories.
  for (const index of freshActiveIndexes.slice(-2)) {
    selectedIndexes.add(index);
  }
  const selectedTurns = Array.from(selectedIndexes)
    .sort((left, right) => left - right)
    .map((index) => withStableProjectedTurnId(orderedTurns[index], index));
  return normalizeBoundedTurnsForRuntime(selectedTurns, state);
}

function boundedIndexedDesktopLiveTurns(state, index, nowValue, retainedTurnIds) {
  if (index.entries.length === 0) {
    return [];
  }
  const selectedTurnIds = new Set();
  const tailEntry = index.entries[index.entries.length - 1];
  if (tailEntry?.id) {
    selectedTurnIds.add(tailEntry.id);
  }
  for (const turnId of retainedTurnIds) {
    if (index.entryIndexByTurnId.has(turnId)) {
      selectedTurnIds.add(turnId);
    }
  }
  const freshActiveTurnIds = [];
  for (const turnId of index.activeTurnIds) {
    const entryIndex = index.entryIndexByTurnId.get(turnId);
    if (entryIndex == null) {
      continue;
    }
    const turn = resolveIndexedTurn(state, index.entries[entryIndex]);
    if (turn && isRawTurnActivityFresh(turn, nowValue)) {
      freshActiveTurnIds.push(turnId);
    }
  }
  freshActiveTurnIds.sort((left, right) => (
    index.entryIndexByTurnId.get(left) - index.entryIndexByTurnId.get(right)
  ));
  for (const turnId of freshActiveTurnIds.slice(-2)) {
    selectedTurnIds.add(turnId);
  }
  const selectedTurns = Array.from(selectedTurnIds)
    .map((turnId) => index.entryIndexByTurnId.get(turnId))
    .filter((entryIndex) => entryIndex != null)
    .sort((left, right) => left - right)
    .map((entryIndex) => {
      const entry = index.entries[entryIndex];
      const turn = resolveIndexedTurn(state, entry);
      if (!turn) {
        return null;
      }
      return turnIdOf(turn) ? turn : { ...turn, id: entry.id };
    })
    .filter(Boolean);
  return normalizeBoundedTurnsForRuntime(selectedTurns, state);
}

function resolveIndexedTurn(state, entry) {
  if (entry.rawIndex != null) {
    return Array.isArray(state?.turns) ? state.turns[entry.rawIndex] : null;
  }
  const store = normalizedTurnStore(state);
  return entry.entityKey && store ? store.entities[entry.entityKey] || null : null;
}

function turnIdOf(turn) {
  return readString(turn?.id)
    || readString(turn?.turnId)
    || readString(turn?.turn_id);
}

function withStableProjectedTurnId(turn, fullHistoryIndex) {
  return turnIdOf(turn)
    ? turn
    : { ...turn, id: `ipc-turn-${fullHistoryIndex}` };
}

function activeDesktopTurnDescriptors(state) {
  const turns = Array.isArray(state?.turns) ? state.turns : [];
  const descriptors = [];
  for (const turn of turns) {
    if (!isActiveRawTurn(turn)) {
      continue;
    }
    const id = turnIdOf(turn);
    if (id) {
      descriptors.push({ id, status: readString(turn?.status) || "inProgress" });
    }
  }
  return descriptors;
}

function desktopLiveTurnLifecycleNotification(method, threadId, turn) {
  const status = readString(turn?.status) || (method === "turn/started" ? "inProgress" : "completed");
  return {
    method,
    params: {
      threadId,
      turnId: turn.id,
      id: turn.id,
      status,
      turn: { id: turn.id, status },
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
      // Lets a live authoritative start clear a guessed `.stopped` marker that
      // survived a prior disconnect, even when the chat is already selected.
      remodexBackgroundDiscovery: method === "turn/started",
      remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
    },
  };
}

function normalizeBoundedTurnsForRuntime(turns, state) {
  if (!isExplicitlyIdleDesktopRuntime(state)) {
    return turns;
  }
  return turns.map((turn) => (
    isActiveRawTurn(turn)
      ? { ...turn, status: "completed" }
      : turn
  ));
}

function desktopRuntimeStatusToken(state) {
  return normalizeToken(
    readString(state?.threadRuntimeStatus?.type)
      || readString(state?.thread_runtime_status?.type)
      || readString(state?.runtimeStatus?.type)
      || readString(state?.runtime_status?.type)
  );
}

function isExplicitlyIdleDesktopRuntime(state) {
  const status = desktopRuntimeStatusToken(state);
  return status === "idle"
    || status === "inactive"
    || status === "completed"
    || status === "stopped"
    || status === "notrunning";
}

function isActiveRawTurn(turn) {
  const status = normalizeToken(turn?.status);
  return status === "inprogress"
    || status === "running"
    || status === "active"
    || status === "processing";
}

function isRawTurnActivityFresh(turn, nowValue) {
  const startedAt = Number(turn?.turnStartedAtMs ?? turn?.turn_started_at_ms);
  const durationMs = Number(turn?.durationMs ?? turn?.duration_ms);
  if (!Number.isFinite(startedAt) || startedAt <= 0) {
    return false;
  }
  const activityAt = Number.isFinite(durationMs) && durationMs >= 0
    ? startedAt + durationMs
    : startedAt;
  return nowValue - activityAt <= STALE_ACTIVE_READ_MAX_AGE_MS;
}

function backgroundRawTurnById(state, turnId) {
  const turns = Array.isArray(state?.turns) ? state.turns : [];
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = backgroundRawTurn(turns[index], index);
    if (turn.id === turnId) {
      return turn;
    }
  }
  return null;
}

function backgroundHistoryTurns(state) {
  const turns = Array.isArray(state?.turns) ? state.turns.filter(Boolean) : [];
  const turnHistory = state?.turnHistory ?? state?.turn_history;
  const history = turnHistory?.history;
  const entities = history?.entitiesByKey ?? history?.entities_by_key;
  if (!entities || typeof entities !== "object" || Array.isArray(entities)) {
    return turns;
  }

  const rawTurnsById = new Map();
  for (const turn of turns) {
    const turnId = readString(turn?.id)
      || readString(turn?.turnId)
      || readString(turn?.turn_id);
    if (turnId) {
      rawTurnsById.set(turnId, turn);
    }
  }
  const orderedTurns = [];
  const addedTurnIds = new Set();
  const addedEntityKeys = new Set();
  const appendEntity = (key) => {
    const entityKey = readString(key);
    const entity = entities[entityKey];
    if (!entityKey || addedEntityKeys.has(entityKey) || !entity || typeof entity !== "object") {
      return;
    }
    const keyedTurnId = entityKey.startsWith("turn:")
      ? readString(entityKey.slice("turn:".length))
      : "";
    const entityTurnId = readString(entity?.turnId) || readString(entity?.turn_id);
    const turnId = keyedTurnId || entityTurnId;
    const looksLikeTurn = Boolean(keyedTurnId)
      || (Boolean(entityTurnId) && (entity?.status != null || Array.isArray(entity?.items)));
    if (!looksLikeTurn || !turnId || addedTurnIds.has(turnId)) {
      return;
    }
    addedEntityKeys.add(entityKey);
    addedTurnIds.add(turnId);
    // Prefer the fresher legacy/live object when Litter materialized this same
    // turn in both stores, but keep the canonical island position.
    orderedTurns.push(rawTurnsById.get(turnId) || entity);
  };

  // Litter's islands preserve timeline order even though entitiesByKey is a
  // normalized object store. Prefer that order, then tolerate snapshots that
  // provide only the entity map.
  for (const island of Array.isArray(history?.islands) ? history.islands : []) {
    for (const entry of Array.isArray(island?.entries) ? island.entries : []) {
      appendEntity(readString(entry?.value) || readString(entry?.key));
    }
  }
  // When islands exist they are the canonical order. Do not append orphaned
  // normalized entities after the tail: a stale unreferenced inProgress turn
  // would otherwise look newer than the real current turn. Entity-map order is
  // only a compatibility fallback for snapshots that omit islands entirely.
  if (orderedTurns.length === 0) {
    for (const key of Object.keys(entities)) {
      appendEntity(key);
    }
  }
  for (const turn of turns) {
    const turnId = readString(turn?.id)
      || readString(turn?.turnId)
      || readString(turn?.turn_id);
    if (!turnId || !addedTurnIds.has(turnId)) {
      orderedTurns.push(turn);
    }
  }
  return orderedTurns.length > 0 ? orderedTurns : turns;
}

function backgroundRawTurn(turn, index) {
  const id = readString(turn?.turnId)
    || readString(turn?.turn_id)
    || readString(turn?.id)
    // Must match desktop-ipc-conversation-projector so opening the thread
    // mid-run does not replace the active id and strand iOS running state.
    || `ipc-turn-${index}`;
  const status = normalizeToken(turn?.status);
  let normalizedStatus = "completed";
  if (status === "inprogress" || status === "running" || status === "active" || status === "processing") {
    normalizedStatus = "inProgress";
  } else if (status === "failed" || status === "error" || status === "systemerror") {
    normalizedStatus = "failed";
  } else if (status === "interrupted" || status === "cancelled" || status === "canceled" || status === "stopped") {
    normalizedStatus = "interrupted";
  }
  return {
    id,
    status: normalizedStatus,
    error: turn?.error ?? null,
  };
}

function backgroundTurnLifecycleNotification(method, threadId, turn) {
  const turnId = readString(turn?.id);
  const params = {
    threadId,
    remodexDesktopMirror: true,
    remodexDesktopIpcMirror: true,
    remodexBackgroundDiscovery: true,
    remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
  };
  if (turnId) {
    params.turnId = turnId;
    params.id = turnId;
  }
  if (method === "turn/completed") {
    params.status = readString(turn?.status) || "completed";
    if (turn?.error != null) {
      params.error = cloneJSON(turn.error);
    }
  }
  return { method, params };
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
  buildDesktopTurnsListResult,
  createDesktopIpcActionFollower,
  desktopFollowerPayloadForResponse,
  projectDesktopAssistantDeltaNotifications,
  projectPendingDesktopActions,
  resolveDefaultIpcSocketPath,
  seedConversationStateFromThreadRead,
};
