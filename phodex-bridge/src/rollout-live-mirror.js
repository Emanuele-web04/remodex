// FILE: rollout-live-mirror.js
// Purpose: Mirrors desktop-origin rollout activity back into live bridge notifications for iPhone catch-up.
// Layer: CLI helper
// Exports: createRolloutLiveMirrorController
// Depends on: fs, crypto, path, ./rollout-watch, ./codex-home

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");
const {
  findRecentRolloutFileForContextRead,
  resolveSessionsRoot,
} = require("./rollout-watch");
const { resolveCodexGeneratedImagesRoot } = require("./codex-home");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");

const DEFAULT_POLL_INTERVAL_MS = 700;
const DEFAULT_LOOKUP_TIMEOUT_MS = 5_000;
const DEFAULT_IDLE_TIMEOUT_MS = 60_000;
const DEFAULT_ACTIVITY_HEARTBEAT_MS = 5_000;
const DESKTOP_RESUME_METHODS = new Set(["thread/read", "thread/resume"]);

// Observes desktop-authored rollout files and replays the currently active run as
// bridge notifications so the phone can render live thinking/tool activity.
function createRolloutLiveMirrorController({
  sendApplicationResponse,
  logPrefix = "[remodex]",
  fsModule = fs,
  now = () => Date.now(),
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  lookupTimeoutMs = DEFAULT_LOOKUP_TIMEOUT_MS,
  idleTimeoutMs = DEFAULT_IDLE_TIMEOUT_MS,
  activityHeartbeatMs = DEFAULT_ACTIVITY_HEARTBEAT_MS,
} = {}) {
  const mirrorsByThreadId = new Map();

  function observeInbound(rawMessage) {
    const request = safeParseJSON(rawMessage);
    const method = readString(request?.method);
    if (!DESKTOP_RESUME_METHODS.has(method)) {
      return;
    }

    const threadId = readThreadId(request?.params);
    if (!threadId) {
      return;
    }

    const existingMirror = mirrorsByThreadId.get(threadId);
    if (existingMirror) {
      existingMirror.bump();
      return;
    }

    let mirror;
    mirror = createThreadRolloutLiveMirror({
      threadId,
      sendApplicationResponse,
      logPrefix,
      fsModule,
      now,
      setIntervalFn,
      clearIntervalFn,
      pollIntervalMs,
      lookupTimeoutMs,
      idleTimeoutMs,
      activityHeartbeatMs,
      onStop() {
        if (mirrorsByThreadId.get(threadId) === mirror) {
          mirrorsByThreadId.delete(threadId);
        }
      },
    });
    mirrorsByThreadId.set(threadId, mirror);
  }

  function stopAll() {
    for (const mirror of mirrorsByThreadId.values()) {
      mirror.stop();
    }
    mirrorsByThreadId.clear();
  }

  return {
    observeInbound,
    stopAll,
  };
}

