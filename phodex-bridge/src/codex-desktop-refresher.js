// FILE: codex-desktop-refresher.js
// Purpose: Debounced Mac desktop refresh controller for Codex.app after phone-authored conversation changes.
// Layer: CLI helper
// Exports: CodexDesktopRefresher, readBridgeConfig
// Depends on: child_process, path, ./rollout-watch, ./daemon-state

const { execFile } = require("child_process");
const fs = require("fs");
const path = require("path");
const { readDaemonConfig } = require("./daemon-state");
const { createThreadRolloutActivityWatcher } = require("./rollout-watch");

const DEFAULT_BUNDLE_ID = "com.openai.codex";
const DEFAULT_APP_PATH = "/Applications/Codex.app";
const DEFAULT_DEBOUNCE_MS = 1200;
const DEFAULT_FALLBACK_NEW_THREAD_MS = 2_000;
const DEFAULT_MID_RUN_REFRESH_THROTTLE_MS = 3_000;
const DEFAULT_ROLLOUT_LOOKUP_TIMEOUT_MS = 5_000;
const DEFAULT_ROLLOUT_IDLE_TIMEOUT_MS = 10_000;
const DEFAULT_CUSTOM_REFRESH_FAILURE_THRESHOLD = 3;
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
    fallbackNewThreadMs = DEFAULT_FALLBACK_NEW_THREAD_MS,
    midRunRefreshThrottleMs = DEFAULT_MID_RUN_REFRESH_THROTTLE_MS,
    rolloutLookupTimeoutMs = DEFAULT_ROLLOUT_LOOKUP_TIMEOUT_MS,
    rolloutIdleTimeoutMs = DEFAULT_ROLLOUT_IDLE_TIMEOUT_MS,
    now = () => Date.now(),
    refreshExecutor = null,
    watchThreadRolloutFactory = createThreadRolloutActivityWatcher,
    refreshBackend = null,
    customRefreshFailureThreshold = DEFAULT_CUSTOM_REFRESH_FAILURE_THRESHOLD,
  } = {}) {
    this.enabled = enabled;
    this.debounceMs = debounceMs;
    this.refreshCommand = refreshCommand;
    this.bundleId = bundleId;
    this.appPath = appPath;
    this.logPrefix = logPrefix;
    this.fallbackNewThreadMs = fallbackNewThreadMs;
    this.midRunRefreshThrottleMs = midRunRefreshThrottleMs;
    this.rolloutLookupTimeoutMs = rolloutLookupTimeoutMs;
    this.rolloutIdleTimeoutMs = rolloutIdleTimeoutMs;
    this.now = now;
    this.refreshExecutor = refreshExecutor;
    this.watchThreadRolloutFactory = watchThreadRolloutFactory;
    this.refreshBackend = refreshBackend
      || (this.refreshCommand ? "command" : (this.refreshExecutor ? "command" : "applescript"));
    this.customRefreshFailureThreshold = customRefreshFailureThreshold;

    this.mode = "idle";
    this.pendingNewThread = false;
    this.pendingRefreshKinds = new Set();
    this.pendingCompletionRefresh = false;
    this.pendingCompletionTurnId = null;
    this.pendingCompletionTargetUrl = "";
    this.pendingCompletionTargetThreadId = "";
    this.pendingTargetUrl = "";
    this.pendingTargetThreadId = "";
    this.lastRefreshAt = 0;
    this.lastRefreshSignature = "";
    this.lastTurnIdRefreshed = null;
    this.lastMidRunRefreshAt = 0;
    this.refreshTimer = null;
    this.refreshRunning = false;
    this.fallbackTimer = null;
    this.activeWatcher = null;
    this.activeWatchedThreadId = null;
    this.watchStartAt = 0;
    this.lastRolloutSize = null;
    this.stopWatcherAfterRefreshThreadId = null;
    this.runtimeRefreshAvailable = enabled;
    this.consecutiveRefreshFailures = 0;
    this.unavailableLogged = false;
  }

  handleInbound(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return;
    }

    const method = parsed.method;
    if (method === "thread/start") {
      const target = resolveInboundTarget(method, parsed);
      if (target?.threadId) {
        this.queueRefresh("phone", target, `phone ${method}`);
        this.ensureWatcher(target.threadId);
        return;
      }

      this.pendingNewThread = true;
      this.mode = "pending_new_thread";
      this.clearPendingTarget();
      this.scheduleNewThreadFallback();
      return;
    }

    if (method === "turn/start") {
      const target = resolveInboundTarget(method, parsed);
      if (!target) {
        return;
      }

      this.queueRefresh("phone", target, `phone ${method}`);
      if (target.threadId) {
        this.ensureWatcher(target.threadId);
      }
    }
  }

  handleOutbound(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return;
    }

    const method = parsed.method;
    if (method === "turn/completed") {
      this.clearFallbackTimer();
      const turnId = extractTurnId(parsed);
      if (turnId && turnId === this.lastTurnIdRefreshed) {
        this.log(`refresh skipped (debounced): completion already refreshed for ${turnId}`);
        return;
      }

      const target = resolveOutboundTarget(method, parsed);
      this.queueCompletionRefresh(target, turnId, `codex ${method}`);
      return;
    }

    if (method === "thread/started") {
      const target = resolveOutboundTarget(method, parsed);
      this.pendingNewThread = false;
      this.clearFallbackTimer();
      this.queueRefresh("phone", target, `codex ${method}`);
      if (target?.threadId) {
        this.mode = "watching_thread";
        this.ensureWatcher(target.threadId);
      }
    }
  }

  // Stops volatile watcher/fallback state when transport drops or bridge exits.
  handleTransportReset() {
    this.clearRefreshTimer();
    this.clearPendingState();
    this.lastRefreshAt = 0;
    this.lastRefreshSignature = "";
    this.mode = "idle";
    this.clearFallbackTimer();
    this.stopWatcher();
  }

  queueRefresh(kind, target, reason) {
    this.noteRefreshTarget(target);
    this.pendingRefreshKinds.add(kind);
    this.scheduleRefresh(reason);
  }

  queueCompletionRefresh(target, turnId, reason) {
    this.noteCompletionTarget(target);
    this.pendingCompletionRefresh = true;
    this.pendingCompletionTurnId = turnId;
    this.stopWatcherAfterRefreshThreadId = target?.threadId || null;
    this.scheduleRefresh(reason);
  }

  noteRefreshTarget(target) {
    if (!target?.url) {
      return;
    }

    this.pendingTargetUrl = target.url;
    this.pendingTargetThreadId = target.threadId || "";
  }

  clearPendingTarget() {
    this.pendingTargetUrl = "";
    this.pendingTargetThreadId = "";
  }

  noteCompletionTarget(target) {
    if (!target?.url) {
      return;
    }

    this.pendingCompletionTargetUrl = target.url;
    this.pendingCompletionTargetThreadId = target.threadId || "";
  }

  clearPendingCompletionTarget() {
    this.pendingCompletionTargetUrl = "";
    this.pendingCompletionTargetThreadId = "";
  }

  scheduleRefresh(reason) {
    if (!this.canRefresh()) {
      return;
    }

    if (this.refreshTimer) {
      this.log(`refresh already pending: ${reason}`);
      return;
    }

    const elapsedSinceLastRefresh = this.now() - this.lastRefreshAt;
    const waitMs = Math.max(0, this.debounceMs - elapsedSinceLastRefresh);
    this.log(`refresh scheduled: ${reason}`);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      void this.runPendingRefresh();
    }, waitMs);
  }

  async runPendingRefresh() {
    if (!this.canRefresh()) {
      this.clearPendingState();
      return;
    }

    if (!this.hasPendingRefreshWork()) {
      return;
    }

    if (this.refreshRunning) {
      this.log("refresh skipped (debounced): another refresh is already running");
      return;
    }

    const isCompletionRun = this.pendingCompletionRefresh;
    const pendingRefreshKinds = isCompletionRun
      ? new Set(["completion"])
      : new Set(this.pendingRefreshKinds);
    const completionTurnId = this.pendingCompletionTurnId;
    const targetUrl = isCompletionRun ? this.pendingCompletionTargetUrl : this.pendingTargetUrl;
    const targetThreadId = isCompletionRun
      ? this.pendingCompletionTargetThreadId
      : this.pendingTargetThreadId;
    const stopWatcherAfterRefreshThreadId = isCompletionRun
      ? this.stopWatcherAfterRefreshThreadId
      : null;
    const shouldForceCompletionRefresh = isCompletionRun;

    if (isCompletionRun) {
      this.pendingCompletionRefresh = false;
      this.pendingCompletionTurnId = null;
      this.clearPendingCompletionTarget();
      this.stopWatcherAfterRefreshThreadId = null;
    } else {
      this.pendingRefreshKinds.clear();
      this.clearPendingTarget();
    }
    this.refreshRunning = true;
    this.log(
      `refresh running: ${Array.from(pendingRefreshKinds).join("+")}${targetThreadId ? ` thread=${targetThreadId}` : ""}`
    );

    let didRefresh = false;
    try {
      const refreshSignature = `${targetUrl || "app"}|${targetThreadId || "no-thread"}`;
      if (
        !shouldForceCompletionRefresh
        && refreshSignature === this.lastRefreshSignature
        && this.now() - this.lastRefreshAt < this.debounceMs
      ) {
        this.log(`refresh skipped (duplicate target): ${refreshSignature}`);
      } else {
        await this.executeRefresh(targetUrl);
        this.lastRefreshAt = this.now();
        this.lastRefreshSignature = refreshSignature;
        this.consecutiveRefreshFailures = 0;
        didRefresh = true;
      }
      if (completionTurnId && didRefresh) {
        this.lastTurnIdRefreshed = completionTurnId;
      }
    } catch (error) {
      this.handleRefreshFailure(error);
    } finally {
      this.refreshRunning = false;
      if (
        didRefresh
        && stopWatcherAfterRefreshThreadId
        && stopWatcherAfterRefreshThreadId === this.activeWatchedThreadId
      ) {
        this.stopWatcher();
        this.mode = this.pendingNewThread ? "pending_new_thread" : "idle";
      }
      // A completion refresh can queue while another refresh is still running,
      // so retry whenever either queue still has work.
      if (this.hasPendingRefreshWork()) {
        this.scheduleRefresh("pending follow-up refresh");
      }
    }
  }

  executeRefresh(targetUrl) {
    if (this.refreshExecutor) {
      return this.refreshExecutor(targetUrl || "");
    }

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
    this.pendingNewThread = false;
    this.pendingRefreshKinds.clear();
    this.pendingCompletionRefresh = false;
    this.pendingCompletionTurnId = null;
    this.clearPendingCompletionTarget();
    this.clearPendingTarget();
    this.stopWatcherAfterRefreshThreadId = null;
  }

  clearRefreshTimer() {
    if (!this.refreshTimer) {
      return;
    }

    clearTimeout(this.refreshTimer);
    this.refreshTimer = null;
  }

  // Schedules a single low-cost fallback when a brand new thread id is still unknown.
  scheduleNewThreadFallback() {
    if (!this.canRefresh()) {
      return;
    }

    if (this.fallbackTimer) {
      return;
    }

    this.fallbackTimer = setTimeout(() => {
      this.fallbackTimer = null;
      if (!this.pendingNewThread || this.pendingTargetThreadId) {
        return;
      }

      this.noteRefreshTarget({ threadId: null, url: NEW_THREAD_DEEP_LINK });
      this.pendingRefreshKinds.add("phone");
      this.scheduleRefresh("fallback thread/start");
    }, this.fallbackNewThreadMs);
  }

  clearFallbackTimer() {
    if (!this.fallbackTimer) {
      return;
    }

    clearTimeout(this.fallbackTimer);
    this.fallbackTimer = null;
  }

  // Keeps one lightweight rollout watcher alive for the current Remodex-controlled thread.
  ensureWatcher(threadId) {
    if (!this.canRefresh() || !threadId) {
      return;
    }

    if (this.activeWatchedThreadId === threadId && this.activeWatcher) {
      return;
    }

    this.stopWatcher();
    this.activeWatchedThreadId = threadId;
    this.watchStartAt = this.now();
    this.lastRolloutSize = null;
    this.mode = "watching_thread";
    this.activeWatcher = this.watchThreadRolloutFactory({
      threadId,
      lookupTimeoutMs: this.rolloutLookupTimeoutMs,
      idleTimeoutMs: this.rolloutIdleTimeoutMs,
      onEvent: (event) => this.handleWatcherEvent(event),
      onIdle: () => {
        this.log(`rollout watcher idle thread=${threadId}`);
        this.stopWatcher();
        this.mode = this.pendingNewThread ? "pending_new_thread" : "idle";
      },
      onTimeout: () => {
        this.log(`rollout watcher timeout thread=${threadId}`);
        this.stopWatcher();
        this.mode = this.pendingNewThread ? "pending_new_thread" : "idle";
      },
      onError: (error) => {
        this.log(`rollout watcher failed thread=${threadId}: ${error.message}`);
        this.stopWatcher();
        this.mode = this.pendingNewThread ? "pending_new_thread" : "idle";
      },
    });
  }

  stopWatcher() {
    if (!this.activeWatcher) {
      this.activeWatchedThreadId = null;
      this.watchStartAt = 0;
      this.lastRolloutSize = null;
      return;
    }

    this.activeWatcher.stop();
    this.activeWatcher = null;
    this.activeWatchedThreadId = null;
    this.watchStartAt = 0;
    this.lastRolloutSize = null;
  }

  // Converts rollout growth into occasional refreshes without spamming the desktop.
  handleWatcherEvent(event) {
    if (!event?.threadId || event.threadId !== this.activeWatchedThreadId) {
      return;
    }

    const previousSize = this.lastRolloutSize;
    this.lastRolloutSize = event.size;
    this.noteRefreshTarget({
      threadId: event.threadId,
      url: buildThreadDeepLink(event.threadId),
    });

    if (event.reason === "materialized") {
      this.queueRefresh("rollout_materialized", {
        threadId: event.threadId,
        url: buildThreadDeepLink(event.threadId),
      }, `rollout ${event.reason}`);
      return;
    }

    if (event.reason !== "growth") {
      return;
    }

    if (previousSize == null) {
      this.queueRefresh("rollout_growth", {
        threadId: event.threadId,
        url: buildThreadDeepLink(event.threadId),
      }, "rollout first-growth");
      this.lastMidRunRefreshAt = this.now();
      return;
    }

    if (this.now() - this.lastMidRunRefreshAt < this.midRunRefreshThrottleMs) {
      return;
    }

    this.lastMidRunRefreshAt = this.now();
    this.queueRefresh("rollout_growth", {
      threadId: event.threadId,
      url: buildThreadDeepLink(event.threadId),
    }, "rollout mid-run");
  }

  log(message) {
    console.log(`${this.logPrefix} ${message}`);
  }

  handleRefreshFailure(error) {
    const message = extractErrorMessage(error);
    console.error(`${this.logPrefix} refresh failed: ${message}`);

    if (this.refreshBackend === "applescript" && isDesktopUnavailableError(message)) {
      this.disableRuntimeRefresh("desktop refresh unavailable on this Mac");
      return;
    }

    if (this.refreshBackend === "command") {
      this.consecutiveRefreshFailures += 1;
      if (this.consecutiveRefreshFailures >= this.customRefreshFailureThreshold) {
        this.disableRuntimeRefresh("custom refresh command kept failing");
      }
    }
  }

  disableRuntimeRefresh(reason) {
    if (!this.runtimeRefreshAvailable) {
      return;
    }

    this.runtimeRefreshAvailable = false;
    this.clearRefreshTimer();
    this.clearFallbackTimer();
    this.stopWatcher();
    this.clearPendingState();
    this.mode = "idle";

    if (!this.unavailableLogged) {
      console.error(`${this.logPrefix} desktop refresh disabled until restart: ${reason}`);
      this.unavailableLogged = true;
    }
  }

  canRefresh() {
    return this.enabled && this.runtimeRefreshAvailable;
  }

  // Tells the debounce loop whether any phone/completion refresh is still waiting to run.
  hasPendingRefreshWork() {
    return this.pendingCompletionRefresh || this.pendingRefreshKinds.size > 0;
  }
}

