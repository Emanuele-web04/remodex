// FILE: codex-transport.js
// Purpose: Abstracts the Codex-side transport so the bridge can talk to either a spawned app-server or an existing WebSocket endpoint.
// Layer: CLI helper
// Exports: createCodexTransport
// Depends on: child_process, ws

const { spawn } = require("child_process");
const WebSocket = require("ws");

function createCodexTransport({
  endpoint = "",
  env = process.env,
  WebSocketImpl = WebSocket,
} = {}) {
  if (endpoint) {
    return createWebSocketTransport({ endpoint, WebSocketImpl });
  }

  return createSpawnTransport({ env });
}

function createSpawnTransport({ env }) {
  const launch = createCodexLaunchPlan({ env });
  let codex = spawn(launch.command, launch.args, launch.options);
  let isRestarting = false;

  let stdoutBuffer = "";
  let stderrBuffer = "";
  let didRequestShutdown = false;
  let didReportError = false;
  const listeners = createListenerBag();

  function wireProcessHandlers(proc, ctx) {
    proc.on("error", (error) => {
      ctx.didReportError = true;
      ctx.listeners.emitError(error);
    });
    proc.on("close", (code, signal) => {
      if (ctx.isRestarting) {
        return;
      }
      if (!ctx.didRequestShutdown && !ctx.didReportError && code !== 0) {
        ctx.didReportError = true;
        ctx.listeners.emitError(createCodexCloseError({
          code,
          signal,
          stderrBuffer: ctx.stderrBuffer,
          launchDescription: ctx.launch.description,
        }));
        return;
      }
      ctx.listeners.emitClose(code, signal);
    });
    proc.stdin.on("error", (error) => {
      if (ctx.didRequestShutdown && isIgnorableStdinShutdownError(error)) {
        return;
      }
      if (isIgnorableStdinShutdownError(error)) {
        return;
      }
      ctx.didReportError = true;
      ctx.listeners.emitError(error);
    });
    proc.stderr.on("data", (chunk) => {
      ctx.stderrBuffer = appendOutputBuffer(ctx.stderrBuffer, chunk.toString("utf8"));
    });
    proc.stdout.on("data", (chunk) => {
      ctx.stdoutBuffer += chunk.toString("utf8");
      const lines = ctx.stdoutBuffer.split("\n");
      ctx.stdoutBuffer = lines.pop() || "";
      for (const line of lines) {
        const trimmedLine = line.trim();
        if (trimmedLine) {
          ctx.listeners.emitMessage(trimmedLine);
        }
      }
    });
  }

  const ctx = {
    stdoutBuffer: "",
    stderrBuffer: "",
    didRequestShutdown: false,
    didReportError: false,
    get isRestarting() { return isRestarting; },
    listeners,
    launch,
  };
  wireProcessHandlers(codex, ctx);

  return {
    mode: "spawn",
    describe() {
      return launch.description;
    },
    send(message) {
      if (!codex.stdin.writable || codex.stdin.destroyed || codex.stdin.writableEnded) {
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
      ctx.didRequestShutdown = true;
      shutdownCodexProcess(codex);
    },
    async restart() {
      if (isRestarting) {
        // Serialize: wait for the in-flight restart to finish before starting another.
        await new Promise((resolve) => {
          const check = setInterval(() => {
            if (!isRestarting) { clearInterval(check); resolve(); }
          }, 100);
        });
      }
      isRestarting = true;
      try {
        shutdownCodexProcess(codex);
        await new Promise((resolve) => {
          codex.on("close", resolve);
          setTimeout(resolve, 3000);
        });
        ctx.stdoutBuffer = "";
        ctx.stderrBuffer = "";
        ctx.didRequestShutdown = false;
        ctx.didReportError = false;
        codex = spawn(launch.command, launch.args, launch.options);
        wireProcessHandlers(codex, ctx);
      } finally {
        isRestarting = false;
      }
    },
    get isRestarting() {
      return isRestarting;
    },
  };
}

// Builds a single, platform-aware launch path so the bridge never "guesses"
// between multiple commands and accidentally starts duplicate runtimes.
function createCodexLaunchPlan({ env }) {
  const sharedOptions = {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...env },
  };

  if (process.platform === "win32") {
    return {
      command: env.ComSpec || "cmd.exe",
      args: ["/d", "/c", "codex app-server"],
      options: {
        ...sharedOptions,
        windowsHide: true,
      },
      description: "`cmd.exe /d /c codex app-server`",
    };
  }

  return {
    command: "codex",
    args: ["app-server"],
    options: sharedOptions,
    description: "`codex app-server`",
  };
}

// Stops the exact process tree we launched on Windows so the shell wrapper
// does not leave a child Codex process running in the background.
function shutdownCodexProcess(codex) {
  if (codex.killed || codex.exitCode !== null) {
    return;
  }

  if (process.platform === "win32" && codex.pid) {
    const killer = spawn("taskkill", ["/pid", String(codex.pid), "/t", "/f"], {
      stdio: "ignore",
      windowsHide: true,
    });
    killer.on("error", () => {
      codex.kill();
    });
    return;
  }

  codex.kill("SIGTERM");
}

function createCodexCloseError({ code, signal, stderrBuffer, launchDescription }) {
  const details = stderrBuffer.trim();
  const reason = details || `Process exited with code ${code}${signal ? ` (signal: ${signal})` : ""}.`;
  return new Error(`Codex launcher ${launchDescription} failed: ${reason}`);
}

function appendOutputBuffer(buffer, chunk) {
  const next = `${buffer}${chunk}`;
  return next.slice(-4_096);
}

function isIgnorableStdinShutdownError(error) {
  return error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED";
}

function createWebSocketTransport({ endpoint, WebSocketImpl = WebSocket }) {
  const socket = new WebSocketImpl(endpoint);
  const listeners = createListenerBag();
  const openState = WebSocketImpl.OPEN ?? WebSocket.OPEN ?? 1;
  const connectingState = WebSocketImpl.CONNECTING ?? WebSocket.CONNECTING ?? 0;

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
      if (socket.readyState === openState) {
        socket.send(message);
      }
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
      if (socket.readyState === openState || socket.readyState === connectingState) {
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
