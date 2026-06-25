// FILE: bridge.js
// Purpose: Runs Codex locally, bridges relay traffic, and coordinates desktop refreshes for Codex.app.
// Layer: CLI service
// Exports: startBridge
// Depends on: ws, crypto, os, ./bridge-status, ./codex-desktop-refresher, ./codex-transport, ./rollout-watch, ./voice-handler

const WebSocket = require("ws");
const { createHash, randomBytes } = require("crypto");
const { execFile, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { promisify } = require("util");
const { CodexDesktopRefresher, readBridgeConfig } = require("./codex-desktop-refresher");
const {
  buildHeartbeatBridgeStatus,
  buildOpenCodeBridgeStatusSection,
  createBridgeStatusPublisher,
  hasRelayConnectionGoneStale,
} = require("./bridge-status");
const { createCodexTransport } = require("./codex-transport");
const {
  createThreadRolloutActivityWatcher,
  findRecentRolloutFileForContextRead,
  resolveSessionsRoot,
} = require("./rollout-watch");
const { printQR } = require("./qr");
const { safeParseJSON } = require("./safe-json");
const { createStructuredLogger, extractLogContext } = require("./structured-logger");
const { rememberActiveThread } = require("./session-state");
const { handleDesktopRequest } = require("./desktop-handler");
const { readDaemonConfig, writeDaemonConfig, writePairingSession } = require("./daemon-state");
const { handleGitRequest } = require("./git-handler");
const { handleThreadContextRequest } = require("./thread-context-handler");
const { handleWorkspaceRequest } = require("./workspace-handler");
const { handleProjectRequest } = require("./project-handler");
const { handlePetRequest } = require("./pet-handler");
const { createNotificationsHandler } = require("./notifications-handler");
const { createVoiceHandler, resolveVoiceAuth } = require("./voice-handler");
const { composeSanitizedAuthStatusFromSettledResults } = require("./account-status");
const { createBridgePackageVersionStatusReader } = require("./package-version-status");
const { createPushNotificationServiceClient } = require("./push-notification-service-client");
const { createPushNotificationTracker } = require("./push-notification-tracker");
const { resolveCodexGeneratedImagesRoot } = require("./codex-home");
const {
  loadOrCreateBridgeDeviceState,
  rememberLastSeenClientDeviceKind,
  rememberLastSeenPhoneAppVersion,
  resolveBridgeRelaySession,
} = require("./secure-device-state");
const { createBridgeSecureTransport } = require("./secure-transport");
const { createRolloutLiveMirrorController } = require("./rollout-live-mirror");
const {
  createDesktopIpcActionFollower,
  seedConversationStateFromThreadRead,
} = require("./desktop-ipc-action-follower");
const { version: bridgePackageVersion = "" } = require("../package.json");
const {
  MINIMUM_SUPPORTED_IOS_APP_VERSION,
  buildCachedIOSAppCompatibilityWarning,
  buildIOSAppCompatibilitySnapshot,
  normalizeVersionString,
} = require("./ios-app-compatibility");
const { createShortPairingCode, SHORT_PAIRING_CODE_LENGTH } = require("./qr");
const {
  parseSessionJsonlMetadata,
  parseSessionJsonlTurns,
  readThreadTurnsListPageFromSessionJsonl,
} = require("./session-jsonl-history");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");
const {
  createRuntimeProviderRouter,
  stripRuntimeProviderFieldsForCodex,
} = require("./runtime-provider-router");
const { isOpenCodeRuntimeDisabled } = require("./opencode-runtime-policy");
const {
  formatRuntimePreflightFailureMessage,
  opencodeCarriesBridge,
  resolveAvailableRuntimes,
} = require("./runtime-detection");
const { createProjectRegistry } = require("./project-registry");
const { createThreadOwnershipStore } = require("./thread-ownership-store");
const { readStringOrNull, resolvedParam } = require("./normalize");

const execFileAsync = promisify(execFile);
const RELAY_WATCHDOG_PING_INTERVAL_MS = 10_000;
const RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS = 30_000;
const BRIDGE_PACKAGE_UPDATE_COMMAND = "npm install -g remodex@latest";
const BRIDGE_PACKAGE_UPDATE_TIMEOUT_MS = 180_000;
const BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS = 750;
const MODELS_WITHOUT_REASONING_SUMMARY = new Set(["gpt-5.3-codex-spark"]);
const {
  RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES,
  buildThreadTurnsListRelaySanitizeContext,
  fetchAdaptiveThreadTurnsListForRelay,
  findTurnsListResultKey,
  hasRelayCursor,
  isEmptyTurnsListResponse,
  jsonlArtifactItemsCacheByThread,
  maybeMergeLatestJsonlTurnIntoTurnsListResponse,
  resolveJsonlTurnsListRolloutPathForFallback,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeThreadHistoryImagesForRelay,
  threadIdFromRequestParams,
  unwrapAppServerPayloadResult,
} = require("./relay-history-sanitize");
const FORWARDED_REQUEST_METHODS_MAX_SIZE = 500;
const JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE = 200;

function evictOldestEntries(map, maxSize) {
  if (map.size <= maxSize) {
    return;
  }
  const excess = map.size - maxSize;
  const iterator = map.keys();
  for (let i = 0; i < excess; i += 1) {
    const key = iterator.next().value;
    map.delete(key);
  }
}

function startBridge({
  config: explicitConfig = null,
  printPairingQr = true,
  onPairingSession = null,
  onBridgeStatus = null,
} = {}) {
  const config = explicitConfig || readBridgeConfig();
  config.keepMacAwakeEnabled = config.keepMacAwakeEnabled === true;
  const logger = createStructuredLogger("[remodex]");
  
  const availableRuntimes = resolveAvailableRuntimes(process.env, {
    appPath: config.codexAppPath,
    codexEndpoint: config.codexEndpoint,
  });
  if (availableRuntimes.mode === "none") {
    logger.error("Runtime preflight failed", null, {
      mode: availableRuntimes.mode,
      codexAvailable: availableRuntimes.codexAvailable,
      opencodeAvailable: availableRuntimes.opencodeAvailable,
    });
    process.exit(1);
  }
  console.log(
    JSON.stringify({
      event: "bridge_runtime_preflight",
      mode: availableRuntimes.mode,
      codexAvailable: availableRuntimes.codexAvailable,
      opencodeAvailable: availableRuntimes.opencodeAvailable,
    }),
  );
  const bridgeWakeAssertion = createMacOSBridgeWakeAssertion({
    enabled: config.keepMacAwakeEnabled,
  });
  const relayBaseUrl = config.relayUrl.replace(/\/+$/, "");
  if (!relayBaseUrl) {
    logger.error("No relay URL configured");
    process.exit(1);
  }

  let deviceState;
  try {
    deviceState = loadOrCreateBridgeDeviceState();
  } catch (error) {
    logger.error("Failed to load bridge pairing state", error);
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
  let lastRelayActivityAt = 0;
  let lastConnectionStatus = null;
  let codexLaunchState = config.codexEndpoint
    ? "connected"
    : availableRuntimes.codexAvailable
      ? "starting"
      : "degraded";
  let codexHandshakeState = config.codexEndpoint ? "warm" : "cold";
  const forwardedInitializeRequestIds = new Set();
  const bridgeManagedCodexRequestWaiters = new Map();
  const forwardedRequestMethodsById = new Map();
  const relaySanitizedResponseMethodsById = new Map();
  const jsonlTurnsListRolloutCacheByThread = new Map();
  const jsonlTurnsListRolloutMissCacheByThread = new Map();
  const trackedForwardedRequestMethods = new Set([
    "account/login/start",
    "account/login/cancel",
    "account/logout",
  ]);
  const relaySanitizedRequestMethods = new Set([
    "thread/list",
    "thread/read",
    "thread/resume",
    "thread/turns/list",
  ]);
  const forwardedRequestMethodTTLms = 2 * 60_000;
  const pendingAuthLogin = {
    loginId: null,
    authUrl: null,
    requestId: null,
    startedAt: 0,
  };
  let activePhoneSummary = null;
  const secureTransport = createBridgeSecureTransport({
    sessionId,
    relayUrl: relayBaseUrl,
    deviceState,
    displayName: os.hostname(),
    onTrustedPhoneUpdate(nextDeviceState) {
      deviceState = nextDeviceState;
      sendRelayRegistrationUpdate(nextDeviceState);
    },
    onSecureSessionReady(session) {
      activePhoneSummary = buildActivePhoneSummary(session, deviceState);
      const lastPublishedBridgeStatus = bridgeStatusPublisher.latest();
      if (lastPublishedBridgeStatus) {
        publishBridgeStatus(lastPublishedBridgeStatus);
      }
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
        getCodexLaunchState: () => codexLaunchState,
      })
    : null;
  const desktopIpcActionFollower = !config.codexEndpoint
    ? createDesktopIpcActionFollower({
        sendApplicationResponse,
        getCodexLaunchState: () => codexLaunchState,
        readConversationState: async (threadId) =>
          seedConversationStateFromThreadRead(await sendCodexRequest("thread/read", { threadId })),
        socketPath: config.desktopIpcSocketPath || undefined,
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

  codex.onError((error) => {
    const openCodeCarriesBridge = opencodeCarriesBridge(availableRuntimes);
    codexLaunchState = openCodeCarriesBridge ? "degraded" : "error";
    publishBridgeStatus({
      state: openCodeCarriesBridge ? "running" : "error",
      connectionStatus: openCodeCarriesBridge ? lastConnectionStatus || "connected" : "error",
      pid: process.pid,
      lastError: error.message,
    });
    if (config.codexEndpoint) {
      logger.error("Failed to connect to Codex endpoint", error, {
        endpoint: config.codexEndpoint,
      });
    } else {
      logger.error("Failed to start Codex app-server", error, {
        launchCommand: codex.describe(),
        openCodeCarriesBridge,
      });
      if (!openCodeCarriesBridge) {
        logger.error("Codex CLI must be installed, authenticated, and launchable");
      }
    }
    if (!openCodeCarriesBridge) {
      process.exit(1);
    }
  });
  // Marks the local Codex runtime as launchable before relay/network recovery updates.
  codex.onStarted(() => {
    codexLaunchState = "connected";
    const lastPublishedBridgeStatus = bridgeStatusPublisher.latest();
    if (!lastPublishedBridgeStatus) {
      return;
    }

    publishBridgeStatus(lastPublishedBridgeStatus);
  });
  codex.onClose(() => {
    const wasShuttingDown = isShuttingDown;
    const openCodeCarriesBridge = !wasShuttingDown && opencodeCarriesBridge(availableRuntimes);
    if (openCodeCarriesBridge) {
      codexLaunchState = "degraded";
      const lastError = "Codex transport closed unexpectedly.";
      publishBridgeStatus({
        state: "running",
        connectionStatus: lastConnectionStatus || "connected",
        pid: process.pid,
        lastError,
      });
      console.warn(`[remodex] ${lastError} Continuing in degraded mode because OpenCode is available.`);
      failBridgeManagedCodexRequests(
        new Error("Codex transport closed before the bridge request completed."),
      );
      forwardedRequestMethodsById.clear();
      desktopRefresher.handleTransportReset();
      return;
    }

    clearRelayWatchdog();
    bridgeStatusPublisher.stopHeartbeat();
    logConnectionStatus("disconnected");
    const lastError = wasShuttingDown ? "" : "Codex transport closed unexpectedly.";
    publishBridgeStatus({
      state: wasShuttingDown ? "stopped" : "error",
      connectionStatus: "disconnected",
      pid: process.pid,
      lastError,
    });
    if (!wasShuttingDown) {
      console.error(`[remodex] ${lastError}`);
      process.exitCode = 1;
    }
    prepareBridgeShutdown();
    desktopRefresher.handleTransportReset();
    failBridgeManagedCodexRequests(
      new Error("Codex transport closed before the bridge request completed."),
    );
    forwardedRequestMethodsById.clear();
    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
      socket.close();
    }
  });

  const projectRegistry = createProjectRegistry();
  const ownershipStore = createThreadOwnershipStore();
  const runtimeProviderRouter = createRuntimeProviderRouter({
    sendApplicationResponse,
    sendCodexRequest,
    sendRuntimeMessage: (message) => sendRuntimeApplicationMessage("opencode", message),
    projectRegistry,
    ownershipStore,
    providers: isOpenCodeRuntimeDisabled(process.env) ? [] : undefined,
    logPrefix: "[remodex]",
    getCodexLaunchState: () => codexLaunchState,
  });
  const opencodeProvider = runtimeProviderRouter.providers.find(
    (provider) => provider.id === "opencode",
  ) || null;
  const voiceHandler = createVoiceHandler({
    sendCodexRequest,
    logPrefix: "[remodex]",
  });
  const bridgeStatusPublisher = createBridgeStatusPublisher({
    onBridgeStatus,
    getCodexLaunchState: () => codexLaunchState,
  });
  bridgeStatusPublisher.startHeartbeat({
    shouldPublish: () => !isShuttingDown,
    getLastRelayActivityAt: () => lastRelayActivityAt,
    refreshStatus: (status) => {
      const opencode = buildOpenCodeBridgeStatusSection(opencodeProvider, process.env);
      return opencode ? { ...status, opencode } : status;
    },
  });
  publishBridgeStatus({
    state: "starting",
    connectionStatus: "starting",
    pid: process.pid,
    lastError: "",
  });

  function clearReconnectTimer() {
    if (!reconnectTimer) {
      return;
    }

    clearTimeout(reconnectTimer);
    reconnectTimer = null;
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

  function prepareBridgeShutdown() {
    isShuttingDown = true;
    bridgeWakeAssertion.stop();
    clearReconnectTimer();
    clearRelayWatchdog();
    bridgeStatusPublisher.stopHeartbeat();
    runtimeProviderRouter.shutdown();
    stopContextUsageWatcher();
    rolloutLiveMirror?.stopAll();
    desktopIpcActionFollower?.stopAll();
  }

  function stopBridge() {
    if (isShuttingDown) {
      return;
    }

    prepareBridgeShutdown();
    desktopRefresher.handleTransportReset();
    failBridgeManagedCodexRequests(new Error("Bridge stopped before the request completed."));
    forwardedRequestMethodsById.clear();

    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
      socket.close();
    }
    codex.shutdown();
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
        logger.warn("Relay heartbeat stalled; forcing reconnect", {
          lastRelayActivityAt,
        });
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
    if (status !== "connected") {
      activePhoneSummary = null;
    }
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
      shutdown(codex, () => socket, prepareBridgeShutdown);
      return;
    }

    if (reconnectTimer) {
      return;
    }

    reconnectAttempt += 1;
    const baseDelayMs = Math.min(1_000 * reconnectAttempt, 5_000);
    const jitterMs = Math.floor(Math.random() * Math.min(baseDelayMs, 2_000));
    const delayMs = baseDelayMs + jitterMs;
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
      perMessageDeflate: {
        zlibDeflateOptions: { level: 6 },
        threshold: 256,
        concurrencyLimit: 4,
      },
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
      publishPairingSessionIfNeeded();
    });

    nextSocket.on("message", (data) => {
      markRelayActivity();
      const message = typeof data === "string" ? data : data.toString("utf8");
      if (
        secureTransport.handleIncomingWireMessage(message, {
          sendControlMessage(controlMessage) {
            if (nextSocket.readyState === WebSocket.OPEN) {
              nextSocket.send(JSON.stringify(controlMessage));
            }
          },
          onApplicationMessage(plaintextMessage) {
            handleApplicationMessage(plaintextMessage);
          },
        })
      ) {
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
      // Relay reconnects are transport-only: keep local live observers running
      // so their output can enter secure replay and catch up on the next resume.
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
  let pairingSessionPublished = false;
  function publishPairingSessionIfNeeded() {
    if (pairingSessionPublished) {
      return;
    }
    pairingSessionPublished = true;
    onPairingSession?.(pairingSession);
    if (printPairingQr) {
      writePairingSession(pairingSession);
      printQR(pairingSession);
    }
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
      sendRelayWireMessage,
    );
  });

  process.on("SIGINT", () => shutdown(codex, () => socket, prepareBridgeShutdown));
  process.on("SIGTERM", () => shutdown(codex, () => socket, prepareBridgeShutdown));

  // Routes decrypted app payloads through the same bridge handlers as before.
  // 
  // HANDLER CASCADE ORDER (LOAD-BEARING - DO NOT REORDER WITHOUT REVIEW):
  // The order of handlers in this function is critical. Each handler checks if it can
  // handle the message and returns early if so. This ensures proper message routing
  // and prevents handlers from interfering with each other.
  // 
  // INSERTION POINTS FOR NEW HANDLERS:
  // 1. Bridge-managed handlers (lines 643-648): Handshake, account requests
  //    - Insert new bridge infrastructure handlers here
  // 2. Voice handler (line 649): Voice-specific requests
  // 3. Thread context (line 652): Thread metadata and ownership
  // 4. OpenCode session usage (line 659): OpenCode-specific session queries
  //    - Insert new OpenCode-specific handlers before workspace handlers
  // 5. Workspace (line 666): Workspace management
  // 6. OpenCode project discovery (line 670): OpenCode project listing
  //    - Insert new project-related handlers here
  // 7. Project (line 677): Generic project requests
  // 8. Pet (line 680): Pet/animal-related requests
  // 9. Notifications (line 683): Push notification management
  // 10. Desktop (line 687): Desktop app integration
  // 11. Git (line 703): Git operations
  // 12. Runtime provider router (line 710): OpenCode/Codex provider routing
  //     - This is the PRIMARY OpenCode handler insertion point
  //     - All provider-specific messages should be handled here
  // 13. Desktop refresher (line 713): Desktop state refresh
  // 14. Rollout live mirror (line 714): Rollout state synchronization
  // 15. Desktop IPC follower (line 715): Desktop IPC message handling
  // 16. Bridge-managed thread turns list (line 718): Thread history queries
  // 17. Codex fallback (lines 721-743): Final fallback to Codex app-server
  //     - MUST REMAIN LAST: ensures all other handlers get first chance
  //     - Strips runtime provider fields before forwarding to Codex
  //
  // WHY ORDER MATTERS:
  // - Early handlers (handshake, account) must run before provider logic
  // - OpenCode handlers must run before the generic Codex fallback
  // - Provider router handles all runtime-specific messages (OpenCode, etc.)
  // - Codex fallback is the catch-all for unhandled messages
  function handleApplicationMessage(rawMessage) {
    if (handleBridgeManagedHandshakeMessage(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleBridgeManagedAccountRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (voiceHandler.handleVoiceRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleThreadContextRequest(rawMessage, sendApplicationResponse, {
      ownershipStore,
      opencodeProvider,
    })) {
      return;
    }
    if (runtimeProviderRouter.handleAuxiliaryRequest(rawMessage)) {
      return;
    }
    if (handleWorkspaceRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleProjectRequest(rawMessage, sendApplicationResponse, { projectRegistry })) {
      return;
    }
    if (handlePetRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (notificationsHandler.handleNotificationsRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (
      handleDesktopRequest(rawMessage, sendApplicationResponse, {
        bundleId: config.codexBundleId,
        appPath: config.codexAppPath,
        readBridgePreferences,
        updateBridgePreferences,
        updateBridgePackageAndRestart,
        ownershipStore,
        opencodeProvider,
        logPrefix: "[remodex:opencode]",
      })
    ) {
      return;
    }
    if (
      handleGitRequest(rawMessage, sendApplicationResponse, {
        codexAppPath: config.codexAppPath,
        onThreadNameSet: sendThreadNameUpdatedNotification,
      })
    ) {
      return;
    }
    if (runtimeProviderRouter.handleApplicationMessage(rawMessage)) {
      return;
    }
    desktopRefresher.handleInbound(rawMessage);
    rolloutLiveMirror?.observeInbound(rawMessage);
    if (desktopIpcActionFollower?.observeInbound(rawMessage)) {
      return;
    }
    if (handleBridgeManagedThreadTurnsListRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (codexLaunchState === "degraded" || codexLaunchState === "error") {
      const parsed = safeParseJSON(rawMessage);
      if (parsed?.id != null) {
        sendApplicationResponse(
          createJsonRpcErrorResponse(
            parsed.id,
            {
              message: `Codex unavailable (${codexLaunchState})`,
              errorCode: "codex_unavailable",
            },
            "codex_unavailable",
          ),
        );
      }
      return;
    }
    const codexRequest = stripRuntimeProviderFieldsForCodex(
      disableUnsupportedReasoningSummaryForTurnStart(rawMessage),
    );
    rememberForwardedRequestMethod(rawMessage);
    rememberThreadFromMessage("phone", codexRequest);
    rememberKnownProjectFromRequest("codex-request", codexRequest);
    codex.send(codexRequest);
  }

  // Encrypts bridge-generated responses instead of letting the relay see plaintext.
  function sendApplicationResponse(rawMessage) {
    secureTransport.queueOutboundApplicationMessage(
      sanitizeRelayBoundCodexMessage(rawMessage),
      sendRelayWireMessage,
    );
  }

  function sendRuntimeApplicationMessage(provider, rawMessage) {
    if (provider !== "opencode") {
      desktopRefresher.handleOutbound(rawMessage);
    }
    pushNotificationTracker.handleOutbound(rawMessage);
    rememberThreadFromMessage(provider, rawMessage);
    logBridgeNotifyForward(provider, rawMessage);
    secureTransport.queueOutboundApplicationMessage(
      sanitizeRelayBoundCodexMessage(rawMessage),
      sendRelayWireMessage,
    );
  }

  function logBridgeNotifyForward(provider, rawMessage) {
    const NOTIFY_FORWARD_METHODS = new Set([
      "turn/started",
      "item/agentMessage/delta",
      "turn/completed",
      "runtime/catalog/updated",
    ]);
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return;
    }
    const method = readStringOrNull(parsed?.method);
    if (!NOTIFY_FORWARD_METHODS.has(method)) {
      return;
    }
    const params = parsed?.params && typeof parsed.params === "object" ? parsed.params : {};
    const turnObject = params.turn && typeof params.turn === "object" ? params.turn : {};
    console.log(
      JSON.stringify({
        event: "bridge_notify_forward",
        method,
        provider: readStringOrNull(provider) || "unknown",
        threadId: redactLogIdentifier(extractThreadId(method, params), "thread"),
        turnId: redactLogIdentifier(extractTurnId(method, params), "turn"),
        status: readStringOrNull(params.status) || readStringOrNull(turnObject.status),
        hasMacRelaySocket: socket?.readyState === WebSocket.OPEN,
      }),
    );
    // MSG-3 rate metric hook (late/buffer/watchdog/dedup); actual late rates emitted from provider as bridge_late_delta_suppressed.
  }

  // Mirrors accepted local renames back to the phone using the existing push-event shape.
  function sendThreadNameUpdatedNotification(result) {
    const threadId = readStringOrNull(result?.threadId || result?.thread_id);
    const name = readStringOrNull(result?.name || result?.title);
    if (!threadId || !name) {
      return;
    }

    sendApplicationResponse(
      JSON.stringify({
        method: "thread/name/updated",
        params: {
          threadId,
          thread_id: threadId,
          name,
          title: name,
        },
      }),
    );
  }

  function handleBridgeManagedThreadTurnsListRequest(
    rawMessage,
    sendResponse = sendApplicationResponse,
  ) {
    const request = parseAdaptiveThreadTurnsListRequest(rawMessage);
    if (!request) {
      return false;
    }

    rememberThreadFromMessage("phone", rawMessage);
    (async () => {
      try {
        const response = await fetchAdaptiveThreadTurnsListForRelay(request, {
          fetchPage: (params) => sendCodexRequest("thread/turns/list", params),
        });
        const jsonlFallback = maybeBuildJsonlThreadTurnsListFallback(request, response);
        const responsePayload = jsonlFallback?.response ?? response;
        const finalSanitizeContext = buildThreadTurnsListRelaySanitizeContext(request);
        relaySanitizedResponseMethodsById.set(String(request.id), {
          method: "thread/turns/list",
          ...finalSanitizeContext,
          createdAt: Date.now(),
        });
        sendResponse(
          sanitizeThreadHistoryImagesForRelay(
            JSON.stringify(responsePayload),
            "thread/turns/list",
            finalSanitizeContext,
          ),
        );
      } catch (error) {
        sendResponse(createJsonRpcErrorResponse(request.id, error, "thread_turns_list_failed"));
      }
    })();

    return true;
  }

  function maybeBuildJsonlThreadTurnsListFallback(request, response) {
    const params = request?.params || {};
    const threadId =
      normalizeNonEmptyString(params.threadId) || normalizeNonEmptyString(params.thread_id);
    if (!threadId || hasRelayCursor(params.cursor)) {
      return null;
    }

    try {
      const responseIsEmpty = isEmptyTurnsListResponse(response);
      const rolloutPath = resolveJsonlTurnsListRolloutPathForFallback({
        threadId,
        responseIsEmpty,
        readCachedPath: readCachedJsonlTurnsListRolloutPath,
        findAndCachePath: findAndCacheJsonlTurnsListRolloutPath,
      });
      if (!rolloutPath) {
        return null;
      }

      const result = readThreadTurnsListPageFromSessionJsonl(rolloutPath, {
        threadId,
        limit: params.limit,
        maxLimit: 1,
        cursor: params.cursor,
      });
      const turnsKey = findTurnsListResultKey(result);
      if (!turnsKey || result[turnsKey].length === 0) {
        return null;
      }

      if (!responseIsEmpty) {
        const mergedResponse = maybeMergeLatestJsonlTurnIntoTurnsListResponse(
          request,
          response,
          result,
          params,
        );
        return mergedResponse ? { response: mergedResponse, usesJsonl: true } : null;
      }

      return {
        response: {
          id: request.id,
          result,
        },
        usesJsonl: true,
      };
    } catch (error) {
      jsonlTurnsListRolloutCacheByThread.delete(threadId);
      console.warn(`[remodex] thread/turns/list jsonl fallback failed: ${error.message}`);
      return null;
    }
  }

  function findAndCacheJsonlTurnsListRolloutPath(threadId) {
    if (hasFreshJsonlTurnsListRolloutMiss(threadId)) {
      return "";
    }

    const rolloutPath = findRecentRolloutFileForContextRead(resolveSessionsRoot(), { threadId });
    if (rolloutPath) {
      jsonlTurnsListRolloutMissCacheByThread.delete(threadId);
      jsonlTurnsListRolloutCacheByThread.set(threadId, {
        rolloutPath,
        cachedAt: Date.now(),
      });
    } else {
      jsonlTurnsListRolloutMissCacheByThread.set(threadId, Date.now());
    }
    return rolloutPath;
  }

  function readCachedJsonlTurnsListRolloutPath(threadId) {
    const cached = jsonlTurnsListRolloutCacheByThread.get(threadId);
    if (!cached) {
      return "";
    }
    if (Date.now() - cached.cachedAt > RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS) {
      jsonlTurnsListRolloutCacheByThread.delete(threadId);
      return "";
    }
    // Non-empty app-server pages only consult this positive cache to avoid
    // walking the sessions tree during ordinary pagination.
    return cached.rolloutPath;
  }

  function hasFreshJsonlTurnsListRolloutMiss(threadId) {
    const missedAt = jsonlTurnsListRolloutMissCacheByThread.get(threadId);
    if (!missedAt) {
      return false;
    }
    if (Date.now() - missedAt <= RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS) {
      return true;
    }
    jsonlTurnsListRolloutMissCacheByThread.delete(threadId);
    return false;
  }

  // ─── Bridge-owned auth snapshot ─────────────────────────────

  // Handles the bridge-owned auth status wrappers without exposing tokens to the phone.
  // This dispatcher stays synchronous so non-account messages can continue down the normal routing chain.
  function handleBridgeManagedAccountRequest(rawMessage, sendResponse) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (
      method !== "account/status/read" &&
      method !== "getAuthStatus" &&
      method !== "account/login/openOnMac" &&
      method !== "voice/resolveAuth"
    ) {
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
    const [accountReadResult, authStatusResult, bridgeVersionInfoResult] = await Promise.allSettled(
      [
        sendCodexRequest("account/read", {
          refreshToken: false,
        }),
        sendCodexRequest("getAuthStatus", {
          includeToken: true,
          refreshToken: true,
        }),
        readBridgePackageVersionStatus(),
      ],
    );

    return composeSanitizedAuthStatusFromSettledResults({
      accountReadResult:
        accountReadResult.status === "fulfilled"
          ? {
              status: "fulfilled",
              value: normalizeAccountRead(accountReadResult.value),
            }
          : accountReadResult,
      authStatusResult,
      loginInFlight: Boolean(pendingAuthLogin.loginId),
      bridgeVersionInfo:
        bridgeVersionInfoResult.status === "fulfilled" ? bridgeVersionInfoResult.value : null,
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

    const authUrl = readStringOrNull(params?.authUrl) || pendingAuthLogin.authUrl;
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
      const trackedRequest = {
        method,
        threadId:
          method === "thread/turns/list" || method === "thread/read" || method === "thread/resume"
            ? threadIdFromRequestParams(parsed.params)
            : "",
        createdAt: Date.now(),
      };
      if (method === "thread/turns/list") {
        trackedRequest.skipJsonlArtifactAugmentation = false;
      }
      relaySanitizedResponseMethodsById.set(String(requestId), trackedRequest);
    }
  }

  // Replaces huge inline desktop-history images with lightweight references before relay encryption.
  function sanitizeRelayBoundCodexMessage(rawMessage) {
    pruneExpiredForwardedRequestMethods();
    const normalizedMessage = normalizeRelayBoundJsonRpcMessage(rawMessage, {
      pendingRequestMethodsById: relaySanitizedResponseMethodsById,
    });
    if (!normalizedMessage) {
      return null;
    }

    const parsed = safeParseJSON(normalizedMessage);
    const responseId = parsed?.id;
    if (responseId == null) {
      return sanitizeLiveGeneratedImageMessageForRelay(normalizedMessage);
    }

    const trackedRequest = relaySanitizedResponseMethodsById.get(String(responseId));
    if (!trackedRequest) {
      return normalizedMessage;
    }
    relaySanitizedResponseMethodsById.delete(String(responseId));

    return sanitizeThreadHistoryImagesForRelay(
      normalizedMessage,
      trackedRequest.method,
      trackedRequest,
    );
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
          const loginId = readStringOrNull(parsed?.result?.loginId);
          const authUrl = readStringOrNull(parsed?.result?.authUrl);
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
    const expiredForwarded = [];
    for (const [requestId, trackedRequest] of forwardedRequestMethodsById.entries()) {
      if (!trackedRequest || (now - trackedRequest.createdAt) >= forwardedRequestMethodTTLms) {
        expiredForwarded.push(requestId);
      }
    }
    for (const id of expiredForwarded) {
      forwardedRequestMethodsById.delete(id);
    }

    const expiredSanitized = [];
    for (const [requestId, trackedRequest] of relaySanitizedResponseMethodsById.entries()) {
      if (!trackedRequest || (now - trackedRequest.createdAt) >= forwardedRequestMethodTTLms) {
        expiredSanitized.push(requestId);
      }
    }
    for (const id of expiredSanitized) {
      relaySanitizedResponseMethodsById.delete(id);
    }

    evictOldestEntries(forwardedRequestMethodsById, FORWARDED_REQUEST_METHODS_MAX_SIZE);
    evictOldestEntries(relaySanitizedResponseMethodsById, FORWARDED_REQUEST_METHODS_MAX_SIZE);
    evictOldestEntries(jsonlArtifactItemsCacheByThread, RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES);
    evictOldestEntries(jsonlTurnsListRolloutCacheByThread, JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE);
    evictOldestEntries(jsonlTurnsListRolloutMissCacheByThread, JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE);
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

  // Captures explicit cwd selections before Codex creates the first thread, so
  // provider-neutral pickers do not depend on a later provider-specific message.
  function rememberKnownProjectFromRequest(source, rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "thread/start" && method !== "turn/start") {
      return;
    }

    const params = parsed?.params || {};
    const cwd = resolvedParam(params, 'cwd', 'current_working_directory', 'working_directory');
    if (!cwd) {
      return;
    }

    try {
      projectRegistry.rememberProjectPath(cwd, {
        source,
        provider: "codex",
      });
    } catch {
      // Registry persistence is best-effort; thread creation must keep flowing.
    }
  }

  // Mirrors CodexMonitor's persisted token_count fallback so the phone keeps
  // receiving context-window usage even when the runtime omits live thread usage.
  function ensureContextUsageWatcher({ threadId, turnId }) {
    const normalizedThreadId = readStringOrNull(threadId);
    const normalizedTurnId = readStringOrNull(turnId);
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

    sendApplicationResponse(
      JSON.stringify({
        method: "thread/tokenUsage/updated",
        params: {
          threadId,
          usage,
        },
      }),
    );
  }

  // The spawned/shared Codex app-server stays warm across phone reconnects.
  // When iPhone reconnects it sends initialize again, but forwarding that to the
  // already-initialized Codex transport only produces "Already initialized".
  function handleBridgeManagedHandshakeMessage(rawMessage, sendResponse = sendApplicationResponse) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (!method) {
      return false;
    }

    if (method === "initialize" && parsed.id != null) {
      const compatibilityError = bridgeManagedInitializeCompatibilityError(parsed.params || {});
      if (compatibilityError) {
        sendResponse(
          JSON.stringify({
            id: parsed.id,
            error: compatibilityError,
          }),
        );
        return true;
      }

      const openCodeCarriesBridge = opencodeCarriesBridge(availableRuntimes);
      if (codexHandshakeState !== "warm" && !openCodeCarriesBridge) {
        forwardedInitializeRequestIds.add(String(parsed.id));
        return false;
      }

      sendResponse(
        JSON.stringify({
          id: parsed.id,
          result: {
            bridgeManaged: true,
          },
        }),
      );
      return true;
    }

    if (method === "initialized") {
      return codexHandshakeState === "warm" || opencodeCarriesBridge(availableRuntimes);
    }

    return false;
  }

  // Blocks bridge/app version skew before the phone starts calling newer bridge APIs.
  function bridgeManagedInitializeCompatibilityError(params) {
    const clientInfo = params && typeof params === "object" ? params.clientInfo : null;
    const clientName = normalizeNonEmptyString(clientInfo?.name);
    const clientDeviceKind = classifyClientDeviceKind(clientName);
    if (clientDeviceKind) {
      deviceState = rememberLastSeenClientDeviceKind(deviceState, clientDeviceKind);
      if (activePhoneSummary?.connected) {
        activePhoneSummary = {
          ...activePhoneSummary,
          deviceKind: clientDeviceKind,
        };
        const lastPublishedBridgeStatus = bridgeStatusPublisher.latest();
        if (lastPublishedBridgeStatus) {
          publishBridgeStatus(lastPublishedBridgeStatus);
        }
      }
    }
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

    logIOSAppCompatibilityWarning(
      buildCachedIOSAppCompatibilityWarning({
        bridgeVersion: bridgePackageVersion,
        iosAppVersion: clientVersion,
      }),
    );

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
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
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

    const errorMessage =
      typeof parsed?.error?.message === "string" ? parsed.error.message.toLowerCase() : "";
    if (errorMessage.includes("already initialized")) {
      codexHandshakeState = "warm";
    }
  }

  // Runs bridge-private JSON-RPC calls against the local app-server so token-bearing responses
  // can power bridge features like transcription without ever reaching the phone.
  function sendCodexRequest(method, params) {
    if (codexLaunchState === "degraded" || codexLaunchState === "error") {
      return Promise.reject(new Error(`Codex unavailable (${codexLaunchState})`));
    }
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
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
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

    waiter.resolve(readBridgeManagedSuccessPayload(parsed));
    return true;
  }

  // Normalizes private app-server responses before the bridge re-wraps them for iOS.
  function readBridgeManagedSuccessPayload(parsed) {
    if (Object.prototype.hasOwnProperty.call(parsed, "result")) {
      return parsed.result ?? null;
    }
    if (Object.prototype.hasOwnProperty.call(parsed, "payload")) {
      return parsed.payload ?? null;
    }
    return null;
  }

  function failBridgeManagedCodexRequests(error) {
    for (const waiter of bridgeManagedCodexRequestWaiters.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    bridgeManagedCodexRequestWaiters.clear();
  }

  function publishBridgeStatus(status) {
    const opencode = buildOpenCodeBridgeStatusSection(opencodeProvider, process.env);
    const baseStatus = {
      ...status,
      activeDevice: activePhoneSummary,
      activePhone: activePhoneSummary,
    };
    bridgeStatusPublisher.publish(
      opencode ? { ...baseStatus, opencode } : baseStatus,
    );
  }

  // Refreshes the relay's trusted-mac index after the QR bootstrap locks in a phone identity.
  function sendRelayRegistrationUpdate(nextDeviceState) {
    deviceState = nextDeviceState;
    if (socket?.readyState !== WebSocket.OPEN) {
      return;
    }

    socket.send(
      JSON.stringify({
        kind: "relayMacRegistration",
        registration: buildMacRegistration(nextDeviceState, pairingSession),
      }),
    );
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

  async function updateBridgePackageAndRestart() {
    if (process.platform !== "darwin") {
      const error = new Error("Bridge self-update is available only for the macOS bridge service.");
      error.errorCode = "unsupported_platform";
      error.userMessage = error.message;
      throw error;
    }

    try {
      await execFileAsync(
        "/bin/zsh",
        [
          "-lc",
          [
            "export TERM=dumb",
            "source ~/.zshrc >/dev/null 2>/dev/null || true",
            BRIDGE_PACKAGE_UPDATE_COMMAND,
          ].join("; "),
        ],
        {
          timeout: BRIDGE_PACKAGE_UPDATE_TIMEOUT_MS,
          maxBuffer: 2 * 1024 * 1024,
        },
      );
    } catch (error) {
      const nextError = new Error(
        truncateCommandOutput(error?.stderr || error?.stdout || error?.message) ||
          "Could not update the Remodex bridge package on this Mac.",
      );
      nextError.errorCode = "bridge_update_failed";
      nextError.userMessage = nextError.message;
      nextError.cause = error;
      throw nextError;
    }

    scheduleBridgeServiceRestartAfterUpdate();
    return {
      success: true,
      command: BRIDGE_PACKAGE_UPDATE_COMMAND,
      restartScheduled: true,
      restartDelayMs: BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS,
    };
  }

  // Restarts after the RPC response has crossed the encrypted phone channel.
  function scheduleBridgeServiceRestartAfterUpdate() {
    const restartTimer = setTimeout(() => {
      const cliPath = path.join(__dirname, "..", "bin", "remodex.js");
      const child = spawn(process.execPath, [cliPath, "restart"], {
        detached: true,
        stdio: "ignore",
        env: process.env,
      });
      child.unref?.();
    }, BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS);
    restartTimer.unref?.();
  }

  return {
    stop: stopBridge,
  };
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
        consoleImpl.warn(
          `[remodex] Failed to hold the Mac awake while the bridge is active: ${error.message}`,
        );
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
        `[remodex] Failed to start the bridge wake assertion: ${(error && error.message) || "unknown error"}`,
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

// Registers the canonical Mac identity and the one trusted phone allowed for auto-resolve.
function buildMacRegistrationHeaders(deviceState, pairingSession) {
  const registration = buildMacRegistration(deviceState, pairingSession);
  const headers = {
    "x-mac-device-id": registration.macDeviceId,
    "x-mac-identity-public-key": registration.macIdentityPublicKey,
    "x-machine-name": registration.displayName,
    "x-pairing-code": registration.pairingCode,
    "x-pairing-version": registration.pairingVersion ? String(registration.pairingVersion) : "",
    "x-pairing-expires-at": registration.pairingExpiresAt
      ? String(registration.pairingExpiresAt)
      : "",
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
    pairingVersion: Number.isInteger(pairingSession?.pairingPayload?.v)
      ? pairingSession.pairingPayload.v
      : 0,
    pairingExpiresAt: Number.isFinite(pairingSession?.pairingPayload?.expiresAt)
      ? pairingSession.pairingPayload.expiresAt
      : 0,
  };
}

function buildActivePhoneSummary(session, deviceState = null) {
  const phoneFingerprint = shortFingerprint(session?.phoneDeviceId);
  if (!phoneFingerprint) {
    return null;
  }

  return {
    connected: true,
    phoneFingerprint,
    deviceKind: normalizeNonEmptyString(deviceState?.lastSeenDeviceKind) || null,
    handshakeMode: normalizeNonEmptyString(session?.handshakeMode) || null,
    keyEpoch: Number.isFinite(session?.keyEpoch) ? session.keyEpoch : null,
    updatedAt: new Date().toISOString(),
  };
}

function classifyClientDeviceKind(clientName) {
  const normalized = normalizeNonEmptyString(clientName).toLowerCase();
  if (!normalized) {
    return null;
  }
  if (normalized.includes("android")) {
    return "android";
  }
  if (normalized.includes("ios") || normalized.includes("iphone")) {
    return "iphone";
  }
  if (normalized.includes("macos") || normalized.includes("mac")) {
    return "mac";
  }
  return null;
}

function shortFingerprint(value) {
  const normalized = normalizeNonEmptyString(value);
  if (!normalized) {
    return null;
  }
  return createHash("sha256").update(normalized).digest("hex").slice(0, 8);
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

// Forces app-server summary generation off for models whose Responses API calls
// reject reasoning.summary, while leaving the phone-facing runtime choice intact.
function disableUnsupportedReasoningSummaryForTurnStart(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || parsed.method !== "turn/start") {
    return rawMessage;
  }

  const params =
    parsed.params && typeof parsed.params === "object" && !Array.isArray(parsed.params)
      ? parsed.params
      : null;
  if (!params || params.summary === "none") {
    return rawMessage;
  }

  const model = readTurnStartModel(params);
  if (!MODELS_WITHOUT_REASONING_SUMMARY.has(model)) {
    return rawMessage;
  }

  return JSON.stringify({
    ...parsed,
    params: {
      ...params,
      summary: "none",
    },
  });
}

function readTurnStartModel(params) {
  return (
    normalizeNonEmptyString(params?.model).toLowerCase() ||
    normalizeNonEmptyString(params?.collaborationMode?.settings?.model).toLowerCase() ||
    normalizeNonEmptyString(params?.collaboration_mode?.settings?.model).toLowerCase()
  );
}

function extractBridgeMessageContext(rawMessage) {
  const parsed = safeParseJSON(rawMessage);
  if (!parsed) {
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

  return context.method === "turn/start" || context.method === "turn/started";
}

function extractThreadId(method, params) {
  if (method === "turn/start" || method === "turn/started") {
    return (
      readStringOrNull(params?.threadId) ||
      readStringOrNull(params?.thread_id) ||
      readStringOrNull(params?.turn?.threadId) ||
      readStringOrNull(params?.turn?.thread_id)
    );
  }

  if (method === "thread/start" || method === "thread/started") {
    return (
      readStringOrNull(params?.threadId) ||
      readStringOrNull(params?.thread_id) ||
      readStringOrNull(params?.thread?.id) ||
      readStringOrNull(params?.thread?.threadId) ||
      readStringOrNull(params?.thread?.thread_id)
    );
  }

  if (method === "turn/completed") {
    return (
      readStringOrNull(params?.threadId) ||
      readStringOrNull(params?.thread_id) ||
      readStringOrNull(params?.turn?.threadId) ||
      readStringOrNull(params?.turn?.thread_id)
    );
  }

  if (method === "item/agentMessage/delta" || method === "item/completed") {
    return (
      readStringOrNull(params?.threadId) ||
      readStringOrNull(params?.thread_id) ||
      readStringOrNull(params?.item?.threadId) ||
      readStringOrNull(params?.item?.thread_id)
    );
  }

  return null;
}

function extractTurnId(method, params) {
  if (method === "turn/started" || method === "turn/completed") {
    return (
      readStringOrNull(params?.turnId) ||
      readStringOrNull(params?.turn_id) ||
      readStringOrNull(params?.id) ||
      readStringOrNull(params?.turn?.id) ||
      readStringOrNull(params?.turn?.turnId) ||
      readStringOrNull(params?.turn?.turn_id)
    );
  }

  if (method === "item/agentMessage/delta" || method === "item/completed") {
    return (
      readStringOrNull(params?.turnId) ||
      readStringOrNull(params?.turn_id) ||
      readStringOrNull(params?.item?.turnId) ||
      readStringOrNull(params?.item?.turn_id) ||
      readStringOrNull(params?.item?.id)
    );
  }

  return null;
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function truncateCommandOutput(value, maxChars = 1_200) {
  const normalized = normalizeNonEmptyString(value);
  if (!normalized || normalized.length <= maxChars) {
    return normalized;
  }
  return `...${normalized.slice(-maxChars)}`;
}

function parseAdaptiveThreadTurnsListRequest(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }

  if (parsed.method !== "thread/turns/list") {
    return null;
  }

  if (parsed.id == null) {
    return null;
  }

  const params = parsed.params;
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return null;
  }

  if (!Number.isInteger(params.limit) || params.limit <= 0) {
    return null;
  }

  return parsed;
}

function parseBridgeJSON(value) {
  return safeParseJSON(value);
}

// Keeps app-server responses in the JSON-RPC shape that the App Store iOS client decodes.
function normalizeRelayBoundJsonRpcMessage(rawMessage, { pendingRequestMethodsById = null } = {}) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }

  const hasMethod = typeof parsed.method === "string" && parsed.method.length > 0;
  const hasResponseId = parsed.id !== undefined && parsed.id !== null;
  const hasResult = Object.prototype.hasOwnProperty.call(parsed, "result");
  const hasError = Object.prototype.hasOwnProperty.call(parsed, "error");
  const hasPayload = Object.prototype.hasOwnProperty.call(parsed, "payload");
  if (hasResponseId && !hasMethod && !hasResult && !hasError && hasPayload) {
    const { payload, ...rest } = parsed;
    return JSON.stringify({
      ...rest,
      result: payload ?? null,
    });
  }

  if (hasResponseId && !hasMethod && hasResult && !hasError) {
    const unwrappedResult = unwrapAppServerPayloadResult(parsed.result);
    if (unwrappedResult !== parsed.result) {
      return JSON.stringify({
        ...parsed,
        result: unwrappedResult,
      });
    }
  }

  if (hasMethod && hasResponseId && !isRelayBoundServerRequestMethod(parsed.method)) {
    const trackedRequest = pendingRequestMethodsById?.get(String(parsed.id));
    const isTrackedResponse =
      trackedRequest?.method === parsed.method && (hasResult || hasError || hasPayload);
    if (isTrackedResponse) {
      const { method: _method, payload, ...rest } = parsed;
      if (!hasResult && !hasError && hasPayload) {
        return JSON.stringify({
          ...rest,
          result: payload ?? null,
        });
      }
      if (hasResult && !hasError) {
        return JSON.stringify({
          ...rest,
          result: unwrapAppServerPayloadResult(rest.result),
        });
      }
      return JSON.stringify(rest);
    }

    return null;
  }

  if (!hasMethod && !hasResponseId) {
    return null;
  }

  return rawMessage;
}

function isRelayBoundServerRequestMethod(method) {
  return (
    method === "item/tool/requestUserInput" ||
    method === "tool/requestUserInput" ||
    method.endsWith("requestApproval")
  );
}

function persistBridgePreferences(
  { keepMacAwakeEnabled },
  { readDaemonConfigImpl = readDaemonConfig, writeDaemonConfigImpl = writeDaemonConfig } = {},
) {
  writeDaemonConfigImpl({
    ...readDaemonConfigImpl(),
    keepMacAwakeEnabled,
  });
}

function readVerboseLogsEnabled() {
  const value = process.env.REMODEX_VERBOSE_LOGS;
  return value === "1" || (typeof value === "string" && value.toLowerCase() === "true");
}

// SEC-06: hash bearer-like thread/turn identifiers unless verbose logging is explicitly enabled.
function redactLogIdentifier(value, label = "id") {
  const normalized = readStringOrNull(value);
  if (!normalized) {
    return null;
  }

  if (readVerboseLogsEnabled()) {
    return normalized;
  }

  const digest = createHash("sha256").update(normalized).digest("hex").slice(0, 8);
  return `${label}#${digest}`;
}

module.exports = {
  buildThreadTurnsListRelaySanitizeContext,
  buildHeartbeatBridgeStatus,
  createMacOSBridgeWakeAssertion,
  disableUnsupportedReasoningSummaryForTurnStart,
  fetchAdaptiveThreadTurnsListForRelay,
  hasRelayConnectionGoneStale,
  normalizeRelayBoundJsonRpcMessage,
  persistBridgePreferences,
  redactLogIdentifier,
  resolveJsonlTurnsListRolloutPathForFallback,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeThreadHistoryImagesForRelay,
  startBridge,
};
