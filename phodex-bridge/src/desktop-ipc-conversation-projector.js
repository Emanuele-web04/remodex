// FILE: desktop-ipc-conversation-projector.js
// Purpose: Projects Codex Desktop IPC conversation snapshots into app-server-style live notifications.
// Layer: CLI helper
// Exports: createDesktopConversationProjector, projectDesktopConversationStateToThread
// Depends on: ./desktop-ipc-shared

const {
  cloneJSON,
  normalizeToken,
  readString,
  readText,
  sanitizeUserInputEntries: sanitizeSharedUserInputEntries,
} = require("./desktop-ipc-shared");

const DESKTOP_IPC_ACTION_SOURCE = "desktop-ipc-action-follower";
const MIRROR_TAG = {
  remodexDesktopMirror: true,
  remodexDesktopIpcMirror: true,
  remodexActionSource: DESKTOP_IPC_ACTION_SOURCE,
};

// --- Projector lifecycle --------------------------------------

// Caches the previous projected Desktop state so raw IPC snapshots/patches become granular mobile events.
function createDesktopConversationProjector({
  now = () => Date.now(),
  maxCacheSize = 64,
} = {}) {
  const cacheByThreadId = new Map();
  // Threads whose cache was evicted for size were already mirrored to the phone;
  // re-seeding them as a baseline avoids replaying their whole history again.
  const evictedThreadIds = new Set();
  // The follower applies IPC patches copy-on-write, so raw turn/item objects
  // keep their identity while untouched. Memoizing projections on that identity
  // makes each diff cost O(changed turns) instead of O(whole conversation).
  const projectedTurnsByRawTurn = new WeakMap();
  const projectedItemsByRawItem = new WeakMap();

  function projectState(threadId, rawState) {
    return projectConversationState(threadId, rawState, {
      now,
      turnCache: projectedTurnsByRawTurn,
      itemCache: projectedItemsByRawItem,
    });
  }

  function project(threadId, rawState) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !rawState || typeof rawState !== "object") {
      return {
        type: "none",
        notifications: [],
      };
    }

    const nextProjection = projectState(normalizedThreadId, rawState);
    const previousCache = cacheByThreadId.get(normalizedThreadId) || null;
    const previousProjection = previousCache?.projection || null;

    let notifications;
    let type = "events";
    if (!previousProjection && evictedThreadIds.has(normalizedThreadId)) {
      // Previously mirrored but evicted: reseed silently so the phone does not
      // receive a duplicate bootstrap replay of already-delivered history.
      evictedThreadIds.delete(normalizedThreadId);
      type = "baseline";
      notifications = [];
    } else if (!previousProjection) {
      notifications = bootstrapNotifications(normalizedThreadId, nextProjection);
    } else if (hasSynthesizedTurnIds(previousProjection) && !hasSynthesizedTurnIds(nextProjection)) {
      type = "fullReplace";
      notifications = [
        threadStartedNotification(nextProjection.thread),
        ...bootstrapNotifications(normalizedThreadId, nextProjection, { includeThreadStarted: false }),
      ];
    } else {
      notifications = diffProjections(
        normalizedThreadId,
        previousProjection,
        nextProjection
      );
    }

    cacheByThreadId.set(normalizedThreadId, {
      projection: nextProjection,
      lastUpdated: now(),
    });
    evictOldest();

    return {
      type,
      notifications,
      thread: nextProjection.thread,
    };
  }

  // Seeds a baseline without replaying old history; subsequent IPC changes diff against it.
  function seed(threadId, rawState) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !rawState || typeof rawState !== "object") {
      return;
    }
    const projection = projectState(normalizedThreadId, rawState);
    cacheByThreadId.set(normalizedThreadId, {
      projection,
      lastUpdated: now(),
    });
    evictOldest();
  }

  function remove(threadId) {
    const normalizedThreadId = readString(threadId);
    cacheByThreadId.delete(normalizedThreadId);
    // Explicit removals are semantic (archive, ownership change): a later
    // re-follow of this thread should bootstrap fresh, not stay silent.
    evictedThreadIds.delete(normalizedThreadId);
  }

  function reset() {
    cacheByThreadId.clear();
    evictedThreadIds.clear();
  }

  function evictOldest() {
    while (cacheByThreadId.size > maxCacheSize) {
      const oldest = Array.from(cacheByThreadId.entries())
        .sort((left, right) => left[1].lastUpdated - right[1].lastUpdated)[0];
      if (!oldest) {
        return;
      }
      cacheByThreadId.delete(oldest[0]);
      evictedThreadIds.add(oldest[0]);
    }
  }

  return {
    project,
    seed,
    remove,
    reset,
  };
}

