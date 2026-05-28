// FILE: daemon-bridge-runner.js
// Purpose: Runs the bridge inside an OS-managed background launcher while persisting daemon status.
// Layer: CLI helper
// Exports: runDaemonBridgeService, mergeBridgeStatusForDaemon
// Depends on: ./bridge, ./daemon-state

const { startBridge } = require("./bridge");
const {
  clearPairingSession,
  readBridgeStatus,
  readDaemonConfig,
  writeBridgeStatus,
  writePairingSession,
} = require("./daemon-state");

function runDaemonBridgeService({
  env = process.env,
  processImpl = process,
  consoleImpl = console,
  startBridgeImpl = startBridge,
  missingRelayMessage = "No relay URL configured for the bridge service.",
} = {}) {
  const config = readDaemonConfig({ env });
  if (!config?.relayUrl) {
    clearPairingSession({ env });
    writeBridgeStatus({
      state: "error",
      connectionStatus: "error",
      pid: processImpl.pid,
      lastError: missingRelayMessage,
    }, { env });
    consoleImpl.error(`[remodex] ${missingRelayMessage}`);
    return;
  }

  startBridgeImpl({
    config,
    printPairingQr: false,
    onPairingSession(pairingSession) {
      writePairingSession(pairingSession, { env });
    },
    onBridgeStatus(status) {
      writeBridgeStatus(
        mergeBridgeStatusForDaemon(status, readBridgeStatus({ env })),
        { env }
      );
    },
  });
}

function mergeBridgeStatusForDaemon(nextStatus, persistedStatus) {
  if (!nextStatus || typeof nextStatus !== "object") {
    return nextStatus;
  }

  const lastError = normalizeNonEmptyString(nextStatus.lastError);
  if (lastError || nextStatus.connectionStatus === "connected") {
    return nextStatus;
  }

  if (
    nextStatus.codexLaunchState !== "starting"
    || (nextStatus.connectionStatus !== "starting" && nextStatus.connectionStatus !== "connecting")
  ) {
    return nextStatus;
  }

  const persistedError = normalizeNonEmptyString(persistedStatus?.lastError);
  if (!persistedError) {
    return nextStatus;
  }

  return {
    ...nextStatus,
    lastError: persistedError,
  };
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  mergeBridgeStatusForDaemon,
  runDaemonBridgeService,
};
