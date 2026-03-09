// FILE: codex-transport.js
// Purpose: Abstracts the Codex-side transport so the bridge can talk to either a spawned app-server or an existing WebSocket endpoint.
// Layer: CLI helper
// Exports: createCodexTransport
// Depends on: child_process, ws

const { spawn } = require("child_process");
const WebSocket = require("ws");

function createCodexTransport({ endpoint = "", env = process.env } = {}) {
  if (endpoint) {
    return createWebSocketTransport({ endpoint });
  }

  return createSpawnTransport({ env });
}

function createSpawnTransport({ env }) {
  const codex = spawn("codex", ["app-server"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...env },
  });

  let stdoutBuffer = "";
  const listeners = createListenerBag();

  codex.on("error", (error) => listeners.emitError(error));
  codex.on("close", (code, signal) => listeners.emitClose(code, signal));
  // The bridge keeps stdout focused on connection state, so raw app-server logs stay muted here.
  codex.stderr.on("data", () => {});

  codex.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString("utf8");
    const lines = stdoutBuffer.split("\n");
    stdoutBuffer = lines.pop() || "";

    for (const line of lines) {
      const trimmedLine = line.trim();
      if (trimmedLine) {
        listeners.emitMessage(trimmedLine);
      }
    }
  });

  return {
    mode: "spawn",
    describe() {
      return "`codex app-server`";
    },
    send(message) {
      if (!codex.stdin.writable) {
        return;
      }

      codex.stdin.write(message.endsWith("\n") ? message : `${message}\n`);
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    shutdown() {
      if (!codex.killed) {
        codex.kill("SIGTERM");
      }
    },
  };
}

function createWebSocketTransport({ endpoint }) {
  const socket = new WebSocket(endpoint);
  const listeners = createListenerBag();

  socket.on("message", (chunk) => {
    const message = typeof chunk === "string" ? chunk : chunk.toString("utf8");
    if (message.trim()) {
      listeners.emitMessage(message);
    }
  });

  socket.on("close", (code, reason) => {
    const safeReason = reason ? reason.toString("utf8") : "no reason";
    listeners.emitClose(code, safeReason);
  });

  socket.on("error", (error) => listeners.emitError(error));

  return {
    mode: "websocket",
    describe() {
      return endpoint;
    },
    send(message) {
      if (socket.readyState !== WebSocket.OPEN) {
        return;
      }

      socket.send(message);
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    shutdown() {
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close();
      }
    },
  };
}

function createListenerBag() {
  return {
    onMessage: null,
    onClose: null,
    onError: null,
    emitMessage(message) {
      this.onMessage?.(message);
    },
    emitClose(...args) {
      this.onClose?.(...args);
    },
    emitError(error) {
      this.onError?.(error);
    },
  };
}

module.exports = { createCodexTransport };
