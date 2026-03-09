// FILE: codex-desktop-refresher.js
// Purpose: Debounced Mac desktop refresh controller for Codex.app after phone-authored conversation changes.
// Layer: CLI helper
// Exports: CodexDesktopRefresher, readBridgeConfig
// Depends on: child_process, path

const { execFile } = require("child_process");
const path = require("path");

const DEFAULT_BUNDLE_ID = "com.openai.codex";
const DEFAULT_APP_PATH = "/Applications/Codex.app";
const DEFAULT_DEBOUNCE_MS = 1200;
const REFRESH_SCRIPT_PATH = path.join(__dirname, "scripts", "codex-refresh.applescript");
const NEW_THREAD_DEEP_LINK = "codex://threads/new";

class CodexDesktopRefresher {
  constructor({
    enabled = true,
    debounceMs = DEFAULT_DEBOUNCE_MS,
    refreshCommand = "",
    bundleId = DEFAULT_BUNDLE_ID,
    appPath = DEFAULT_APP_PATH,
    logPrefix = "[remodex]",
  } = {}) {
    this.enabled = enabled;
    this.debounceMs = debounceMs;
    this.refreshCommand = refreshCommand;
    this.bundleId = bundleId;
    this.appPath = appPath;
    this.logPrefix = logPrefix;

    this.pendingUserRefresh = false;
    this.pendingCompletionRefresh = false;
    this.pendingCompletionTurnId = null;
    this.pendingTargetUrl = "";
    this.pendingTargetThreadId = null;
    this.lastRefreshAt = 0;
    this.lastTurnIdRefreshed = null;
    this.refreshTimer = null;
    this.refreshRunning = false;
  }

  handleInbound(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return;
    }

    const method = parsed.method;
    if (method !== "thread/start" && method !== "turn/start") {
      return;
    }

    this.noteRefreshTarget(resolveInboundTarget(method, parsed));
    this.pendingUserRefresh = true;
    this.scheduleRefresh(`phone ${method}`);
  }

  handleOutbound(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return;
    }

    const method = parsed.method;
    if (method === "turn/completed") {
      const turnId = extractTurnId(parsed);
      if (turnId && turnId === this.lastTurnIdRefreshed) {
        this.log(`refresh skipped (debounced): completion already refreshed for ${turnId}`);
        return;
      }

      this.noteRefreshTarget(resolveOutboundTarget(method, parsed));
      this.pendingCompletionRefresh = true;
      this.pendingCompletionTurnId = turnId;
      this.scheduleRefresh(`codex ${method}`);
      return;
    }

    if (method === "thread/started") {
      this.noteRefreshTarget(resolveOutboundTarget(method, parsed));
      this.pendingUserRefresh = true;
      this.scheduleRefresh(`codex ${method}`);
    }
  }

  noteRefreshTarget(target) {
    if (!target?.url) {
      return;
    }

    this.pendingTargetUrl = target.url;
    if (target.threadId) {
      this.pendingTargetThreadId = target.threadId;
    }
  }

  scheduleRefresh(reason) {
    if (!this.enabled) {
      return;
    }

    if (this.refreshTimer) {
      this.log(`refresh already pending: ${reason}`);
      return;
    }

    const elapsedSinceLastRefresh = Date.now() - this.lastRefreshAt;
    const waitMs = Math.max(0, this.debounceMs - elapsedSinceLastRefresh);
    this.log(`refresh scheduled: ${reason}`);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      void this.runPendingRefresh();
    }, waitMs);
  }

  async runPendingRefresh() {
    if (!this.enabled) {
      this.clearPendingState();
      return;
    }

    if (!this.pendingUserRefresh && !this.pendingCompletionRefresh) {
      return;
    }

    if (this.refreshRunning) {
      this.log("refresh skipped (debounced): another refresh is already running");
      return;
    }

    const completionTurnId = this.pendingCompletionTurnId;
    const targetUrl = this.pendingTargetUrl;
    const targetThreadId = this.pendingTargetThreadId;
    const labelParts = [];
    if (this.pendingUserRefresh) {
      labelParts.push("user");
    }
    if (this.pendingCompletionRefresh) {
      labelParts.push("completion");
    }

    this.pendingUserRefresh = false;
    this.pendingCompletionRefresh = false;
    this.pendingCompletionTurnId = null;
    this.pendingTargetUrl = "";
    this.pendingTargetThreadId = null;
    this.refreshRunning = true;
    this.log(
      `refresh running: ${labelParts.join("+")}${targetThreadId ? ` thread=${targetThreadId}` : ""}`
    );

    try {
      await this.executeRefresh(targetUrl);
      this.lastRefreshAt = Date.now();
      if (completionTurnId) {
        this.lastTurnIdRefreshed = completionTurnId;
      }
    } catch (error) {
      this.logRefreshFailure(error);
    } finally {
      this.refreshRunning = false;
      if (this.pendingUserRefresh || this.pendingCompletionRefresh) {
        this.scheduleRefresh("pending follow-up refresh");
      }
    }
  }

  executeRefresh(targetUrl) {
    if (this.refreshCommand) {
      return execFilePromise("/bin/sh", ["-lc", this.refreshCommand]);
    }

    return execFilePromise("osascript", [
      REFRESH_SCRIPT_PATH,
      this.bundleId,
      this.appPath,
      targetUrl || "",
    ]);
  }

  clearPendingState() {
    this.pendingUserRefresh = false;
    this.pendingCompletionRefresh = false;
    this.pendingCompletionTurnId = null;
    this.pendingTargetUrl = "";
    this.pendingTargetThreadId = null;
  }

  log(message) {
    console.log(`${this.logPrefix} ${message}`);
  }

  logRefreshFailure(error) {
    const message = error?.stderr?.toString("utf8")
      || error?.stdout?.toString("utf8")
      || error?.message
      || "unknown refresh error";

    console.error(`${this.logPrefix} refresh failed: ${message.trim()}`);
  }
}