// --- Projection model ------------------------------------------

// Converts Desktop's raw conversationState JSON into the thread shape mobile history already parses.
function projectDesktopConversationStateToThread(threadId, rawState, { now = () => Date.now() } = {}) {
  return projectConversationState(threadId, rawState, { now }).thread;
}

function projectConversationState(threadId, rawState, {
  now = () => Date.now(),
  turnCache = null,
  itemCache = null,
} = {}) {
  const turns = projectTurns(threadId, rawState, { turnCache, itemCache });
  const activeTurnId = activeTurnIdFromTurns(turns);
  const thread = {
    id: threadId,
    sessionId: threadId,
    session_id: threadId,
    title: readString(rawState?.title) || null,
    name: readString(rawState?.title) || null,
    preview: threadPreview(turns),
    createdAt: normalizeTimestamp(rawState?.createdAt ?? rawState?.created_at) || now(),
    updatedAt: normalizeTimestamp(rawState?.updatedAt ?? rawState?.updated_at) || now(),
    cwd: readString(rawState?.cwd) || readString(rawState?.current_working_directory) || "",
    path: readString(rawState?.rolloutPath) || readString(rawState?.rollout_path) || null,
    modelProvider: readString(rawState?.modelProvider) || readString(rawState?.model_provider) || "",
    model: readString(rawState?.latestModel) || readString(rawState?.latest_model) || "",
    cliVersion: readString(rawState?.cliVersion) || readString(rawState?.cli_version) || "",
    source: rawState?.source ?? null,
    gitInfo: cloneJSON(rawState?.gitInfo ?? rawState?.git_info ?? null),
    agentNickname: readString(rawState?.agentNickname) || readString(rawState?.agent_nickname) || null,
    agentRole: readString(rawState?.agentRole) || readString(rawState?.agent_role) || null,
    status: resolveThreadStatus(rawState, activeTurnId),
    tokenUsage: cloneJSON(rawState?.latestTokenUsageInfo ?? rawState?.latest_token_usage_info ?? null),
    turns,
  };

  return {
    thread,
    turns,
    activeTurnId,
    status: thread.status,
  };
}

function projectTurns(threadId, rawState, { turnCache = null, itemCache = null } = {}) {
  const rawTurns = Array.isArray(rawState?.turns) ? rawState.turns : [];
  return rawTurns
    .map((turn, index) => projectTurnCached(threadId, turn, index, { turnCache, itemCache }))
    .filter(Boolean);
}

function projectTurnCached(threadId, rawTurn, index, { turnCache = null, itemCache = null } = {}) {
  if (!rawTurn || typeof rawTurn !== "object") {
    return null;
  }
  // Synthetic ids depend on the array index, so only turns with a real id are
  // safe to reuse by identity.
  const hasStableId = Boolean(readString(rawTurn.turnId) || readString(rawTurn.turn_id) || readString(rawTurn.id));
  if (!turnCache || !hasStableId) {
    return projectTurn(threadId, rawTurn, index, { itemCache });
  }
  const cached = turnCache.get(rawTurn);
  if (cached) {
    return cached;
  }
  const projected = projectTurn(threadId, rawTurn, index, { itemCache });
  if (projected) {
    turnCache.set(rawTurn, projected);
  }
  return projected;
}

