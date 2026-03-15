// FILE: relay-core.js
// Purpose: Shared Remodex WebSocket relay logic for hosted and self-hosted servers.
// Layer: Transport helper
// Exports: getRelayStats, hasActiveMacSession, hasAuthenticatedMacSession, setupRelay
// Depends on: ws

const { WebSocket } = require("ws");

const CLEANUP_DELAY_MS = 60_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_IPHONE_REPLACED = 4003;

const sessions = new Map();

function setupRelay(wss) {
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

    if (role === "iphone" && !sessions.has(sessionId)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (!sessions.has(sessionId)) {
      sessions.set(sessionId, {
        mac: null,
        clients: new Set(),
        cleanupTimer: null,
        notificationSecret: null,
      });
    }

    const session = sessions.get(sessionId);

    if (role === "iphone" && session.mac?.readyState !== WebSocket.OPEN) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (session.cleanupTimer) {
      clearTimeout(session.cleanupTimer);
      session.cleanupTimer = null;
    }

    if (role === "mac") {
      // Bind push registration to a live bridge socket, not just a public session id.
      session.notificationSecret = readHeaderString(req.headers["x-notification-secret"]);
      if (session.mac && session.mac.readyState === WebSocket.OPEN) {
        session.mac.close(4001, "Replaced by new Mac connection");
      }
      session.mac = ws;
      console.log(`[relay] Mac connected -> session ${sessionId}`);
    } else {
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
        `[relay] iPhone connected -> session ${sessionId} (${session.clients.size} client(s))`
      );
    }

    ws.on("message", (data) => {
      const msg = typeof data === "string" ? data : data.toString("utf-8");
      console.log(
        `[relay] forwarded ${role} -> session ${sessionId} (${Buffer.byteLength(msg, "utf8")} bytes)`
      );

      if (role === "mac") {
        for (const client of session.clients) {
          if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
          }
        }
      } else if (session.mac?.readyState === WebSocket.OPEN) {
        session.mac.send(msg);
      }
    });

    ws.on("close", () => {
      if (role === "mac") {
        if (session.mac === ws) {
          session.mac = null;
          session.notificationSecret = null;
          console.log(`[relay] Mac disconnected -> session ${sessionId}`);
          for (const client of session.clients) {
            if (client.readyState === WebSocket.OPEN || client.readyState === WebSocket.CONNECTING) {
              client.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac disconnected");
            }
          }
        }
      } else {
        session.clients.delete(ws);
        console.log(
          `[relay] iPhone disconnected -> session ${sessionId} (${session.clients.size} remaining)`
        );
      }
      scheduleCleanup(sessionId);
    });

    ws.on("error", (err) => {
      console.error(
        `[relay] WebSocket error (${role}, session ${sessionId}):`,
        err.message
      );
    });
  });
}

function scheduleCleanup(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) {
    return;
  }
  if (session.mac || session.clients.size > 0 || session.cleanupTimer) {
    return;
  }

  session.cleanupTimer = setTimeout(() => {
    const activeSession = sessions.get(sessionId);
    if (activeSession && !activeSession.mac && activeSession.clients.size === 0) {
      sessions.delete(sessionId);
      console.log(`[relay] Session ${sessionId} cleaned up`);
    }
  }, CLEANUP_DELAY_MS);
  session.cleanupTimer.unref?.();
}

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

function hasActiveMacSession(sessionId) {
  if (typeof sessionId !== "string" || !sessionId.trim()) {
    return false;
  }

  const session = sessions.get(sessionId.trim());
  return Boolean(session?.mac && session.mac.readyState === WebSocket.OPEN);
}

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
  getRelayStats,
  hasActiveMacSession,
  hasAuthenticatedMacSession,
  setupRelay,
};
