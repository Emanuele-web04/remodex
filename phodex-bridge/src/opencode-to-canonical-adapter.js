// FILE: opencode-to-canonical-adapter.js
// Purpose: Converts OpenCode SSE events into Remodex canonical bridge events.
// Layer: Bridge adapter
// Exports: convertOpenCodeEventToCanonical, createOpenCodeCanonicalState
// Depends on: ./canonical-events

const {
  CANONICAL_EVENT_TYPES,
  createCanonicalEvent,
} = require("./canonical-events");

const PERMISSION_REQUEST_METHOD = "remodex/request/permission";

function createOpenCodeCanonicalState() {
  return {
    partsById: new Map(),
    messageTextById: new Map(),
    completedMessageIds: new Set(),
    textItemIdBySessionId: new Map(),
  };
}

function convertOpenCodeEventToCanonical(event, {
  threadId,
  agentSessionId,
  turnId,
  state = createOpenCodeCanonicalState(),
  now = () => new Date().toISOString(),
} = {}) {
  const type = readString(event?.type);
  const properties = event?.properties && typeof event.properties === "object" ? event.properties : {};
  const sessionId = readString(properties.sessionID) || readString(properties.sessionId);
  if (!type || (sessionId && agentSessionId && sessionId !== agentSessionId)) {
    return [];
  }

  const common = {
    agentRuntime: "opencode",
    threadId,
    agentSessionId: sessionId || agentSessionId,
    turnId,
    createdAt: now(),
  };

  if (type === "message.part.updated") {
    rememberPart(state, properties.part);
    return [];
  }

  if (type === "message.part.delta") {
    return convertMessagePartDelta(properties, common, state);
  }

  if (type === "message.updated") {
    return convertMessageUpdated(properties, common, state);
  }

  if (type === "session.diff") {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.DIFF_UPDATED,
      payload: {
        sourceEventType: type,
        diff: properties.diff ?? null,
      },
    })];
  }

  if (type === "session.error") {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.ERROR,
      payload: {
        sourceEventType: type,
        message: readErrorMessage(properties.error) || "OpenCode session failed.",
        code: readString(properties.error?.name) || readString(properties.error?.code),
      },
    })];
  }

  if (type === "session.next.text.started") {
    const itemId = readString(event.id) || `opencode-text-${turnId || sessionId || Date.now()}`;
    state.textItemIdBySessionId.set(sessionId || agentSessionId || "", itemId);
    return [];
  }

  if (type === "session.next.text.delta") {
    const delta = readString(properties.delta);
    if (!delta) {
      return [];
    }
    const itemId = state.textItemIdBySessionId.get(sessionId || agentSessionId || "")
      || `opencode-text-${turnId || sessionId || "active"}`;
    appendMessageText(state, itemId, delta);
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.ASSISTANT_DELTA,
      itemId,
      payload: {
        sourceEventType: type,
        delta,
      },
    })];
  }

  if (type === "session.next.text.ended") {
    const itemId = state.textItemIdBySessionId.get(sessionId || agentSessionId || "")
      || `opencode-text-${turnId || sessionId || "active"}`;
    const text = readString(properties.text) || state.messageTextById.get(itemId) || "";
    state.messageTextById.set(itemId, text);
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.ASSISTANT_COMPLETED,
      itemId,
      payload: {
        sourceEventType: type,
        text,
        status: "completed",
      },
    })];
  }

  if (type === "session.next.reasoning.delta") {
    const reasoning = readString(properties.delta);
    if (!reasoning) {
      return [];
    }
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.ASSISTANT_DELTA,
      itemId: readString(properties.reasoningID) || readString(event.id),
      payload: {
        sourceEventType: type,
        reasoning,
      },
    })];
  }

  if (type === "session.next.tool.called" || type === "session.next.shell.started") {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.TOOL_STARTED,
      itemId: readString(properties.callID) || readString(event.id),
      payload: {
        sourceEventType: type,
        toolName: readString(properties.tool) || readString(properties.command) || readString(properties.name),
        command: readString(properties.command),
        input: properties.input,
      },
    })];
  }

  if (type === "session.next.tool.input.delta" || type === "session.next.tool.progress") {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.TOOL_DELTA,
      itemId: readString(properties.callID) || readString(event.id),
      payload: {
        sourceEventType: type,
        delta: readString(properties.delta) || stringifyToolContent(properties.content) || stringifyToolContent(properties.structured),
      },
    })];
  }

  if (type === "session.next.tool.success" || type === "session.next.tool.failed" || type === "session.next.shell.ended") {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.TOOL_COMPLETED,
      itemId: readString(properties.callID) || readString(event.id),
      payload: {
        sourceEventType: type,
        status: type.endsWith(".failed") ? "failed" : "completed",
        output: readString(properties.output) || stringifyToolContent(properties.content) || stringifyToolContent(properties.structured),
        message: readErrorMessage(properties.error),
      },
    })];
  }

  if (type === "permission.asked") {
    return [createPermissionRequest(event, properties, common)];
  }

  return [];
}

