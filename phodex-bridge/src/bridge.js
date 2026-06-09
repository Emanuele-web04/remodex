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
const { handleOpenCodeProjectDiscoverRequest } = require("./opencode-project-discover-handler");
const { handleOpenCodeSessionUsageRequest } = require("./opencode-session-usage-handler");
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
const RELAY_HISTORY_IMAGE_REFERENCE_URL = "remodex://history-image-elided";
const RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES = 4 * 1024 * 1024;
const RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS = 24_000;
const RELAY_HISTORY_RECENT_TURN_TARGET = 40;
const RELAY_TURNS_LIST_TARGET_BUDGET_MS = 5_500;
const RELAY_TURNS_LIST_BUDGET_RESERVE_MS = 1_000;
const RELAY_TURNS_LIST_MAX_INITIAL_LIMIT = 5;
const RELAY_TURNS_LIST_SAFE_RETRY_LIMIT = 5;
const RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS = 30_000;
const RELAY_JSONL_ARTIFACT_CACHE_TTL_MS = 2_000;
const RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES = 128;
const BRIDGE_PACKAGE_UPDATE_COMMAND = "npm install -g remodex@latest";
const BRIDGE_PACKAGE_UPDATE_TIMEOUT_MS = 180_000;
const BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS = 750;
const MODELS_WITHOUT_REASONING_SUMMARY = new Set(["gpt-5.3-codex-spark"]);
const RELAY_TURNS_LIST_RESULT_KEYS = ["data", "items", "turns"];
const RELAY_TURNS_LIST_PAGINATION_RESULT_KEYS = [
  "nextCursor",
  "next_cursor",
  "cursor",
  "hasNextCursor",
  "has_next_cursor",
  "hasNextPage",
  "has_next_page",
  "hasMore",
  "has_more",
  "prevCursor",
  "prev_cursor",
  "previousCursor",
  "previous_cursor",
];
const jsonlArtifactItemsCacheByThread = new Map();
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
      const opencodeProvider = runtimeProviderRouter.providers.find(
        (provider) => provider.id === "opencode",
      ) || null;
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
      opencodeProvider: runtimeProviderRouter.providers.find((provider) => provider.id === "opencode") || null,
    })) {
      return;
    }
    if (
      handleOpenCodeSessionUsageRequest(rawMessage, sendApplicationResponse, {
        ownershipStore,
        opencodeProvider: runtimeProviderRouter.providers.find((provider) => provider.id === "opencode") || null,
      })
    ) {
      return;
    }
    if (handleWorkspaceRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (
      handleOpenCodeProjectDiscoverRequest(rawMessage, sendApplicationResponse, {
        projectRegistry,
        opencodeProvider: runtimeProviderRouter.providers.find((provider) => provider.id === "opencode") || null,
      })
    ) {
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
        opencodeProvider: runtimeProviderRouter.providers.find(
          (provider) => provider.id === "opencode",
        ) || null,
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
    const opencodeProvider = runtimeProviderRouter.providers.find(
      (provider) => provider.id === "opencode",
    ) || null;
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

function threadIdFromRequestParams(params) {
  return (
    normalizeNonEmptyString(params?.threadId) ||
    normalizeNonEmptyString(params?.thread_id) ||
    normalizeNonEmptyString(params?.id) ||
    ""
  );
}

function buildThreadTurnsListRelaySanitizeContext(
  request,
  { skipJsonlArtifactAugmentation = false } = {},
) {
  return {
    threadId: threadIdFromRequestParams(request?.params || {}),
    skipJsonlArtifactAugmentation,
  };
}

async function fetchAdaptiveThreadTurnsListForRelay(
  request,
  {
    fetchPage,
    now = Date.now,
    targetBudgetMs = RELAY_TURNS_LIST_TARGET_BUDGET_MS,
    budgetReserveMs = RELAY_TURNS_LIST_BUDGET_RESERVE_MS,
    rawPageSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
    payloadSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
    sanitizeForRelay = sanitizeThreadHistoryImagesForRelay,
  } = {},
) {
  if (typeof fetchPage !== "function") {
    throw new Error("fetchPage is required for adaptive turns-list pagination.");
  }

  const params = request?.params;
  const requestedLimit =
    Number.isInteger(params?.limit) && params.limit > 0
      ? Math.min(params.limit, RELAY_TURNS_LIST_MAX_INITIAL_LIMIT)
      : 1;
  const sanitizeContext = buildThreadTurnsListRelaySanitizeContext(request, {
    skipJsonlArtifactAugmentation: true,
  });
  const startedAt = now();
  let nextCursor = params?.cursor;
  let turnsKey = null;
  let firstResult = null;
  let lastResult = null;
  let combinedTurns = [];
  let response = null;

  while (combinedTurns.length < requestedLimit) {
    const remaining = requestedLimit - combinedTurns.length;
    const pageLimit = selectAdaptiveTurnsListBatchLimit(combinedTurns.length, remaining);
    const pageParams = buildAdaptiveTurnsListPageParams(params, pageLimit, nextCursor);
    let page;

    try {
      page = await fetchMeasuredAdaptiveTurnsListPage(fetchPage, pageParams, now);
    } catch {
      if (response) {
        return response;
      }
      return await fetchSafeThreadTurnsListFallback(request, {
        fetchPage,
        now,
        sanitizeForRelay,
        sanitizeContext,
        payloadSoftLimitBytes,
      });
    }

    const pageResult = unwrapAppServerPayloadResult(page.result);
    const pageTurnsKey = findTurnsListResultKey(pageResult);
    if (!pageTurnsKey) {
      if (!response) {
        return await fetchSafeThreadTurnsListFallback(request, {
          fetchPage,
          now,
          sanitizeForRelay,
          sanitizeContext,
          payloadSoftLimitBytes,
        });
      }
      return response;
    }

    if (!turnsKey) {
      turnsKey = pageTurnsKey;
    }
    if (!firstResult) {
      firstResult = pageResult;
    }
    lastResult = pageResult;

    const pageTurns = pageResult[pageTurnsKey];
    combinedTurns = combinedTurns.concat(pageTurns);
    response = buildSafeTurnsListResponse(
      request.id,
      firstResult,
      lastResult,
      turnsKey,
      combinedTurns,
    );

    if (
      measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) >=
      payloadSoftLimitBytes
    ) {
      response =
        buildLargestSafeTurnsListResponse({
          requestId: request.id,
          firstResult,
          lastResult,
          turnsKey,
          turns: combinedTurns,
          maxTurns: RELAY_TURNS_LIST_SAFE_RETRY_LIMIT,
          sanitizeForRelay,
          sanitizeContext,
          payloadSoftLimitBytes,
        }) ?? buildEmptyTurnsListResponse(request);
      break;
    }

    nextCursor = readTurnsListNextCursor(pageResult);
    if (
      combinedTurns.length >= requestedLimit ||
      !hasRelayCursor(nextCursor) ||
      pageTurns.length === 0
    ) {
      break;
    }

    const rawPageBytes = jsonByteLength(pageResult);
    const sanitizedResponseBytes = measureSanitizedTurnsListResponseBytes(
      response,
      sanitizeForRelay,
      sanitizeContext,
    );
    const elapsedMs = Math.max(0, now() - startedAt);
    const remainingBudgetMs = Math.max(0, targetBudgetMs - elapsedMs);
    if (
      rawPageBytes >= rawPageSoftLimitBytes ||
      sanitizedResponseBytes >= payloadSoftLimitBytes ||
      page.elapsedMs >= Math.max(0, targetBudgetMs - budgetReserveMs) ||
      remainingBudgetMs <= budgetReserveMs
    ) {
      break;
    }
  }

  return (
    response ?? {
      id: request.id,
      result: {
        data: [],
      },
    }
  );
}

function buildEmptyTurnsListResponse(request) {
  return {
    id: request.id,
    result: {
      data: [],
      nextCursor: null,
    },
  };
}

function isEmptyTurnsListResponse(response) {
  const turnsKey = findTurnsListResultKey(response?.result);
  return Boolean(turnsKey) && response.result[turnsKey].length === 0;
}

// Non-empty app-server pages can be stale for Mac-started runs, so the first page
// still gets one JSONL lookup when the positive rollout cache is cold.
function resolveJsonlTurnsListRolloutPathForFallback({
  threadId,
  responseIsEmpty,
  readCachedPath,
  findAndCachePath,
}) {
  if (!threadId || typeof findAndCachePath !== "function") {
    return "";
  }

  if (responseIsEmpty) {
    return findAndCachePath(threadId);
  }

  return typeof readCachedPath === "function"
    ? readCachedPath(threadId) || findAndCachePath(threadId)
    : findAndCachePath(threadId);
}

function maybeMergeLatestJsonlTurnIntoTurnsListResponse(
  request,
  response,
  jsonlResult,
  params = {},
) {
  const responseResult = response?.result;
  const responseTurnsKey = findTurnsListResultKey(responseResult);
  const jsonlTurnsKey = findTurnsListResultKey(jsonlResult);
  if (!responseTurnsKey || !jsonlTurnsKey) {
    return null;
  }

  const responseTurns = responseResult[responseTurnsKey];
  const jsonlTurn = jsonlResult[jsonlTurnsKey]?.[0];
  const jsonlTurnId = turnListTurnIdentifier(jsonlTurn);
  if (!jsonlTurnId || responseTurns.some((turn) => turnListTurnIdentifier(turn) === jsonlTurnId)) {
    return null;
  }

  if (!shouldMergeLatestJsonlTurn(jsonlTurn)) {
    return null;
  }

  const requestedLimit =
    Number.isInteger(params?.limit) && params.limit > 0 ? params.limit : responseTurns.length + 1;
  const mergedTurns = [jsonlTurn, ...responseTurns].slice(0, requestedLimit);
  return {
    id: request.id,
    result: {
      ...responseResult,
      [responseTurnsKey]: mergedTurns,
      remodexJsonlMergedLatest: true,
    },
  };
}

function shouldMergeLatestJsonlTurn(turn) {
  if (!turn || typeof turn !== "object") {
    return false;
  }

  const status = normalizeHistoryItemToken(turn.status);
  if (status === "running" || status === "inprogress" || status === "active") {
    return true;
  }

  return (
    Array.isArray(turn.items) &&
    turn.items.some((item) => {
      const type = normalizeHistoryItemToken(item?.type);
      return type === "plan" || type === "filechange";
    })
  );
}

function turnListTurnIdentifier(turn) {
  return (
    normalizeNonEmptyString(turn?.id) ||
    normalizeNonEmptyString(turn?.turnId) ||
    normalizeNonEmptyString(turn?.turn_id)
  );
}

async function fetchSafeThreadTurnsListFallback(
  request,
  { fetchPage, now, sanitizeForRelay, sanitizeContext = {}, payloadSoftLimitBytes },
) {
  const params = request?.params;
  const requestedLimit =
    Number.isInteger(params?.limit) && params.limit > 0
      ? params.limit
      : RELAY_TURNS_LIST_SAFE_RETRY_LIMIT;
  const safeLimit = Math.min(requestedLimit, RELAY_TURNS_LIST_SAFE_RETRY_LIMIT);
  const safeParams = buildAdaptiveTurnsListPageParams(params, safeLimit, params?.cursor);

  try {
    const page = await fetchMeasuredAdaptiveTurnsListPage(fetchPage, safeParams, now);
    const pageResult = unwrapAppServerPayloadResult(page.result);
    const turnsKey = findTurnsListResultKey(pageResult);
    if (!turnsKey) {
      return buildEmptyTurnsListResponse(request);
    }

    // If the normal pagination path returns a bad first page, retry once with a small page.
    // The retry response is intentionally minimal so Swift does not decode stale server metadata.
    const response = buildLargestSafeTurnsListResponse({
      requestId: request.id,
      firstResult: pageResult,
      lastResult: pageResult,
      turnsKey,
      turns: pageResult[turnsKey],
      maxTurns: safeLimit,
      sanitizeForRelay,
      sanitizeContext,
      payloadSoftLimitBytes,
    });
    if (response) {
      return response;
    }
  } catch {
    // Fall through to a valid empty page: the phone can keep the thread open instead of crashing.
  }

  return buildEmptyTurnsListResponse(request);
}

async function fetchMeasuredAdaptiveTurnsListPage(fetchPage, params, now) {
  const startedAt = now();
  const result = await fetchPage(params);
  const elapsedMs = Math.max(0, now() - startedAt);
  return {
    result,
    elapsedMs,
  };
}

function selectAdaptiveTurnsListBatchLimit(fetchedTurnCount, remainingTurnCount) {
  if (fetchedTurnCount <= 0) {
    return Math.min(1, remainingTurnCount);
  }
  if (fetchedTurnCount <= 1) {
    return Math.min(4, remainingTurnCount);
  }
  return remainingTurnCount;
}

function buildAdaptiveTurnsListPageParams(baseParams, limit, cursor) {
  const params = {
    ...baseParams,
    limit,
  };
  if (hasRelayCursor(cursor)) {
    params.cursor = cursor;
  } else {
    delete params.cursor;
  }
  return params;
}

function findTurnsListResultKey(result) {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return null;
  }
  return RELAY_TURNS_LIST_RESULT_KEYS.find((key) => Array.isArray(result[key])) || null;
}

