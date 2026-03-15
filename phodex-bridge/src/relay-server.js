// FILE: relay-server.js
// Purpose: Starts a standalone self-hosted Remodex relay with health and stats HTTP endpoints.
// Layer: CLI service
// Exports: DEFAULT_RELAY_HOST, DEFAULT_RELAY_PATH, DEFAULT_RELAY_PORT, listReachableRelayUrls, startRelayServer
// Depends on: node:http, node:os, ./relay-core

const http = require("node:http");
const os = require("node:os");
const { WebSocketServer } = require("ws");
const { setupRelay, getRelayStats } = require("./relay-core");

const DEFAULT_RELAY_HOST = "0.0.0.0";
const DEFAULT_RELAY_PORT = 9000;
const DEFAULT_RELAY_PATH = "/relay";

function startRelayServer({
  host = DEFAULT_RELAY_HOST,
  port = DEFAULT_RELAY_PORT,
} = {}) {
  const normalizedHost = normalizeHost(host);
  const normalizedPort = normalizePort(port, DEFAULT_RELAY_PORT, { allowZero: true });

  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const url = safeParseUrl(req);
      if (!url) {
        writeJson(res, 400, { error: "Invalid URL" });
        return;
      }

      if (req.method === "GET" && url.pathname === "/healthz") {
        writeJson(res, 200, {
          ok: true,
          relayPath: DEFAULT_RELAY_PATH,
          stats: getRelayStats(),
        });
        return;
      }

      if (req.method === "GET" && url.pathname === "/stats") {
        writeJson(res, 200, getRelayStats());
        return;
      }

      if (req.method === "GET" && url.pathname === "/") {
        writeJson(res, 200, {
          name: "remodex-relay",
          ok: true,
          relayPath: DEFAULT_RELAY_PATH,
          healthz: "/healthz",
          stats: "/stats",
        });
        return;
      }

      writeJson(res, 404, { error: "Not found" });
    });

    const wss = new WebSocketServer({ noServer: true });
    setupRelay(wss);

    server.on("upgrade", (req, socket, head) => {
      const url = safeParseUrl(req);
      if (!url || !url.pathname.startsWith(`${DEFAULT_RELAY_PATH}/`)) {
        socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit("connection", ws, req);
      });
    });

    server.once("error", reject);
    server.listen(normalizedPort, normalizedHost, () => {
      server.removeListener("error", reject);
      const address = server.address();
      const listenPort = typeof address === "object" && address ? address.port : normalizedPort;

      resolve({
        host: normalizedHost,
        port: listenPort,
        relayPath: DEFAULT_RELAY_PATH,
        server,
        wss,
        close() {
          return closeRelayServer(server, wss);
        },
      });
    });
  });
}

function closeRelayServer(server, wss) {
  return new Promise((resolve, reject) => {
    wss.close(() => {
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  });
}

function listReachableRelayUrls({ host, port }) {
  const normalizedHost = normalizeHost(host);
  const normalizedPort = normalizePort(port, DEFAULT_RELAY_PORT);
  const candidates = new Set();

  if (normalizedHost === "0.0.0.0" || normalizedHost === "::") {
    for (const address of listExternalIPv4Addresses()) {
      candidates.add(`ws://${address}:${normalizedPort}${DEFAULT_RELAY_PATH}`);
    }
    candidates.add(`ws://127.0.0.1:${normalizedPort}${DEFAULT_RELAY_PATH}`);
  } else {
    const wsHost = formatUrlHost(normalizedHost);
    candidates.add(`ws://${wsHost}:${normalizedPort}${DEFAULT_RELAY_PATH}`);
  }

  return Array.from(candidates);
}

function listExternalIPv4Addresses() {
  const addresses = new Set();
  const interfaces = os.networkInterfaces();

  for (const interfaceEntries of Object.values(interfaces)) {
    for (const entry of interfaceEntries || []) {
      if (!entry || entry.internal || entry.family !== "IPv4") {
        continue;
      }
      addresses.add(entry.address);
    }
  }

  return Array.from(addresses).sort();
}

function writeJson(res, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body, "utf8"),
  });
  res.end(body);
}

function safeParseUrl(req) {
  try {
    return new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
  } catch {
    return null;
  }
}

function normalizeHost(value) {
  if (typeof value !== "string") {
    return DEFAULT_RELAY_HOST;
  }
  const trimmed = value.trim();
  return trimmed || DEFAULT_RELAY_HOST;
}

function formatUrlHost(host) {
  if (host.includes(":") && !(host.startsWith("[") && host.endsWith("]"))) {
    return `[${host}]`;
  }
  return host;
}

function normalizePort(value, fallback, { allowZero = false } = {}) {
  const parsed = Number.parseInt(String(value), 10);
  const minimum = allowZero ? 0 : 1;
  if (!Number.isFinite(parsed) || parsed < minimum || parsed > 65_535) {
    return fallback;
  }
  return parsed;
}

module.exports = {
  DEFAULT_RELAY_HOST,
  DEFAULT_RELAY_PATH,
  DEFAULT_RELAY_PORT,
  listReachableRelayUrls,
  startRelayServer,
};