function convertMessagePartDelta(properties, common, state) {
  const delta = readString(properties.delta);
  const partId = readString(properties.partID) || readString(properties.partId);
  const field = readString(properties.field);
  if (!delta || (field && field !== "text")) {
    return [];
  }

  const part = state.partsById.get(partId) || {};
  const partType = readString(part.type);
  const messageId = readString(properties.messageID) || readString(properties.messageId) || readString(part.messageID) || readString(part.messageId);
  if (partType === "reasoning") {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.ASSISTANT_DELTA,
      itemId: partId,
      payload: {
        sourceEventType: "message.part.delta",
        reasoning: delta,
      },
    })];
  }

  const itemId = messageId || partId;
  appendMessageText(state, itemId, delta);
  return [createCanonicalEvent({
    ...common,
    type: CANONICAL_EVENT_TYPES.ASSISTANT_DELTA,
    itemId,
    payload: {
      sourceEventType: "message.part.delta",
      delta,
    },
  })];
}

function convertMessageUpdated(properties, common, state) {
  const info = properties.info && typeof properties.info === "object" ? properties.info : {};
  const role = readString(info.role);
  const messageId = readString(info.id);
  if (role !== "assistant" || !messageId) {
    return [];
  }

  if (info.error) {
    return [createCanonicalEvent({
      ...common,
      type: CANONICAL_EVENT_TYPES.ERROR,
      itemId: messageId,
      payload: {
        sourceEventType: "message.updated",
        message: readErrorMessage(info.error) || "OpenCode assistant message failed.",
        code: readString(info.error?.name) || readString(info.error?.code),
      },
    })];
  }

  if (!info.time?.completed && !readString(info.finish)) {
    return [];
  }
  if (state.completedMessageIds.has(messageId)) {
    return [];
  }
  state.completedMessageIds.add(messageId);

  return [createCanonicalEvent({
    ...common,
    type: CANONICAL_EVENT_TYPES.ASSISTANT_COMPLETED,
    itemId: messageId,
    payload: {
      sourceEventType: "message.updated",
      text: state.messageTextById.get(messageId) || readString(info.text) || readString(info.content) || "",
      status: readString(info.finish) || "completed",
    },
  })];
}

function createPermissionRequest(event, properties, common) {
  const requestId = readString(properties.id) || readString(event.id);
  const permissionName = readString(properties.permission) || "permission";
  const patterns = Array.isArray(properties.patterns) ? properties.patterns.filter((entry) => typeof entry === "string") : [];
  const metadata = properties.metadata && typeof properties.metadata === "object" ? properties.metadata : {};
  const tool = properties.tool && typeof properties.tool === "object" ? properties.tool : {};
  const permissions = {
    [permissionName]: true,
  };

  return {
    jsonrpc: "2.0",
    id: requestId || undefined,
    method: PERMISSION_REQUEST_METHOD,
    params: {
      schemaVersion: 1,
      ...common,
      itemId: readString(tool.callID) || readString(tool.messageID) || undefined,
      permissionId: requestId,
      payload: {
        sourceEventType: "permission.asked",
        request: {
          id: requestId,
          toolName: permissionName,
          reason: readString(metadata.description)
            || readString(metadata.reason)
            || `OpenCode is requesting ${permissionName} permission.`,
          command: patterns.join(", "),
          permissions,
          patterns,
          metadata,
          always: Array.isArray(properties.always) ? properties.always : [],
          tool,
        },
      },
    },
  };
}

function rememberPart(state, part) {
  if (!part || typeof part !== "object") {
    return;
  }
  const partId = readString(part.id);
  if (!partId) {
    return;
  }
  state.partsById.set(partId, part);
}

function appendMessageText(state, messageId, delta) {
  if (!messageId || !delta) {
    return;
  }
  state.messageTextById.set(messageId, `${state.messageTextById.get(messageId) || ""}${delta}`);
}

function stringifyToolContent(value) {
  if (typeof value === "string") {
    return value;
  }
  if (value === undefined || value === null) {
    return "";
  }
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function readErrorMessage(error) {
  if (typeof error === "string") {
    return error;
  }
  return readString(error?.message)
    || readString(error?.name)
    || readString(error?.code);
}

function readString(value) {
  return typeof value === "string" ? value : "";
}

module.exports = {
  PERMISSION_REQUEST_METHOD,
  convertOpenCodeEventToCanonical,
  createOpenCodeCanonicalState,
};
