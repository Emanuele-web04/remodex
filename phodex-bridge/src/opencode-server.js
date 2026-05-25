// FILE: opencode-server.js
// Purpose: Manages a local loopback-only OpenCode server process for the OpenCode runtime.
// Layer: Bridge adapter
// Exports: createOpenCodeServerManager plus spawn/auth/allowlist helpers
// Depends on: child_process, crypto

const { spawn } = require("child_process");
const { randomBytes } = require("crypto");

const OPENCODE_SERVER_USERNAME = "opencode";
const OPENCODE_HOSTNAME = "127.0.0.1";

function buildOpenCodeServeArgs({
  hostname = OPENCODE_HOSTNAME,
  port = 0,
} = {}) {
  return [
    "serve",
    "--hostname",
    hostname,
    "--port",
    String(port),
    "--pure",
    "--print-logs",
  ];
}

function createOpenCodeServerManager({
  spawnImpl = spawn,
  randomBytesImpl = randomBytes,
  fetchImpl = globalThis.fetch,
  logImpl = console,
} = {}) {
  let childProcess = null;
  let status = {
    state: "stopped",
    baseUrl: "",
    lastError: "",
  };
  let password = "";

  function start({ cwd, env = process.env } = {}) {
    if (childProcess && status.state !== "stopped") {
      return getStatus();
    }

    password = randomBytesImpl(24).toString("base64url");
    const childEnv = {
      ...env,
      OPENCODE_SERVER_USERNAME,
      OPENCODE_SERVER_PASSWORD: password,
    };
    const args = buildOpenCodeServeArgs();
    childProcess = spawnImpl("opencode", args, {
      cwd: cwd || process.cwd(),
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });
    status = {
      state: "starting",
      baseUrl: "",
      lastError: "",
      pid: childProcess?.pid || null,
    };

    childProcess?.stdout?.on?.("data", handleProcessOutput);
    childProcess?.stderr?.on?.("data", handleProcessOutput);
    childProcess?.on?.("error", (error) => {
      status = {
        state: isMissingCommandError(error) ? "not_installed" : "error",
        baseUrl: "",
        lastError: redactOpenCodeServerSecret(error?.message || String(error)),
      };
      childProcess = null;
    });
    childProcess?.on?.("exit", (code, signal) => {
      if (status.state !== "stopped") {
        status = {
          state: "stopped",
          baseUrl: "",
          lastError: code || signal ? `OpenCode server exited (${code ?? signal}).` : "",
        };
      }
      childProcess = null;
    });

    return getStatus();
  }

  function handleProcessOutput(chunk) {
    const output = redactOpenCodeServerSecret(String(chunk));
    const baseUrl = parseOpenCodeServerUrl(output);
    if (baseUrl) {
      status = {
        ...status,
        state: "ready",
        baseUrl,
        lastError: "",
      };
      return;
    }
    if (output && /error|failed|exception/i.test(output)) {
      logImpl.warn?.(`[remodex] OpenCode server output: ${output.trim()}`);
    }
  }

  async function request(method, path, { body } = {}) {
    const normalizedMethod = readString(method).toUpperCase();
    if (!isAllowedOpenCodeRequest(normalizedMethod, path)) {
      throw Object.assign(new Error(`OpenCode endpoint is not allowed: ${normalizedMethod} ${path}`), {
        errorCode: "opencode_endpoint_not_allowed",
      });
    }
    if (status.state !== "ready" || !status.baseUrl) {
      throw Object.assign(new Error("OpenCode server is not ready."), {
        errorCode: "opencode_server_not_ready",
      });
    }
    if (typeof fetchImpl !== "function") {
      throw Object.assign(new Error("OpenCode server requests require fetch."), {
        errorCode: "opencode_fetch_missing",
      });
    }

    const response = await fetchImpl(new URL(path, status.baseUrl), {
      method: normalizedMethod,
      headers: {
        Authorization: buildBasicAuthHeader(OPENCODE_SERVER_USERNAME, password),
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });

    if (!response?.ok) {
      throw Object.assign(new Error(`OpenCode request failed with status ${response?.status || "unknown"}.`), {
        errorCode: "opencode_request_failed",
      });
    }
    if (response.status === 204) {
      return null;
    }
    const text = typeof response.text === "function" ? await response.text() : "";
    return text ? JSON.parse(text) : null;
  }

  function subscribeEvents({
    path = "/event",
    onEvent,
    onError,
    signal,
  } = {}) {
    const abortController = new AbortController();
    const abort = () => abortController.abort();
    signal?.addEventListener?.("abort", abort, { once: true });

    const closed = (async () => {
      try {
        await readOpenCodeEventStream(path, {
          onEvent,
          signal: abortController.signal,
        });
      } catch (error) {
        if (!isAbortError(error)) {
          onError?.(error);
          throw error;
        }
      } finally {
        signal?.removeEventListener?.("abort", abort);
      }
    })();

    return {
      close() {
        abortController.abort();
      },
      closed,
    };
  }

  async function readOpenCodeEventStream(path, {
    onEvent,
    signal,
  } = {}) {
    if (!isAllowedOpenCodeRequest("GET", path)) {
      throw Object.assign(new Error(`OpenCode endpoint is not allowed: GET ${path}`), {
        errorCode: "opencode_endpoint_not_allowed",
      });
    }
    if (status.state !== "ready" || !status.baseUrl) {
      throw Object.assign(new Error("OpenCode server is not ready."), {
        errorCode: "opencode_server_not_ready",
      });
    }
    if (typeof fetchImpl !== "function") {
      throw Object.assign(new Error("OpenCode server requests require fetch."), {
        errorCode: "opencode_fetch_missing",
      });
    }

    const response = await fetchImpl(new URL(path, status.baseUrl), {
      method: "GET",
      signal,
      headers: {
        Accept: "text/event-stream",
        Authorization: buildBasicAuthHeader(OPENCODE_SERVER_USERNAME, password),
      },
    });

    if (!response?.ok) {
      throw Object.assign(new Error(`OpenCode event stream failed with status ${response?.status || "unknown"}.`), {
        errorCode: "opencode_event_stream_failed",
      });
    }
    if (!response.body || typeof response.body.getReader !== "function") {
      throw Object.assign(new Error("OpenCode event stream response is not readable."), {
        errorCode: "opencode_event_stream_unreadable",
      });
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        buffer += decoder.decode(value, { stream: true });
        buffer = consumeSseBuffer(buffer, onEvent);
      }
      buffer += decoder.decode();
      consumeSseBuffer(`${buffer}\n\n`, onEvent);
    } finally {
      reader.releaseLock?.();
    }
  }

  function stop() {
    status = {
      state: "stopped",
      baseUrl: "",
      lastError: "",
    };
    password = "";
    childProcess?.kill?.();
    childProcess = null;
  }

  function getStatus() {
    return {
      ...status,
      hasPassword: Boolean(password),
    };
  }

  return {
    getStatus,
    request,
    subscribeEvents,
    start,
    stop,
  };
}