function projectTurn(threadId, rawTurn, index, { itemCache = null } = {}) {
  if (!rawTurn || typeof rawTurn !== "object") {
    return null;
  }
  const turnId = readString(rawTurn.turnId)
    || readString(rawTurn.turn_id)
    || readString(rawTurn.id)
    || `ipc-turn-${index}`;
  const status = normalizeTurnStatus(rawTurn.status);
  const paramsInput = Array.isArray(rawTurn?.params?.input) ? cloneJSON(rawTurn.params.input) : [];
  const visibleInput = sanitizeUserInputEntries(paramsInput);
  const items = [];
  if (visibleInput.length > 0) {
    items.push({
      id: `${turnId}:input`,
      type: "userMessage",
      content: visibleInput,
    });
  }

  for (const item of Array.isArray(rawTurn.items) ? rawTurn.items : []) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const itemType = normalizeToken(item.type);
    if (!isSupportedItemType(itemType)) {
      continue;
    }
    // Desktop stores the prompt both in turn params and as a canonical
    // userMessage item, often with different entry shapes (extra fields,
    // wrapper text). Matching on the sanitized visible text instead of raw
    // JSON equality keeps one user row; the strict shape check alone let the
    // same prompt through twice and duplicated it on the phone via history.
    if (itemType === "usermessage"
      && visibleInput.length > 0
      && (sameUserInput(item.content, paramsInput)
        || sameVisibleUserText(item.content, visibleInput))) {
      continue;
    }
    // Projected items are treated as immutable by every consumer, so raw items
    // that survived copy-on-write untouched can reuse their previous clone.
    const cachedItem = itemCache?.get(item);
    if (cachedItem) {
      if (cachedItem !== SKIPPED_ITEM) {
        items.push(cachedItem);
      }
      continue;
    }
    const projectedItem = projectItemForMobile(item, itemType);
    itemCache?.set(item, projectedItem ?? SKIPPED_ITEM);
    if (projectedItem) {
      items.push(projectedItem);
    }
  }

  return {
    id: turnId,
    turnId,
    status,
    error: cloneJSON(rawTurn.error || null),
    startedAt: rawTurn.startedAt ?? rawTurn.started_at ?? null,
    completedAt: rawTurn.completedAt ?? rawTurn.completed_at ?? null,
    durationMs: rawTurn.durationMs ?? rawTurn.duration_ms ?? null,
    items,
  };
}

// --- Notification generation ----------------------------------

function bootstrapNotifications(threadId, projection, { includeThreadStarted = true } = {}) {
  const notifications = includeThreadStarted && shouldEmitThreadStarted(projection.thread)
    ? [threadStartedNotification(projection.thread)]
    : [];
  const activeTurn = projection.activeTurnId
    ? projection.turns.find((turn) => turn.id === projection.activeTurnId)
    : null;
  if (!activeTurn) {
    return notifications;
  }

  notifications.push(turnStartedNotification(threadId, activeTurn));
  for (const item of activeTurn.items) {
    notifications.push(itemStartedNotification(threadId, activeTurn.id, item));
    // Streaming items (running commands, in-flight tools) must not be closed
    // prematurely; later diffs emit their deltas and eventual completion.
    if (isTerminalItemState(item)) {
      notifications.push(itemCompletedNotification(threadId, activeTurn.id, item));
    }
  }
  return notifications;
}

function shouldEmitThreadStarted(thread) {
  return Boolean(readString(thread.title)
    || readString(thread.name)
    || readString(thread.cwd)
    || readString(thread.preview)
    || (Array.isArray(thread.turns) && thread.turns.length > 0));
}

