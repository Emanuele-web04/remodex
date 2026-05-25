// FILE: codex-to-canonical-adapter.js
// Purpose: Converts Codex app-server notifications into Remodex canonical events.
// Layer: Bridge adapter
// Exports: convertCodexNotificationToCanonical
// Depends on: ./canonical-events

const {
  CANONICAL_EVENT_TYPES,
  createCanonicalEvent,
} = require("./canonical-events");

function convertCodexNotificationToCanonical(rawMessage, {
  agentRuntime = "codex",
  resolveAgentSessionId,
  now = () => new Date().toISOString(),
} = {}) {
  const parsed = parseJsonRpcMessage(rawMessage);
  if (!parsed || parsed.id != null) {
    return null;
  }

  const method = readString(parsed.method);
  const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
  const mapping = mapCodexMethod(method, params);
  if (!mapping) {
    return null;
  }

  const threadId = mapping.threadId || extractThreadId(params);
  const turnId = mapping.turnId || extractTurnId(params);
  const itemId = mapping.itemId || extractItemId(params);
  const agentSessionId = typeof resolveAgentSessionId === "function"
    ? resolveAgentSessionId({ threadId, params, method })
    : threadId;

  return createCanonicalEvent({
    type: mapping.type,
    agentRuntime,
    threadId,
    agentSessionId,
    turnId,
    itemId,
    createdAt: now(),
    payload: {
      ...mapping.payload,
      sourceMethod: method,
      raw: params,
    },
  });
}

function mapCodexMethod(method, params) {
  if (method === "thread/started") {
    return {
      type: CANONICAL_EVENT_TYPES.THREAD_STARTED,
      threadId: extractThreadId(params),
      payload: {
        thread: params.thread && typeof params.thread === "object" ? params.thread : null,
      },
    };
  }

  if (method === "turn/started") {
    return {
      type: CANONICAL_EVENT_TYPES.TURN_STARTED,
      payload: {},
    };
  }

  if (method === "codex/event/user_message") {
    return {
      type: CANONICAL_EVENT_TYPES.USER_MESSAGE,
      payload: {
        text: readString(params.text)
          || readString(params.message?.text)
          || readString(params.item?.text),
      },
    };
  }

  if (method === "item/agentMessage/delta"
    || method === "codex/event/agent_message_content_delta"
    || method === "codex/event/agent_message_delta") {
    return {
      type: CANONICAL_EVENT_TYPES.ASSISTANT_DELTA,
      itemId: extractItemId(params),
      payload: {
        delta: readString(params.delta)
          || readString(params.text)
          || readString(params.content),
      },
    };
  }

  if (method === "codex/event/agent_message") {
    return {
      type: CANONICAL_EVENT_TYPES.ASSISTANT_COMPLETED,
      itemId: extractItemId(params),
      payload: {
        text: readString(params.text)
          || readString(params.message?.text)
          || readString(params.item?.text),
      },
    };
  }

  if (method === "item/completed" || method === "codex/event/item_completed") {
    return mapItemCompleted(params);
  }

  if (isToolStartMethod(method)) {
    return {
      type: CANONICAL_EVENT_TYPES.TOOL_STARTED,
      itemId: extractItemId(params),
      payload: extractToolPayload(params, method),
    };
  }

  if (isToolDeltaMethod(method)) {
    return {
      type: CANONICAL_EVENT_TYPES.TOOL_DELTA,
      itemId: extractItemId(params),
      payload: extractToolPayload(params, method),
    };
  }

  if (isToolCompletedMethod(method)) {
    return {
      type: CANONICAL_EVENT_TYPES.TOOL_COMPLETED,
      itemId: extractItemId(params),
      payload: extractToolPayload(params, method),
    };
  }

  if (method === "turn/diff/updated" || method === "codex/event/turn_diff_updated") {
    return {
      type: CANONICAL_EVENT_TYPES.DIFF_UPDATED,
      payload: {
        diff: params.diff || params.patch || null,
      },
    };
  }

  if (method === "turn/completed") {
    return {
      type: CANONICAL_EVENT_TYPES.TURN_COMPLETED,
      payload: {
        status: readString(params.status) || "completed",
      },
    };
  }

  if (method === "error" || method === "codex/event/error" || method === "turn/failed") {
    return {
      type: CANONICAL_EVENT_TYPES.ERROR,
      payload: {
        message: readString(params.message)
          || readString(params.error?.message)
          || "Runtime event failed.",
        code: readString(params.code) || readString(params.error?.code),
      },
    };
  }

  return null;
}

function mapItemCompleted(params) {
  const item = params.item && typeof params.item === "object"
    ? params.item
    : params.event?.item && typeof params.event.item === "object"
      ? params.event.item
      : {};
  const itemType = readString(item.type) || readString(params.type);
  const isAssistant = itemType === "agent_message"
    || itemType === "agentMessage"
    || itemType === "assistant_message"
    || readString(item.role) === "assistant";

  if (isAssistant) {
    return {
      type: CANONICAL_EVENT_TYPES.ASSISTANT_COMPLETED,
      itemId: extractItemId(params),
      payload: {
        text: readString(item.text)
          || readString(item.content)
          || readString(params.text),
      },
    };
  }

  return {
    type: CANONICAL_EVENT_TYPES.TOOL_COMPLETED,
    itemId: extractItemId(params),
    payload: {
      toolType: itemType,
      status: readString(item.status) || readString(params.status) || "completed",
      item,
    },
  };
}

function isToolStartMethod(method) {
  return method === "codex/event/exec_command_begin"
    || method === "codex/event/patch_apply_begin"
    || method === "codex/event/file_search_begin"
    || method === "codex/event/image_generation_begin";
}

function isToolDeltaMethod(method) {
  return method === "codex/event/exec_command_output_delta"
    || method === "codex/event/background_event"
    || method === "codex/event/patch_apply_delta";
}

function isToolCompletedMethod(method) {
  return method === "codex/event/exec_command_end"
    || method === "codex/event/patch_apply_end"
    || method === "codex/event/image_generation_end";
}

function extractToolPayload(params, method) {
  return {
    toolType: method.replace(/^codex\/event\//, ""),
    command: readString(params.command),
    chunk: readString(params.chunk) || readString(params.delta) || readString(params.output),
    status: readString(params.status),
    fileChanges: Array.isArray(params.fileChanges) ? params.fileChanges : undefined,
  };
}

function extractThreadId(params = {}) {
  return readString(params.threadId)
    || readString(params.thread_id)
    || readString(params.thread?.id)
    || readString(params.event?.threadId)
    || readString(params.event?.thread_id);
}

function extractTurnId(params = {}) {
  return readString(params.turnId)
    || readString(params.turn_id)
    || readString(params.turn?.id)
    || readString(params.event?.turnId)
    || readString(params.event?.turn_id);
}

function extractItemId(params = {}) {
  return readString(params.itemId)
    || readString(params.item_id)
    || readString(params.item?.id)
    || readString(params.event?.itemId)
    || readString(params.event?.item_id)
    || readString(params.event?.item?.id);
}

function parseJsonRpcMessage(rawMessage) {
  try {
    return JSON.parse(rawMessage);
  } catch {
    return null;
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  convertCodexNotificationToCanonical,
  mapCodexMethod,
};