function readBridgeConfig() {
  return {
    relayUrl: readFirstDefinedEnv(["REMODEX_RELAY", "PHODEX_RELAY"], "wss://relay.example.invalid/relay"),
    refreshEnabled: parseBooleanEnv(readFirstDefinedEnv(["REMODEX_REFRESH_ENABLED"], "false")),
    refreshDebounceMs: parseIntegerEnv(
      readFirstDefinedEnv(["REMODEX_REFRESH_DEBOUNCE_MS"], String(DEFAULT_DEBOUNCE_MS)),
      DEFAULT_DEBOUNCE_MS
    ),
    codexEndpoint: readFirstDefinedEnv(["REMODEX_CODEX_ENDPOINT", "PHODEX_CODEX_ENDPOINT"], ""),
    refreshCommand: readFirstDefinedEnv(
      ["REMODEX_REFRESH_COMMAND", "PHODEX_ON_PHONE_MESSAGE"],
      ""
    ),
    codexBundleId: readFirstDefinedEnv(["REMODEX_CODEX_BUNDLE_ID"], DEFAULT_BUNDLE_ID),
    codexAppPath: DEFAULT_APP_PATH,
  };
}

function execFilePromise(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, (error, stdout, stderr) => {
      if (error) {
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function extractTurnId(message) {
  const params = message?.params;
  if (!params || typeof params !== "object") {
    return null;
  }

  if (typeof params.turnId === "string" && params.turnId) {
    return params.turnId;
  }

  if (params.turn && typeof params.turn === "object" && typeof params.turn.id === "string") {
    return params.turn.id;
  }

  return null;
}

function extractThreadId(message) {
  const params = message?.params;
  if (!params || typeof params !== "object") {
    return null;
  }

  const candidates = [
    params.threadId,
    params.conversationId,
    params.thread?.id,
    params.thread?.threadId,
    params.turn?.threadId,
    params.turn?.conversationId,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate) {
      return candidate;
    }
  }

  return null;
}

function resolveInboundTarget(method, message) {
  const threadId = extractThreadId(message);
  if (threadId) {
    return { threadId, url: buildThreadDeepLink(threadId) };
  }

  if (method === "thread/start" || method === "turn/start") {
    return { threadId: null, url: NEW_THREAD_DEEP_LINK };
  }

  return null;
}

function resolveOutboundTarget(method, message) {
  const threadId = extractThreadId(message);
  if (threadId) {
    return { threadId, url: buildThreadDeepLink(threadId) };
  }

  if (method === "thread/started") {
    return { threadId: null, url: NEW_THREAD_DEEP_LINK };
  }

  return null;
}

function buildThreadDeepLink(threadId) {
  return `codex://threads/${threadId}`;
}

function readFirstDefinedEnv(keys, fallback) {
  for (const key of keys) {
    const value = process.env[key];
    if (typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return fallback;
}

function parseBooleanEnv(value) {
  const normalized = String(value).trim().toLowerCase();
  return normalized !== "false" && normalized !== "0" && normalized !== "no";
}

function parseIntegerEnv(value, fallback) {
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

module.exports = {
  CodexDesktopRefresher,
  readBridgeConfig,
};
