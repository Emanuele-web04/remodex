// FILE: bridge.js
// Purpose: Runs Codex locally, bridges relay traffic, and coordinates desktop refreshes for Codex.app.
// Layer: CLI service
// Exports: startBridge
// Depends on: ws, crypto, os, ./qr, ./codex-desktop-refresher, ./codex-transport, ./rollout-watch, ./voice-handler, ./ios-app-compatibility

const WebSocket = require("ws");
const { randomBytes } = require("crypto");
const { execFile, spawn } = require("child_process");
const os = require("os");
const { promisify } = require("util");
const {
  CodexDesktopRefresher,
  readBridgeConfig,
} = require("./codex-desktop-refresher");
const { createCodexTransport } = require("./codex-transport");
const { createThreadRolloutActivityWatcher } = require("./rollout-watch");
const { printQR } = require("./qr");
const { rememberActiveThread } = require("./session-state");
const { handleDesktopRequest } = require("./desktop-handler");
const { readDaemonConfig, writeDaemonConfig } = require("./daemon-state");
const { handleGitRequest } = require("./git-handler");
const { handleThreadContextRequest } = require("./thread-context-handler");
const { handleWorkspaceRequest } = require("./workspace-handler");
const { handleProjectRequest } = require("./project-handler");
const { createNotificationsHandler } = require("./notifications-handler");
const { createVoiceHandler, resolveVoiceAuth } = require("./voice-handler");
const {
  composeSanitizedAuthStatusFromSettledResults,
} = require("./account-status");
const { createBridgePackageVersionStatusReader } = require("./package-version-status");
const { createPushNotificationServiceClient } = require("./push-notification-service-client");
const { createPushNotificationTracker } = require("./push-notification-tracker");
const {
  loadOrCreateBridgeDeviceState,
  rememberLastSeenPhoneAppVersion,
  resolveBridgeRelaySession,
} = require("./secure-device-state");
const { createBridgeSecureTransport } = require("./secure-transport");
const { createRolloutLiveMirrorController } = require("./rollout-live-mirror");
const { version: bridgePackageVersion = "" } = require("../package.json");
const {
  MINIMUM_SUPPORTED_IOS_APP_VERSION,
  buildCachedIOSAppCompatibilityWarning,
  buildIOSAppCompatibilitySnapshot,
  normalizeVersionString,
} = require("./ios-app-compatibility");
const { createShortPairingCode, SHORT_PAIRING_CODE_LENGTH } = require("./qr");