function diffProjections(threadId, previousProjection, nextProjection) {
  const notifications = [];

  notifications.push(...diffThreadMetadata(previousProjection.thread, nextProjection.thread));
  notifications.push(...diffTurnLifecycle(threadId, previousProjection, nextProjection));
  notifications.push(...diffTurnItems(threadId, previousProjection, nextProjection));

  return notifications;
}

function diffThreadMetadata(previousThread, nextThread) {
  const notifications = [];
  const previousTitle = readString(previousThread.title) || readString(previousThread.name);
  const nextTitle = readString(nextThread.title) || readString(nextThread.name);
  if (nextTitle && previousTitle !== nextTitle) {
    notifications.push(tagNotification({
      method: "thread/name/updated",
      params: {
        threadId: nextThread.id,
        threadName: nextTitle,
        name: nextTitle,
        title: nextTitle,
      },
    }));
  }

  if (JSON.stringify(previousThread.status || null) !== JSON.stringify(nextThread.status || null)) {
    notifications.push(tagNotification({
      method: "thread/status/changed",
      params: {
        threadId: nextThread.id,
        status: cloneJSON(nextThread.status || null),
      },
    }));
  }

  if (nextThread.tokenUsage != null
    && JSON.stringify(previousThread.tokenUsage || null) !== JSON.stringify(nextThread.tokenUsage)) {
    notifications.push(tagNotification({
      method: "thread/tokenUsage/updated",
      params: {
        threadId: nextThread.id,
        usage: cloneJSON(nextThread.tokenUsage),
        tokenUsage: cloneJSON(nextThread.tokenUsage),
      },
    }));
  }

  return notifications;
}

function diffTurnLifecycle(threadId, previousProjection, nextProjection) {
  const notifications = [];
  const previousActive = previousProjection.activeTurnId || null;
  const nextActive = nextProjection.activeTurnId || null;
  if (!previousActive && nextActive) {
    const nextTurn = findTurn(nextProjection.turns, nextActive);
    if (nextTurn) {
      notifications.push(turnStartedNotification(threadId, nextTurn));
    }
    return notifications;
  }
  if (previousActive && !nextActive) {
    const completedTurn = findTurn(nextProjection.turns, previousActive)
      || findTurn(previousProjection.turns, previousActive);
    if (completedTurn) {
      notifications.push(turnCompletedNotification(threadId, completedTurn));
    }
    return notifications;
  }
  if (previousActive && nextActive && previousActive !== nextActive) {
    const completedTurn = findTurn(nextProjection.turns, previousActive)
      || findTurn(previousProjection.turns, previousActive);
    const startedTurn = findTurn(nextProjection.turns, nextActive);
    if (completedTurn) {
      notifications.push(turnCompletedNotification(threadId, completedTurn));
    }
    if (startedTurn) {
      notifications.push(turnStartedNotification(threadId, startedTurn));
    }
  }
  return notifications;
}

function diffTurnItems(threadId, previousProjection, nextProjection) {
  const notifications = [];
  const previousTurnsById = new Map(previousProjection.turns.map((turn) => [turn.id, turn]));

  for (const nextTurn of nextProjection.turns) {
    const previousTurn = previousTurnsById.get(nextTurn.id) || null;
    // Memoized projections keep their identity when the raw turn survived
    // copy-on-write untouched, so unchanged turns cost nothing to skip.
    if (previousTurn === nextTurn) {
      continue;
    }
    const previousItemsById = new Map((previousTurn?.items || []).map((item) => [itemIdOf(item), item]));
    const isActiveTurn = nextProjection.activeTurnId === nextTurn.id;

    for (const nextItem of nextTurn.items) {
      const itemId = itemIdOf(nextItem);
      if (!itemId) {
        continue;
      }
      const previousItem = previousItemsById.get(itemId) || null;
      if (!previousItem) {
        notifications.push(itemStartedNotification(threadId, nextTurn.id, nextItem));
        // Only close items that are actually finished; a newly observed running
        // item keeps streaming through later diffs on the active turn.
        if (!isActiveTurn || isTerminalItemState(nextItem)) {
          notifications.push(itemCompletedNotification(threadId, nextTurn.id, nextItem));
        }
        continue;
      }
      if (previousItem === nextItem
        || JSON.stringify(previousItem) === JSON.stringify(nextItem)) {
        continue;
      }
      if (!isActiveTurn) {
        notifications.push(itemCompletedNotification(threadId, nextTurn.id, nextItem));
        continue;
      }
      notifications.push(...diffItem(threadId, nextTurn.id, previousItem, nextItem));
    }
  }

  return notifications;
}

