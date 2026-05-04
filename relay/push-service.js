// FILE: push-service.js
// Purpose: Stores session-scoped APNs registration state and sends completion pushes for relay-hosted Remodex sessions.
// Layer: Hosted service helper
// Exports: createPushSessionService, createFileBackedPushStateStore, resolvePushStateFilePath
// Depends on: crypto, fs, os, path, ./apns-client

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createAPNsClient } = require("./apns-client");

const PUSH_DEDUPE_TTL_MS = 24 * 60 * 60 * 1000;
const PUSH_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const PUSH_PREVIEW_MAX_CHARS = 160;

function createPushSessionService({
  apnsClient = createAPNsClient(apnsConfigFromEnv(process.env)),
  canRegisterSession = () => true,
  canNotifyCompletion = null,
  now = () => Date.now(),
  logPrefix = "[relay]",
  stateStore = createFileBackedPushStateStore({
    stateFilePath: resolvePushStateFilePath(process.env),
  }),
} = {}) {
  const resolvedCanNotifyCompletion = typeof canNotifyCompletion === "function"
    ? canNotifyCompletion
    : canRegisterSession;
  const persistedState = stateStore.read();
  const sessions = new Map(persistedState.sessions || []);
  const deliveredDedupeKeys = new Map(persistedState.deliveredDedupeKeys || []);
  pruneStaleState();

  async function registerDevice({
    sessionId,
    notificationSecret,
    deviceToken,
    alertsEnabled,
    apnsEnvironment,
  } = {}) {
    const normalizedSessionId = readString(sessionId);
    const normalizedSecret = readString(notificationSecret);
    const normalizedDeviceToken = normalizeDeviceToken(deviceToken);

    if (!normalizedSessionId || !normalizedSecret || !normalizedDeviceToken) {
      throw pushServiceError(
        "invalid_request",
        "Push registration requires sessionId, notificationSecret, and deviceToken.",
        400
      );
    }

    if (!await canRegisterSession({
      sessionId: normalizedSessionId,
      notificationSecret: normalizedSecret,
    })) {
      throw pushServiceError(
        "session_unavailable",
        "Push registration requires an active relay session.",
        403
      );
    }

    const existing = sessions.get(normalizedSessionId);
    if (existing && !secretsEqual(existing.notificationSecret, normalizedSecret)) {
      throw pushServiceError("unauthorized", "Invalid notification secret for this session.", 403);
    }

    sessions.set(normalizedSessionId, {
      notificationSecret: normalizedSecret,
      deviceToken: normalizedDeviceToken,
      alertsEnabled: Boolean(alertsEnabled),
      apnsEnvironment: apnsEnvironment === "development" ? "development" : "production",
      updatedAt: now(),
    });
    persistState("registerDevice");
    return { ok: true };
  }

  async function notifyCompletion({
    sessionId,
    notificationSecret,
    threadId,
    turnId,
    result,
    title,
    body,
    dedupeKey,
  } = {}) {
    const normalizedSessionId = readString(sessionId);
    const normalizedSecret = readString(notificationSecret);
    const normalizedThreadId = readString(threadId);
    const normalizedResult = result === "failed" ? "failed" : "completed";
    const normalizedDedupeKey = readString(dedupeKey);

    if (!normalizedSessionId || !normalizedSecret || !normalizedThreadId || !normalizedDedupeKey) {
      throw pushServiceError(
        "invalid_request",
        "Push completion requires sessionId, notificationSecret, threadId, and dedupeKey.",
        400
      );
    }

    if (!await resolvedCanNotifyCompletion({
      sessionId: normalizedSessionId,
      notificationSecret: normalizedSecret,
    })) {
      throw pushServiceError(
        "session_unavailable",
        "Push completion requires an active relay session.",
        403
      );
    }

    pruneDeliveredDedupeKeys();
    if (deliveredDedupeKeys.has(normalizedDedupeKey)) {
      return { ok: true, deduped: true };
    }

    const session = sessions.get(normalizedSessionId);
    if (!session || !secretsEqual(session.notificationSecret, normalizedSecret)) {
      throw pushServiceError("unauthorized", "Invalid notification secret for this session.", 403);
    }

    if (!session.alertsEnabled || !session.deviceToken) {
      return { ok: true, skipped: true };
    }

    await apnsClient.sendNotification({
      deviceToken: session.deviceToken,
      apnsEnvironment: session.apnsEnvironment,
      title: normalizePreviewText(title) || "Conversation",
      body: normalizePreviewText(body) || fallbackBodyForResult(normalizedResult),
      payload: {
        source: "codex.runCompletion",
        threadId: normalizedThreadId,
        turnId: readString(turnId) || "",
        result: normalizedResult,
      },
    });

    deliveredDedupeKeys.set(normalizedDedupeKey, now());
    persistState("notifyCompletion");
    return { ok: true };
  }

  function getStats() {
    pruneDeliveredDedupeKeys();
    return {
      registeredSessions: sessions.size,
      deliveredDedupeKeys: deliveredDedupeKeys.size,
      apnsConfigured: apnsClient.isConfigured(),
    };
  }

  function pruneDeliveredDedupeKeys() {
    let didChange = false;
    const cutoff = now() - PUSH_DEDUPE_TTL_MS;
    for (const [key, timestamp] of deliveredDedupeKeys.entries()) {
      if (timestamp < cutoff) {
        deliveredDedupeKeys.delete(key);
        didChange = true;
      }
    }
    return didChange;
  }

  function pruneSessions() {
    let didChange = false;
    const cutoff = now() - PUSH_SESSION_TTL_MS;
    for (const [sessionId, session] of sessions.entries()) {
      if (Number(session?.updatedAt || 0) < cutoff) {
        sessions.delete(sessionId);
        didChange = true;
      }
    }
    return didChange;
  }

  function pruneStaleState() {
    if (pruneDeliveredDedupeKeys() || pruneSessions()) {
      persistState("pruneStaleState");
    }
  }

  // Keeps live registrations usable even if the optional state file cannot be updated.
  function persistState(reason) {
    try {
      stateStore.write({
        sessions: [...sessions.entries()],
        deliveredDedupeKeys: [...deliveredDedupeKeys.entries()],
      });
    } catch (error) {
      console.error(
        `${logPrefix} push state persistence failed during ${reason}: ${error.message}`
      );
    }
  }

  return {
    registerDevice,
    notifyCompletion,
    getStats,
  };
}