// Tails one thread rollout and emits synthetic app-server-like notifications for
// the currently active desktop-origin run only.
function createThreadRolloutLiveMirror({
  threadId,
  sendApplicationResponse,
  logPrefix,
  fsModule,
  now,
  setIntervalFn,
  clearIntervalFn,
  pollIntervalMs,
  lookupTimeoutMs,
  idleTimeoutMs,
  activityHeartbeatMs,
  onStop = () => {},
}) {
  const startedAt = now();
  const state = createMirrorState(threadId);

  let isStopped = false;
  let rolloutPath = null;
  let lastSize = 0;
  let partialLine = "";
  let lastActivityAt = startedAt;
  let lastHeartbeatAt = 0;
  let didBootstrap = false;

  const intervalId = setIntervalFn(tick, pollIntervalMs);
  tick();

  function tick() {
    if (isStopped) {
      return;
    }

    try {
      const currentTime = now();

      if (!rolloutPath) {
        if (currentTime - startedAt >= lookupTimeoutMs) {
          stop();
          return;
        }

        rolloutPath = findRecentRolloutFileForContextRead(resolveSessionsRoot(), {
          threadId,
          fsModule,
        });
        if (!rolloutPath) {
          return;
        }
      }

      const fileSize = readFileSize(rolloutPath, fsModule);
      if (!didBootstrap) {
        didBootstrap = true;
        bootstrapFromExistingRollout({
          rolloutPath,
          fileSize,
          state,
          fsModule,
          sendApplicationResponse,
        });
        lastSize = fileSize;
        lastActivityAt = currentTime;
        lastHeartbeatAt = currentTime;
        if (state.isDesktopOrigin === false) {
          stop();
        }
        return;
      }

      if (fileSize > lastSize) {
        const chunk = readFileSlice(rolloutPath, lastSize, fileSize, fsModule);
        lastSize = fileSize;
        lastActivityAt = currentTime;
        lastHeartbeatAt = currentTime;
        if (!chunk) {
          return;
        }

        const combined = partialLine ? `${partialLine}${chunk}` : chunk;
        let searchStart = 0;
        let nlIndex;
        const lines = [];
        while ((nlIndex = combined.indexOf("\n", searchStart)) !== -1) {
          lines.push(combined.substring(searchStart, nlIndex));
          searchStart = nlIndex + 1;
        }
        partialLine = searchStart < combined.length ? combined.substring(searchStart) : "";
        processRolloutLines(lines, state, sendApplicationResponse);
        return;
      }

      if (
        state.isDesktopOrigin !== false
        && state.activeTurnId
        && currentTime - lastHeartbeatAt >= activityHeartbeatMs
      ) {
        lastHeartbeatAt = currentTime;
        sendApplicationResponse(JSON.stringify(createNotification("turn/activity", {
          threadId: state.threadId,
          turnId: state.activeTurnId,
          id: state.activeTurnId,
        })));
      }

      if (currentTime - lastActivityAt >= idleTimeoutMs) {
        stop();
      }
    } catch (error) {
      console.warn(`${logPrefix} rollout live mirror stopped for ${threadId}: ${error.message}`);
      stop();
    }
  }

  function bump() {
    lastActivityAt = now();
  }

  function stop() {
    if (isStopped) {
      return;
    }

    isStopped = true;
    clearIntervalFn(intervalId);
    onStop();
  }

  return {
    bump,
    stop,
  };
}

function bootstrapFromExistingRollout({
  rolloutPath,
  fileSize,
  state,
  fsModule,
  sendApplicationResponse,
}) {
  const initialContents = readFileSlice(rolloutPath, 0, fileSize, fsModule);
  if (!initialContents) {
    return;
  }

  const lines = initialContents.split("\n");
  const activeRunLines = [];
  let insideActiveRun = false;
  let activeTurnId = null;
  let pendingUserPreludeLine = null;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    const parsed = safeParseJSON(line);
    if (!parsed) {
      continue;
    }

    if (parsed.type === "session_meta") {
      populateSessionMetaState(state, parsed.payload);
    }

    const taskEventType = parsed?.type === "event_msg"
      ? readString(parsed?.payload?.type)
      : "";
    if (taskEventType === "user_message") {
      pendingUserPreludeLine = line;
    }
    if (taskEventType === "task_started") {
      insideActiveRun = true;
      activeTurnId = readString(parsed?.payload?.turn_id)
        || readString(parsed?.payload?.turnId)
        || "";
      activeRunLines.length = 0;
      if (pendingUserPreludeLine) {
        activeRunLines.push(pendingUserPreludeLine);
      }
      activeRunLines.push(line);
      continue;
    }

    if (!insideActiveRun) {
      continue;
    }

    activeRunLines.push(line);
    if (taskEventType === "task_complete") {
      insideActiveRun = false;
      activeTurnId = "";
      activeRunLines.length = 0;
      pendingUserPreludeLine = null;
    }
  }

  if (!isDesktopRolloutOrigin(state.sessionMeta)) {
    state.isDesktopOrigin = false;
    return;
  }

  state.isDesktopOrigin = true;
  processRolloutLines(activeRunLines, state, sendApplicationResponse);
}

function processRolloutLines(lines, state, sendApplicationResponse) {
  if (!Array.isArray(lines) || lines.length === 0) {
    return;
  }

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    const parsed = safeParseJSON(line);
    if (!parsed) {
      continue;
    }

    const notifications = synthesizeNotificationsFromRolloutEntry(parsed, state);
    for (const notification of notifications) {
      sendApplicationResponse(JSON.stringify(notification));
    }
  }
}