function diffItem(threadId, turnId, previousItem, nextItem) {
  const itemId = itemIdOf(nextItem);
  const itemType = normalizeToken(nextItem.type);
  // Previous text lengths come straight from the previous projection, which is
  // exactly what the per-thread snapshot map used to store.
  const snapshot = snapshotItem(previousItem);
  if (isAssistantMessageItem(nextItem)) {
    const previousText = assistantMessageText(previousItem);
    const nextText = assistantMessageText(nextItem);
    const delta = appendedDelta(previousText, nextText, snapshot.agentTextLen);
    if (delta) {
      return [deltaNotification("item/agentMessage/delta", threadId, turnId, itemId, delta)];
    }
    return [itemCompletedNotification(threadId, turnId, nextItem)];
  }

  if (itemType === "plan" || itemType === "todolist") {
    const previousText = planText(previousItem);
    const nextText = planText(nextItem);
    const delta = appendedDelta(previousText, nextText, snapshot.planTextLen);
    if (delta) {
      return [deltaNotification("item/plan/delta", threadId, turnId, itemId, delta)];
    }
    return [itemCompletedNotification(threadId, turnId, nextItem)];
  }

  if (itemType === "reasoning") {
    const reasoning = reasoningDeltaNotifications(threadId, turnId, itemId, previousItem, nextItem, snapshot);
    return reasoning.length > 0 ? reasoning : [itemCompletedNotification(threadId, turnId, nextItem)];
  }

  if (itemType === "commandexecution") {
    if (normalizeToken(previousItem.status) !== normalizeToken(nextItem.status)) {
      return [itemCompletedNotification(threadId, turnId, nextItem)];
    }
    const delta = appendedDelta(commandOutput(previousItem), commandOutput(nextItem), snapshot.commandOutputLen);
    if (delta) {
      return [deltaNotification("item/commandExecution/outputDelta", threadId, turnId, itemId, delta)];
    }
    return [itemCompletedNotification(threadId, turnId, nextItem)];
  }

  if (itemType === "filechange") {
    const delta = appendedDelta(fileChangeOutput(previousItem), fileChangeOutput(nextItem), snapshot.fileOutputLen);
    if (delta) {
      return [deltaNotification("item/fileChange/outputDelta", threadId, turnId, itemId, delta)];
    }
    return [itemCompletedNotification(threadId, turnId, nextItem)];
  }

  if (isToolCallItem(nextItem)) {
    const delta = appendedDelta(toolCallOutput(previousItem), toolCallOutput(nextItem), snapshot.toolOutputLen);
    if (delta) {
      return [deltaNotification("item/toolCall/outputDelta", threadId, turnId, itemId, delta, {
        item: cloneJSON(nextItem),
      })];
    }
  }

  return [itemCompletedNotification(threadId, turnId, nextItem)];
}

