// FILE: desktop-ipc-owner-transport.js
// Purpose: Framed IPC client and fallback router for the bridge's Desktop stream-owner role.
// Layer: CLI helper
// Exports: createDesktopOwnerIpcClient, createDesktopIpcRouterServer
// Depends on: crypto, fs, path, ./desktop-ipc-shared

const { randomUUID } = require("crypto");
const fs = require("fs");
const path = require("path");

const {
  CLIENT_STATUS_CHANGED,
  DESKTOP_IPC_METHOD_VERSIONS: METHOD_VERSION_BY_NAME,
  FRAME_HEADER_BYTES,
  MAX_FRAME_BYTES,
  normalizeToken,
  readString,
  requestIdKey,
  safeParseJSON,
  writeFrame,
} = require("./desktop-ipc-shared");

const DEFAULT_DISCOVERY_TIMEOUT_MS = 1_000;

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

module.exports = {
  DEFAULT_DISCOVERY_TIMEOUT_MS,
  createDesktopIpcRouterServer,
  createDesktopOwnerIpcClient,
};
