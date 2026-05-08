// FILE: local-relay.js
// Purpose: Bundled foreground relay for `remodex up` so local pairing is one command.
// Layer: CLI support
// Exports: createRelayServer
// Depends on: http, ws

const http = require("http");
const { WebSocketServer, WebSocket } = require("ws");

const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_MOBILE_REPLACED = 4003;
const HEARTBEAT_INTERVAL_MS = 30_000;

function createRelayServer() {
  const sessions = new Map();
  const server = http.createServer((req, res) => {
    if (req.method === "GET" && safePathname(req.url) === "/health") {
      res.statusCode = 200;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    res.statusCode = 404;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ ok: false, error: "Not found" }));
  });
  const wss = new WebSocketServer({ noServer: true });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws._remodexAlive === false) {
        ws.terminate();
        continue;
      }
      ws._remodexAlive = false;
      ws.ping();
    }
  }, HEARTBEAT_INTERVAL_MS);
  heartbeat.unref?.();

  server.on("upgrade", (req, socket, head) => {
    const pathname = safePathname(req.url);
    if (!pathname.startsWith("/relay/")) {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  });

  server.on("close", () => {
    clearInterval(heartbeat);
    for (const session of sessions.values()) {
      session.mac?.close();
      for (const client of session.clients) {
        client.close();
      }
    }
    wss.close();
  });

  wss.on("connection", (ws, req) => {
    const pathname = safePathname(req.url);
    const sessionId = pathname.match(/^\/relay\/([^/?]+)/)?.[1] || "";
    const role = readHeaderString(req.headers["x-role"]).toLowerCase();
    if (!sessionId || (role !== "mac" && role !== "iphone" && role !== "android")) {
      ws.close(4000, "Missing sessionId or invalid x-role header");
      return;
    }

    ws._remodexAlive = true;
    ws.on("pong", () => {
      ws._remodexAlive = true;
    });

    if (role !== "mac" && !sessions.has(sessionId)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    let session = sessions.get(sessionId);
    if (!session) {
      session = {
        mac: null,
        clients: new Set(),
      };
      sessions.set(sessionId, session);
    }

    if (role === "mac") {
      if (session.mac && session.mac.readyState === WebSocket.OPEN) {
        session.mac.close(4001, "Replaced by new Mac connection");
      }
      session.mac = ws;
      console.log(`[relay] Mac connected -> ${relaySessionLogLabel(sessionId)}`);
    } else {
      for (const existingClient of session.clients) {
        if (
          existingClient.readyState === WebSocket.OPEN
          || existingClient.readyState === WebSocket.CONNECTING
        ) {
          existingClient.close(CLOSE_CODE_MOBILE_REPLACED, "Replaced by newer mobile connection");
        }
        session.clients.delete(existingClient);
      }
      session.clients.add(ws);
      console.log(`[relay] Mobile connected (${role}) -> ${relaySessionLogLabel(sessionId)}`);
    }

    ws.on("message", (data) => {
      const msg = typeof data === "string" ? data : data.toString("utf8");
      if (role === "mac") {
        for (const client of session.clients) {
          if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
          }
        }
        return;
      }
      if (session.mac?.readyState === WebSocket.OPEN) {
        session.mac.send(msg);
      } else {
        ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      }
    });

    ws.on("close", () => {
      if (role === "mac") {
        if (session.mac === ws) {
          session.mac = null;
          console.log(`[relay] Mac disconnected -> ${relaySessionLogLabel(sessionId)}`);
        }
      } else {
        session.clients.delete(ws);
        console.log(`[relay] Mobile disconnected (${role}) -> ${relaySessionLogLabel(sessionId)}`);
      }
      if (!session.mac && session.clients.size === 0) {
        sessions.delete(sessionId);
      }
    });

    ws.on("error", (error) => {
      console.error(`[relay] ${role} ${relaySessionLogLabel(sessionId)} error: ${error.message}`);
    });
  });

  return {
    server,
    wss,
  };
}

function safePathname(rawUrl) {
  try {
    return new URL(rawUrl || "/", "http://localhost").pathname;
  } catch {
    return "/";
  }
}

function readHeaderString(value) {
  if (Array.isArray(value)) {
    return String(value[0] || "");
  }
  return String(value || "");
}

function relaySessionLogLabel(sessionId) {
  return sessionId ? `session#${sessionId.slice(0, 8)}` : "session#unknown";
}

module.exports = {
  createRelayServer,
};
