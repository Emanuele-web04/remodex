// FILE: gemini-transport.js
// Purpose: Spawns Gemini CLI in ACP mode behind the bridge transport interface.
// Layer: CLI helper
// Exports: createGeminiTransport
// Depends on: child_process

const { spawn } = require("child_process");

function createGeminiTransport({
  env = process.env,
  spawnImpl = spawn,
  command = "gemini",
  args = ["--acp"],
} = {}) {
  let stdoutBuffer = "";
  let stderrBuffer = "";
  let didRequestShutdown = false;
  const listeners = createListenerBag();
  const child = spawnImpl(command, args, {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...env },
  });

  child.on("spawn", () => {
    listeners.emitStarted({
      mode: "spawn",
      launchDescription: describe(),
    });
  });

  child.on("error", (error) => {
    listeners.emitError(error);
  });

  child.on("close", (code, signal) => {
    if (!didRequestShutdown && code !== 0) {
      listeners.emitError(createGeminiCloseError({ code, signal, stderrBuffer }));
      return;
    }
    listeners.emitClose(code, signal);
  });

  child.stdin.on("error", (error) => {
    if (didRequestShutdown && isIgnorableStdinShutdownError(error)) {
      return;
    }
    listeners.emitError(error);
  });

  child.stderr.on("data", (chunk) => {
    stderrBuffer = appendOutputBuffer(stderrBuffer, chunk.toString("utf8"));
  });

  child.stdout.on("data", (chunk) => {
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
    describe,
    send(message) {
      if (!child.stdin.writable || child.stdin.destroyed || child.stdin.writableEnded) {
        return;
      }
      child.stdin.write(message.endsWith("\n") ? message : `${message}\n`);
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
    onStarted(handler) {
      listeners.onStarted = handler;
    },
    shutdown() {
      didRequestShutdown = true;
      shutdownChildProcess(child);
    },
  };

  function describe() {
    return `\`${[command, ...args].join(" ")}\``;
  }
}

function createListenerBag() {
  const listeners = {
    onMessage: null,
    onClose: null,
    onError: null,
    onStarted: null,
    emitMessage(message) {
      listeners.onMessage?.(message);
    },
    emitClose(code, signal) {
      listeners.onClose?.(code, signal);
    },
    emitError(error) {
      listeners.onError?.(error);
    },
    emitStarted(event) {
      listeners.onStarted?.(event);
    },
  };
  return listeners;
}

function appendOutputBuffer(current, chunk, maxChars = 4000) {
  const next = `${current || ""}${chunk || ""}`;
  return next.length > maxChars ? next.slice(next.length - maxChars) : next;
}

function createGeminiCloseError({ code, signal, stderrBuffer }) {
  const details = stderrBuffer?.trim() ? `\n${stderrBuffer.trim()}` : "";
  return new Error(`Gemini CLI exited unexpectedly (code ${code ?? "unknown"}, signal ${signal || "none"}).${details}`);
}

function isIgnorableStdinShutdownError(error) {
  return error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED";
}

function shutdownChildProcess(child) {
  if (!child || child.killed) {
    return;
  }
  child.kill("SIGTERM");
}

module.exports = {
  createGeminiTransport,
};