function synthesizeNotificationsFromRolloutEntry(entry, state) {
  if (entry?.type === "session_meta") {
    populateSessionMetaState(state, entry.payload);
    if (!isDesktopRolloutOrigin(state.sessionMeta)) {
      state.isDesktopOrigin = false;
    } else if (state.isDesktopOrigin == null) {
      state.isDesktopOrigin = true;
    }
    return [];
  }

  if (state.isDesktopOrigin === false) {
    return [];
  }

  const notifications = [];

  if (entry?.type === "event_msg") {
    const payload = entry.payload || {};
    const eventType = readString(payload.type);

    if (eventType === "task_started") {
      const explicitTurnId = readString(payload.turn_id) || readString(payload.turnId);
      const turnId = explicitTurnId || buildSyntheticTurnId(state, entry);
      state.activeTurnId = turnId;
      state.activeTurnIdIsSynthetic = !explicitTurnId;
      state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, turnId);
      state.hasThinking = false;
      state.commandCalls.clear();
      state.applyPatchCalls.clear();
      state.emittedPatchApplyEndCalls.clear();

      const startedParams = {
        threadId: state.threadId,
        remodexDesktopMirror: true,
        remodexRolloutLiveMirror: true,
      };
      startedParams.turnId = turnId;
      startedParams.id = turnId;
      notifications.push(createNotification("turn/started", startedParams));
      notifications.push(...flushPendingUserMessageNotifications(state, turnId));
      notifications.push(...ensureThinkingNotifications(state));
      return notifications;
    }

    if (eventType === "user_message") {
      const message = readString(payload.message) || readString(payload.text);
      if (!message) {
        return [];
      }

      const turnId = resolveRolloutEventTurnId(state, payload);
      if (!turnId) {
        state.pendingUserMessages.push({
          id: readString(payload.id),
          message,
          timestamp: readUserMessageTimestamp(entry, payload),
        });
        return [];
      }

      notifications.push(createNotification("codex/event/user_message", {
        threadId: state.threadId,
        turnId,
        message,
        ...timestampParams(readUserMessageTimestamp(entry, payload)),
      }));
      return notifications;
    }

    if (eventType === "task_complete") {
      const turnId = resolveRolloutEventTurnId(state, payload);
      if (!turnId) {
        return [];
      }

      notifications.push(...turnFileChangeSnapshotNotifications(state, turnId));
      notifications.push(createNotification("turn/completed", {
        threadId: state.threadId,
        turnId,
        id: turnId,
      }));
      resetRunState(state);
      return notifications;
    }

    if (eventType === "item_completed") {
      notifications.push(...itemCompletedNotifications(state, payload));
      return notifications;
    }

    if (eventType === "agent_reasoning") {
      notifications.push(...reasoningNotifications(state, firstNonEmptyString([
        readString(payload.message),
        readString(payload.text),
        readString(payload.summary),
      ])));
      return notifications;
    }

    if (eventType === "agent_message") {
      const message = readString(payload.message) || readString(payload.text);
      if (!message || !shouldMirrorAgentMessage(payload)) {
        return [];
      }
      const turnId = resolveRolloutEventTurnId(state, payload);

      notifications.push(createNotification("codex/event/agent_message", {
        threadId: state.threadId,
        turnId,
        itemId: buildAgentMessageItemId(state.threadId, turnId, entry, message),
        message,
      }));
      return notifications;
    }

    if (eventType === "image_generation_end") {
      notifications.push(...imageGenerationNotifications(state, payload, {
        preferCallId: true,
      }));
      return notifications;
    }

    if (eventType === "patch_apply_end") {
      notifications.push(...patchApplyEndNotifications(state, payload));
      return notifications;
    }

    return [];
  }

  if (entry?.type !== "response_item") {
    return [];
  }

  const payload = entry.payload || {};
  const itemType = normalizeRolloutItemType(payload.type);

  if (itemType === "reasoning") {
    notifications.push(...reasoningNotifications(state, extractReasoningText(payload)));
    return notifications;
  }

  if (itemType === "functioncall") {
    notifications.push(...toolStartNotifications(state, payload));
    return notifications;
  }

  if (itemType === "customtoolcall") {
    notifications.push(...customToolStartNotifications(state, payload));
    return notifications;
  }

  if (itemType === "functioncalloutput") {
    notifications.push(...toolOutputNotifications(state, payload));
    return notifications;
  }

  if (itemType === "imagegeneration" || itemType === "imagegenerationcall" || itemType === "imagegenerationend" || itemType === "imageview") {
    notifications.push(...imageGenerationNotifications(state, payload));
    return notifications;
  }

  return notifications;
}

