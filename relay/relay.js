// FILE: relay.js
// Purpose: Thin self-hostable WebSocket relay for Remodex pairing and encrypted message forwarding.
// Layer: Standalone server module
// Exports: setupRelay, getRelayStats, hasActiveMacSession, hasAuthenticatedMacSession

const { createHash } = require("crypto");
const { WebSocket } = require("ws");

const CLEANUP_DELAY_MS = 60_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_IPHONE_REPLACED = 4003;
const CLOSE_CODE_MAC_ABSENCE_BUFFER_FULL = 4004;
const MAC_ABSENCE_GRACE_MS = 15_000;

// In-memory session registry for one Mac host and one live iPhone client per session.
const sessions = new Map();

// Attaches relay behavior to a ws WebSocketServer instance.
function setupRelay(
  wss,
  {
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
    macAbsenceGraceMs = MAC_ABSENCE_GRACE_MS,
  } = {}
) {
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws._relayAlive === false) {
        ws.terminate();
        continue;
      }
      ws._relayAlive = false;
      ws.ping();
    }
  }, HEARTBEAT_INTERVAL_MS);
  heartbeat.unref?.();

  wss.on("close", () => clearInterval(heartbeat));

  wss.on("connection", (ws, req) => {
    const urlPath = req.url || "";
    const match = urlPath.match(/^\/relay\/([^/?]+)/);
    const sessionId = match?.[1];
    const role = req.headers["x-role"];

    if (!sessionId || (role !== "mac" && role !== "iphone")) {
      ws.close(4000, "Missing sessionId or invalid x-role header");
      return;
    }

    ws._relayAlive = true;
    ws.on("pong", () => {
      ws._relayAlive = true;
    });

    // Only the Mac host is allowed to create a fresh session room.
    if (role === "iphone" && !sessions.has(sessionId)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (!sessions.has(sessionId)) {
      sessions.set(sessionId, {
        mac: null,
        clients: new Set(),
        cleanupTimer: null,
        macAbsenceTimer: null,
        notificationSecret: null,
      });
    }

    const session = sessions.get(sessionId);

    if (role === "iphone" && !canAcceptIphoneConnection(session)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (session.cleanupTimer) {
      clearTimeoutFn(session.cleanupTimer);
      session.cleanupTimer = null;
    }

    if (role === "mac") {
      clearMacAbsenceTimer(session, { clearTimeoutFn });
      // The relay keeps a per-session push secret so first-time device registration
      // cannot be claimed by someone who only knows the session id.
      session.notificationSecret = readHeaderString(req.headers["x-notification-secret"]);
      if (session.mac && session.mac.readyState === WebSocket.OPEN) {
        session.mac.close(4001, "Replaced by new Mac connection");
      }
      session.mac = ws;
      console.log(`[relay] Mac connected -> ${relaySessionLogLabel(sessionId)}`);
    } else {
      // Keep one live iPhone RPC client per session to avoid competing sockets.
      for (const existingClient of session.clients) {
        if (existingClient === ws) {
          continue;
        }
        if (
          existingClient.readyState === WebSocket.OPEN
          || existingClient.readyState === WebSocket.CONNECTING
        ) {
          existingClient.close(
            CLOSE_CODE_IPHONE_REPLACED,
            "Replaced by newer iPhone connection"
          );
        }
        session.clients.delete(existingClient);
      }

      session.clients.add(ws);
      console.log(
        `[relay] iPhone connected -> ${relaySessionLogLabel(sessionId)} `
        + `(${session.clients.size} client(s))`
      );
    }

    ws.on("message", (data) => {
      const msg = typeof data === "string" ? data : data.toString("utf-8");

      if (role === "mac") {
        for (const client of session.clients) {
          if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
          }
        }
      } else if (session.mac?.readyState === WebSocket.OPEN) {
        session.mac.send(msg);
      } else {
        // The relay cannot prove a buffered request really reached the bridge after
        // a reconnect, so fail fast with an explicit retry-required close instead
        // of silently dropping queued client work during a later flush.
        ws.close(CLOSE_CODE_MAC_ABSENCE_BUFFER_FULL, "Mac temporarily unavailable");
      }
    });

    ws.on("close", () => {
      if (role === "mac") {
        if (session.mac === ws) {
          session.mac = null;
          console.log(`[relay] Mac disconnected -> ${relaySessionLogLabel(sessionId)}`);
          if (session.clients.size > 0) {
            scheduleMacAbsenceTimeout(sessionId, {
              macAbsenceGraceMs,
              setTimeoutFn,
              clearTimeoutFn,
            });
          } else {
            scheduleCleanup(sessionId, { setTimeoutFn });
          }
        }
      } else {
        session.clients.delete(ws);
        console.log(
          `[relay] iPhone disconnected -> ${relaySessionLogLabel(sessionId)} `
          + `(${session.clients.size} remaining)`
        );
      }
      scheduleCleanup(sessionId, { setTimeoutFn });
    });

    ws.on("error", (err) => {
      console.error(
        `[relay] WebSocket error (${role}, ${relaySessionLogLabel(sessionId)}):`,
        err.message
      );
    });
  });
}

