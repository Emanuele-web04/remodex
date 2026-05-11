// FILE: relay.mjs
// Purpose: WebSocket relay for Phodex Local Mode.
//          Pairs Mac (running Codex) with iPhone (UI client) via session rooms.
//          Also exposes short pairing-code resolution for newer Remodex clients.
// Deploy to: /app/codex-backend/src/relay.mjs

import { WebSocket } from "ws";

const MAX_HISTORY = 0;
const CLEANUP_DELAY_MS = 5_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_IPHONE_REPLACED = 4003;
const SHORT_PAIRING_CODE_MIN_LENGTH = 8;
const SHORT_PAIRING_CODE_MAX_LENGTH = 12;

/** @type {Map<string, {
 *   mac: WebSocket|null,
 *   clients: Set<WebSocket>,
 *   history: string[],
 *   cleanupTimer: NodeJS.Timeout|null,
 *   macRegistration: {
 *     sessionId: string,
 *     pairingCode: string,
 *     pairingVersion: number,
 *     pairingExpiresAt: number,
 *     macDeviceId: string,
 *     macIdentityPublicKey: string,
 *   } | null
 * }>} */
const sessions = new Map();

/** @type {Map<string, {
 *   sessionId: string,
 *   pairingVersion: number,
 *   pairingExpiresAt: number,
 *   macDeviceId: string,
 *   macIdentityPublicKey: string,
 * }>} */
const liveSessionsByPairingCode = new Map();

function normalizeRelayRole(value) {
  const raw = Array.isArray(value) ? value[0] : value;
  return typeof raw === "string" ? raw.trim().toLowerCase() : "";
}

function isRelayMobileRole(role) {
  return role === "iphone" || role === "android";
}

function readRelayRole(req, urlPath) {
  const headerRole = normalizeRelayRole(req.headers["x-role"]);
  if (headerRole) {
    return headerRole;
  }

  try {
    const queryUrl = new URL(urlPath || "/", "http://relay.local");
    return normalizeRelayRole(queryUrl.searchParams.get("role"));
  } catch {
    return "";
  }
}

/**
 * Attach relay logic to a WebSocketServer.
 * @param {import('ws').WebSocketServer} wss
 */