function reasoningNotifications(state, text) {
  if (!state.activeTurnId) {
    return [];
  }

  const delta = readString(text);
  if (!delta) {
    return ensureThinkingNotifications(state);
  }

  state.hasThinking = true;
  return [
    createNotification("item/reasoning/textDelta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      itemId: state.reasoningItemId || buildSyntheticItemId("thinking", state.threadId, state.activeTurnId),
      delta,
    }),
  ];
}

function toolStartNotifications(state, payload) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = readString(payload.call_id) || readString(payload.callId);
  const toolName = readString(payload.name);
  if (!callId || !toolName) {
    return [];
  }

  const argumentsObject = parseToolArguments(payload.arguments);
  if (isInternalProgressPlanToolName(toolName)) {
    return [
      ...ensureThinkingNotifications(state),
      ...planUpdateNotifications(state, argumentsObject),
    ];
  }

  state.commandCalls.set(callId, {
    toolName,
    command: resolveToolCommand(toolName, argumentsObject),
    cwd: resolveToolWorkingDirectory(argumentsObject, state),
  });

  if (isCommandToolName(toolName)) {
    const command = state.commandCalls.get(callId)?.command || toolName;
    return [
      ...ensureThinkingNotifications(state),
      createNotification("codex/event/exec_command_begin", {
        threadId: state.threadId,
        turnId: state.activeTurnId,
        call_id: callId,
        command,
        cwd: state.commandCalls.get(callId)?.cwd || state.sessionMeta?.cwd || "",
        status: "running",
      }),
    ];
  }

  const activityMessage = genericToolActivityMessage(toolName);
  if (!activityMessage) {
    return ensureThinkingNotifications(state);
  }

  return [
    ...ensureThinkingNotifications(state),
    createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      message: activityMessage,
    }),
  ];
}

function customToolStartNotifications(state, payload) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = readString(payload.call_id) || readString(payload.callId);
  const toolName = readString(payload.name);
  if (!callId || !toolName) {
    return [];
  }

  const notifications = [...ensureThinkingNotifications(state)];
  if (toolName === "apply_patch") {
    const item = buildApplyPatchFileChangeItem({
      callId,
      patch: readString(payload.input),
      status: readString(payload.status) || "completed",
      idFallback: buildSyntheticItemId("file-change", state.threadId, state.activeTurnId, callId),
    });
    if (item) {
      state.applyPatchCalls.set(callId, item);
      notifications.push(createNotification("codex/event/patch_apply_begin", {
        threadId: state.threadId,
        turnId: state.activeTurnId,
        id: state.activeTurnId,
        call_id: callId,
        itemId: item.id,
        status: "inProgress",
        changes: item.changes,
      }));
    }
  }

  const activityMessage = genericToolActivityMessage(toolName);
  if (!activityMessage) {
    return notifications;
  }

  return [
    ...notifications,
    createNotification("codex/event/background_event", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      message: activityMessage,
    }),
  ];
}

function patchApplyEndNotifications(state, payload) {
  const turnId = resolveRolloutEventTurnId(state, payload);
  const callId = readString(payload.call_id) || readString(payload.callId);
  if (!turnId || !callId || state.emittedPatchApplyEndCalls.has(callId)) {
    return [];
  }

  const fileChangeItem = state.applyPatchCalls.get(callId);
  const changes = Array.isArray(payload.changes)
    ? payload.changes
    : fileChangeItem?.changes || [];
  if (changes.length === 0) {
    return [];
  }

  state.emittedPatchApplyEndCalls.add(callId);
  return [
    ...ensureThinkingNotifications(state),
    createNotification("codex/event/patch_apply_end", {
      threadId: state.threadId,
      turnId,
      id: turnId,
      call_id: callId,
      itemId: fileChangeItem?.id || callId,
      status: readString(payload.status) || fileChangeItem?.status || "completed",
      success: payload.success !== false,
      changes,
    }),
  ];
}