function buildSafeTurnsListResponse(requestId, firstResult, lastResult, turnsKey, turns) {
  return {
    id: requestId,
    result: buildAdaptiveTurnsListResult(firstResult, lastResult, turnsKey, turns),
  };
}

// Trims oversized history pages progressively: normal page -> 5 turns -> ... -> 1 turn.
function buildLargestSafeTurnsListResponse({
  requestId,
  firstResult,
  lastResult,
  turnsKey,
  turns,
  maxTurns,
  sanitizeForRelay,
  sanitizeContext = {},
  payloadSoftLimitBytes,
}) {
  const sliceLimit = Math.min(turns.length, maxTurns);
  for (let count = sliceLimit; count > 0; count -= 1) {
    const response = buildSafeTurnsListResponse(
      requestId,
      firstResult,
      lastResult,
      turnsKey,
      turns.slice(0, count),
    );
    if (
      measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) <
      payloadSoftLimitBytes
    ) {
      return response;
    }
  }
  return buildEmergencySingleTurnResponse({
    requestId,
    lastResult,
    turnsKey,
    turn: turns[0],
    sanitizeForRelay,
    sanitizeContext,
    payloadSoftLimitBytes,
  });
}

function buildEmergencySingleTurnResponse({
  requestId,
  lastResult,
  turnsKey,
  turn,
  sanitizeForRelay,
  sanitizeContext = {},
  payloadSoftLimitBytes,
}) {
  if (!turn || typeof turn !== "object" || Array.isArray(turn)) {
    return null;
  }

  for (const maxItems of [16, 4, 1]) {
    for (const maxChars of [
      RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
      Math.floor(RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS / 4),
      1_000,
      0,
    ]) {
      const response = {
        id: requestId,
        result: {
          ...buildAdaptiveTurnsListResult({}, lastResult, turnsKey, [
            compactEmergencySingleTurnForRelay(turn, maxChars, maxItems),
          ]),
          remodexEmergencySingleTurnForRelay: true,
        },
      };
      if (
        measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) <
        payloadSoftLimitBytes
      ) {
        return response;
      }
    }
  }

  return null;
}