function scheduleCleanup(sessionId, { setTimeoutFn = setTimeout } = {}) {
  const session = sessions.get(sessionId);
  if (!session) {
    return;
  }
  if (session.mac || session.clients.size > 0 || session.cleanupTimer || session.macAbsenceTimer) {
    return;
  }

  session.cleanupTimer = setTimeoutFn(() => {
    const activeSession = sessions.get(sessionId);
    if (
      activeSession
      && !activeSession.mac
      && activeSession.clients.size === 0
      && !activeSession.macAbsenceTimer
    ) {
      sessions.delete(sessionId);
      console.log(`[relay] ${relaySessionLogLabel(sessionId)} cleaned up`);
    }
  }, CLEANUP_DELAY_MS);
  session.cleanupTimer.unref?.();
}

function scheduleMacAbsenceTimeout(
  sessionId,
  {
    macAbsenceGraceMs,
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
  } = {}
) {
  const session = sessions.get(sessionId);
  if (!session || session.mac || session.macAbsenceTimer) {
    return;
  }

  session.macAbsenceTimer = setTimeoutFn(() => {
    const activeSession = sessions.get(sessionId);
    if (!activeSession) {
      return;
    }

    activeSession.macAbsenceTimer = null;
    activeSession.notificationSecret = null;
    closeSessionClients(activeSession, CLOSE_CODE_SESSION_UNAVAILABLE, "Mac disconnected");
    scheduleCleanup(sessionId, { setTimeoutFn });
  }, macAbsenceGraceMs);
  session.macAbsenceTimer.unref?.();

  if (session.cleanupTimer) {
    clearTimeoutFn(session.cleanupTimer);
    session.cleanupTimer = null;
  }
}

function clearMacAbsenceTimer(session, { clearTimeoutFn = clearTimeout } = {}) {
  if (!session?.macAbsenceTimer) {
    return;
  }

  clearTimeoutFn(session.macAbsenceTimer);
  session.macAbsenceTimer = null;
}

function canAcceptIphoneConnection(session) {
  if (!session) {
    return false;
  }

  if (session.mac?.readyState === WebSocket.OPEN) {
    return true;
  }

  // Lets the phone rejoin the same relay session while the Mac is still inside
  // the temporary-absence grace window instead of forcing a full disconnect flow.
  return Boolean(session.macAbsenceTimer);
}

function closeSessionClients(session, code, reason) {
  for (const client of session.clients) {
    if (client.readyState === WebSocket.OPEN || client.readyState === WebSocket.CONNECTING) {
      client.close(code, reason);
    }
  }
}

function relaySessionLogLabel(sessionId) {
  const normalizedSessionId = typeof sessionId === "string" ? sessionId.trim() : "";
  if (!normalizedSessionId) {
    return "session=[redacted]";
  }

  const digest = createHash("sha256")
    .update(normalizedSessionId)
    .digest("hex")
    .slice(0, 8);
  return `session#${digest}`;
}

// Exposes lightweight runtime stats for health/status endpoints.
function getRelayStats() {
  let totalClients = 0;
  let sessionsWithMac = 0;

  for (const session of sessions.values()) {
    totalClients += session.clients.size;
    if (session.mac) {
      sessionsWithMac += 1;
    }
  }

  return {
    activeSessions: sessions.size,
    sessionsWithMac,
    totalClients,
  };
}

// Lets the push-registration side verify that a session still belongs to a live Mac bridge.
function hasActiveMacSession(sessionId) {
  if (typeof sessionId !== "string" || !sessionId.trim()) {
    return false;
  }

  const session = sessions.get(sessionId.trim());
  return Boolean(session?.mac && session.mac.readyState === WebSocket.OPEN);
}

// Used by: relay/server.js push registration gate.
function hasAuthenticatedMacSession(sessionId, notificationSecret) {
  if (!hasActiveMacSession(sessionId)) {
    return false;
  }

  const session = sessions.get(sessionId.trim());
  return session?.notificationSecret === readHeaderString(notificationSecret);
}

function readHeaderString(value) {
  const candidate = Array.isArray(value) ? value[0] : value;
  return typeof candidate === "string" && candidate.trim() ? candidate.trim() : null;
}

module.exports = {
  setupRelay,
  getRelayStats,
  hasActiveMacSession,
  hasAuthenticatedMacSession,
};