function readBridgeConfig({
  env = process.env,
  platform = process.platform,
  runtimeRoot = path.resolve(__dirname, ".."),
  fsImpl = fs,
} = {}) {
  const daemonConfig = readDaemonConfig({ env, fsImpl }) || {};
  const privateDefaults = readPrivatePackageDefaults({ runtimeRoot, fsImpl });
  const sourceCheckout = isSourceCheckout(runtimeRoot, fsImpl);
  const defaultRelayUrl = sourceCheckout
    ? ""
    : privateDefaults.relayUrl;
  const explicitRelayUrl = readFirstDefinedEnv(
    ["REMODEX_RELAY", "PHODEX_RELAY"],
    "",
    env
  );
  const relayUrl = readFirstDefinedEnv(
    ["REMODEX_RELAY", "PHODEX_RELAY"],
    defaultRelayUrl,
    env
  );
  const defaultPushServiceUrl = sourceCheckout || explicitRelayUrl
    ? ""
    : privateDefaults.pushServiceUrl;
  const codexEndpoint = readFirstDefinedEnv(
    ["REMODEX_CODEX_ENDPOINT", "PHODEX_CODEX_ENDPOINT"],
    "",
    env
  );
  const refreshCommand = readFirstDefinedEnv(
    ["REMODEX_REFRESH_COMMAND", "PHODEX_ON_PHONE_MESSAGE"],
    "",
    env
  );
  const explicitRefreshEnabled = readOptionalBooleanEnv(["REMODEX_REFRESH_ENABLED"], env);
  const explicitKeepMacAwakeEnabled = readOptionalBooleanEnv(["REMODEX_KEEP_MAC_AWAKE"], env);
  const persistedKeepMacAwakeEnabled = typeof daemonConfig.keepMacAwakeEnabled === "boolean"
    ? daemonConfig.keepMacAwakeEnabled
    : null;
  // Desktop refresh is opt-in for now because Codex.app still lacks true live updates.
  const defaultRefreshEnabled = false;
  return {
    relayUrl,
    pushServiceUrl: readFirstDefinedEnv(
      ["REMODEX_PUSH_SERVICE_URL"],
      defaultPushServiceUrl,
      env
    ),
    pushPreviewMaxChars: parseIntegerEnv(
      readFirstDefinedEnv(["REMODEX_PUSH_PREVIEW_MAX_CHARS"], "160", env),
      160
    ),
    refreshEnabled: explicitRefreshEnabled == null
      ? defaultRefreshEnabled
      : explicitRefreshEnabled,
    refreshDebounceMs: parseIntegerEnv(
      readFirstDefinedEnv(["REMODEX_REFRESH_DEBOUNCE_MS"], String(DEFAULT_DEBOUNCE_MS), env),
      DEFAULT_DEBOUNCE_MS
    ),
    keepMacAwakeEnabled: explicitKeepMacAwakeEnabled == null
      ? (persistedKeepMacAwakeEnabled == null ? false : persistedKeepMacAwakeEnabled)
      : explicitKeepMacAwakeEnabled,
    codexEndpoint,
    desktopIpcSocketPath: readFirstDefinedEnv(["REMODEX_DESKTOP_IPC_SOCKET"], "", env),
    refreshCommand,
    codexBundleId: readFirstDefinedEnv(["REMODEX_CODEX_BUNDLE_ID"], DEFAULT_BUNDLE_ID, env),
    codexAppPath: DEFAULT_APP_PATH,
  };
}