export function setupRelay(wss) {
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

  wss.on("close", () => clearInterval(heartbeat));

  wss.on("connection", (ws, req) => {
    const urlPath = req.url || "";
    const match = urlPath.match(/^\/relay\/([^/?]+)/);
    const sessionId = match?.[1];
    const role = readRelayRole(req, urlPath);

    if (!sessionId || (role !== "mac" && !isRelayMobileRole(role))) {
      ws.close(4000, "Missing sessionId or invalid x-role header/query");
      return;
    }

    ws._relayAlive = true;
    ws.on("pong", () => {
      ws._relayAlive = true;
    });

    if (isRelayMobileRole(role) && !sessions.has(sessionId)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (!sessions.has(sessionId)) {
      sessions.set(sessionId, {
        mac: null,
        clients: new Set(),
        history: [],
        cleanupTimer: null,
        macRegistration: null,
      });
    }

    const session = sessions.get(sessionId);

    if (isRelayMobileRole(role) && session.mac?.readyState !== WebSocket.OPEN) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (session.cleanupTimer) {
      clearTimeout(session.cleanupTimer);
      session.cleanupTimer = null;
    }

    if (role === "mac") {
      if (session.macRegistration) {
        unregisterLiveMacSession(session.macRegistration);
        session.macRegistration = null;
      }

      if (session.mac && session.mac.readyState === WebSocket.OPEN) {
        session.mac.close(4001, "Replaced by new Mac connection");
      }

      session.mac = ws;
      session.macRegistration = readMacRegistrationHeaders(req.headers, sessionId);
      registerLiveMacSession(session.macRegistration);
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

      for (const msg of session.history) {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(msg);
        }
      }
    }

    ws.on("message", (data) => {
      const msg = typeof data === "string" ? data : data.toString("utf-8");

      if (role === "mac") {
        if (MAX_HISTORY > 0) {
          session.history.push(msg);
          if (session.history.length > MAX_HISTORY) {
            session.history.shift();
          }
        }
        for (const client of session.clients) {
          if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
          }
        }
      } else {
        if (session.mac?.readyState === WebSocket.OPEN) {
          session.mac.send(msg);
        }
      }
    });

    ws.on("close", () => {
      if (role === "mac") {
        if (session.mac === ws) {
          session.mac = null;
          if (session.macRegistration) {
            unregisterLiveMacSession(session.macRegistration);
            session.macRegistration = null;
          }
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
  if (!session) return;
  if (session.mac || session.clients.size > 0) return;
  if (session.cleanupTimer) return;

  session.cleanupTimer = setTimeout(() => {
    const s = sessions.get(sessionId);
    if (s && !s.mac && s.clients.size === 0) {
      if (s.macRegistration) {
        unregisterLiveMacSession(s.macRegistration);
      }
      sessions.delete(sessionId);
      console.log(`[relay] Session ${sessionId} cleaned up`);
    }
  }, CLEANUP_DELAY_MS);
}

/**
 * Resolve a short pairing code into the live session bootstrap payload.
 * @param {{ code?: string, now?: number }} body
 */
export function resolvePairingCode({ code, now = Date.now() } = {}) {
  const normalizedCode = normalizeShortPairingCode(code);
  if (!normalizedCode) {
    throw createRelayError(400, "invalid_request", "The pairing code is missing or malformed.");
  }

  const registration = liveSessionsByPairingCode.get(normalizedCode);
  if (!registration || !hasActiveMacSession(registration.sessionId)) {
    throw createRelayError(404, "pairing_code_unavailable", "This pairing code is unavailable.");
  }

  if (!Number.isFinite(registration.pairingExpiresAt) || now > registration.pairingExpiresAt) {
    liveSessionsByPairingCode.delete(normalizedCode);
    throw createRelayError(410, "pairing_code_expired", "This pairing code has expired.");
  }

  if (
    !registration.macDeviceId
    || !registration.macIdentityPublicKey
    || !Number.isFinite(registration.pairingVersion)
  ) {
    throw createRelayError(409, "pairing_code_incomplete", "The bridge pairing metadata is incomplete.");
  }

  return {
    ok: true,
    v: registration.pairingVersion,
    sessionId: registration.sessionId,
    macDeviceId: registration.macDeviceId,
    macIdentityPublicKey: registration.macIdentityPublicKey,
    expiresAt: registration.pairingExpiresAt,
  };
}

function hasActiveMacSession(sessionId) {
  const session = sessions.get(sessionId);
  return Boolean(session?.mac && session.mac.readyState === WebSocket.OPEN);
}

function registerLiveMacSession(registration) {
  if (!registration?.pairingCode) {
    return;
  }

  liveSessionsByPairingCode.set(registration.pairingCode, {
    sessionId: registration.sessionId,
    pairingVersion: registration.pairingVersion,
    pairingExpiresAt: registration.pairingExpiresAt,
    macDeviceId: registration.macDeviceId,
    macIdentityPublicKey: registration.macIdentityPublicKey,
  });
}

function unregisterLiveMacSession(registration) {
  if (!registration?.pairingCode) {
    return;
  }

  const existing = liveSessionsByPairingCode.get(registration.pairingCode);
  if (existing?.sessionId === registration.sessionId) {
    liveSessionsByPairingCode.delete(registration.pairingCode);
  }
}

function readMacRegistrationHeaders(headers, sessionId) {
  return {
    sessionId,
    pairingCode: normalizeShortPairingCode(headers["x-pairing-code"]),
    pairingVersion: readHeaderInt(headers["x-pairing-version"]),
    pairingExpiresAt: readHeaderInt(headers["x-pairing-expires-at"]),
    macDeviceId: readHeaderString(headers["x-mac-device-id"]),
    macIdentityPublicKey: readHeaderString(headers["x-mac-identity-public-key"]),
  };
}

function readHeaderString(value) {
  if (Array.isArray(value)) {
    value = value[0];
  }
  if (typeof value !== "string") {
    return "";
  }
  return value.trim();
}

function readHeaderInt(value) {
  const normalized = readHeaderString(value);
  if (!normalized) {
    return NaN;
  }
  const parsed = Number.parseInt(normalized, 10);
  return Number.isFinite(parsed) ? parsed : NaN;
}

function normalizeShortPairingCode(code) {
  const normalized = readHeaderString(code)
    .toUpperCase()
    .replace(/[-\s]/g, "");

  if (
    normalized.length < SHORT_PAIRING_CODE_MIN_LENGTH
    || normalized.length > SHORT_PAIRING_CODE_MAX_LENGTH
    || !/^[A-Z2-9]+$/.test(normalized)
  ) {
    return "";
  }

  return normalized;
}

function createRelayError(status, code, message) {
  return Object.assign(new Error(message), {
    status,
    code,
  });
}

/**
 * Returns relay stats for the health endpoint.
 */
export function getRelayStats() {
  let totalClients = 0;
  let sessionsWithMac = 0;
  for (const session of sessions.values()) {
    totalClients += session.clients.size;
    if (session.mac) sessionsWithMac++;
  }
  return {
    activeSessions: sessions.size,
    sessionsWithMac,
    totalClients,
    livePairingCodes: liveSessionsByPairingCode.size,
  };
}