function turnFileChangeSnapshotNotifications(state, turnId) {
  const patchEntries = Array.from(state.applyPatchCalls.entries());
  if (!turnId || patchEntries.length === 0) {
    return [];
  }

  const changes = patchEntries.flatMap(([, item]) => Array.isArray(item?.changes) ? item.changes : []);
  if (changes.length === 0) {
    return [];
  }

  const [lastCallId, lastItem] = patchEntries[patchEntries.length - 1];
  const itemId = readString(lastItem?.id) || readString(lastCallId) || buildSyntheticItemId("file-change", state.threadId, turnId);
  return [
    createNotification("codex/event/patch_apply_end", {
      threadId: state.threadId,
      turnId,
      id: turnId,
      call_id: itemId,
      itemId,
      status: "completed",
      success: true,
      changes,
      remodexTurnFileChangeSnapshot: true,
    }),
  ];
}

function toolOutputNotifications(state, payload) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = readString(payload.call_id) || readString(payload.callId);
  if (!callId) {
    return [];
  }

  const toolCall = state.commandCalls.get(callId);
  if (!toolCall) {
    return [];
  }

  if (!isCommandToolName(toolCall.toolName)) {
    state.commandCalls.delete(callId);
    return [];
  }

  const output = readString(payload.output);
  const notifications = [...ensureThinkingNotifications(state)];
  if (output) {
    notifications.push(createNotification("codex/event/exec_command_output_delta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      command: toolCall.command,
      cwd: toolCall.cwd || "",
      chunk: output,
    }));
  }

  notifications.push(createNotification("codex/event/exec_command_end", {
    threadId: state.threadId,
    turnId: state.activeTurnId,
    call_id: callId,
    command: toolCall.command,
    cwd: toolCall.cwd || "",
    status: "completed",
    output: output || "",
  }));
  state.commandCalls.delete(callId);
  return notifications;
}

function imageGenerationNotifications(state, payload, { preferCallId = false } = {}) {
  if (!state.activeTurnId) {
    return [];
  }

  const callId = preferCallId
    ? firstNonEmptyString([
        readString(payload.call_id),
        readString(payload.callId),
        readString(payload.itemId),
        readString(payload.item_id),
        readString(payload.id),
      ])
    : firstNonEmptyString([
        readString(payload.id),
        readString(payload.call_id),
        readString(payload.callId),
        readString(payload.itemId),
        readString(payload.item_id),
      ]);
  if (!callId) {
    return [];
  }

  const imagePath = firstNonEmptyString([
    readString(payload.saved_path),
    readString(payload.savedPath),
    readString(payload.file_path),
    readString(payload.path),
  ]) || generatedImagePathForRolloutItem(state.threadId, callId);
  if (!imagePath) {
    return [];
  }

  return [
    ...ensureThinkingNotifications(state),
    createNotification("codex/event/image_generation_end", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      call_id: callId,
      itemId: callId,
      saved_path: imagePath,
      file_path: imagePath,
      path: imagePath,
    }),
  ];
}

function itemCompletedNotifications(state, payload) {
  const item = payload && typeof payload.item === "object" && !Array.isArray(payload.item)
    ? payload.item
    : null;
  if (!item || normalizeRolloutItemType(item.type) !== "plan") {
    return [];
  }

  const turnId = resolveRolloutEventTurnId(state, payload);
  if (!turnId) {
    return [];
  }

  return [
    createNotification("item/completed", {
      threadId: state.threadId,
      turnId,
      item,
    }),
  ];
}