function compactEmergencySingleTurnForRelay(turn, maxChars, maxItems) {
  const safeTurn = {};
  for (const key of [
    "id",
    "turnId",
    "turn_id",
    "threadId",
    "thread_id",
    "createdAt",
    "created_at",
    "completedAt",
    "completed_at",
    "timeZoneIdentifier",
    "timeZone",
    "timezone",
    "time_zone",
    "status",
    "role",
    "kind",
  ]) {
    const value = turn[key];
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      safeTurn[key] = value;
    }
  }

  const items = Array.isArray(turn.items) ? turn.items : [];
  safeTurn.items = items.slice(-maxItems).map((item) => compactHistoryItemForRelay(item, maxChars));
  safeTurn.remodexEmergencySingleTurnForRelay = true;
  safeTurn.remodexPageCompactedForRelay = true;
  return safeTurn;
}

function buildAdaptiveTurnsListResult(firstResult, lastResult, turnsKey, turns) {
  const result = {};
  result[turnsKey] = turns;

  for (const key of RELAY_TURNS_LIST_PAGINATION_RESULT_KEYS) {
    if (Object.prototype.hasOwnProperty.call(lastResult, key)) {
      result[key] = lastResult[key];
    } else {
      delete result[key];
    }
  }

  return result;
}

function readTurnsListNextCursor(result) {
  if (!result || typeof result !== "object") {
    return undefined;
  }
  if (hasRelayCursor(result.nextCursor)) {
    return result.nextCursor;
  }
  if (hasRelayCursor(result.next_cursor)) {
    return result.next_cursor;
  }
  return undefined;
}

function hasRelayCursor(cursor) {
  return cursor !== undefined && cursor !== null && cursor !== "";
}