function createFileBackedPushStateStore({ stateFilePath } = {}) {
  const resolvedPath = typeof stateFilePath === "string" && stateFilePath.trim()
    ? stateFilePath.trim()
    : "";

  return {
    read() {
      if (!resolvedPath || !fs.existsSync(resolvedPath)) {
        return emptyPushState();
      }

      const parsed = safeParseJSON(fs.readFileSync(resolvedPath, "utf8"));
      if (!parsed || typeof parsed !== "object") {
        return emptyPushState();
      }

      return {
        sessions: normalizeEntryList(parsed.sessions),
        deliveredDedupeKeys: normalizeEntryList(parsed.deliveredDedupeKeys),
      };
    },
    write(state) {
      if (!resolvedPath) {
        return;
      }

      const normalizedState = {
        sessions: normalizeEntryList(state?.sessions),
        deliveredDedupeKeys: normalizeEntryList(state?.deliveredDedupeKeys),
      };
      fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
      const tempPath = `${resolvedPath}.tmp`;
      fs.writeFileSync(tempPath, JSON.stringify(normalizedState), {
        encoding: "utf8",
        mode: 0o600,
      });
      fs.renameSync(tempPath, resolvedPath);
      try {
        fs.chmodSync(resolvedPath, 0o600);
      } catch {
        // Best-effort only on filesystems that support POSIX modes.
      }
    },
  };
}

function apnsConfigFromEnv(env) {
  return {
    teamId: readFirstDefinedEnv(["REMODEX_APNS_TEAM_ID", "PHODEX_APNS_TEAM_ID"], env),
    keyId: readFirstDefinedEnv(["REMODEX_APNS_KEY_ID", "PHODEX_APNS_KEY_ID"], env),
    bundleId: readFirstDefinedEnv(["REMODEX_APNS_BUNDLE_ID", "PHODEX_APNS_BUNDLE_ID"], env),
    privateKey: readAPNsPrivateKey(env),
  };
}

function readAPNsPrivateKey(env) {
  const rawValue = readFirstDefinedEnv(["REMODEX_APNS_PRIVATE_KEY", "PHODEX_APNS_PRIVATE_KEY"], env);
  if (rawValue) {
    return rawValue;
  }

  const filePath = readFirstDefinedEnv(
    ["REMODEX_APNS_PRIVATE_KEY_FILE", "PHODEX_APNS_PRIVATE_KEY_FILE"],
    env
  );
  if (!filePath) {
    return "";
  }

  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return "";
  }
}

function readFirstDefinedEnv(keys, env) {
  for (const key of keys) {
    const value = readString(env?.[key]);
    if (value) {
      return value;
    }
  }
  return "";
}

function normalizeDeviceToken(value) {
  const normalized = readString(value);
  if (!normalized) {
    return "";
  }

  return normalized.replace(/[^a-fA-F0-9]/g, "").toLowerCase();
}

function normalizePreviewText(value) {
  const normalized = readString(value).replace(/\s+/g, " ");
  if (!normalized) {
    return "";
  }

  return normalized.length > PUSH_PREVIEW_MAX_CHARS
    ? `${normalized.slice(0, PUSH_PREVIEW_MAX_CHARS - 1).trimEnd()}…`
    : normalized;
}

function fallbackBodyForResult(result) {
  return result === "failed" ? "Run failed" : "Response ready";
}

function resolvePushStateFilePath(env = process.env) {
  const explicitPath = readFirstDefinedEnv(
    ["REMODEX_PUSH_STATE_FILE", "PHODEX_PUSH_STATE_FILE"],
    env
  );
  if (explicitPath) {
    return explicitPath;
  }

  const codexHome = readString(env.CODEX_HOME) || path.join(os.homedir(), ".codex");
  return path.join(codexHome, "remodex", "push-state.json");
}

function normalizeEntryList(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((entry) => Array.isArray(entry) && entry.length === 2);
}

function emptyPushState() {
  return {
    sessions: [],
    deliveredDedupeKeys: [],
  };
}

function safeParseJSON(value) {
  if (!value || typeof value !== "string") {
    return null;
  }

  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function secretsEqual(left, right) {
  const leftBuffer = Buffer.from(readString(left));
  const rightBuffer = Buffer.from(readString(right));
  if (!leftBuffer.length || leftBuffer.length !== rightBuffer.length) {
    return false;
  }

  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function pushServiceError(code, message, status) {
  const error = new Error(message);
  error.code = code;
  error.status = status;
  return error;
}

module.exports = {
  createPushSessionService,
  createFileBackedPushStateStore,
  resolvePushStateFilePath,
};