const execFileAsync = promisify(execFile);
const RELAY_WATCHDOG_PING_INTERVAL_MS = 10_000;
const RELAY_WATCHDOG_STALE_AFTER_MS = 25_000;
const BRIDGE_STATUS_HEARTBEAT_INTERVAL_MS = 5_000;
const STALE_RELAY_STATUS_MESSAGE = "Relay heartbeat stalled; reconnect pending.";
const RELAY_HISTORY_IMAGE_REFERENCE_URL = "remodex://history-image-elided";
const RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES = 3 * 1024 * 1024;
const RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS = 24_000;
function startBridge({
  config: explicitConfig = null,
  printPairingQr = true,
  onPairingSession = null,
  onBridgeStatus = null,
} = {}) {
  const config = explicitConfig || readBridgeConfig();
  config.keepMacAwakeEnabled = config.keepMacAwakeEnabled === true;
  const bridgeWakeAssertion = createMacOSBridgeWakeAssertion({
    enabled: config.keepMacAwakeEnabled,
  });
  const relayBaseUrl = config.relayUrl.replace(/\/+$/, "");
  if (!relayBaseUrl) {
    console.error("[remodex] No relay URL configured.");
    console.error("[remodex] In a source checkout, run ./run-local-remodex.sh or set REMODEX_RELAY.");
    process.exit(1);
  }

  let deviceState;
  try {
    deviceState = loadOrCreateBridgeDeviceState();
  } catch (error) {
    console.error(`[remodex] ${(error && error.message) || "Failed to load the saved bridge pairing state."}`);
    process.exit(1);
  }
  const relaySession = resolveBridgeRelaySession(deviceState);
  deviceState = relaySession.deviceState;
  let lastIOSAppCompatibilityWarning = "";
  const cachedIOSAppCompatibilityWarning = buildCachedIOSAppCompatibilityWarning({
    bridgeVersion: bridgePackageVersion,
    iosAppVersion: deviceState.lastSeenPhoneAppVersion,
  });
  logIOSAppCompatibilityWarning(cachedIOSAppCompatibilityWarning);
  const sessionId = relaySession.sessionId;
  const relaySessionUrl = `${relayBaseUrl}/${sessionId}`;
  const notificationSecret = randomBytes(24).toString("hex");
  const desktopRefresher = new CodexDesktopRefresher({
    enabled: config.refreshEnabled,
    debounceMs: config.refreshDebounceMs,
    refreshCommand: config.refreshCommand,
    bundleId: config.codexBundleId,
    appPath: config.codexAppPath,
  });
  const pushServiceClient = createPushNotificationServiceClient({
    baseUrl: config.pushServiceUrl,
    sessionId,
    notificationSecret,
  });
  const notificationsHandler = createNotificationsHandler({
    pushServiceClient,
  });
  const pushNotificationTracker = createPushNotificationTracker({
    sessionId,
    pushServiceClient,
    previewMaxChars: config.pushPreviewMaxChars,
  });
  const readBridgePackageVersionStatus = createBridgePackageVersionStatusReader();

  // Keep the local Codex runtime alive across transient relay disconnects.
  let socket = null;
  let isShuttingDown = false;
  let reconnectAttempt = 0;
  let reconnectTimer = null;
  let relayWatchdogTimer = null;
  let statusHeartbeatTimer = null;
  let lastRelayActivityAt = 0;
  let lastPublishedBridgeStatus = null;
  let lastConnectionStatus = null;
  let codexLaunchState = config.codexEndpoint ? "connected" : "starting";
  let codexHandshakeState = config.codexEndpoint ? "warm" : "cold";
  const forwardedInitializeRequestIds = new Set();
  const bridgeManagedCodexRequestWaiters = new Map();
  const forwardedRequestMethodsById = new Map();
  const relaySanitizedResponseMethodsById = new Map();
  const trackedForwardedRequestMethods = new Set([
    "account/login/start",
    "account/login/cancel",
    "account/logout",
  ]);
  const relaySanitizedRequestMethods = new Set([
    "thread/read",
    "thread/resume",
  ]);
  const forwardedRequestMethodTTLms = 2 * 60_000;
  const pendingAuthLogin = {
    loginId: null,
    authUrl: null,
    requestId: null,
    startedAt: 0,
  };
  const secureTransport = createBridgeSecureTransport({
    sessionId,
    relayUrl: relayBaseUrl,
    deviceState,
    onTrustedPhoneUpdate(nextDeviceState) {
      deviceState = nextDeviceState;
      sendRelayRegistrationUpdate(nextDeviceState);
    },
  });
  // Keeps one stable sender identity across reconnects so buffered replay state
  // reflects what actually made it onto the current relay socket.
  function sendRelayWireMessage(wireMessage) {
    if (socket?.readyState !== WebSocket.OPEN) {
      return false;
    }

    socket.send(wireMessage);
    return true;
  }
  // Only the spawned local runtime needs rollout mirroring; a real endpoint
  // already provides the authoritative live stream for resumed threads.
  const rolloutLiveMirror = !config.codexEndpoint
    ? createRolloutLiveMirrorController({
      sendApplicationResponse,
    })
    : null;
  let contextUsageWatcher = null;
  let watchedContextUsageKey = null;

  const codex = createCodexTransport({
    endpoint: config.codexEndpoint,
    env: process.env,
    appPath: config.codexAppPath,
    logPrefix: "[remodex]",
  });
  const voiceHandler = createVoiceHandler({
    sendCodexRequest,
    logPrefix: "[remodex]",
  });
  startBridgeStatusHeartbeat();
  publishBridgeStatus({
    state: "starting",
    connectionStatus: "starting",
    pid: process.pid,
    lastError: "",
  });

  codex.onError((error) => {
    codexLaunchState = "error";
    publishBridgeStatus({
      state: "error",
      connectionStatus: "error",
      pid: process.pid,
      lastError: error.message,
    });
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
  // Marks the local Codex runtime as launchable before relay/network recovery updates.
  codex.onStarted(() => {
    codexLaunchState = "connected";
    if (!lastPublishedBridgeStatus) {
      return;
    }

    publishBridgeStatus(lastPublishedBridgeStatus);
  });

  function clearReconnectTimer() {
    if (!reconnectTimer) {
      return;
    }

    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  // Periodically rewrites the latest bridge snapshot so CLI status does not stay frozen.
  function startBridgeStatusHeartbeat() {
    if (statusHeartbeatTimer) {
      return;
    }

    statusHeartbeatTimer = setInterval(() => {
      if (!lastPublishedBridgeStatus || isShuttingDown) {
        return;
      }

      onBridgeStatus?.(buildHeartbeatBridgeStatus(lastPublishedBridgeStatus, lastRelayActivityAt));
    }, BRIDGE_STATUS_HEARTBEAT_INTERVAL_MS);
    statusHeartbeatTimer.unref?.();
  }

  function clearBridgeStatusHeartbeat() {
    if (!statusHeartbeatTimer) {
      return;
    }

    clearInterval(statusHeartbeatTimer);
    statusHeartbeatTimer = null;
  }

  // Tracks relay liveness locally so sleep/wake zombie sockets can be force-reconnected.
  function markRelayActivity() {
    lastRelayActivityAt = Date.now();
  }

  function clearRelayWatchdog() {
    if (!relayWatchdogTimer) {
      return;
    }

    clearInterval(relayWatchdogTimer);
    relayWatchdogTimer = null;
  }

  function startRelayWatchdog(trackedSocket) {
    clearRelayWatchdog();
    markRelayActivity();

    relayWatchdogTimer = setInterval(() => {
      if (isShuttingDown || socket !== trackedSocket) {
        clearRelayWatchdog();
        return;
      }

      if (trackedSocket.readyState !== WebSocket.OPEN) {
        return;
      }

      if (hasRelayConnectionGoneStale(lastRelayActivityAt)) {
        console.warn("[remodex] relay heartbeat stalled; forcing reconnect");
        logConnectionStatus("disconnected");
        trackedSocket.terminate();
        return;
      }

      try {
        trackedSocket.ping();
      } catch {
        trackedSocket.terminate();
      }
    }, RELAY_WATCHDOG_PING_INTERVAL_MS);
    relayWatchdogTimer.unref?.();
  }

  // Keeps npm start output compact by emitting only high-signal connection states.
  function logConnectionStatus(status) {
    if (lastConnectionStatus === status) {
      return;
    }

    lastConnectionStatus = status;
    publishBridgeStatus({
      state: "running",
      connectionStatus: status,
      pid: process.pid,
      lastError: "",
    });
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
        bridgeWakeAssertion.stop();
        clearReconnectTimer();
        clearRelayWatchdog();
        clearBridgeStatusHeartbeat();
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
      // The relay uses this per-session secret to authenticate the first push registration.
      headers: {
        "x-role": "mac",
        "x-notification-secret": notificationSecret,
        ...buildMacRegistrationHeaders(deviceState, pairingSession),
      },
    });
    socket = nextSocket;

    nextSocket.on("open", () => {
      markRelayActivity();
      clearReconnectTimer();
      reconnectAttempt = 0;
      startRelayWatchdog(nextSocket);
      logConnectionStatus("connected");
      secureTransport.bindLiveSendWireMessage(sendRelayWireMessage);
      sendRelayRegistrationUpdate(deviceState);
    });

    nextSocket.on("message", (data) => {
      markRelayActivity();
      const message = typeof data === "string" ? data : data.toString("utf8");
      if (secureTransport.handleIncomingWireMessage(message, {
        sendControlMessage(controlMessage) {
          if (nextSocket.readyState === WebSocket.OPEN) {
            nextSocket.send(JSON.stringify(controlMessage));
          }
        },
        onApplicationMessage(plaintextMessage) {
          handleApplicationMessage(plaintextMessage);
        },
      })) {
        return;
      }
    });

    nextSocket.on("ping", () => {
      markRelayActivity();
    });

    nextSocket.on("pong", () => {
      markRelayActivity();
    });

    nextSocket.on("close", (code) => {
      if (socket === nextSocket) {
        clearRelayWatchdog();
      }
      logConnectionStatus("disconnected");
      if (socket === nextSocket) {
        socket = null;
      }
      stopContextUsageWatcher();
      rolloutLiveMirror?.stopAll();
      desktopRefresher.handleTransportReset();
      scheduleRelayReconnect(code);
    });

    nextSocket.on("error", () => {
      if (socket === nextSocket) {
        clearRelayWatchdog();
      }
      logConnectionStatus("disconnected");
    });
  }

  const pairingPayload = secureTransport.createPairingPayload();
  const pairingSession = {
    pairingPayload,
    pairingCode: createShortPairingCode({ length: SHORT_PAIRING_CODE_LENGTH }),
  };
  onPairingSession?.(pairingSession);
  if (printPairingQr) {
    printQR(pairingSession);
  }
  pushServiceClient.logUnavailable();
  connectRelay();

  codex.onMessage((message) => {
    if (handleBridgeManagedCodexResponse(message)) {
      return;
    }
    updatePendingAuthLoginFromCodexMessage(message);
    trackCodexHandshakeState(message);
    desktopRefresher.handleOutbound(message);
    pushNotificationTracker.handleOutbound(message);
    rememberThreadFromMessage("codex", message);
    secureTransport.queueOutboundApplicationMessage(
      sanitizeRelayBoundCodexMessage(message),
      sendRelayWireMessage
    );
  });

  codex.onClose(() => {
    clearRelayWatchdog();
    clearBridgeStatusHeartbeat();
    logConnectionStatus("disconnected");
    publishBridgeStatus({
      state: "stopped",
      connectionStatus: "disconnected",
      pid: process.pid,
      lastError: "",
    });
    isShuttingDown = true;
    bridgeWakeAssertion.stop();
    clearReconnectTimer();
    stopContextUsageWatcher();
    rolloutLiveMirror?.stopAll();
    desktopRefresher.handleTransportReset();
    failBridgeManagedCodexRequests(new Error("Codex transport closed before the bridge request completed."));
    forwardedRequestMethodsById.clear();
    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
      socket.close();
    }
  });

  process.on("SIGINT", () => shutdown(codex, () => socket, () => {
    isShuttingDown = true;
    bridgeWakeAssertion.stop();
    clearReconnectTimer();
    clearRelayWatchdog();
    clearBridgeStatusHeartbeat();
  }));
  process.on("SIGTERM", () => shutdown(codex, () => socket, () => {
    isShuttingDown = true;
    bridgeWakeAssertion.stop();
    clearReconnectTimer();
    clearRelayWatchdog();
    clearBridgeStatusHeartbeat();
  }));

  // Routes decrypted app payloads through the same bridge handlers as before.
  function handleApplicationMessage(rawMessage) {
    if (handleBridgeManagedHandshakeMessage(rawMessage)) {
      return;
    }
    if (handleBridgeManagedAccountRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (voiceHandler.handleVoiceRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleThreadContextRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleWorkspaceRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleProjectRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (notificationsHandler.handleNotificationsRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleDesktopRequest(rawMessage, sendApplicationResponse, {
      bundleId: config.codexBundleId,
      appPath: config.codexAppPath,
      readBridgePreferences,
      updateBridgePreferences,
    })) {
      return;
    }
    if (handleGitRequest(rawMessage, sendApplicationResponse, {
      codexAppPath: config.codexAppPath,
      onThreadNameSet: sendThreadNameUpdatedNotification,
    })) {
      return;
    }
    desktopRefresher.handleInbound(rawMessage);
    rolloutLiveMirror?.observeInbound(rawMessage);
    rememberForwardedRequestMethod(rawMessage);
    rememberThreadFromMessage("phone", rawMessage);
    codex.send(rawMessage);
  }

  // Encrypts bridge-generated responses instead of letting the relay see plaintext.
  function sendApplicationResponse(rawMessage) {
    secureTransport.queueOutboundApplicationMessage(rawMessage, sendRelayWireMessage);
  }

  // Mirrors accepted local renames back to the phone using the existing push-event shape.
  function sendThreadNameUpdatedNotification(result) {
    const threadId = readString(result?.threadId || result?.thread_id);
    const name = readString(result?.name || result?.title);
    if (!threadId || !name) {
      return;
    }

    sendApplicationResponse(JSON.stringify({
      method: "thread/name/updated",
      params: {
        threadId,
        thread_id: threadId,
        name,
        title: name,
      },
    }));
  }

  // ─── Bridge-owned auth snapshot ─────────────────────────────

  // Handles the bridge-owned auth status wrappers without exposing tokens to the phone.
  // This dispatcher stays synchronous so non-account messages can continue down the normal routing chain.
  function handleBridgeManagedAccountRequest(rawMessage, sendResponse) {
    let parsed = null;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "account/status/read"
      && method !== "getAuthStatus"
      && method !== "account/login/openOnMac"
      && method !== "voice/resolveAuth") {
      return false;
    }

    const requestId = parsed.id;
    const shouldRespond = requestId != null;
    readBridgeManagedAccountResult(method, parsed.params || {})
      .then((result) => {
        if (shouldRespond) {
          sendResponse(JSON.stringify({ id: requestId, result }));
        }
      })
      .catch((error) => {
        if (shouldRespond) {
          sendResponse(createJsonRpcErrorResponse(requestId, error, "auth_status_failed"));
        }
      });

    return true;
  }

  // Resolves bridge-owned account helpers like status reads and Mac-side browser opening.
  async function readBridgeManagedAccountResult(method, params) {
    switch (method) {
      case "account/status/read":
      case "getAuthStatus":
        return readSanitizedAuthStatus();
      case "account/login/openOnMac":
        return openPendingAuthLoginOnMac(params);
      case "voice/resolveAuth":
        return resolveVoiceAuth(sendCodexRequest);
      default:
        throw new Error(`Unsupported bridge-managed account method: ${method}`);
    }
  }

  // Combines account/read + getAuthStatus into one safe snapshot for the phone UI.
  // The two RPCs are settled independently so one transient failure does not hide the other.
  async function readSanitizedAuthStatus() {
    const [accountReadResult, authStatusResult, bridgeVersionInfoResult] = await Promise.allSettled([
      sendCodexRequest("account/read", {
        refreshToken: false,
      }),
      sendCodexRequest("getAuthStatus", {
        includeToken: true,
        refreshToken: true,
      }),
      readBridgePackageVersionStatus(),
    ]);

    return composeSanitizedAuthStatusFromSettledResults({
      accountReadResult: accountReadResult.status === "fulfilled"
        ? {
          status: "fulfilled",
          value: normalizeAccountRead(accountReadResult.value),
        }
        : accountReadResult,
      authStatusResult,
      loginInFlight: Boolean(pendingAuthLogin.loginId),
      bridgeVersionInfo: bridgeVersionInfoResult.status === "fulfilled"
        ? bridgeVersionInfoResult.value
        : null,
      transportMode: codex.mode,
      hostPlatform: process.platform,
    });
  }

  // Opens the ChatGPT sign-in URL in the default browser on the bridge Mac.
  async function openPendingAuthLoginOnMac(params) {
    if (process.platform !== "darwin") {
      const error = new Error("Opening ChatGPT sign-in on the bridge is only supported on macOS.");
      error.errorCode = "unsupported_platform";
      throw error;
    }

    const authUrl = readString(params?.authUrl) || pendingAuthLogin.authUrl;
    if (!authUrl) {
      const error = new Error("No pending ChatGPT sign-in URL is available on this bridge.");
      error.errorCode = "missing_auth_url";
      throw error;
    }

    await execFileAsync("open", [authUrl], { timeout: 15_000 });
    return {
      success: true,
      openedOnMac: true,
    };
  }

  function normalizeAccountRead(payload) {
    if (!payload || typeof payload !== "object") {
      return {
        account: null,
        requiresOpenaiAuth: true,
      };
    }

    return {
      account: payload.account && typeof payload.account === "object" ? payload.account : null,
      requiresOpenaiAuth: Boolean(payload.requiresOpenaiAuth),
    };
  }

  function createJsonRpcErrorResponse(requestId, error, defaultErrorCode) {
    return JSON.stringify({
      id: requestId,
      error: {
        code: -32000,
        message: error?.userMessage || error?.message || "Bridge request failed.",
        data: {
          errorCode: error?.errorCode || defaultErrorCode,
        },
      },
    });
  }

  function rememberForwardedRequestMethod(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    const requestId = parsed?.id;
    if (!method || requestId == null) {
      return;
    }

    pruneExpiredForwardedRequestMethods();
    if (trackedForwardedRequestMethods.has(method)) {
      forwardedRequestMethodsById.set(String(requestId), {
        method,
        createdAt: Date.now(),
      });
    }
    if (relaySanitizedRequestMethods.has(method)) {
      relaySanitizedResponseMethodsById.set(String(requestId), {
        method,
        createdAt: Date.now(),
      });
    }
  }

  // Replaces huge inline desktop-history images with lightweight references before relay encryption.
  function sanitizeRelayBoundCodexMessage(rawMessage) {
    pruneExpiredForwardedRequestMethods();
    const parsed = safeParseJSON(rawMessage);
    const responseId = parsed?.id;
    if (responseId == null) {
      return rawMessage;
    }

    const trackedRequest = relaySanitizedResponseMethodsById.get(String(responseId));
    if (!trackedRequest) {
      return rawMessage;
    }
    relaySanitizedResponseMethodsById.delete(String(responseId));

    return sanitizeThreadHistoryImagesForRelay(rawMessage, trackedRequest.method);
  }

  function updatePendingAuthLoginFromCodexMessage(rawMessage) {
    pruneExpiredForwardedRequestMethods();
    const parsed = safeParseJSON(rawMessage);
    const responseId = parsed?.id;
    if (responseId != null) {
      const trackedRequest = forwardedRequestMethodsById.get(String(responseId));
      if (trackedRequest) {
        forwardedRequestMethodsById.delete(String(responseId));
        const requestMethod = trackedRequest.method;

        if (requestMethod === "account/login/start") {
          const loginId = readString(parsed?.result?.loginId);
          const authUrl = readString(parsed?.result?.authUrl);
          if (!loginId || !authUrl) {
            clearPendingAuthLogin();
            return;
          }
          pendingAuthLogin.loginId = loginId || null;
          pendingAuthLogin.authUrl = authUrl || null;
          pendingAuthLogin.requestId = String(responseId);
          pendingAuthLogin.startedAt = Date.now();
          return;
        }

        if (requestMethod === "account/login/cancel" || requestMethod === "account/logout") {
          clearPendingAuthLogin();
          return;
        }
      }
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method === "account/login/completed") {
      clearPendingAuthLogin();
      return;
    }

    if (method === "account/updated") {
      clearPendingAuthLogin();
    }
  }

  function clearPendingAuthLogin() {
    pendingAuthLogin.loginId = null;
    pendingAuthLogin.authUrl = null;
    pendingAuthLogin.requestId = null;
    pendingAuthLogin.startedAt = 0;
  }

  function pruneExpiredForwardedRequestMethods(now = Date.now()) {
    for (const [requestId, trackedRequest] of forwardedRequestMethodsById.entries()) {
      if (!trackedRequest || (now - trackedRequest.createdAt) >= forwardedRequestMethodTTLms) {
        forwardedRequestMethodsById.delete(requestId);
      }
    }
    for (const [requestId, trackedRequest] of relaySanitizedResponseMethodsById.entries()) {
      if (!trackedRequest || (now - trackedRequest.createdAt) >= forwardedRequestMethodTTLms) {
        relaySanitizedResponseMethodsById.delete(requestId);
      }
    }
  }

  function safeParseJSON(value) {
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  }

  function rememberThreadFromMessage(source, rawMessage) {
    const context = extractBridgeMessageContext(rawMessage);
    if (!context.threadId) {
      return;
    }

    rememberActiveThread(context.threadId, source);
    if (shouldStartContextUsageWatcher(context)) {
      ensureContextUsageWatcher(context);
    }
  }

  // Mirrors CodexMonitor's persisted token_count fallback so the phone keeps
  // receiving context-window usage even when the runtime omits live thread usage.
  function ensureContextUsageWatcher({ threadId, turnId }) {
    const normalizedThreadId = readString(threadId);
    const normalizedTurnId = readString(turnId);
    if (!normalizedThreadId) {
      return;
    }

    const nextWatcherKey = `${normalizedThreadId}|${normalizedTurnId || "pending-turn"}`;
    if (watchedContextUsageKey === nextWatcherKey && contextUsageWatcher) {
      return;
    }

    stopContextUsageWatcher();
    watchedContextUsageKey = nextWatcherKey;
    contextUsageWatcher = createThreadRolloutActivityWatcher({
      threadId: normalizedThreadId,
      turnId: normalizedTurnId,
      onUsage: ({ threadId: usageThreadId, usage }) => {
        sendContextUsageNotification(usageThreadId, usage);
      },
      onIdle: () => {
        if (watchedContextUsageKey === nextWatcherKey) {
          stopContextUsageWatcher();
        }
      },
      onTimeout: () => {
        if (watchedContextUsageKey === nextWatcherKey) {
          stopContextUsageWatcher();
        }
      },
      onError: () => {
        if (watchedContextUsageKey === nextWatcherKey) {
          stopContextUsageWatcher();
        }
      },
    });
  }

  function stopContextUsageWatcher() {
    if (contextUsageWatcher) {
      contextUsageWatcher.stop();
    }

    contextUsageWatcher = null;
    watchedContextUsageKey = null;
  }

  function sendContextUsageNotification(threadId, usage) {
    if (!threadId || !usage) {
      return;
    }

    sendApplicationResponse(JSON.stringify({
      method: "thread/tokenUsage/updated",
      params: {
        threadId,
        usage,
      },
    }));
  }

  // The spawned/shared Codex app-server stays warm across phone reconnects.
  // When iPhone reconnects it sends initialize again, but forwarding that to the
  // already-initialized Codex transport only produces "Already initialized".
  function handleBridgeManagedHandshakeMessage(rawMessage) {
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
      const compatibilityError = bridgeManagedInitializeCompatibilityError(parsed.params || {});
      if (compatibilityError) {
        sendApplicationResponse(JSON.stringify({
          id: parsed.id,
          error: compatibilityError,
        }));
        return true;
      }

      if (codexHandshakeState !== "warm") {
        forwardedInitializeRequestIds.add(String(parsed.id));
        return false;
      }

      sendApplicationResponse(JSON.stringify({
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

  // Blocks bridge/app version skew before the phone starts calling newer bridge APIs.
  function bridgeManagedInitializeCompatibilityError(params) {
    const clientInfo = params && typeof params === "object" ? params.clientInfo : null;
    const clientName = normalizeNonEmptyString(clientInfo?.name);
    if (clientName !== "codexmobile_ios") {
      return null;
    }

    const clientVersion = normalizeVersionString(clientInfo?.version);
    if (clientVersion) {
      deviceState = rememberLastSeenPhoneAppVersion(deviceState, clientVersion);
    }

    const compatibility = buildIOSAppCompatibilitySnapshot({
      bridgeVersion: bridgePackageVersion,
      iosAppVersion: clientVersion,
    });
    if (!compatibility.requiresAppUpdate) {
      return null;
    }

    logIOSAppCompatibilityWarning(buildCachedIOSAppCompatibilityWarning({
      bridgeVersion: bridgePackageVersion,
      iosAppVersion: clientVersion,
    }));

    return {
      code: -32001,
      message: compatibility.message,
      data: {
        errorCode: "ios_app_update_required",
        minimumSupportedAppVersion: MINIMUM_SUPPORTED_IOS_APP_VERSION,
        bridgeVersion: normalizeVersionString(bridgePackageVersion) || null,
        clientVersion,
        compatibleBridgeVersion: compatibility.legacyBridgeVersion,
        downgradeCommand: compatibility.downgradeCommand,
      },
    };
  }

  function logIOSAppCompatibilityWarning(warning) {
    const normalizedWarning = typeof warning === "string" ? warning.trim() : "";
    if (!normalizedWarning || normalizedWarning === lastIOSAppCompatibilityWarning) {
      return;
    }

    lastIOSAppCompatibilityWarning = normalizedWarning;
    console.warn(normalizedWarning);
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

  // Runs bridge-private JSON-RPC calls against the local app-server so token-bearing responses
  // can power bridge features like transcription without ever reaching the phone.
  function sendCodexRequest(method, params) {
    const requestId = `bridge-managed-${randomBytes(12).toString("hex")}`;
    const payload = JSON.stringify({
      id: requestId,
      method,
      params,
    });

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        bridgeManagedCodexRequestWaiters.delete(requestId);
        reject(new Error(`Codex request timed out: ${method}`));
      }, 20_000);

      bridgeManagedCodexRequestWaiters.set(requestId, {
        method,
        resolve,
        reject,
        timeout,
      });

      try {
        codex.send(payload);
      } catch (error) {
        clearTimeout(timeout);
        bridgeManagedCodexRequestWaiters.delete(requestId);
        reject(error);
      }
    });
  }

  // Intercepts responses for bridge-private requests so only user-visible app-server traffic
  // is forwarded back through secure transport.
  function handleBridgeManagedCodexResponse(rawMessage) {
    let parsed = null;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return false;
    }

    const responseId = typeof parsed?.id === "string" ? parsed.id : null;
    if (!responseId) {
      return false;
    }

    const waiter = bridgeManagedCodexRequestWaiters.get(responseId);
    if (!waiter) {
      return false;
    }

    bridgeManagedCodexRequestWaiters.delete(responseId);
    clearTimeout(waiter.timeout);

    if (parsed.error) {
      const error = new Error(parsed.error.message || `Codex request failed: ${waiter.method}`);
      error.code = parsed.error.code;
      error.data = parsed.error.data;
      waiter.reject(error);
      return true;
    }

    waiter.resolve(parsed.result ?? null);
    return true;
  }

  function failBridgeManagedCodexRequests(error) {
    for (const waiter of bridgeManagedCodexRequestWaiters.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    bridgeManagedCodexRequestWaiters.clear();
  }

  function publishBridgeStatus(status) {
    const nextStatus = {
      ...status,
      codexLaunchState,
    };
    lastPublishedBridgeStatus = nextStatus;
    onBridgeStatus?.(nextStatus);
  }

  // Refreshes the relay's trusted-mac index after the QR bootstrap locks in a phone identity.
  function sendRelayRegistrationUpdate(nextDeviceState) {
    deviceState = nextDeviceState;
    if (socket?.readyState !== WebSocket.OPEN) {
      return;
    }

    socket.send(JSON.stringify({
      kind: "relayMacRegistration",
      registration: buildMacRegistration(nextDeviceState, pairingSession),
    }));
  }

  function readBridgePreferences() {
    return {
      success: true,
      preferences: {
        keepMacAwake: config.keepMacAwakeEnabled !== false,
      },
      applied: bridgeWakeAssertion.active,
    };
  }

  function updateBridgePreferences(preferences = {}) {
    const nextKeepMacAwakeEnabled = preferences.keepMacAwake !== false;
    config.keepMacAwakeEnabled = nextKeepMacAwakeEnabled;
    bridgeWakeAssertion.setEnabled?.(nextKeepMacAwakeEnabled);

    try {
      persistBridgePreferences({
        keepMacAwakeEnabled: nextKeepMacAwakeEnabled,
      });
    } catch (error) {
      const nextError = new Error("Could not save the bridge preference on this Mac.");
      nextError.errorCode = "bridge_preferences_persist_failed";
      nextError.userMessage = nextError.message;
      nextError.cause = error;
      throw nextError;
    }

    return readBridgePreferences();
  }
}

// Holds a single macOS idle-sleep assertion for as long as the bridge process stays alive.
function createMacOSBridgeWakeAssertion({
  platform = process.platform,
  pid = process.pid,
  spawnImpl = spawn,
  consoleImpl = console,
  enabled = true,
} = {}) {
  if (platform !== "darwin") {
    return {
      active: false,
      enabled: false,
      setEnabled() {
        return { active: false, enabled: false };
      },
      stop() {},
    };
  }

  let desiredEnabled = Boolean(enabled);
  let child = null;

  function stop() {
    if (!child || child.killed || typeof child.kill !== "function") {
      child = null;
      return;
    }

    try {
      child.kill();
    } catch {}
    child = null;
  }

  function start() {
    if (!desiredEnabled || child) {
      return;
    }

    try {
      const nextChild = spawnImpl("/usr/bin/caffeinate", ["-i", "-w", String(pid)], {
        stdio: "ignore",
      });

      nextChild.on?.("error", (error) => {
        consoleImpl.warn(`[remodex] Failed to hold the Mac awake while the bridge is active: ${error.message}`);
      });
      nextChild.on?.("exit", () => {
        if (child === nextChild) {
          child = null;
        }
      });
      nextChild.unref?.();
      child = nextChild;
    } catch (error) {
      consoleImpl.warn(
        `[remodex] Failed to start the bridge wake assertion: ${(error && error.message) || "unknown error"}`
      );
      child = null;
    }
  }

  function setEnabled(nextEnabled) {
    desiredEnabled = Boolean(nextEnabled);
    if (desiredEnabled) {
      start();
    } else {
      stop();
    }

    return {
      active: Boolean(child && !child.killed),
      enabled: desiredEnabled,
    };
  }

  start();

  return {
    get active() {
      return Boolean(child && !child.killed);
    },
    get enabled() {
      return desiredEnabled;
    },
    setEnabled,
    stop,
  };
}

// Registers the canonical Mac identity and the one trusted iPhone allowed for auto-resolve.
function buildMacRegistrationHeaders(deviceState, pairingSession) {
  const registration = buildMacRegistration(deviceState, pairingSession);
  const headers = {
    "x-mac-device-id": registration.macDeviceId,
    "x-mac-identity-public-key": registration.macIdentityPublicKey,
    "x-machine-name": registration.displayName,
    "x-pairing-code": registration.pairingCode,
    "x-pairing-version": registration.pairingVersion ? String(registration.pairingVersion) : "",
    "x-pairing-expires-at": registration.pairingExpiresAt ? String(registration.pairingExpiresAt) : "",
  };
  if (registration.trustedPhoneDeviceId && registration.trustedPhonePublicKey) {
    headers["x-trusted-phone-device-id"] = registration.trustedPhoneDeviceId;
    headers["x-trusted-phone-public-key"] = registration.trustedPhonePublicKey;
  }
  return headers;
}

function buildMacRegistration(deviceState, pairingSession) {
  const trustedPhoneEntry = Object.entries(deviceState?.trustedPhones || {})[0] || null;
  return {
    macDeviceId: normalizeNonEmptyString(deviceState?.macDeviceId),
    macIdentityPublicKey: normalizeNonEmptyString(deviceState?.macIdentityPublicKey),
    displayName: normalizeNonEmptyString(os.hostname()),
    trustedPhoneDeviceId: normalizeNonEmptyString(trustedPhoneEntry?.[0]),
    trustedPhonePublicKey: normalizeNonEmptyString(trustedPhoneEntry?.[1]),
    pairingCode: normalizeNonEmptyString(pairingSession?.pairingCode),
    pairingVersion: Number.isInteger(pairingSession?.pairingPayload?.v) ? pairingSession.pairingPayload.v : 0,
    pairingExpiresAt: Number.isFinite(pairingSession?.pairingPayload?.expiresAt)
      ? pairingSession.pairingPayload.expiresAt
      : 0,
  };
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

function extractBridgeMessageContext(rawMessage) {
  let parsed = null;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return { method: "", threadId: null, turnId: null };
  }

  const method = parsed?.method;
  const params = parsed?.params;
  const threadId = extractThreadId(method, params);
  const turnId = extractTurnId(method, params);

  return {
    method: typeof method === "string" ? method : "",
    threadId,
    turnId,
  };
}

function shouldStartContextUsageWatcher(context) {
  if (!context?.threadId) {
    return false;
  }

  return context.method === "turn/start"
    || context.method === "turn/started";
}

function extractThreadId(method, params) {
  if (method === "turn/start" || method === "turn/started") {
    return (
      readString(params?.threadId)
      || readString(params?.thread_id)
      || readString(params?.turn?.threadId)
      || readString(params?.turn?.thread_id)
    );
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

function extractTurnId(method, params) {
  if (method === "turn/started" || method === "turn/completed") {
    return (
      readString(params?.turnId)
      || readString(params?.turn_id)
      || readString(params?.id)
      || readString(params?.turn?.id)
      || readString(params?.turn?.turnId)
      || readString(params?.turn?.turn_id)
    );
  }

  return null;
}

function readString(value) {
  return typeof value === "string" && value ? value : null;
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

// Shrinks `thread/read` and `thread/resume` snapshots by eliding bulky history payloads
// that the iPhone does not render directly (inline images, compaction replacement history).
function sanitizeThreadHistoryImagesForRelay(rawMessage, requestMethod) {
  if (requestMethod !== "thread/read" && requestMethod !== "thread/resume") {
    return rawMessage;
  }

  const parsed = parseBridgeJSON(rawMessage);
  const thread = parsed?.result?.thread;
  if (!thread || typeof thread !== "object" || !Array.isArray(thread.turns)) {
    return rawMessage;
  }

  let didSanitize = false;
  const sanitizedTurns = thread.turns.map((turn) => {
    if (!turn || typeof turn !== "object" || !Array.isArray(turn.items)) {
      return turn;
    }

    let turnDidChange = false;
    const sanitizedItems = turn.items.map((item) => {
      if (!item || typeof item !== "object") {
        return item;
      }

      let itemDidChange = false;
      let sanitizedItem = item;

      if (Array.isArray(item.content)) {
        const sanitizedContent = item.content.map((contentItem) => {
          const sanitizedEntry = sanitizeInlineHistoryImageContentItem(contentItem);
          if (sanitizedEntry !== contentItem) {
            itemDidChange = true;
          }
          return sanitizedEntry;
        });

        if (itemDidChange) {
          sanitizedItem = {
            ...sanitizedItem,
            content: sanitizedContent,
          };
        }
      }

      const sanitizedCompactionItem = sanitizeCompactionHistoryItem(sanitizedItem);
      if (sanitizedCompactionItem !== sanitizedItem) {
        sanitizedItem = sanitizedCompactionItem;
        itemDidChange = true;
      }

      if (itemDidChange) {
        turnDidChange = true;
      }

      return itemDidChange ? sanitizedItem : item;
    });

    if (!turnDidChange) {
      return turn;
    }

    didSanitize = true;
    return {
      ...turn,
      items: sanitizedItems,
    };
  });

  if (!didSanitize) {
    const trimmedPayload = trimThreadPayloadForRelay(parsed, thread);
    return trimmedPayload == null ? rawMessage : trimmedPayload;
  }

  const sanitizedPayload = JSON.stringify({
    ...parsed,
    result: {
      ...parsed.result,
      thread: {
        ...thread,
        turns: sanitizedTurns,
      },
    },
  });

  return trimThreadPayloadForRelay(parseBridgeJSON(sanitizedPayload), null) ?? sanitizedPayload;
}

// Drops huge replacement-history blobs from compaction items because the phone only needs
// the compacted marker itself, not the entire pre-compaction transcript snapshot.
function sanitizeCompactionHistoryItem(item) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return item;
  }

  let sanitizedItem = omitCompactionReplacementHistory(item);
  const payload = sanitizedItem.payload;
  if (payload && typeof payload === "object" && !Array.isArray(payload)) {
    const sanitizedPayload = omitCompactionReplacementHistory(payload);
    if (sanitizedPayload !== payload) {
      sanitizedItem = {
        ...sanitizedItem,
        payload: sanitizedPayload,
      };
    }
  }

  return sanitizedItem;
}

function omitCompactionReplacementHistory(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return value;
  }

  let nextValue = value;
  let didChange = false;
  for (const key of ["replacement_history", "replacementHistory"]) {
    if (Object.prototype.hasOwnProperty.call(nextValue, key)) {
      if (!didChange) {
        nextValue = { ...nextValue };
        didChange = true;
      }
      delete nextValue[key];
    }
  }

  return didChange ? nextValue : value;
}

// Converts `data:image/...` history content into a tiny placeholder the iPhone can render safely.
function sanitizeInlineHistoryImageContentItem(contentItem) {
  if (!contentItem || typeof contentItem !== "object") {
    return contentItem;
  }

  const normalizedType = normalizeRelayHistoryContentType(contentItem.type);
  if (!isRelayHistoryImageContentType(normalizedType)) {
    return contentItem;
  }

  const hasInlineUrl = hasInlineHistoryImageDataURL(contentItem.url)
    || hasInlineHistoryImageDataURL(contentItem.image_url)
    || hasInlineHistoryImageDataURL(contentItem.path);
  if (!hasInlineUrl) {
    return contentItem;
  }

  const {
    url: _url,
    image_url: _imageUrl,
    path: _path,
    ...rest
  } = contentItem;

  return {
    ...rest,
    url: RELAY_HISTORY_IMAGE_REFERENCE_URL,
  };
}

function normalizeRelayHistoryContentType(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[\s_-]+/g, "")
    : "";
}

// Covers Codex history variants such as image, local_image, and input_image.
function isRelayHistoryImageContentType(normalizedType) {
  return normalizedType === "image"
    || normalizedType === "localimage"
    || normalizedType === "inputimage"
    || normalizedType === "outputimage";
}

function hasInlineHistoryImageDataURL(value) {
  if (typeof value === "string") {
    return value.toLowerCase().startsWith("data:image");
  }

  if (Array.isArray(value)) {
    return value.some(hasInlineHistoryImageDataURL);
  }

  if (value && typeof value === "object") {
    return Object.values(value).some(hasInlineHistoryImageDataURL);
  }

  return false;
}

function parseBridgeJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function trimThreadPayloadForRelay(parsed, explicitThread = undefined) {
  const thread = explicitThread ?? parsed?.result?.thread;
  if (!parsed || !thread || typeof thread !== "object" || !Array.isArray(thread.turns)) {
    return null;
  }

  let workingThread = thread;
  let encoded = encodeRelayThreadPayload(parsed, workingThread);
  if (encoded == null) {
    return null;
  }

  if (Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    return explicitThread === undefined ? null : encoded;
  }

  const turns = thread.turns;
  let trimmedTurns = turns.slice();
  while (trimmedTurns.length > 1) {
    trimmedTurns = trimmedTurns.slice(1);
    const candidateThread = {
      ...thread,
      turns: trimmedTurns,
      historyTailTruncatedForRelay: true,
    };
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (encoded != null && Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
      return encoded;
    }
    workingThread = candidateThread;
  }

  const newestTurn = trimmedTurns[0];
  if (!newestTurn || typeof newestTurn !== "object" || !Array.isArray(newestTurn.items)) {
    return encodeRelayThreadPayload(parsed, workingThread);
  }

  let trimmedItems = newestTurn.items.slice();
  while (trimmedItems.length > 1) {
    trimmedItems = trimmedItems.slice(1);
    const candidateThread = {
      ...thread,
      turns: [{
        ...newestTurn,
        items: trimmedItems,
      }],
      historyTailTruncatedForRelay: true,
    };
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (encoded != null && Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
      return encoded;
    }
    workingThread = candidateThread;
  }

  const mostRecentItem = trimmedItems[0];
  if (!mostRecentItem || typeof mostRecentItem !== "object") {
    return encodeRelayThreadPayload(parsed, workingThread);
  }

  const truncatedItem = truncateHistoryItemTextForRelay(
    mostRecentItem,
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS
  );
  let candidateThread = {
    ...thread,
    turns: [{
      ...newestTurn,
      items: [truncatedItem],
    }],
    historyTailTruncatedForRelay: true,
  };
  encoded = encodeRelayThreadPayload(parsed, candidateThread);
  if (encoded != null && Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    return encoded;
  }

  candidateThread = {
    ...thread,
    turns: [{
      ...newestTurn,
      items: [compactHistoryItemForRelay(mostRecentItem, RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS)],
    }],
    historyTailTruncatedForRelay: true,
  };
  return encodeRelayThreadPayload(parsed, candidateThread);
}

function encodeRelayThreadPayload(parsed, thread) {
  try {
    return JSON.stringify({
      ...parsed,
      result: {
        ...parsed.result,
        thread,
      },
    });
  } catch {
    return null;
  }
}

function truncateHistoryItemTextForRelay(item, maxChars) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return item;
  }

  let didChange = false;
  let nextItem = item;
  const textKeys = ["text", "message", "summary", "output", "outputText", "output_text"];

  for (const key of textKeys) {
    if (typeof item[key] === "string" && item[key].length > maxChars) {
      nextItem = {
        ...nextItem,
        [key]: truncateRelayTextTail(item[key], maxChars),
      };
      didChange = true;
    }
  }

  if (Array.isArray(item.content)) {
    const nextContent = item.content.map((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        return entry;
      }

      const truncatedEntry = truncateHistoryItemTextForRelay(entry, maxChars);
      if (truncatedEntry !== entry) {
        didChange = true;
      }
      return truncatedEntry;
    });

    if (didChange) {
      nextItem = {
        ...nextItem,
        content: nextContent,
      };
    }
  }

  return didChange
    ? {
      ...nextItem,
      relayTextTailTruncated: true,
    }
    : item;
}

