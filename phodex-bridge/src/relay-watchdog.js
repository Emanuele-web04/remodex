// FILE: relay-watchdog.js
// Purpose: Probes silent relay sockets without duplicating healthy relay traffic.
// Layer: Bridge transport helper
// Exports: createRelayWatchdog
// Depends on: ws, ./bridge-status

const WebSocket = require("ws");
const { hasRelayConnectionGoneStale } = require("./bridge-status");

const WATCHDOG_INTERVAL_MS = 10_000;
// The relay already pings every 30s. Incoming messages, pings, and pongs prove
// liveness; only a quiet connection needs an additional client-side probe.
const PROBE_AFTER_IDLE_MS = 30_000;

function createRelayWatchdog({
  socket,
  getLastActivityAt,
  shouldRun = () => true,
  onStale = () => {},
  now = () => Date.now(),
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
}) {
  let stopped = false;
  const timer = setIntervalFn(() => {
    if (stopped || !shouldRun()) {
      stop();
      return;
    }

    if (socket.readyState !== WebSocket.OPEN) {
      return;
    }

    const currentTime = now();
    const lastActivityAt = getLastActivityAt();
    // Preserve the existing 45s stale threshold, including after sleep/wake.
    if (hasRelayConnectionGoneStale(lastActivityAt, { now: currentTime })) {
      stop();
      onStale();
      socket.terminate();
      return;
    }

    if (currentTime - lastActivityAt < PROBE_AFTER_IDLE_MS) {
      return;
    }

    try {
      socket.ping();
    } catch {
      stop();
      socket.terminate();
    }
  }, WATCHDOG_INTERVAL_MS);
  timer.unref?.();

  function stop() {
    if (stopped) {
      return;
    }
    stopped = true;
    clearIntervalFn(timer);
  }

  return { stop };
}

module.exports = { createRelayWatchdog };