function isAllowedOpenCodeRequest(method, path) {
  const normalizedMethod = readString(method).toUpperCase();
  const normalizedPath = normalizePath(path);
  if (!normalizedMethod || !normalizedPath) {
    return false;
  }

  if (normalizedPath === "/event" || normalizedPath === "/global/event") {
    return normalizedMethod === "GET";
  }
  if (normalizedPath === "/permission") {
    return normalizedMethod === "GET";
  }
  if (/^\/permission\/[^/]+\/reply$/.test(normalizedPath)) {
    return normalizedMethod === "POST";
  }
  if (normalizedPath === "/agent" || normalizedPath === "/skill") {
    return normalizedMethod === "GET";
  }
  if (normalizedPath === "/provider" || normalizedPath === "/config/providers") {
    return normalizedMethod === "GET";
  }
  if (normalizedPath === "/session") {
    return normalizedMethod === "GET" || normalizedMethod === "POST";
  }
  if (normalizedPath === "/session/status") {
    return normalizedMethod === "GET";
  }
  if (/^\/session\/[^/]+$/.test(normalizedPath)) {
    return ["GET", "PATCH", "DELETE"].includes(normalizedMethod);
  }
  if (/^\/session\/[^/]+\/(abort|prompt_async|diff)$/.test(normalizedPath)) {
    return (normalizedMethod === "POST" && !normalizedPath.endsWith("/diff"))
      || (normalizedMethod === "GET" && normalizedPath.endsWith("/diff"));
  }
  if (/^\/session\/[^/]+\/permissions\/[^/]+$/.test(normalizedPath)) {
    return normalizedMethod === "POST";
  }
  return false;
}