function ensureThinkingNotifications(state) {
  if (!state.activeTurnId || state.hasThinking) {
    return [];
  }

  state.hasThinking = true;
  if (!state.reasoningItemId) {
    state.reasoningItemId = buildSyntheticItemId("thinking", state.threadId, state.activeTurnId);
  }

  return [
    createNotification("item/reasoning/textDelta", {
      threadId: state.threadId,
      turnId: state.activeTurnId,
      itemId: state.reasoningItemId,
      delta: "Thinking...",
    }),
  ];
}

function createMirrorState(threadId) {
  return {
    threadId,
    sessionMeta: null,
    isDesktopOrigin: null,
    activeTurnId: null,
    reasoningItemId: null,
    hasThinking: false,
    commandCalls: new Map(),
    applyPatchCalls: new Map(),
    emittedPatchApplyEndCalls: new Set(),
    pendingUserMessages: [],
    activeTurnIdIsSynthetic: false,
  };
}

function populateSessionMetaState(state, payload) {
  if (!payload || typeof payload !== "object") {
    return;
  }

  state.sessionMeta = {
    originator: readString(payload.originator),
    source: readString(payload.source),
    cwd: readString(payload.cwd),
  };
}

function isDesktopRolloutOrigin(sessionMeta) {
  const originator = readString(sessionMeta?.originator).toLowerCase();
  const source = readString(sessionMeta?.source).toLowerCase();
  if (!originator && !source) {
    return false;
  }

  if (originator.includes("mobile") || originator.includes("ios")) {
    return false;
  }

  return originator.includes("desktop")
    || originator.includes("vscode")
    || source.includes("vscode")
    || source.includes("desktop");
}

function extractReasoningText(payload) {
  const summary = Array.isArray(payload?.summary)
    ? payload.summary
        .map((part) => readString(part?.text) || readString(part?.summary))
        .filter(Boolean)
        .join("\n")
    : "";
  return firstNonEmptyString([
    summary,
    readString(payload?.text),
    readString(payload?.content),
  ]);
}

function parseToolArguments(rawArguments) {
  const parsed = safeParseJSON(rawArguments);
  return parsed && typeof parsed === "object" ? parsed : {};
}

function planUpdateNotifications(state, argumentsObject) {
  const plan = normalizeProgressPlanSteps(argumentsObject.plan);
  if (plan.length === 0) {
    return [];
  }

  const params = {
    threadId: state.threadId,
    turnId: state.activeTurnId,
    plan,
  };
  const explanation = readString(argumentsObject.explanation);
  if (explanation) {
    params.explanation = explanation;
  }

  return [createNotification("turn/plan/updated", params)];
}

function normalizeProgressPlanSteps(rawPlan) {
  if (!Array.isArray(rawPlan)) {
    return [];
  }

  return rawPlan.flatMap((rawStep) => {
    if (!rawStep || typeof rawStep !== "object") {
      return [];
    }

    const step = readString(rawStep.step);
    const status = normalizeProgressPlanStatus(rawStep.status);
    if (!step || !status) {
      return [];
    }

    return [{ step, status }];
  });
}

function normalizeProgressPlanStatus(rawStatus) {
  const normalized = readString(rawStatus);
  switch (normalized) {
  case "pending":
  case "in_progress":
  case "inProgress":
  case "completed":
    return normalized;
  default:
    return "";
  }
}

function resolveToolCommand(toolName, argumentsObject) {
  if (isCommandToolName(toolName)) {
    return firstNonEmptyString([
      readString(argumentsObject.cmd),
      readString(argumentsObject.command),
      readString(argumentsObject.raw_command),
      readString(argumentsObject.rawCommand),
    ]) || toolName;
  }

  return toolName;
}

function resolveToolWorkingDirectory(argumentsObject, state) {
  return firstNonEmptyString([
    readString(argumentsObject.workdir),
    readString(argumentsObject.cwd),
    readString(argumentsObject.working_directory),
    readString(state.sessionMeta?.cwd),
  ]) || "";
}

function isCommandToolName(toolName) {
  const normalized = readString(toolName).toLowerCase();
  return normalized === "exec_command" || normalized === "shell_command";
}

function isInternalProgressPlanToolName(toolName) {
  return readString(toolName).toLowerCase() === "update_plan";
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

function shouldMirrorAgentMessage(payload) {
  const phase = readString(payload?.phase).toLowerCase();
  return phase !== "commentary";
}

function createNotification(method, params = {}) {
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return { method, params };
  }

  return {
    method,
    params: {
      remodexDesktopMirror: true,
      remodexRolloutLiveMirror: true,
      ...params,
    },
  };
}

