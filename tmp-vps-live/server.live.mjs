// FILE: server.mjs
// Purpose: Custom Next.js server with WebSocket relay for Phodex Local Mode.
//          Replaces `next start` — all existing API routes keep working.
//          Adds /relay/{sessionId} WebSocket endpoint for Mac↔iPhone pairing.
//          Adds /v1/pairing/code/resolve for short pairing-code bootstrap.
// Deploy to: /app/codex-backend/server.mjs

import { createServer } from "node:http";
import { parse } from "node:url";
import next from "next";
import { WebSocketServer } from "ws";
import { setupRelay, getRelayStats, resolvePairingCode } from "./src/relay.mjs";

const dev = process.env.NODE_ENV !== "production";
const hostname = process.env.HOSTNAME || "0.0.0.0";
const port = parseInt(process.env.PORT || "3000", 10);

const app = next({ dev, hostname, port });
const handle = app.getRequestHandler();

app.prepare().then(() => {
  const server = createServer((req, res) => {
    const parsedUrl = parse(req.url || "/", true);
    const pathname = parsedUrl.pathname || "/";

    if (req.method === "GET" && pathname === "/relay/health") {
      const stats = getRelayStats();
      const body = JSON.stringify({ ok: true, ...stats });
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
      });
      res.end(body);
      return;
    }

    if (req.method === "POST" && pathname === "/v1/pairing/code/resolve") {
      void handleJSONRoute(req, res, async (body) => resolvePairingCode(body));
      return;
    }

    handle(req, res, parsedUrl);
  });

  const wss = new WebSocketServer({ noServer: true });
  setupRelay(wss);

  server.on("upgrade", (req, socket, head) => {
    if (req.url?.startsWith("/relay/")) {
      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit("connection", ws, req);
      });
    } else {
      socket.destroy();
    }
  });

  server.listen(port, hostname, () => {
    console.log(`[server] Ready on http://${hostname}:${port}`);
    console.log(
      `[server] Relay available at ws://${hostname}:${port}/relay/{sessionId}`
    );
  });
});

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

function writeJSON(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}