function jsonByteLength(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, requestContext = {}) {
  try {
    const rawResponse = JSON.stringify(response);
    const sanitizedResponse = sanitizeForRelay(rawResponse, "thread/turns/list", requestContext);
    return Buffer.byteLength(sanitizedResponse, "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
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

function unwrapAppServerPayloadResult(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return value;
  }
  if (!Object.prototype.hasOwnProperty.call(value, "payload")) {
    return value;
  }

  const payload = value.payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return value;
  }

  const directPayloadKeys = ["data", "items", "threads", "turns", "thread"];
  const hasDirectResultPayload = directPayloadKeys.some((key) =>
    Object.prototype.hasOwnProperty.call(payload, key),
  );
  if (!hasDirectResultPayload) {
    return value;
  }

  return {
    ...value,
    ...payload,
  };
}

function isRelayBoundServerRequestMethod(method) {
  return (
    method === "item/tool/requestUserInput" ||
    method === "tool/requestUserInput" ||
    method.endsWith("requestApproval")
  );
}

// Shrinks thread history snapshots/pages for mobile relay delivery.
// This elides bulky blobs and replaces oversized older history with a compact marker.
function sanitizeThreadHistoryImagesForRelay(rawMessage, requestMethod, requestContext = {}) {
  if (requestMethod === "thread/turns/list") {
    return sanitizeThreadTurnsListForRelay(rawMessage, requestContext);
  }

  if (requestMethod !== "thread/read" && requestMethod !== "thread/resume") {
    return rawMessage;
  }

  const parsed = parseBridgeJSON(rawMessage);
  const thread = parsed?.result?.thread;
  if (!thread || typeof thread !== "object" || !Array.isArray(thread.turns)) {
    return rawMessage;
  }

  const threadId =
    normalizeNonEmptyString(requestContext?.threadId) ||
    normalizeNonEmptyString(thread.id) ||
    normalizeNonEmptyString(thread.threadId) ||
    normalizeNonEmptyString(thread.thread_id);
  const { turns: sanitizedTurns, didSanitize } = sanitizeRelayHistoryTurns(thread.turns, threadId);
  const { thread: threadWithJsonlMetadata, didAugment: didAugmentThreadMetadata } =
    augmentRelayThreadWithJsonlMetadata(thread, threadId);
  const { turns: augmentedTurns, didAugment } = augmentRelayHistoryTurnsWithJsonlArtifacts(
    sanitizedTurns,
    threadId,
  );

  if (!didSanitize && !didAugment && !didAugmentThreadMetadata) {
    const trimmedPayload = trimThreadPayloadForRelay(parsed, thread);
    return trimmedPayload == null ? rawMessage : trimmedPayload;
  }

  const sanitizedPayload = JSON.stringify({
    ...parsed,
    result: {
      ...parsed.result,
      thread: {
        ...threadWithJsonlMetadata,
        turns: augmentedTurns,
      },
    },
  });

  return trimThreadPayloadForRelay(parseBridgeJSON(sanitizedPayload), null) ?? sanitizedPayload;
}

function sanitizeThreadTurnsListForRelay(rawMessage, requestContext = {}) {
  const parsed = parseBridgeJSON(rawMessage);
  const result = parsed?.result;
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return rawMessage;
  }

  const turnsKey = ["data", "items", "turns"].find((key) => Array.isArray(result[key]));
  if (!turnsKey) {
    return rawMessage;
  }

  const threadId =
    normalizeNonEmptyString(requestContext?.threadId) ||
    normalizeNonEmptyString(result.threadId) ||
    normalizeNonEmptyString(result.thread_id) ||
    normalizeNonEmptyString(result.thread?.id) ||
    normalizeNonEmptyString(result.thread?.threadId) ||
    normalizeNonEmptyString(result.thread?.thread_id) ||
    inferThreadIdFromTurns(result[turnsKey]);
  const { turns: sanitizedTurns, didSanitize } = sanitizeRelayHistoryTurns(
    result[turnsKey],
    threadId,
  );
  const shouldAugmentJsonlArtifacts = requestContext?.skipJsonlArtifactAugmentation !== true;
  const { turns: augmentedTurns, didAugment } = shouldAugmentJsonlArtifacts
    ? augmentRelayHistoryTurnsWithJsonlArtifacts(sanitizedTurns, threadId)
    : { turns: sanitizedTurns, didAugment: false };
  const didChange = didSanitize || didAugment;
  const sanitizedParsed = didChange
    ? {
        ...parsed,
        result: {
          ...result,
          [turnsKey]: augmentedTurns,
        },
      }
    : parsed;

  return trimTurnsListPayloadForRelay(sanitizedParsed, turnsKey, didChange ? null : rawMessage);
}

function augmentRelayThreadWithJsonlMetadata(thread, threadId = "") {
  const cwd = readJsonlThreadCwd(threadId);
  if (!cwd || !thread || typeof thread !== "object") {
    return { thread, didAugment: false };
  }

  if (
    normalizeNonEmptyString(thread.cwd) === cwd &&
    normalizeNonEmptyString(thread.current_working_directory) === cwd
  ) {
    return { thread, didAugment: false };
  }

  return {
    thread: {
      ...thread,
      cwd,
      current_working_directory: cwd,
    },
    didAugment: true,
  };
}

function readJsonlThreadCwd(threadId) {
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId) {
    return "";
  }

  try {
    const rolloutPath = findRecentRolloutFileForContextRead(resolveSessionsRoot(), {
      threadId: normalizedThreadId,
    });
    if (!rolloutPath) {
      return "";
    }

    const metadata = parseSessionJsonlMetadata(fs.readFileSync(rolloutPath, "utf8"));
    const cwd = normalizeNonEmptyString(metadata?.cwd);
    return cwd && path.isAbsolute(cwd) ? cwd : "";
  } catch {
    return "";
  }
}

function augmentRelayHistoryTurnsWithJsonlArtifacts(turns, threadId = "") {
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId || !Array.isArray(turns) || turns.length === 0) {
    return { turns, didAugment: false };
  }

  const jsonlArtifactsByTurnId = readJsonlArtifactItemsByTurnId(normalizedThreadId);
  if (jsonlArtifactsByTurnId.size === 0) {
    return { turns, didAugment: false };
  }

  let didAugment = false;
  const augmentedTurns = turns.map((turn) => {
    const turnId =
      normalizeNonEmptyString(turn?.id) ||
      normalizeNonEmptyString(turn?.turnId) ||
      normalizeNonEmptyString(turn?.turn_id);
    const artifacts = turnId ? jsonlArtifactsByTurnId.get(turnId) : null;
    if (!artifacts || !turn || typeof turn !== "object") {
      return turn;
    }

    const items = Array.isArray(turn.items) ? turn.items : [];
    let nextItems = items;
    if (
      artifacts.fileChangeItem &&
      !hasEquivalentFileChangeItem(nextItems, artifacts.fileChangeItem)
    ) {
      nextItems = nextItems === items ? [...items] : nextItems;
      nextItems.push(artifacts.fileChangeItem);
    }
    for (const imageViewItem of artifacts.imageViewItems || []) {
      if (hasEquivalentImageViewItem(nextItems, imageViewItem)) {
        continue;
      }
      nextItems = nextItems === items ? [...items] : nextItems;
      nextItems.push(imageViewItem);
    }
    if (artifacts.progressPlanItem && !hasEquivalentProgressPlanItem(nextItems, artifacts.progressPlanItem)) {
      nextItems = nextItems === items ? [...items] : nextItems;
      nextItems.push(artifacts.progressPlanItem);
    }

    if (nextItems === items) {
      return turn;
    }

    didAugment = true;
    return {
      ...turn,
      items: nextItems,
    };
  });

  return { turns: didAugment ? augmentedTurns : turns, didAugment };
}