function flushPendingUserMessageNotifications(state, turnId) {
  const messages = state.pendingUserMessages.splice(0);
  if (messages.length === 0) {
    return [];
  }

  return messages.map((pending) => createNotification("codex/event/user_message", {
    threadId: state.threadId,
    turnId: turnId || state.activeTurnId || "",
    message: pending.message,
    ...(pending.id ? { id: pending.id } : {}),
    ...timestampParams(pending.timestamp),
  }));
}

function readUserMessageTimestamp(entry, payload = {}) {
  return firstNonEmptyString([
    readString(payload.createdAt),
    readString(payload.created_at),
    readString(payload.timestamp),
    readString(payload.time),
    readString(entry?.timestamp),
  ]);
}

function timestampParams(timestamp) {
  const normalizedTimestamp = readString(timestamp);
  return normalizedTimestamp
    ? { createdAt: normalizedTimestamp, timestamp: normalizedTimestamp }
    : {};
}

function buildSyntheticItemId(kind, threadId, turnId, suffix = "") {
  const suffixPart = suffix ? `:${suffix}` : "";
  return `rollout-${kind}:${threadId}:${turnId}${suffixPart}`;
}

function buildSyntheticTurnId(state, entry) {
  const timestamp = readString(entry?.timestamp) || "unknown";
  return `rollout-turn:${state.threadId}:${timestamp}`;
}

function resolveRolloutEventTurnId(state, payload = {}) {
  if (state.activeTurnIdIsSynthetic && state.activeTurnId) {
    return state.activeTurnId;
  }
  return readString(payload.turn_id) || readString(payload.turnId) || state.activeTurnId || "";
}

function buildAgentMessageItemId(threadId, turnId, entry, message) {
  const timestamp = readString(entry?.timestamp) || "untimed";
  const messageHash = crypto
    .createHash("sha256")
    .update(readString(message))
    .digest("hex")
    .slice(0, 12);
  return buildSyntheticItemId(
    "agent-message",
    threadId,
    turnId || "turnless",
    `${timestamp}:${messageHash}`
  );
}

function generatedImagePathForRolloutItem(threadId, callId) {
  const resolvedThreadId = readString(threadId);
  const resolvedCallId = readString(callId);
  if (!resolvedThreadId || !resolvedCallId) {
    return "";
  }

  return path.join(resolveCodexGeneratedImagesRoot(), resolvedThreadId, `${resolvedCallId}.png`);
}

function normalizeRolloutItemType(value) {
  return readString(value).replace(/[_-]/g, "").toLowerCase();
}

function resetRunState(state) {
  state.activeTurnId = null;
  state.reasoningItemId = null;
  state.hasThinking = false;
  state.commandCalls.clear();
  state.applyPatchCalls.clear();
  state.emittedPatchApplyEndCalls.clear();
  state.pendingUserMessages.length = 0;
  state.activeTurnIdIsSynthetic = false;
}

function readThreadId(params) {
  return firstNonEmptyString([
    readString(params?.threadId),
    readString(params?.thread_id),
  ]) || "";
}

function readFileSize(filePath, fsModule) {
  return fsModule.statSync(filePath).size;
}

function readFileSlice(filePath, start, endExclusive, fsModule) {
  const length = Math.max(0, endExclusive - start);
  if (length === 0) {
    return "";
  }

  const fileHandle = fsModule.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytesRead = fsModule.readSync(fileHandle, buffer, 0, length, start);
    return buffer.toString("utf8", 0, bytesRead);
  } finally {
    fsModule.closeSync(fileHandle);
  }
}

function safeParseJSON(rawValue) {
  if (typeof rawValue !== "string" || !rawValue.trim()) {
    return null;
  }

  try {
    return JSON.parse(rawValue);
  } catch {
    return null;
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function firstNonEmptyString(values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return "";
}

module.exports = {
  createRolloutLiveMirrorController,
  isDesktopRolloutOrigin,
};