function compactHistoryItemForRelay(item, maxChars) {
  const compactItem = {
    id: typeof item?.id === "string" ? item.id : undefined,
    type: typeof item?.type === "string" ? item.type : "relay_truncated_item",
    role: typeof item?.role === "string" ? item.role : undefined,
    itemId: typeof item?.itemId === "string" ? item.itemId : undefined,
    relayPayloadTruncated: true,
  };
  const tailText = firstRelayTextTail(item, maxChars);
  if (tailText) {
    compactItem.text = tailText;
  }

  return Object.fromEntries(
    Object.entries(compactItem).filter(([, value]) => value !== undefined)
  );
}

function firstRelayTextTail(value, maxChars) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "";
  }

  for (const key of ["text", "message", "summary", "output", "outputText", "output_text"]) {
    if (typeof value[key] === "string" && value[key].trim()) {
      return truncateRelayTextTail(value[key], maxChars);
    }
  }

  if (Array.isArray(value.content)) {
    for (const entry of value.content) {
      const tail = firstRelayTextTail(entry, maxChars);
      if (tail) {
        return tail;
      }
    }
  }

  return "";
}

function truncateRelayTextTail(value, maxChars) {
  if (typeof value !== "string" || value.length <= maxChars) {
    return value;
  }

  const tail = value.slice(-maxChars).trimStart();
  return `…\n${tail}`;
}