function readJsonlArtifactItemsByTurnId(threadId) {
  const emptyArtifactsByTurnId = new Map();
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId) {
    return emptyArtifactsByTurnId;
  }

  const sessionsRoot = resolveSessionsRoot();
  const cacheKey = buildJsonlArtifactItemsCacheKey(sessionsRoot, normalizedThreadId);
  const cachedArtifacts = readCachedJsonlArtifactItems(cacheKey, normalizedThreadId);
  if (cachedArtifacts) {
    return cachedArtifacts;
  }

  try {
    const rolloutPath = findRecentRolloutFileForContextRead(sessionsRoot, {
      threadId: normalizedThreadId,
    });
    if (!rolloutPath) {
      jsonlArtifactItemsCacheByThread.delete(cacheKey);
      return emptyArtifactsByTurnId;
    }

    return readAndCacheJsonlArtifactItems(cacheKey, rolloutPath, normalizedThreadId);
  } catch (error) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    console.warn(
      `[remodex] history jsonl artifact augmentation failed for ${normalizedThreadId}: ${error.message}`,
    );
  }

  return emptyArtifactsByTurnId;
}

function buildJsonlArtifactItemsCacheKey(sessionsRoot, threadId) {
  return `${sessionsRoot}\0${threadId}`;
}

function readCachedJsonlArtifactItems(cacheKey, threadId) {
  const cached = jsonlArtifactItemsCacheByThread.get(cacheKey);
  if (!cached) {
    return null;
  }

  const stat = statJsonlArtifactRollout(cached.rolloutPath);
  if (!stat) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    return null;
  }

  if (stat.mtimeMs !== cached.mtimeMs || stat.size !== cached.size) {
    try {
      return readAndCacheJsonlArtifactItems(cacheKey, cached.rolloutPath, threadId, stat);
    } catch (error) {
      jsonlArtifactItemsCacheByThread.delete(cacheKey);
      console.warn(
        `[remodex] history jsonl artifact cache refresh failed for ${threadId}: ${error.message}`,
      );
      return null;
    }
  }

  const now = Date.now();
  if (now - cached.checkedAt <= RELAY_JSONL_ARTIFACT_CACHE_TTL_MS) {
    return cached.artifactsByTurnId;
  }

  cached.checkedAt = now;
  return null;
}

function readAndCacheJsonlArtifactItems(cacheKey, rolloutPath, threadId, stat = null) {
  const rolloutStat = stat || fs.statSync(rolloutPath);
  const artifactsByTurnId = new Map();
  try {
    const turns = parseSessionJsonlTurns(fs.readFileSync(rolloutPath, "utf8"), { threadId });
    for (const turn of turns) {
      const turnId = normalizeNonEmptyString(turn?.id);
      const turnItems = Array.isArray(turn?.items) ? turn.items : [];
      if (!turnId || turnItems.length === 0) {
        continue;
      }

      const fileChanges = turnItems.filter(
        (item) => normalizeHistoryItemToken(item?.type) === "filechange",
      );
      const progressPlan = turnItems.find(
        (item) =>
          normalizeHistoryItemToken(item?.type) === "plan" &&
          item?.remodexJsonlProgressPlan === true,
      );
      const imageViewItems = turnItems.filter(
        (item) => normalizeHistoryItemToken(item?.type) === "imageview",
      );
      const artifacts = {
        fileChangeItem: null,
        imageViewItems: [],
        progressPlanItem: null,
        imageViewItems,
      };

      const changes = [];
      for (const item of fileChanges) {
        if (Array.isArray(item.changes)) {
          changes.push(...item.changes);
        }
      }
      if (changes.length > 0) {
        artifacts.fileChangeItem = {
          id: `remodex-jsonl-file-change-${turnId}`,
          type: "fileChange",
          status: "completed",
          changes,
          remodexJsonlFileChangeAggregate: true,
        };
      }
      if (progressPlan) {
        artifacts.progressPlanItem = {
          ...progressPlan,
          id: normalizeNonEmptyString(progressPlan.id) || `remodex-jsonl-progress-plan-${turnId}`,
        };
      }
      artifacts.imageViewItems = turnItems
        .filter((item) => normalizeHistoryItemToken(item?.type) === "imageview")
        .map((item, index) => ({
          ...item,
          id: normalizeNonEmptyString(item.id) || `remodex-jsonl-image-view-${turnId}-${index + 1}`,
        }));

      if (artifacts.fileChangeItem || artifacts.progressPlanItem || artifacts.imageViewItems.length > 0) {
        artifactsByTurnId.set(turnId, artifacts);
      }
    }
  } catch (error) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    throw error;
  }

  rememberJsonlArtifactItemsCache(cacheKey, {
    rolloutPath,
    mtimeMs: rolloutStat.mtimeMs,
    size: rolloutStat.size,
    checkedAt: Date.now(),
    artifactsByTurnId,
  });
  return artifactsByTurnId;
}

function statJsonlArtifactRollout(rolloutPath) {
  try {
    return fs.statSync(rolloutPath);
  } catch {
    return null;
  }
}

function rememberJsonlArtifactItemsCache(cacheKey, entry) {
  jsonlArtifactItemsCacheByThread.set(cacheKey, entry);
  while (jsonlArtifactItemsCacheByThread.size > RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES) {
    const oldestKey = jsonlArtifactItemsCacheByThread.keys().next().value;
    if (oldestKey == null) {
      break;
    }
    jsonlArtifactItemsCacheByThread.delete(oldestKey);
  }
}

function hasEquivalentFileChangeItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  const incomingPaths = fileChangePathSet(incomingItem);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "filechange") {
      return false;
    }
    if (incomingId && normalizeNonEmptyString(item.id) === incomingId) {
      return true;
    }
    if (item.remodexJsonlFileChangeAggregate === true) {
      return true;
    }

    const existingPaths = fileChangePathSet(item);
    if (incomingPaths.size === 0 || existingPaths.size === 0) {
      return false;
    }
    for (const pathKey of incomingPaths) {
      if (!existingPaths.has(pathKey)) {
        return false;
      }
    }
    return true;
  });
}

function hasEquivalentProgressPlanItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "plan") {
      return false;
    }
    return (
      item.remodexJsonlProgressPlan === true ||
      (incomingId && normalizeNonEmptyString(item.id) === incomingId)
    );
  });
}

function hasEquivalentImageViewItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  const incomingPath = normalizeNonEmptyString(incomingItem?.path);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "imageview") {
      return false;
    }
    if (incomingId && normalizeNonEmptyString(item.id) === incomingId) {
      return true;
    }
    return incomingPath && normalizeNonEmptyString(item.path) === incomingPath;
  });
}

function hasEquivalentImageViewItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  const incomingPath = normalizeImageViewPathKey(incomingItem);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "imageview") {
      return false;
    }
    const itemId = normalizeNonEmptyString(item.id);
    if (incomingId && itemId === incomingId) {
      return true;
    }
    return incomingPath && normalizeImageViewPathKey(item) === incomingPath;
  });
}

function normalizeImageViewPathKey(item) {
  return normalizeNonEmptyString(item?.path)
    || normalizeNonEmptyString(item?.saved_path)
    || normalizeNonEmptyString(item?.savedPath)
    || normalizeNonEmptyString(item?.file_path)
    || normalizeNonEmptyString(item?.filePath);
}

function fileChangePathSet(item) {
  const paths = new Set();
  const changes = Array.isArray(item?.changes) ? item.changes : [];
  for (const change of changes) {
    const pathKey = normalizeFileChangePathKey(
      change?.path || change?.file || change?.filePath || change?.file_path,
    );
    if (pathKey) {
      paths.add(pathKey);
    }
  }
  return paths;
}

function normalizeFileChangePathKey(value) {
  return normalizeNonEmptyString(value).replace(/\\/g, "/").replace(/^\/+/, "").toLowerCase();
}

function inferThreadIdFromTurns(turns) {
  if (!Array.isArray(turns)) {
    return "";
  }
  for (const turn of turns) {
    const threadId =
      normalizeNonEmptyString(turn?.threadId) ||
      normalizeNonEmptyString(turn?.thread_id) ||
      normalizeNonEmptyString(turn?.thread?.id) ||
      normalizeNonEmptyString(turn?.thread?.threadId) ||
      normalizeNonEmptyString(turn?.thread?.thread_id);
    if (threadId) {
      return threadId;
    }
  }
  return "";
}

function sanitizeRelayHistoryTurns(turns, threadId = "") {
  let didSanitize = false;
  const sanitizedTurns = turns.map((turn) => {
    const sanitizedTurn = sanitizeRelayHistoryTurn(turn, threadId);
    if (sanitizedTurn !== turn) {
      didSanitize = true;
    }
    return sanitizedTurn;
  });

  return { turns: sanitizedTurns, didSanitize };
}

