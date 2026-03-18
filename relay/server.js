// FILE: server.js
// Purpose: Hosts the public Remodex relay plus optional push-notification HTTP endpoints.
// Layer: Standalone server entrypoint
// Exports: createRelayServer, createFixedWindowRateLimiter
// Depends on: http, ws, ./relay, ./push-service

const http = require("http");
const { WebSocketServer } = require("ws");
const {
  setupRelay,
  getRelayStats,
  hasAuthenticatedMacSession,
  resolveTrustedMacSession,
} = require("./relay");
const { createPushSessionService } = require("./push-service");

function createRelayServer({
  enablePushService = false,
  exposeDetailedHealth = false,
  httpRateLimiter = createFixedWindowRateLimiter({ windowMs: 60_000, maxRequests: 120 }),
  pushRateLimiter = createFixedWindowRateLimiter({ windowMs: 60_000, maxRequests: 30 }),
  upgradeRateLimiter = createFixedWindowRateLimiter({ windowMs: 60_000, maxRequests: 60 }),
  pushSessionService,
  relayOptions = {},
  trustProxy = false,
} = {}) {
  const pushEnabled = Boolean(enablePushService || pushSessionService);
  const resolvedPushSessionService = pushEnabled
    ? (pushSessionService || createPushSessionService({
      // The first registration must match the live bridge's secret, not just the session id.
      canRegisterSession({ sessionId, notificationSecret }) {
        return hasAuthenticatedMacSession(sessionId, notificationSecret);
      },
      // Completion pushes are only valid while the Mac side of that relay session is still live.
      canNotifyCompletion({ sessionId, notificationSecret }) {
        return hasAuthenticatedMacSession(sessionId, notificationSecret);
      },
    }))
    : createDisabledPushSessionService();

  const server = http.createServer((req, res) => {
    void handleHTTPRequest(req, res, {
      exposeDetailedHealth,
      httpRateLimiter,
      pushEnabled,
      pushRateLimiter,
      pushSessionService: resolvedPushSessionService,
      trustProxy,
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  setupRelay(wss, relayOptions);

  server.on("upgrade", (req, socket, head) => {
    const pathname = safePathname(req.url);
    const loggedPathname = redactRelayPathname(pathname);
    console.log(
      `[relay] upgrade request path=${loggedPathname} remote=${clientAddressKey(req, { trustProxy })} `
      + `role=${readHeaderString(req.headers["x-role"]) || "missing"}`
    );
    if (!pathname.startsWith("/relay/")) {
      console.log(`[relay] rejecting upgrade for non-relay path: ${loggedPathname}`);
      socket.destroy();
      return;
    }

    if (!upgradeRateLimiter.allow(clientAddressKey(req, { trustProxy }))) {
      console.log(`[relay] rejecting upgrade due to rate limit: ${loggedPathname}`);
      socket.write(
        "HTTP/1.1 429 Too Many Requests\r\n" +
        "Connection: close\r\n" +
        "Retry-After: 60\r\n\r\n"
      );
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
    pushSessionService: resolvedPushSessionService,
  };
}

async function handleHTTPRequest(req, res, {
  exposeDetailedHealth,
  httpRateLimiter,
  pushEnabled,
  pushRateLimiter,
  pushSessionService,
  trustProxy,
}) {
  const pathname = safePathname(req.url);
  if (req.method === "GET" && pathname === "/health") {
    return writeJSON(
      res,
      200,
      exposeDetailedHealth
        ? {
            ok: true,
            relay: getRelayStats(),
            push: pushSessionService.getStats(),
          }
        : { ok: true }
    );
  }

  const requestKey = clientAddressKey(req, { trustProxy });
  if (!httpRateLimiter.allow(requestKey)) {
    return writeRateLimitResponse(res);
  }

  if (req.method === "POST" && pathname === "/v1/push/session/register-device") {
    if (!pushEnabled) {
      return writeJSON(res, 404, {
        ok: false,
        error: "Not found",
      });
    }
    if (!pushRateLimiter.allow(`${requestKey}:register-device`)) {
      return writeRateLimitResponse(res);
    }
    return handleJSONRoute(req, res, async (body) => pushSessionService.registerDevice(body));
  }

  if (req.method === "POST" && pathname === "/v1/push/session/notify-completion") {
    if (!pushEnabled) {
      return writeJSON(res, 404, {
        ok: false,
        error: "Not found",
      });
    }
    if (!pushRateLimiter.allow(`${requestKey}:notify-completion`)) {
      return writeRateLimitResponse(res);
    }
    return handleJSONRoute(req, res, async (body) => pushSessionService.notifyCompletion(body));
  }

  if (req.method === "POST" && pathname === "/v1/trusted/session/resolve") {
    return handleJSONRoute(req, res, async (body) => resolveTrustedMacSession(body));
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

function writeJSON(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function writeRateLimitResponse(res) {
  res.setHeader("retry-after", "60");
  return writeJSON(res, 429, {
    ok: false,
    error: "Too many requests",
    code: "rate_limited",
  });
}

function createDisabledPushSessionService() {
  return {
    getStats() {
      return {
        enabled: false,
        registeredSessions: 0,
        deliveredDedupeKeys: 0,
        apnsConfigured: false,
      };
    },
  };
}

function safePathname(rawUrl) {
  try {
    return new URL(rawUrl || "/", "http://localhost").pathname;
  } catch {
    return "/";
  }
}

// Hides bearer-like relay session ids from operational logs while preserving route shape.
function redactRelayPathname(pathname) {
  if (typeof pathname !== "string" || !pathname.startsWith("/relay/")) {
    return pathname || "/";
  }

  const [, relayPrefix, ...rest] = pathname.split("/");
  const suffix = rest.length > 1 ? `/${rest.slice(1).join("/")}` : "";
  return `/${relayPrefix}/[session]${suffix}`;
}

// Trust forwarded client IPs only when a known reverse proxy sits in front of the relay.
function clientAddressKey(req, { trustProxy = false } = {}) {
  if (trustProxy) {
    return forwardedClientAddress(req) || req?.socket?.remoteAddress || "unknown";
  }
  return req?.socket?.remoteAddress || "unknown";
}

function forwardedClientAddress(req) {
  const xRealIP = readHeaderString(req?.headers?.["x-real-ip"]);
  if (xRealIP) {
    return xRealIP;
  }

  const xForwardedFor = readHeaderString(req?.headers?.["x-forwarded-for"]);
  if (xForwardedFor) {
    const forwardedHops = xForwardedFor
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    const clientHop = forwardedHops[0];
    if (clientHop) {
      return clientHop;
    }
  }

  return "";
}

function readHeaderString(value) {
  const candidate = Array.isArray(value) ? value[0] : value;
  return typeof candidate === "string" && candidate.trim() ? candidate.trim() : "";
}

// Reads an opt-in boolean flag for hosted deployments without changing local/self-host defaults.
function readOptionalBooleanEnv(keys, env = process.env) {
  const truthy = new Set(["1", "true", "yes", "on"]);
  const falsy = new Set(["0", "false", "no", "off"]);

  for (const key of keys) {
    const rawValue = env?.[key];
    if (typeof rawValue !== "string" || !rawValue.trim()) {
      continue;
    }
    const normalizedValue = rawValue.trim().toLowerCase();
    if (truthy.has(normalizedValue)) {
      return true;
    }
    if (falsy.has(normalizedValue)) {
      return false;
    }
  }

  return undefined;
}

function createFixedWindowRateLimiter({ windowMs, maxRequests, now = () => Date.now() } = {}) {
  const buckets = new Map();
  const resolvedWindowMs = Number.isFinite(windowMs) && windowMs > 0 ? windowMs : 60_000;
  const resolvedMaxRequests = Number.isFinite(maxRequests) && maxRequests > 0 ? maxRequests : 60;
  let nextPruneAt = 0;

  return {
    allow(key) {
      const normalizedKey = typeof key === "string" && key.trim() ? key.trim() : "unknown";
      const timestamp = now();
      if (timestamp >= nextPruneAt) {
        nextPruneAt = timestamp + resolvedWindowMs;
        for (const [bucketKey, bucketValue] of buckets.entries()) {
          if (timestamp >= bucketValue.expiresAt) {
            buckets.delete(bucketKey);
          }
        }
      }
      const bucket = buckets.get(normalizedKey);

      if (!bucket || timestamp >= bucket.expiresAt) {
        buckets.set(normalizedKey, {
          count: 1,
          expiresAt: timestamp + resolvedWindowMs,
        });
        return true;
      }

      if (bucket.count >= resolvedMaxRequests) {
        return false;
      }

      bucket.count += 1;
      return true;
    },
    bucketCount() {
      return buckets.size;
    },
  };
}

if (require.main === module) {
  const port = Number(process.env.PORT || 9000);
  const trustProxy = readOptionalBooleanEnv(["REMODEX_TRUST_PROXY", "PHODEX_TRUST_PROXY"]) ?? false;
  const enablePushService = readOptionalBooleanEnv(
    ["REMODEX_ENABLE_PUSH_SERVICE", "PHODEX_ENABLE_PUSH_SERVICE"]
  ) ?? false;
  const { server } = createRelayServer({ enablePushService, trustProxy });
  server.listen(port, () => {
    console.log(`[relay] listening on :${port}`);
  });
}

module.exports = {
  createRelayServer,
  createFixedWindowRateLimiter,
  clientAddressKey,
  readOptionalBooleanEnv,
  redactRelayPathname,
};
