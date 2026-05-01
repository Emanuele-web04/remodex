// FILE: desktop-ipc-action-follower.js
// Purpose: Mirrors live Codex Desktop IPC pending actions to the phone and routes replies back to the desktop runtime.
// Layer: CLI helper
// Exports: createDesktopIpcActionFollower, projectPendingDesktopActions
// Depends on: net, os, path

const net = require("net");
const os = require("os");
const path = require("path");

const FRAME_HEADER_BYTES = 4;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 10_000;
const DESKTOP_RESUME_METHODS = new Set(["thread/read", "thread/resume"]);
const ACTION_METHODS = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/tool/requestUserInput",
]);
const REPLY_METHOD_BY_ACTION_METHOD = new Map([
  ["item/commandExecution/requestApproval", "thread-follower-command-approval-decision"],
  ["item/fileChange/requestApproval", "thread-follower-file-approval-decision"],
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
    recoverThreadBaseline(threadId);
    return false;
  }

  function stopAll() {
    rawStatesByThreadId.clear();
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
        queueThreadChange(threadId, params.change);
        recoverThreadBaseline(threadId);
      }
      return;
    }

    rawStatesByThreadId.set(threadId, nextState);
    syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
  }

  function onDisconnect() {
    rawStatesByThreadId.clear();
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
    if (typeof readConversationState !== "function"
      || recoveringThreadIds.has(threadId)
      || rawStatesByThreadId.has(threadId)) {
      return;
    }

    recoveringThreadIds.add(threadId);
    Promise.resolve()
      .then(() => readConversationState(threadId))
      .then((baselineState) => {
        if (!baselineState || typeof baselineState !== "object") {
          return;
        }

        let nextState = cloneJSON(baselineState);
        const queuedChanges = queuedChangesByThreadId.get(threadId) || [];
        queuedChangesByThreadId.delete(threadId);
        for (const change of queuedChanges) {
          nextState = applyConversationStateChange(nextState, change) || nextState;
        }

        rawStatesByThreadId.set(threadId, nextState);
        syncProjectedActions(threadId, projectPendingDesktopActions(threadId, nextState));
      })
      .catch((error) => {
        console.warn(`${logPrefix} desktop IPC baseline recovery failed for ${threadId}: ${error.message}`);
      })
      .finally(() => {
        recoveringThreadIds.delete(threadId);
      });
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

  const decision = readString(responseMessage?.result?.decision);
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

function projectPendingDesktopActions(threadId, conversationState) {
  const requests = Array.isArray(conversationState?.requests) ? conversationState.requests : [];
  return requests
    .filter((request) => request && request.completed !== true)
    .filter((request) => ACTION_METHODS.has(readString(request.method)))
    .map((request) => projectPendingDesktopAction(threadId, request))
    .filter(Boolean);
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

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
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
  projectPendingDesktopActions,
  resolveDefaultIpcSocketPath,
  seedConversationStateFromThreadRead,
};