function reasoningDeltaNotifications(threadId, turnId, itemId, previousItem, nextItem, snapshot) {
  const notifications = [];
  const previousSummary = textArray(previousItem.summary);
  const nextSummary = textArray(nextItem.summary);
  const previousContent = textArray(previousItem.content);
  const nextContent = textArray(nextItem.content);
  const summaryLens = Array.isArray(snapshot.reasoningSummaryLens) ? snapshot.reasoningSummaryLens : [];
  const contentLens = Array.isArray(snapshot.reasoningContentLens) ? snapshot.reasoningContentLens : [];

  for (let index = 0; index < nextSummary.length; index += 1) {
    if (index >= previousSummary.length) {
      notifications.push(tagNotification({
        method: "item/reasoning/summaryPartAdded",
        params: {
          threadId,
          turnId,
          itemId,
          summaryIndex: index,
        },
      }));
      if (nextSummary[index]) {
        notifications.push(deltaNotification(
          "item/reasoning/summaryTextDelta",
          threadId,
          turnId,
          itemId,
          nextSummary[index],
          { summaryIndex: index }
        ));
      }
      continue;
    }
    const delta = appendedDelta(previousSummary[index], nextSummary[index], summaryLens[index]);
    if (delta) {
      notifications.push(deltaNotification(
        "item/reasoning/summaryTextDelta",
        threadId,
        turnId,
        itemId,
        delta,
        { summaryIndex: index }
      ));
    }
  }

  for (let index = 0; index < nextContent.length; index += 1) {
    const previousText = previousContent[index] || "";
    const delta = appendedDelta(previousText, nextContent[index], contentLens[index]);
    if (delta) {
      notifications.push(deltaNotification(
        "item/reasoning/textDelta",
        threadId,
        turnId,
        itemId,
        delta,
        { contentIndex: index }
      ));
    }
  }

  return notifications;
}

// --- Notification shapes --------------------------------------

function threadStartedNotification(thread) {
  return tagNotification({
    method: "thread/started",
    params: {
      threadId: thread.id,
      thread: cloneJSON(thread),
    },
  });
}

function turnStartedNotification(threadId, turn) {
  return tagNotification({
    method: "turn/started",
    params: {
      threadId,
      turnId: turn.id,
      turn: cloneJSON(turn),
    },
  });
}

function turnCompletedNotification(threadId, turn) {
  return tagNotification({
    method: "turn/completed",
    params: {
      threadId,
      turnId: turn.id,
      turn: cloneJSON(turn),
      status: turn.status,
      error: cloneJSON(turn.error || null),
    },
  });
}

function itemStartedNotification(threadId, turnId, item) {
  return tagNotification({
    method: "item/started",
    params: {
      threadId,
      turnId,
      itemId: itemIdOf(item),
      item: cloneJSON(item),
    },
  });
}

function itemCompletedNotification(threadId, turnId, item) {
  return tagNotification({
    method: "item/completed",
    params: {
      threadId,
      turnId,
      itemId: itemIdOf(item),
      item: cloneJSON(item),
    },
  });
}

function deltaNotification(method, threadId, turnId, itemId, delta, extraParams = {}) {
  return tagNotification({
    method,
    params: {
      threadId,
      turnId,
      itemId,
      delta,
      ...extraParams,
    },
  });
}

function tagNotification(notification) {
  return {
    method: notification.method,
    params: {
      ...notification.params,
      ...MIRROR_TAG,
    },
  };
}

// --- Text snapshots -------------------------------------------

function snapshotItem(item) {
  return {
    agentTextLen: assistantMessageText(item).length,
    planTextLen: planText(item).length,
    reasoningSummaryLens: textArray(item.summary).map((entry) => entry.length),
    reasoningContentLens: textArray(item.content).map((entry) => entry.length),
    commandOutputLen: commandOutput(item).length,
    fileOutputLen: fileChangeOutput(item).length,
    toolOutputLen: toolCallOutput(item).length,
  };
}

function appendedDelta(previousText, nextText, snapshotLength) {
  const normalizedPrevious = typeof previousText === "string" ? previousText : "";
  const normalizedNext = typeof nextText === "string" ? nextText : "";
  const previousLength = Number.isInteger(snapshotLength) ? snapshotLength : normalizedPrevious.length;
  const prefix = normalizedPrevious.slice(0, Math.min(previousLength, normalizedPrevious.length));
  if (!normalizedNext.startsWith(prefix) || normalizedNext.length <= previousLength) {
    return "";
  }
  return normalizedNext.slice(previousLength);
}

