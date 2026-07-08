// FILE: desktop-ipc-conversation-adapter.js
// Purpose: Translates app-server JSON-RPC traffic into Codex Desktop's conversationState shape.
// Layer: CLI helper
// Exports: applyAppServerMessageToConversationState, buildConversationStateFromThread, conversation turn/item helpers
// Depends on: crypto, ./desktop-ipc-shared

const { randomUUID } = require("crypto");

const {
  cloneJSON,
  isContextualUserText,
  isUserRoleItem: isUserMessageItem,
  normalizeToken,
  readString,
  requestIdKey,
  sanitizeUserInputEntries: sanitizeSharedUserInputEntries,
} = require("./desktop-ipc-shared");

const LOCAL_HOST_ID = "local";

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
  allowOptimisticFallback = true,
} = {}) {
  const explicitTurnId = readTurnIdFromParams(params);
  if (explicitTurnId) {
    promoteFallbackTurnId(conversation, fallbackTurnIdsByThreadId, explicitTurnId);
    return explicitTurnId;
  }
  const fallbackTurnId = readFallbackTurnId(conversation?.id, fallbackTurnIdsByThreadId);
  if (fallbackTurnId) {
    if (!allowOptimisticFallback && isOptimisticPendingTurnId(conversation, fallbackTurnId)) {
      return latestNonOptimisticTurnId(conversation) || "";
    }
    return fallbackTurnId;
  }
  if (!allowOptimisticFallback) {
    // Turnless file-change events belong on the latest real turn, not a pending
    // phone-send placeholder that may temporarily be the last row.
    return latestNonOptimisticTurnId(conversation) || "";
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

function isOptimisticPendingTurn(turn) {
  return turn?.remodexOptimisticPendingTurn === true;
}

function isOptimisticPendingTurnId(conversation, turnId) {
  const normalizedTurnId = readString(turnId);
  if (!conversation || !normalizedTurnId || !Array.isArray(conversation.turns)) {
    return false;
  }
  return conversation.turns.some((turn) => (
    isOptimisticPendingTurn(turn)
      && (readString(turn?.turnId) || readString(turn?.id)) === normalizedTurnId
  ));
}

function latestNonOptimisticTurnId(conversation) {
  const turns = Array.isArray(conversation?.turns) ? conversation.turns : [];
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = turns[index];
    if (isOptimisticPendingTurn(turn)) {
      continue;
    }
    const turnId = readString(turn?.turnId) || readString(turn?.id);
    if (turnId) {
      return turnId;
    }
  }
  return "";
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
        || readString(message.params?.name)
        || readString(message.params?.title)
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
        applyPendingTurnStartParams(
          conversation,
          upsertedTurn,
          pendingTurnStartParamsByThreadId,
          fallbackTurnIdsByThreadId
        );
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
      const allowOptimisticFallback = !isFileChangeLikeItemType(message.params?.item?.type);
      const turn = ensureTurn(conversation, resolveTurnIdForParams({
        conversation,
        params: message.params,
        fallbackTurnIdsByThreadId,
        allowOptimisticFallback,
        now,
      }), { now, allowLastTurnFallback: allowOptimisticFallback });
      if (turn && message.params?.item) {
        upsertItem(turn, cloneJSON(message.params.item));
        // Desktop derives its "Worked for Ns" divider from these two marks, not
        // from durationMs, so keep them set on every lifecycle path.
        if (message.params.item.type === "agentMessage") {
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
      const allowOptimisticFallback = method !== "item/fileChange/outputDelta";
      applyDeltaNotification(conversation, method, message.params || {}, {
        fallbackTurnIdsByThreadId,
        allowOptimisticFallback,
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
  const builtTurn = {
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
  // Injected context (AGENTS.md instructions, environment_context) rides inside
  // turn.items on turn/started, turn/completed, and hydrated thread/read turns.
  // Drop it here, position-independently, so no Desktop snapshot path leaks it
  // as a user bubble regardless of where the app-server placed it in the turn.
  builtTurn.items = builtTurn.items
    .map(sanitizeUserMessageItem)
    .filter(Boolean);
  // Hydrated turns from thread/read carry the prompt as an item with empty
  // params.input; adopt it into params so Desktop renders a normal bubble.
  normalizeTurnInitialPrompt(builtTurn);
  return builtTurn;
}

function applyPendingTurnStartParams(
  conversation,
  turn,
  pendingTurnStartParamsByThreadId,
  fallbackTurnIdsByThreadId = null
) {
  if (!turn || !(pendingTurnStartParamsByThreadId instanceof Map)) {
    return;
  }
  const threadId = readString(conversation?.id);
  const queue = threadId ? pendingTurnStartParamsByThreadId.get(threadId) : null;
  const pendingEntry = Array.isArray(queue) ? queue.shift() : null;
  if (Array.isArray(queue) && queue.length === 0) {
    pendingTurnStartParamsByThreadId.delete(threadId);
  }
  if (pendingEntry) {
    pendingEntry.consumed = true;
  }
  releaseConsumedOptimisticFallback(threadId, pendingEntry, fallbackTurnIdsByThreadId);
  const pendingParams = pendingEntry?.params;
  if (!pendingParams) {
    return;
  }

  applyTurnRuntimeMetadata(conversation, pendingParams);

  const input = Array.isArray(pendingParams.input) ? pendingParams.input : [];
  if (input.length === 0) {
    return;
  }

  turn.params = {
    ...turn.params,
    ...cloneJSON(pendingParams),
  };
  normalizeTurnInitialPrompt(turn);
}

function releaseConsumedOptimisticFallback(threadId, pendingEntry, fallbackTurnIdsByThreadId) {
  const consumedOptimisticTurnId = readString(pendingEntry?.optimisticTurnId);
  if (!threadId || !consumedOptimisticTurnId || !(fallbackTurnIdsByThreadId instanceof Map)) {
    return;
  }
  if (readString(fallbackTurnIdsByThreadId.get(threadId)) === consumedOptimisticTurnId) {
    fallbackTurnIdsByThreadId.delete(threadId);
  }
}

function applyTurnRuntimeMetadata(conversation, turnParams) {
  if (!conversation || !turnParams) {
    return;
  }
  const model = readString(turnParams.model);
  const effort = readString(turnParams.effort);
  if (model) {
    conversation.previousTurnModel = conversation.latestModel || null;
    conversation.latestModel = model;
  }
  if (effort) {
    conversation.latestReasoningEffort = effort;
  }
  if (turnParams.collaborationMode && typeof turnParams.collaborationMode === "object") {
    conversation.latestCollaborationMode = cloneJSON(turnParams.collaborationMode);
    return;
  }
  if (!model && !effort) {
    return;
  }
  const settings = conversation.latestCollaborationMode?.settings;
  conversation.latestCollaborationMode = {
    mode: conversation.latestCollaborationMode?.mode || "default",
    settings: {
      ...(settings && typeof settings === "object" ? settings : {
        developer_instructions: null,
      }),
      model: model || settings?.model || "",
      reasoning_effort: effort || settings?.reasoning_effort || null,
    },
  };
}

function turnHasUserMessageItem(turn) {
  return turn.items.some((item) => isUserMessageItem(item));
}

const PRE_PROMPT_META_ITEM_TYPES = new Set([
  "automaticapprovalreview",
  "forkedfromconversation",
  "modelchanged",
  "modelrerouted",
  "personalitychanged",
  "remotetaskcreated",
  "worktreeinit",
]);

function extractUserText(entries) {
  if (typeof entries === "string") {
    return entries.trim();
  }
  if (!Array.isArray(entries)) {
    return "";
  }
  return entries
    .map((entry) => {
      if (typeof entry === "string") {
        return entry;
      }
      if (!entry || typeof entry !== "object") {
        return "";
      }
      return typeof entry.text === "string" ? entry.text : "";
    })
    .filter(Boolean)
    .join("\n")
    .trim();
}

function sanitizeUserInputEntries(entries) {
  return sanitizeSharedUserInputEntries(entries).map(cloneJSON);
}

function sanitizeUserMessageItem(item) {
  if (!isUserMessageItem(item)) {
    return item;
  }
  const rawText = extractUserText(item?.content);
  const sanitizedContent = sanitizeUserInputEntries(Array.isArray(item?.content) ? item.content : []);
  if (rawText && sanitizedContent.length === 0) {
    return null;
  }
  if (!Array.isArray(item?.content)) {
    return cloneJSON(item);
  }
  return {
    ...cloneJSON(item),
    content: sanitizedContent,
  };
}

function isInitialPromptUserMessageItem(turn, item) {
  if (!isUserMessageItem(item)) {
    return false;
  }
  const promptText = extractUserText(turn?.params?.input);
  if (!promptText) {
    return false;
  }
  return extractUserText(item?.content) === promptText;
}

function isContextualUserMessageItem(item) {
  if (!isUserMessageItem(item)) {
    return false;
  }
  const text = extractUserText(item?.content);
  return Boolean(text) && isContextualUserText(text);
}

function normalizeTurnInitialPrompt(turn) {
  if (!turn || !Array.isArray(turn.items)) {
    return;
  }
  if (Array.isArray(turn.params?.input)) {
    turn.params = {
      ...turn.params,
      input: sanitizeUserInputEntries(turn.params.input),
    };
  }
  const promptText = extractUserText(turn?.params?.input);
  for (let index = 0; index < turn.items.length; index += 1) {
    let item = turn.items[index];
    const sanitizedItem = sanitizeUserMessageItem(item);
    if (!sanitizedItem) {
      turn.items.splice(index, 1);
      index -= 1;
      continue;
    }
    if (sanitizedItem !== item) {
      turn.items[index] = sanitizedItem;
      item = sanitizedItem;
    }
    // Injected context user items sit before the real prompt in persisted
    // history; strip them so they are never adopted as the prompt bubble.
    if (isContextualUserMessageItem(item)) {
      turn.items.splice(index, 1);
      index -= 1;
      continue;
    }
    if (isUserMessageItem(item)) {
      const itemText = extractUserText(item?.content);
      if (!itemText) {
        return;
      }
      if (!promptText) {
        if (adoptInitialPromptUserMessage(turn, item)) {
          turn.items.splice(index, 1);
        }
        return;
      }
      if (itemText === promptText) {
        turn.items.splice(index, 1);
      }
      return;
    }
    if (!PRE_PROMPT_META_ITEM_TYPES.has(normalizeToken(item?.type))) {
      return;
    }
  }
}

function userMessageContentFromTurnInput(entry) {
  if (typeof entry === "string") {
    const text = readString(entry);
    return text ? { type: "text", text } : null;
  }
  if (!entry || typeof entry !== "object") {
    return null;
  }
  const type = normalizeToken(entry.type);
  if (type === "inputtext" || type === "text") {
    return { type: "text", text: readString(entry.text) };
  }
  return cloneJSON(entry);
}

function adoptInitialPromptUserMessage(turn, item) {
  if (!isUserMessageItem(item) || !Array.isArray(item?.content)) {
    return false;
  }
  const input = item.content
    .map(userMessageContentFromTurnInput)
    .filter(Boolean);
  if (input.length === 0) {
    return false;
  }
  turn.params = {
    ...turn.params,
    input,
  };
  return true;
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

function ensureTurn(conversation, turnId, {
  now = () => Date.now(),
  allowLastTurnFallback = true,
} = {}) {
  const normalizedTurnId = readString(turnId);
  if (!normalizedTurnId) {
    if (!allowLastTurnFallback) {
      return null;
    }
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
  // Injected context (AGENTS.md instructions, environment_context) arrives as
  // user items too; no Codex UI renders it, so it must not reach the stream.
  // Also evict any copy that slipped into the state before this filter existed.
  const index = turn.items.findIndex((candidate) => readString(candidate?.id) === itemId);
  const sanitizedItem = sanitizeUserMessageItem(item);
  const existingItem = index >= 0 ? sanitizeUserMessageItem(turn.items[index]) : null;
  if (!sanitizedItem) {
    if (index >= 0) {
      turn.items.splice(index, 1);
    }
    return;
  }
  if (index >= 0) {
    turn.items[index] = {
      ...(existingItem || {}),
      ...cloneJSON(sanitizedItem),
    };
    return;
  }
  // The app-server echoes the initial prompt as a userMessage item; Desktop
  // already renders it from turn.params.input and would label the duplicate as
  // "Steered conversation". Only later user messages are genuine steers.
  if (isUserMessageItem(sanitizedItem) && !turnHasUserMessageItem(turn)) {
    if (isInitialPromptUserMessageItem(turn, sanitizedItem)) {
      return;
    }
    if (!extractUserText(turn?.params?.input) && adoptInitialPromptUserMessage(turn, sanitizedItem)) {
      return;
    }
  }
  turn.items.push(cloneJSON(sanitizedItem));
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
  allowOptimisticFallback = true,
  now = () => Date.now(),
} = {}) {
  const turn = ensureTurn(conversation, resolveTurnIdForParams({
    conversation,
    params,
    fallbackTurnIdsByThreadId,
    allowOptimisticFallback,
    now,
  }), { now, allowLastTurnFallback: allowOptimisticFallback });
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

  // Deltas prove work is in progress even when item/started was missed (e.g.
  // the bridge joined mid-turn); Desktop's worked-for divider needs the mark.
  turn.firstTurnWorkItemStartedAtMs = turn.firstTurnWorkItemStartedAtMs || now();

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

function isFileChangeLikeItemType(value) {
  const itemType = normalizeToken(value);
  return itemType === "filechange" || itemType === "diff";
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

function timestampSecondsToMs(value) {
  return Number.isFinite(value) && value > 0 ? Math.round(value * 1000) : 0;
}

const REQUEST_METHODS_WITH_THREAD = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/fileRead/requestApproval",
  "item/permissions/requestApproval",
  "item/tool/requestUserInput",
  "mcpServer/elicitation/request",
  "item/tool/call",
]);

module.exports = {
  LOCAL_HOST_ID,
  REQUEST_METHODS_WITH_THREAD,
  applyAppServerMessageToConversationState,
  applyPendingTurnStartParams,
  buildConversationStateFromThread,
  buildConversationTurn,
  createEmptyConversationState,
  ensureConversationInMap,
  mergeConversationTurnsFromThread,
  readThreadIdFromParams,
  readTurnIdFromParams,
  readTurnIdFromTurn,
  timestampSecondsToMs,
  upsertItem,
  upsertTurn,
};