function normalizePath(path) {
  const value = readString(path);
  if (!value || !value.startsWith("/")) {
    return "";
  }
  return value.split("?")[0].replace(/\/+$/, "") || "/";
}

function parseOpenCodeServerUrl(output) {
  const match = readString(output).match(/https?:\/\/127\.0\.0\.1:\d+/);
  return match?.[0] || "";
}

function buildBasicAuthHeader(username, password) {
  return `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
}

function redactOpenCodeServerSecret(value) {
  const text = readString(value);
  if (!text) {
    return "";
  }
  return text
    .replace(/(OPENCODE_SERVER_PASSWORD=)[^\s]+/g, "$1[redacted]")
    .replace(/(Authorization:\s*Basic\s+)[A-Za-z0-9+/=_-]+/gi, "$1[redacted]");
}

function consumeSseBuffer(buffer, onEvent) {
  let remaining = buffer;
  while (true) {
    const delimiterIndex = findSseDelimiterIndex(remaining);
    if (delimiterIndex < 0) {
      return remaining;
    }
    const packet = remaining.slice(0, delimiterIndex);
    remaining = remaining.slice(skipSseDelimiter(remaining, delimiterIndex));
    const event = parseSsePacket(packet);
    if (event) {
      onEvent?.(event);
    }
  }
}

function findSseDelimiterIndex(value) {
  const unixIndex = value.indexOf("\n\n");
  const windowsIndex = value.indexOf("\r\n\r\n");
  if (unixIndex < 0) {
    return windowsIndex;
  }
  if (windowsIndex < 0) {
    return unixIndex;
  }
  return Math.min(unixIndex, windowsIndex);
}

function skipSseDelimiter(value, delimiterIndex) {
  return value.startsWith("\r\n\r\n", delimiterIndex)
    ? delimiterIndex + 4
    : delimiterIndex + 2;
}

function parseSsePacket(packet) {
  let data = "";
  for (const rawLine of String(packet).split(/\r?\n/)) {
    if (!rawLine || rawLine.startsWith(":")) {
      continue;
    }
    if (!rawLine.startsWith("data:")) {
      continue;
    }
    data += `${data ? "\n" : ""}${rawLine.slice("data:".length).trimStart()}`;
  }
  if (!data) {
    return null;
  }
  return JSON.parse(data);
}

function isAbortError(error) {
  return error?.name === "AbortError" || error?.code === "ABORT_ERR";
}

function isMissingCommandError(error) {
  return error?.code === "ENOENT"
    || (typeof error?.message === "string" && error.message.includes("ENOENT"));
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  OPENCODE_HOSTNAME,
  OPENCODE_SERVER_USERNAME,
  buildBasicAuthHeader,
  buildOpenCodeServeArgs,
  createOpenCodeServerManager,
  isAllowedOpenCodeRequest,
  parseOpenCodeServerUrl,
  redactOpenCodeServerSecret,
};