function sanitizeRelayHistoryTurn(turn, threadId = "") {
  if (!turn || typeof turn !== "object" || !Array.isArray(turn.items)) {
    return turn;
  }

  let turnDidChange = false;
  const turnThreadId =
    normalizeNonEmptyString(threadId) ||
    normalizeNonEmptyString(turn.threadId) ||
    normalizeNonEmptyString(turn.thread_id);
  const sanitizedItems = turn.items.map((item) => {
    if (!item || typeof item !== "object") {
      return item;
    }

    let itemDidChange = false;
    let sanitizedItem = convertApplyPatchHistoryItem(item) || item;
    if (sanitizedItem !== item) {
      itemDidChange = true;
    }

    sanitizedItem = annotateImageGenerationHistoryItem(sanitizedItem, turnThreadId);
    if (sanitizedItem !== item) {
      itemDidChange = true;
    }

    if (Array.isArray(sanitizedItem.content)) {
      const sanitizedContent = sanitizedItem.content.map((contentItem) => {
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

  return turnDidChange
    ? {
        ...turn,
        items: sanitizedItems,
      }
    : turn;
}

function convertApplyPatchHistoryItem(item) {
  const itemType = normalizeHistoryItemToken(item?.type);
  const toolName = normalizeNonEmptyString(item?.name);
  if (toolName !== "apply_patch" || itemType !== "customtoolcall") {
    return null;
  }

  const fileChangeItem = buildApplyPatchFileChangeItem({
    callId:
      normalizeNonEmptyString(item.call_id) ||
      normalizeNonEmptyString(item.callId) ||
      normalizeNonEmptyString(item.id),
    patch: normalizeNonEmptyString(item.input),
    status: normalizeNonEmptyString(item.status) || "completed",
    idFallback: normalizeNonEmptyString(item.id) || "history-apply-patch-file-change",
  });
  return fileChangeItem ? { ...item, ...fileChangeItem } : null;
}

function normalizeHistoryItemToken(value) {
  return normalizeNonEmptyString(value)
    .toLowerCase()
    .replace(/[\s_-]+/g, "");
}

// Annotates live image-generation notifications so the phone can render a local-file
// preview and does not receive the bulky inline base64 result over the relay.
function sanitizeLiveGeneratedImageMessageForRelay(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return rawMessage;
  }

  const params = parsed.params;
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return rawMessage;
  }

  const sanitizedParams = sanitizeLiveGeneratedImageParams(params);
  if (sanitizedParams === params) {
    return rawMessage;
  }

  return JSON.stringify({
    ...parsed,
    params: sanitizedParams,
  });
}

function sanitizeLiveGeneratedImageParams(params) {
  const threadId = liveGeneratedImageThreadId(params);
  let nextParams = params;
  let didChange = false;

  const item = params.item;
  if (item && typeof item === "object" && !Array.isArray(item)) {
    const sanitizedItem = annotateImageGenerationPayload(item, threadId);
    if (sanitizedItem !== item) {
      nextParams = { ...nextParams, item: sanitizedItem };
      didChange = true;
    }
  }

  const event = params.event;
  if (event && typeof event === "object" && !Array.isArray(event)) {
    const sanitizedEvent = sanitizeNestedGeneratedImagePayloads(event, threadId);
    if (sanitizedEvent !== event) {
      nextParams = { ...nextParams, event: sanitizedEvent };
      didChange = true;
    }
  }

  const sanitizedDirectParams = annotateImageGenerationPayload(nextParams, threadId);
  if (sanitizedDirectParams !== nextParams) {
    nextParams = sanitizedDirectParams;
    didChange = true;
  }

  return didChange ? nextParams : params;
}

function sanitizeNestedGeneratedImagePayloads(value, threadId) {
  let nextValue = annotateImageGenerationPayload(value, threadId);
  let didChange = nextValue !== value;

  for (const key of ["item", "payload", "data"]) {
    const nested = nextValue?.[key];
    if (!nested || typeof nested !== "object" || Array.isArray(nested)) {
      continue;
    }
    const sanitizedNested = sanitizeNestedGeneratedImagePayloads(nested, threadId);
    if (sanitizedNested !== nested) {
      if (!didChange) {
        nextValue = { ...nextValue };
        didChange = true;
      }
      nextValue[key] = sanitizedNested;
    }
  }

  return didChange ? nextValue : value;
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

function annotateImageGenerationHistoryItem(item, threadId) {
  if (!item || typeof item !== "object") {
    return item;
  }

  const normalizedType = normalizeRelayHistoryContentType(item.type);
  if (!isGeneratedImageRelayType(normalizedType)) {
    return item;
  }

  return annotateImageGenerationPayload(item, threadId);
}

function annotateImageGenerationPayload(item, threadId) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return item;
  }

  const normalizedType = normalizeRelayHistoryContentType(item.type);
  if (!isGeneratedImageRelayType(normalizedType)) {
    return item;
  }

  let nextItem = item;
  let didChange = false;
  const existingPath =
    normalizeNonEmptyString(item.saved_path) ||
    normalizeNonEmptyString(item.savedPath) ||
    normalizeNonEmptyString(item.path) ||
    normalizeNonEmptyString(item.file_path);
  const generatedPath = existingPath || generatedImagePathForHistoryItem(item, threadId);
  if (generatedPath && !existingPath) {
    nextItem = {
      ...nextItem,
      saved_path: generatedPath,
    };
    didChange = true;
  }

  if (typeof nextItem.result === "string" && nextItem.result.length > 0) {
    const { result: _result, ...withoutInlineResult } = nextItem;
    nextItem = {
      ...withoutInlineResult,
      result_elided_for_relay: true,
    };
    didChange = true;
  }

  return didChange ? nextItem : item;
}

function generatedImagePathForHistoryItem(item, threadId) {
  const resolvedThreadId = normalizeNonEmptyString(threadId);
  const normalizedType = normalizeRelayHistoryContentType(item.type);
  const callId =
    normalizedType === "imagegenerationend"
      ? normalizeNonEmptyString(item.call_id) ||
        normalizeNonEmptyString(item.callId) ||
        normalizeNonEmptyString(item.itemId) ||
        normalizeNonEmptyString(item.item_id) ||
        normalizeNonEmptyString(item.id)
      : normalizeNonEmptyString(item.id) ||
        normalizeNonEmptyString(item.call_id) ||
        normalizeNonEmptyString(item.callId) ||
        normalizeNonEmptyString(item.itemId) ||
        normalizeNonEmptyString(item.item_id);
  if (!resolvedThreadId || !callId) {
    return "";
  }

  return path.join(resolveCodexGeneratedImagesRoot(), resolvedThreadId, `${callId}.png`);
}

function isGeneratedImageRelayType(normalizedType) {
  return (
    normalizedType === "imagegeneration" ||
    normalizedType === "imagegenerationcall" ||
    normalizedType === "imagegenerationend" ||
    normalizedType === "imageview"
  );
}

function liveGeneratedImageThreadId(params) {
  const event =
    params?.event && typeof params.event === "object" && !Array.isArray(params.event)
      ? params.event
      : null;
  const item =
    params?.item && typeof params.item === "object" && !Array.isArray(params.item)
      ? params.item
      : null;

  return (
    normalizeNonEmptyString(params?.threadId) ||
    normalizeNonEmptyString(params?.thread_id) ||
    normalizeNonEmptyString(params?.conversationId) ||
    normalizeNonEmptyString(params?.conversation_id) ||
    normalizeNonEmptyString(event?.threadId) ||
    normalizeNonEmptyString(event?.thread_id) ||
    normalizeNonEmptyString(event?.conversationId) ||
    normalizeNonEmptyString(event?.conversation_id) ||
    normalizeNonEmptyString(item?.threadId) ||
    normalizeNonEmptyString(item?.thread_id) ||
    ""
  );
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

  const hasInlineUrl =
    hasInlineHistoryImageDataURL(contentItem.url) ||
    hasInlineHistoryImageDataURL(contentItem.image_url) ||
    hasInlineHistoryImageDataURL(contentItem.path);
  if (!hasInlineUrl) {
    return contentItem;
  }

  const { url: _url, image_url: _imageUrl, path: _path, ...rest } = contentItem;

  return {
    ...rest,
    url: RELAY_HISTORY_IMAGE_REFERENCE_URL,
  };
}

function normalizeRelayHistoryContentType(value) {
  return typeof value === "string" ? value.toLowerCase().replace(/[\s_-]+/g, "") : "";
}

// Covers Codex history variants such as image, local_image, and input_image.
function isRelayHistoryImageContentType(normalizedType) {
  return (
    normalizedType === "image" ||
    normalizedType === "localimage" ||
    normalizedType === "inputimage" ||
    normalizedType === "outputimage"
  );
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
  return safeParseJSON(value);
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
  let trimmedTurns =
    turns.length > RELAY_HISTORY_RECENT_TURN_TARGET
      ? turns.slice(-RELAY_HISTORY_RECENT_TURN_TARGET)
      : turns.slice();
  while (trimmedTurns.length > 1) {
    if (trimmedTurns.length === turns.length) {
      trimmedTurns = trimmedTurns.slice(1);
    }
    const candidateThread = buildRelayHistoryCompactedThread(
      thread,
      buildRelayCompactedHistoryTurns(turns, trimmedTurns),
      Math.max(0, turns.length - trimmedTurns.length),
      trimmedTurns.length,
    );
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (
      encoded != null &&
      Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
    ) {
      return encoded;
    }
    workingThread = candidateThread;
    trimmedTurns = trimmedTurns.slice(1);
  }

  const newestTurn = trimmedTurns[0];
  if (!newestTurn || typeof newestTurn !== "object" || !Array.isArray(newestTurn.items)) {
    return encodeRelayThreadPayload(parsed, workingThread);
  }

  let trimmedItems = newestTurn.items.slice();
  while (trimmedItems.length > 1) {
    trimmedItems = trimmedItems.slice(1);
    const compactedTurnPrefix = buildRelayHistoryCompactionTurn(
      Math.max(0, turns.length - 1),
      1,
      thread,
    );
    const candidateThread = buildRelayHistoryCompactedThread(
      thread,
      compactedTurnPrefix
        ? [
            compactedTurnPrefix,
            {
              ...newestTurn,
              items: trimmedItems,
            },
          ]
        : [
            {
              ...newestTurn,
              items: trimmedItems,
            },
          ],
      Math.max(0, turns.length - 1),
      1,
    );
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (
      encoded != null &&
      Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
    ) {
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
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
  );
  let candidateThread = buildRelayHistoryCompactedThread(
    thread,
    [
      ...buildRelayCompactedHistoryTurns(turns, [newestTurn]).slice(0, -1),
      {
        ...newestTurn,
        items: [truncatedItem],
      },
    ],
    Math.max(0, turns.length - 1),
    1,
  );
  encoded = encodeRelayThreadPayload(parsed, candidateThread);
  if (
    encoded != null &&
    Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
  ) {
    return encoded;
  }

  candidateThread = buildRelayHistoryCompactedThread(
    thread,
    [
      ...buildRelayCompactedHistoryTurns(turns, [newestTurn]).slice(0, -1),
      {
        ...newestTurn,
        items: [compactHistoryItemForRelay(mostRecentItem, RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS)],
      },
    ],
    Math.max(0, turns.length - 1),
    1,
  );
  return encodeRelayThreadPayload(parsed, candidateThread);
}

function trimTurnsListPayloadForRelay(parsed, turnsKey, originalRawMessage = null) {
  const result = parsed?.result;
  const turns = result?.[turnsKey];
  if (!parsed || !result || !Array.isArray(turns)) {
    return originalRawMessage ?? JSON.stringify(parsed);
  }

  const encoded = JSON.stringify(parsed);
  if (Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    return originalRawMessage ?? encoded;
  }

  let fallbackCompactedPayload = null;
  for (const maxChars of [
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
    Math.floor(RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS / 4),
    1_000,
    0,
  ]) {
    const compactedTurns = turns.map((turn) => compactTurnsListTurnForRelay(turn, maxChars));
    const compactedPayload = JSON.stringify({
      ...parsed,
      result: {
        ...result,
        [turnsKey]: compactedTurns,
        remodexPageCompactedForRelay: true,
      },
    });
    fallbackCompactedPayload = compactedPayload;
    if (Buffer.byteLength(compactedPayload, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
      return compactedPayload;
    }
  }

  return fallbackCompactedPayload ?? originalRawMessage ?? encoded;
}

function compactTurnsListTurnForRelay(turn, maxChars) {
  if (!turn || typeof turn !== "object" || !Array.isArray(turn.items)) {
    return turn;
  }

  return {
    ...turn,
    items: turn.items.map((item) => compactHistoryItemForRelay(item, maxChars)),
    remodexPageCompactedForRelay: true,
  };
}

function buildRelayHistoryCompactedThread(thread, turns, omittedTurnCount, keptTurnCount) {
  return {
    ...thread,
    turns,
    historyTailTruncatedForRelay: true,
    remodexHistoryCompacted: omittedTurnCount > 0,
    remodexOmittedTurnCount: omittedTurnCount,
    remodexKeptTurnCount: keptTurnCount,
  };
}

function buildRelayCompactedHistoryTurns(allTurns, keptTurns) {
  const omittedTurnCount = Math.max(0, allTurns.length - keptTurns.length);
  const compactionTurn = buildRelayHistoryCompactionTurn(
    omittedTurnCount,
    keptTurns.length,
    allTurns[0],
  );
  return compactionTurn ? [compactionTurn, ...keptTurns] : keptTurns;
}

function buildRelayHistoryCompactionTurn(omittedTurnCount, keptTurnCount, idSource = {}) {
  if (omittedTurnCount <= 0) {
    return null;
  }

  const baseId =
    normalizeNonEmptyString(idSource?.id) ||
    normalizeNonEmptyString(idSource?.turnId) ||
    normalizeNonEmptyString(idSource?.turn_id) ||
    "history";
  const text = [
    "Earlier conversation compacted for mobile loading.",
    "",
    `Older turns omitted: ${omittedTurnCount}`,
    `Recent turns kept: ${keptTurnCount}`,
    "Full history remains available on the Mac runtime.",
  ].join("\n");

  return {
    id: `remodex-history-compacted-${baseId}`,
    remodexSynthetic: true,
    remodexHistoryCompacted: true,
    remodexOmittedTurnCount: omittedTurnCount,
    remodexKeptTurnCount: keptTurnCount,
    items: [
      {
        id: `remodex-history-compacted-item-${baseId}`,
        type: "assistant_message",
        role: "assistant",
        text,
        remodexSynthetic: true,
        remodexHistoryCompacted: true,
      },
    ],
  };
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
    turnId: typeof item?.turnId === "string" ? item.turnId : undefined,
    turn_id: typeof item?.turn_id === "string" ? item.turn_id : undefined,
    createdAt: relayScalarHistoryMetadata(item?.createdAt),
    created_at: relayScalarHistoryMetadata(item?.created_at),
    startedAt: relayScalarHistoryMetadata(item?.startedAt),
    started_at: relayScalarHistoryMetadata(item?.started_at),
    completedAt: relayScalarHistoryMetadata(item?.completedAt),
    completed_at: relayScalarHistoryMetadata(item?.completed_at),
    timestamp: relayScalarHistoryMetadata(item?.timestamp),
    time: relayScalarHistoryMetadata(item?.time),
    timeZoneIdentifier: relayScalarHistoryMetadata(item?.timeZoneIdentifier),
    timeZone: relayScalarHistoryMetadata(item?.timeZone),
    timezone: relayScalarHistoryMetadata(item?.timezone),
    time_zone: relayScalarHistoryMetadata(item?.time_zone),
    relayPayloadTruncated: true,
  };
  const tailText = maxChars > 0 ? firstRelayTextTail(item, maxChars) : "";
  if (tailText) {
    compactItem.text = tailText;
  }

  return Object.fromEntries(Object.entries(compactItem).filter(([, value]) => value !== undefined));
}

function relayScalarHistoryMetadata(value) {
  return typeof value === "string" || typeof value === "number" ? value : undefined;
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