// --- Shape helpers --------------------------------------------

function activeTurnIdFromTurns(turns) {
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = turns[index];
    if (isActiveTurnStatus(turn.status)) {
      return turn.id;
    }
  }
  return null;
}

function resolveThreadStatus(rawState, activeTurnId) {
  const explicitStatus = rawState?.threadRuntimeStatus ?? rawState?.thread_runtime_status;
  if (explicitStatus != null) {
    return cloneJSON(explicitStatus);
  }
  if (activeTurnId) {
    return {
      type: "active",
      activeFlags: [],
    };
  }
  return {
    type: "idle",
  };
}

function normalizeTurnStatus(value) {
  const token = normalizeToken(value);
  if (token === "inprogress" || token === "running" || token === "active" || token === "processing") {
    return "inProgress";
  }
  if (token === "interrupted" || token === "cancelled" || token === "canceled" || token === "stopped") {
    return "interrupted";
  }
  if (token === "failed" || token === "error" || token === "systemerror") {
    return "failed";
  }
  return "completed";
}

function isActiveTurnStatus(value) {
  return normalizeToken(value) === "inprogress"
    || normalizeToken(value) === "running"
    || normalizeToken(value) === "active"
    || normalizeToken(value) === "processing";
}

// Items without an explicit status (messages, reasoning) are complete as
// delivered; only explicitly running items must stay open for streaming.
function isTerminalItemState(item) {
  const status = normalizeToken(item?.status);
  if (!status) {
    return true;
  }
  return status !== "inprogress"
    && status !== "running"
    && status !== "active"
    && status !== "processing"
    && status !== "pending"
    && status !== "queued";
}

function hasSynthesizedTurnIds(projection) {
  return projection.turns.some((turn) => readString(turn.id).startsWith("ipc-turn-"));
}

function findTurn(turns, turnId) {
  return turns.find((turn) => turn.id === turnId) || null;
}

function threadPreview(turns) {
  for (const turn of turns) {
    for (const item of turn.items) {
      if (normalizeToken(item.type) !== "usermessage") {
        continue;
      }
      const text = renderUserInputText(item.content).trim();
      if (text) {
        return stripRequestWrapper(text);
      }
    }
  }
  return "";
}

function renderUserInputText(content) {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return "";
  }
  return content
    .map((entry) => {
      if (typeof entry === "string") {
        return entry;
      }
      if (!entry || typeof entry !== "object") {
        return "";
      }
      return readString(entry.text) || readString(entry.content) || "";
    })
    .filter(Boolean)
    .join("\n");
}

function stripRequestWrapper(text) {
  const marker = "## My request for Codex:";
  return text.includes(marker) ? text.split(marker).at(-1).trim() : text.trim();
}

function sameUserInput(content, paramsInput) {
  return JSON.stringify(content || []) === JSON.stringify(paramsInput || []);
}

function sameVisibleUserText(content, visibleInput) {
  const itemText = renderUserInputText(sanitizeUserInputEntries(content)).trim();
  const paramsText = renderUserInputText(visibleInput).trim();
  return Boolean(itemText) && itemText === paramsText;
}

// Sentinel so the item cache can also remember "this raw item projects to nothing".
const SKIPPED_ITEM = Symbol("remodex-skipped-item");

// Drops injected context fragments (AGENTS.md instructions, IDE wrappers) and
// strips prompt-request wrappers so only the real user request reaches mobile.
function sanitizeUserInputEntries(entries) {
  return sanitizeSharedUserInputEntries(entries);
}