// Treats silent relay sockets as stale so the daemon can self-heal after sleep/wake.
function hasRelayConnectionGoneStale(
  lastActivityAt,
  {
    now = Date.now(),
    staleAfterMs = RELAY_WATCHDOG_STALE_AFTER_MS,
  } = {}
) {
  return Number.isFinite(lastActivityAt)
    && Number.isFinite(now)
    && now - lastActivityAt >= staleAfterMs;
}

// Keeps persisted daemon status honest by downgrading stale "connected" snapshots.
function buildHeartbeatBridgeStatus(
  status,
  lastActivityAt,
  {
    now = Date.now(),
    staleAfterMs = RELAY_WATCHDOG_STALE_AFTER_MS,
    staleMessage = STALE_RELAY_STATUS_MESSAGE,
  } = {}
) {
  if (!status || typeof status !== "object") {
    return status;
  }

  if (status.connectionStatus !== "connected") {
    return status;
  }

  if (!hasRelayConnectionGoneStale(lastActivityAt, { now, staleAfterMs })) {
    return status;
  }

  return {
    ...status,
    connectionStatus: "disconnected",
    lastError: staleMessage,
  };
}

function persistBridgePreferences(
  {
    keepMacAwakeEnabled,
  },
  {
    readDaemonConfigImpl = readDaemonConfig,
    writeDaemonConfigImpl = writeDaemonConfig,
  } = {}
) {
  writeDaemonConfigImpl({
    ...(readDaemonConfigImpl() || {}),
    keepMacAwakeEnabled,
  });
}

module.exports = {
  buildHeartbeatBridgeStatus,
  createMacOSBridgeWakeAssertion,
  hasRelayConnectionGoneStale,
  persistBridgePreferences,
  sanitizeThreadHistoryImagesForRelay,
  startBridge,
};
