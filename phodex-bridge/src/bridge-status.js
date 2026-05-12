// FILE: bridge-status.js
// Purpose: Owns bridge status publishing and stale-relay heartbeat downgrades.
// Layer: CLI service helper
// Exports: createBridgeStatusPublisher, buildHeartbeatBridgeStatus, hasRelayConnectionGoneStale
// Depends on: timers

const BRIDGE_STATUS_HEARTBEAT_INTERVAL_MS = 5_000;
// Keep the watchdog above the relay heartbeat cadence so quiet healthy sockets survive idle gaps.
const RELAY_WATCHDOG_STALE_AFTER_MS = 70_000;
const STALE_RELAY_STATUS_MESSAGE = "Relay heartbeat stalled; reconnect pending.";

// Wraps daemon status publication so bridge.js does not own heartbeat bookkeeping.
function createBridgeStatusPublisher({
  onBridgeStatus = null,
  getCodexLaunchState = () => undefined,
  heartbeatIntervalMs = BRIDGE_STATUS_HEARTBEAT_INTERVAL_MS,
  now = () => Date.now(),
} = {}) {
  let lastPublishedBridgeStatus = null;
  let heartbeatTimer = null;

  function publish(status) {
    const nextStatus = {
      ...status,
      codexLaunchState: getCodexLaunchState(),
    };
    lastPublishedBridgeStatus = nextStatus;
    onBridgeStatus?.(nextStatus);
  }

  function startHeartbeat({
    shouldPublish = () => true,
    getLastRelayActivityAt = () => 0,
  } = {}) {
    if (heartbeatTimer) {
      return;
    }

    heartbeatTimer = setInterval(() => {
      if (!lastPublishedBridgeStatus || !shouldPublish()) {
        return;
      }

      onBridgeStatus?.(buildHeartbeatBridgeStatus(
        lastPublishedBridgeStatus,
        getLastRelayActivityAt(),
        { now: now() }
      ));
    }, heartbeatIntervalMs);
    heartbeatTimer.unref?.();
  }

  function stopHeartbeat() {
    if (!heartbeatTimer) {
      return;
    }

    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }

  return {
    latest() {
      return lastPublishedBridgeStatus;
    },
    publish,
    startHeartbeat,
    stopHeartbeat,
  };
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

module.exports = {
  BRIDGE_STATUS_HEARTBEAT_INTERVAL_MS,
  RELAY_WATCHDOG_STALE_AFTER_MS,
  STALE_RELAY_STATUS_MESSAGE,
  buildHeartbeatBridgeStatus,
  createBridgeStatusPublisher,
  hasRelayConnectionGoneStale,
};
