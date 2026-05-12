// FILE: local-relay.js
// Purpose: Bundled foreground relay for `remodex up` with the same trusted-session and pairing-code routes as the full relay.
// Layer: CLI support
// Exports: createRelayServer
// Depends on: http, ws, ./embedded-relay-core

const http = require("http");
const { WebSocketServer } = require("ws");
const {
  setupRelay,
  getRelayStats,
  resolvePairingCode,
  resolveTrustedMacSession,
} = require("./embedded-relay-core");

function createRelayServer({
  exposeDetailedHealth = false,
} = {}) {
  const server = http.createServer((req, res) => {
    void handleHTTPRequest(req, res, {
      exposeDetailedHealth,
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  setupRelay(wss);

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

  return {
    server,
    wss,
  };
}

async function handleHTTPRequest(req, res, {
  exposeDetailedHealth = false,
} = {}) {
  const pathname = safePathname(req.url);
  if (req.method === "GET" && pathname === "/health") {
    return writeJSON(
      res,
      200,
      exposeDetailedHealth
        ? {
            ok: true,
            relay: getRelayStats(),
          }
        : { ok: true }
    );
  }

  if (req.method === "POST" && pathname === "/v1/trusted/session/resolve") {
    return handleJSONRoute(req, res, async (body) => resolveTrustedMacSession(body));
  }

  if (req.method === "POST" && pathname === "/v1/pairing/code/resolve") {
    return handleJSONRoute(req, res, async (body) => resolvePairingCode(body));
  }

  return writeJSON(res, 404, {
    ok: false,
    error: "Not found",
  });
}

async function handleJSONRoute(req, res, handler) {
  try {
    const body = await readJSONBody(req);
    const result = await handler(body);
    return writeJSON(res, 200, result);
  } catch (error) {
    return writeJSON(res, error.status || 500, {
      ok: false,
      error: error.message || "Internal server error",
      code: error.code || "internal_error",
    });
  }
}

function readJSONBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalSize = 0;

    req.on("data", (chunk) => {
      totalSize += chunk.length;
      if (totalSize > 64 * 1024) {
        reject(Object.assign(new Error("Request body too large"), {
          status: 413,
          code: "body_too_large",
        }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      const rawBody = Buffer.concat(chunks).toString("utf8");
      if (!rawBody.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(rawBody));
      } catch {
        reject(Object.assign(new Error("Invalid JSON body"), {
          status: 400,
          code: "invalid_json",
        }));
      }
    });

    req.on("error", reject);
  });
}

function safePathname(rawUrl) {
  try {
    return new URL(rawUrl || "/", "http://localhost").pathname;
  } catch {
    return "/";
  }
}

function writeJSON(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

module.exports = {
  createRelayServer,
};