function readPrivatePackageDefaults({ runtimeRoot, fsImpl }) {
  const defaultsPath = path.join(runtimeRoot, "src", "private-defaults.json");
  if (!fsImpl.existsSync(defaultsPath)) {
    return {
      relayUrl: "",
      pushServiceUrl: "",
    };
  }

  try {
    const parsed = safeParseJSON(fsImpl.readFileSync(defaultsPath, "utf8"));
    return {
      relayUrl: readString(parsed?.relayUrl) || "",
      pushServiceUrl: readString(parsed?.pushServiceUrl) || "",
    };
  } catch {
    return {
      relayUrl: "",
      pushServiceUrl: "",
    };
  }
}

// Keeps repo checkouts local-first while published npm installs can stay ready-to-run.
function isSourceCheckout(runtimeRoot, fsImpl) {
  const repoRoot = path.resolve(runtimeRoot, "..");
  return path.basename(runtimeRoot) === "phodex-bridge"
    && fsImpl.existsSync(path.join(repoRoot, ".git"));
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

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
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

function readOptionalBooleanEnv(keys, env = process.env) {
  for (const key of keys) {
    const value = env[key];
    if (typeof value === "string" && value.trim() !== "") {
      return parseBooleanEnv(value.trim());
    }
  }
  return null;
}

function readFirstDefinedEnv(keys, fallback, env = process.env) {
  for (const key of keys) {
    const value = env[key];
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

function extractErrorMessage(error) {
  return (
    error?.stderr?.toString("utf8")
    || error?.stdout?.toString("utf8")
    || error?.message
    || "unknown refresh error"
  ).trim();
}

function isDesktopUnavailableError(message) {
  const normalized = String(message).toLowerCase();
  return [
    "unable to find application named",
    "application isn’t running",
    "application isn't running",
    "can’t get application id",
    "can't get application id",
    "does not exist",
    "no application knows how to open",
    "cannot find app",
    "could not find application",
  ].some((snippet) => normalized.includes(snippet));
}

module.exports = {
  CodexDesktopRefresher,
  readBridgeConfig,
};