// Desktop IPC uses richer tool aliases than the mobile app-server timeline.
// Keep the original type as metadata, but emit the generic shape iOS already decodes.
// Returns null when the item has nothing user-visible left after sanitizing.
function projectItemForMobile(item, itemType = normalizeToken(item?.type)) {
  if (itemType === "usermessage") {
    const visibleContent = sanitizeUserInputEntries(
      Array.isArray(item?.content) ? item.content : []
    );
    if (visibleContent.length === 0) {
      return null;
    }
    const projected = cloneJSON(item);
    projected.content = cloneJSON(visibleContent);
    return projected;
  }

  const projected = cloneJSON(item);
  if (!isGenericToolCallItemType(itemType)) {
    return projected;
  }

  projected.type = "toolCall";
  if (!projected.remodexDesktopIpcItemType) {
    projected.remodexDesktopIpcItemType = readString(item?.type) || itemType;
  }
  return projected;
}

function isSupportedItemType(type) {
  return type === "usermessage"
    || type === "hookprompt"
    || type === "agentmessage"
    || type === "assistantmessage"
    || type === "message"
    || type === "plan"
    || type === "todolist"
    || type === "reasoning"
    || type === "commandexecution"
    || type === "filechange"
    || type === "toolcall"
    || type === "mcptoolcall"
    || type === "dynamictoolcall"
    || type === "collabagenttoolcall"
    || type === "collabtoolcall"
    || type === "websearch"
    || type === "imageview"
    || type === "imagegeneration"
    || type === "enteredreviewmode"
    || type === "exitedreviewmode"
    || type === "contextcompaction";
}

function isAssistantMessageItem(item) {
  const type = normalizeToken(item?.type);
  if (type === "agentmessage" || type === "assistantmessage") {
    return true;
  }
  return type === "message" && normalizeToken(item?.role) !== "user";
}

function isToolCallItem(item) {
  const type = normalizeToken(item?.type);
  return isGenericToolCallItemType(type)
    || type === "collabagenttoolcall"
    || type === "collabtoolcall";
}

function isGenericToolCallItemType(type) {
  return type === "toolcall"
    || type === "mcptoolcall"
    || type === "dynamictoolcall"
    || type === "websearch";
}

function assistantMessageText(item) {
  if (!isAssistantMessageItem(item)) {
    return "";
  }
  return readText(item.text)
    || readText(item.message)
    || renderContentText(item.content);
}

function planText(item) {
  return readText(item.text)
    || renderContentText(item.plan)
    || renderContentText(item.content);
}

function commandOutput(item) {
  return readText(item.aggregatedOutput)
    || readText(item.aggregated_output)
    || readText(item.output)
    || readText(item.stdout)
    || "";
}

function fileChangeOutput(item) {
  return readText(item.aggregatedOutput)
    || readText(item.aggregated_output)
    || readText(item.output)
    || readText(item.diff)
    || readText(item.patch)
    || "";
}

function toolCallOutput(item) {
  return readText(item.output)
    || readText(item.result)
    || readText(item.response)
    || renderContentText(item.result?.content)
    || renderContentText(item.contentItems)
    || renderContentText(item.content_items)
    || renderContentText(item.content)
    || "";
}

function textArray(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((entry) => {
    if (typeof entry === "string") {
      return entry;
    }
    if (!entry || typeof entry !== "object") {
      return "";
    }
    return readText(entry.text) || readText(entry.content) || "";
  });
}

function renderContentText(value) {
  if (typeof value === "string") {
    return value;
  }
  if (!Array.isArray(value)) {
    return "";
  }
  return value
    .map((entry) => {
      if (typeof entry === "string") {
        return entry;
      }
      if (!entry || typeof entry !== "object") {
        return "";
      }
      return readText(entry.text)
        || readText(entry.content)
        || readText(entry?.data?.text)
        || readText(entry?.file?.content);
    })
    .filter((entry) => entry !== "")
    .join("");
}

function itemIdOf(item) {
  return readString(item?.id) || readString(item?.itemId) || readString(item?.item_id);
}

function normalizeTimestamp(value) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric > 0 ? numeric : 0;
}

module.exports = {
  createDesktopConversationProjector,
  projectDesktopConversationStateToThread,
};
