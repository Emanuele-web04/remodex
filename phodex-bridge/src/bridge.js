// FILE: bridge.js
// Purpose: Runs Codex locally, bridges relay traffic, and coordinates desktop refreshes for Codex.app.
// Layer: CLI service
// Exports: startBridge
// Depends on: ws, uuid, ./qr, ./codex-desktop-refresher, ./codex-transport

const WebSocket = require("ws");
const { v4: uuidv4 } = require("uuid");
const {
  CodexDesktopRefresher,
  readBridgeConfig,
} = require("./codex-desktop-refresher");
const { createCodexTransport } = require("./codex-transport");
const { printQR } = require("./qr");
const { rememberActiveThread } = require("./session-state");
const { handleGitRequest } = require("./git-handler");
const { handleWorkspaceRequest } = require("./workspace-handler");

function startBridge() {
  const config = readBridgeConfig();
  const sessionId = uuidv4();
  const relayBaseUrl = config.relayUrl.replace(/\/+$/, "");
  const relaySessionUrl = `${relayBaseUrl}/${sessionId}`;
  const desktopRefresher = new CodexDesktopRefresher({
    enabled: config.refreshEnabled,
    debounceMs: config.refreshDebounceMs,
    refreshCommand: config.refreshCommand,
    bundleId: config.codexBundleId,
    appPath: config.codexAppPath,
  });

  // Keep the local Codex runtime alive across transient relay disconnects.
  let socket = null;
  let isShuttingDown = false;
  let reconnectAttempt = 0;
  let reconnectTimer = null;
  let lastConnectionStatus = null;
  let codexHandshakeState = config.codexEndpoint ? "warm" : "cold";
  const forwardedInitializeRequestIds = new Set();
  const pendingCodexMessages = [];

  const codex = createCodexTransport({
    endpoint: config.codexEndpoint,
    env: process.env,
    logPrefix: "[remodex]",
  });

  codex.onError((error) => {
    if (config.codexEndpoint) {
      console.error(`[remodex] Failed to connect to Codex endpoint: ${config.codexEndpoint}`);
    } else {
      console.error("[remodex] Failed to start `codex app-server`.");
      console.error(`[remodex] Launch command: ${codex.describe()}`);
      console.error("[remodex] Make sure the Codex CLI is installed and that the launcher works on this OS.");
    }
    console.error(error.message);
    process.exit(1);
  });

  function clearReconnectTimer() {
    if (!reconnectTimer) {
      return;
    }

    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  // Keeps npm start output compact by emitting only high-signal connection states.
  function logConnectionStatus(status) {
    if (lastConnectionStatus === status) {
      return;
    }

    lastConnectionStatus = status;
    console.log(`[remodex] ${status}`);
  }

  // Retries the relay socket while preserving the active Codex process and session id.
  function scheduleRelayReconnect(closeCode) {
    if (isShuttingDown) {
      return;
    }

    if (closeCode === 4000 || closeCode === 4001) {
      logConnectionStatus("disconnected");
      shutdown(codex, () => socket, () => {
        isShuttingDown = true;
        clearReconnectTimer();
      });
      return;
    }

    if (reconnectTimer) {
      return;
    }

    reconnectAttempt += 1;
    const delayMs = Math.min(1_000 * reconnectAttempt, 5_000);
    logConnectionStatus("connecting");
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connectRelay();
    }, delayMs);
  }

  function connectRelay() {
    if (isShuttingDown) {
      return;
    }

    logConnectionStatus("connecting");
    const nextSocket = new WebSocket(relaySessionUrl, {
      headers: { "x-role": "mac" },
    });
    socket = nextSocket;

    nextSocket.on("open", () => {
      clearReconnectTimer();
      reconnectAttempt = 0;
      logConnectionStatus("connected");
      while (pendingCodexMessages.length > 0) {
        const buffered = pendingCodexMessages.shift();
        nextSocket.send(buffered);
      }
    });

    nextSocket.on("message", (data) => {
      const message = typeof data === "string" ? data : data.toString("utf8");
      if (handleBridgeManagedHandshakeMessage(message, nextSocket)) {
        return;
      }
      if (handleWorkspaceRequest(message, (r) => nextSocket.send(r))) {
        return;
      }
      if (handleGitRequest(message, (r) => nextSocket.send(r))) {
        return;
      }
      desktopRefresher.handleInbound(message);
      rememberThreadFromMessage("phone", message);
      codex.send(message);
    });

    nextSocket.on("close", (code) => {
      logConnectionStatus("disconnected");
      if (socket === nextSocket) {
        socket = null;
      }
      desktopRefresher.handleTransportReset();
      scheduleRelayReconnect(code);
    });

    nextSocket.on("error", () => {
      logConnectionStatus("disconnected");
    });
  }

  printQR(sessionId, relayBaseUrl);
  connectRelay();

  codex.onMessage((message) => {
    trackCodexHandshakeState(message);
    desktopRefresher.handleOutbound(message);
    rememberThreadFromMessage("codex", message);
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(message);
    } else {
      pendingCodexMessages.push(message);
    }
  });

  codex.onClose(() => {
    logConnectionStatus("disconnected");
    isShuttingDown = true;
    clearReconnectTimer();
    desktopRefresher.handleTransportReset();
    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
      socket.close();
    }
  });

  process.on("SIGINT", () => shutdown(codex, () => socket, () => {
    isShuttingDown = true;
    clearReconnectTimer();
  }));
  process.on("SIGTERM", () => shutdown(codex, () => socket, () => {
    isShuttingDown = true;
    clearReconnectTimer();
  }));

  function rememberThreadFromMessage(source, rawMessage) {
    const threadId = extractThreadId(rawMessage);
    if (!threadId) {
      return;
    }

    rememberActiveThread(threadId, source);
  }

  // The spawned/shared Codex app-server stays warm across phone reconnects.
  // When iPhone reconnects it sends initialize again, but forwarding that to the
  // already-initialized Codex transport only produces "Already initialized".
  function handleBridgeManagedHandshakeMessage(rawMessage, relaySocket) {
    let parsed = null;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (!method) {
      return false;
    }

    if (method === "initialize" && parsed.id != null) {
      if (codexHandshakeState !== "warm") {
        forwardedInitializeRequestIds.add(String(parsed.id));
        return false;
      }

      relaySocket.send(JSON.stringify({
        id: parsed.id,
        result: {
          bridgeManaged: true,
        },
      }));
      return true;
    }

    if (method === "initialized") {
      return codexHandshakeState === "warm";
    }

    return false;
  }

  // Learns whether the underlying Codex transport has already completed its own MCP handshake.
  function trackCodexHandshakeState(rawMessage) {
    let parsed = null;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return;
    }

    const responseId = parsed?.id;
    if (responseId == null) {
      return;
    }

    const responseKey = String(responseId);
    if (!forwardedInitializeRequestIds.has(responseKey)) {
      return;
    }

    forwardedInitializeRequestIds.delete(responseKey);

    if (parsed?.result != null) {
      codexHandshakeState = "warm";
      return;
    }

    const errorMessage = typeof parsed?.error?.message === "string"
      ? parsed.error.message.toLowerCase()
      : "";
    if (errorMessage.includes("already initialized")) {
      codexHandshakeState = "warm";
    }
  }
}

function shutdown(codex, getSocket, beforeExit = () => {}) {
  beforeExit();

  const socket = getSocket();
  if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
    socket.close();
  }

  codex.shutdown();

  setTimeout(() => process.exit(0), 100);
}

function extractThreadId(rawMessage) {
  let parsed = null;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return null;
  }

  const method = parsed?.method;
  const params = parsed?.params;

  if (method === "turn/start") {
    return readString(params?.threadId) || readString(params?.thread_id);
  }

  if (method === "thread/start" || method === "thread/started") {
    return (
      readString(params?.threadId)
      || readString(params?.thread_id)
      || readString(params?.thread?.id)
      || readString(params?.thread?.threadId)
      || readString(params?.thread?.thread_id)
    );
  }

  if (method === "turn/completed") {
    return (
      readString(params?.threadId)
      || readString(params?.thread_id)
      || readString(params?.turn?.threadId)
      || readString(params?.turn?.thread_id)
    );
  }

  return null;
}

function readString(value) {
  return typeof value === "string" && value ? value : null;
}

module.exports = { startBridge };
