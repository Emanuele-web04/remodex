// FILE: push-notification-completion-dedupe.js
// Purpose: Owns duplicate-suppression state for completion pushes emitted by the bridge.
// Layer: Bridge helper
// Exports: createPushNotificationCompletionDedupe
// Depends on: ./json-file-store (for persisted turn-completed-dedupe.json)

const os = require("os");
const fs = require("fs");

const DEFAULT_SENT_DEDUPE_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_STATUS_FALLBACK_TTL_MS = 5_000;
const COMPLETION_DEDUPE_STORE_KEY = "completionDedupe";
const LEGACY_COMPLETION_DEDUPE_STORE_KEY = "undefined";

const { createJsonFileStore } = require("./json-file-store");

function createPushNotificationCompletionDedupe({
  now = () => Date.now(),
  sentDedupeTTLms = DEFAULT_SENT_DEDUPE_TTL_MS,
  statusFallbackTTLms = DEFAULT_STATUS_FALLBACK_TTL_MS,
  homeDir = os.homedir(),
  fsImpl = fs,
  dedupeStore: injectedDedupeStore,
} = {}) {
  const sentDedupeKeys = new Map();
  const pendingDedupeKeys = new Set();
  const recentTurnScopedCompletionsByThread = new Map();

  // Persisted dedupe for turn completions (survives bridge restart; 24h TTL per turn).
  // Schema under completionDedupe: { completedTurns: [{ turnId, completedAt }], lastPruned }
  const completedTurnIds = new Map();
  const dedupeStore = injectedDedupeStore || createJsonFileStore({
    defaultFileName: "turn-completed-dedupe.json",
    homeDir,
    key: COMPLETION_DEDUPE_STORE_KEY,
    fsImpl,
  });
  let persistScheduled = false;
  loadPersistedCompletedTurnDedupe();

  function loadPersistedCompletedTurnDedupe() {
    try {
      const data = readPersistedDedupePayload();
      const { entries, lastPrunedTs } = normalizePersistedEntries(data);
      const lastPrunedStr = typeof data?.lastPruned === "string" ? data.lastPruned.trim() : "";
      if (
        lastPrunedStr
        && Number.isFinite(lastPrunedTs)
        && (now() - lastPrunedTs) >= sentDedupeTTLms
      ) {
        return;
      }
      if (!entries.length) {
        return;
      }

      for (const { turnId, completedAt } of entries) {
        const normalizedTurnId = readString(turnId);
        if (!normalizedTurnId) {
          continue;
        }
        const completedAtTs = parseCompletedAtMs(completedAt, lastPrunedTs);
        completedTurnIds.set(normalizedTurnId, completedAtTs);
        sentDedupeKeys.set(`turn-completed-dedupe:${normalizedTurnId}`, completedAtTs);
      }
    } catch {
      // ignore missing/corrupt persist file
    }
  }

  function readPersistedDedupePayload() {
    const current = dedupeStore.read() || {};
    if (hasPersistedTurnEntries(current)) {
      return current;
    }
    return readLegacyPersistedDedupePayload();
  }

  function readLegacyPersistedDedupePayload() {
    try {
      const raw = fsImpl.readFileSync(dedupeStore.resolvePath(), "utf8");
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        return {};
      }

      const legacyBucket = parsed[LEGACY_COMPLETION_DEDUPE_STORE_KEY];
      if (legacyBucket && typeof legacyBucket === "object" && !Array.isArray(legacyBucket)) {
        return legacyBucket;
      }
      if (hasPersistedTurnEntries(parsed)) {
        return parsed;
      }
    } catch {
      // missing or unreadable file
    }
    return {};
  }

  function schedulePersistedCompletedTurnDedupe() {
    if (persistScheduled) {
      return;
    }
    persistScheduled = true;
    setImmediate(() => {
      persistScheduled = false;
      savePersistedCompletedTurnDedupe();
    });
  }

  function savePersistedCompletedTurnDedupe() {
    try {
      prunePersistedCompletedTurnIds();
      const completedTurns = Array.from(completedTurnIds.entries()).map(([turnId, completedAt]) => ({
        turnId,
        completedAt: new Date(completedAt).toISOString(),
      }));
      dedupeStore.write({
        completedTurns,
        lastPruned: new Date(now()).toISOString(),
      });
    } catch {
      // best effort
    }
  }

  function clearForNewRun(threadId) {
    if (!readString(threadId)) {
      return;
    }

    recentTurnScopedCompletionsByThread.delete(threadId);
  }

  // Thread-level terminal events are only a fallback when we have not already sent a turn-scoped completion.
  function shouldSuppressThreadStatusFallback({ threadId, turnId, result } = {}) {
    if (readString(turnId)) {
      return false;
    }

    pruneRecentTurnScopedCompletions();
    const previous = recentTurnScopedCompletionsByThread.get(readString(threadId));
    return previous?.result === result;
  }

  function hasActiveDedupeKey(dedupeKey) {
    const normalizedKey = readString(dedupeKey);
    if (!normalizedKey) {
      return false;
    }

    pruneSentDedupeKeys();
    if (sentDedupeKeys.has(normalizedKey) || pendingDedupeKeys.has(normalizedKey)) {
      return true;
    }
    // Cross-check persisted completed turns (key may differ post-restart due to sessionId)
    const turnId = extractTurnIdFromDedupeKey(normalizedKey);
    if (turnId && hasPersistedCompletedTurn(turnId)) {
      return true;
    }
    return false;
  }

  function beginNotification({ dedupeKey, threadId, turnId, result } = {}) {
    const normalizedKey = readString(dedupeKey);
    if (!normalizedKey) {
      return;
    }

    pendingDedupeKeys.add(normalizedKey);
    if (readString(turnId)) {
      rememberTurnScopedCompletion(threadId, result);
    }
  }

  function commitNotification({ dedupeKey, threadId, turnId, result } = {}) {
    const normalizedKey = readString(dedupeKey);
    if (normalizedKey) {
      sentDedupeKeys.set(normalizedKey, now());
      pendingDedupeKeys.delete(normalizedKey);
    }

    const normalizedTurnId = readString(turnId);
    if (normalizedTurnId) {
      rememberTurnScopedCompletion(threadId, result);
      completedTurnIds.set(normalizedTurnId, now());
      schedulePersistedCompletedTurnDedupe();
    }
  }

  function abortNotification({ dedupeKey, threadId, turnId, result } = {}) {
    const normalizedKey = readString(dedupeKey);
    if (normalizedKey) {
      pendingDedupeKeys.delete(normalizedKey);
    }

    const normalizedThreadId = readString(threadId);
    if (!readString(turnId) || !normalizedThreadId) {
      return;
    }

    const previous = recentTurnScopedCompletionsByThread.get(normalizedThreadId);
    if (previous?.result === result) {
      recentTurnScopedCompletionsByThread.delete(normalizedThreadId);
    }
  }

  // Exposed for focused tests so we can prove dedupe state stays bounded.
  function debugState() {
    pruneSentDedupeKeys();
    pruneRecentTurnScopedCompletions();
    return {
      sentDedupeKeys: sentDedupeKeys.size,
      pendingDedupeKeys: pendingDedupeKeys.size,
      recentThreadFallbacks: recentTurnScopedCompletionsByThread.size,
      persistedCompletedTurns: completedTurnIds.size,
    };
  }

  function rememberTurnScopedCompletion(threadId, result) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId) {
      return;
    }

    recentTurnScopedCompletionsByThread.set(normalizedThreadId, {
      result,
      timestamp: now(),
    });
  }

  function pruneSentDedupeKeys() {
    const cutoff = now() - sentDedupeTTLms;
    for (const [dedupeKey, timestamp] of sentDedupeKeys.entries()) {
      if (timestamp < cutoff) {
        sentDedupeKeys.delete(dedupeKey);
      }
    }
    prunePersistedCompletedTurnIds(cutoff);
  }

  function hasPersistedCompletedTurn(turnId) {
    const normalizedTurnId = readString(turnId);
    if (!normalizedTurnId) {
      return false;
    }

    prunePersistedCompletedTurnIds();
    const completedAt = completedTurnIds.get(normalizedTurnId);
    if (completedAt === undefined) {
      return false;
    }
    return completedAt >= now() - sentDedupeTTLms;
  }

  function prunePersistedCompletedTurnIds(cutoff = now() - sentDedupeTTLms) {
    let removed = false;
    for (const [turnId, timestamp] of completedTurnIds.entries()) {
      if (timestamp < cutoff) {
        completedTurnIds.delete(turnId);
        removed = true;
      }
    }
    if (removed) {
      schedulePersistedCompletedTurnDedupe();
    }
  }

  function pruneRecentTurnScopedCompletions() {
    const cutoff = now() - statusFallbackTTLms;
    for (const [threadId, entry] of recentTurnScopedCompletionsByThread.entries()) {
      if (entry.timestamp < cutoff) {
        recentTurnScopedCompletionsByThread.delete(threadId);
      }
    }
  }

  return {
    abortNotification,
    beginNotification,
    clearForNewRun,
    commitNotification,
    debugState,
    hasActiveDedupeKey,
    shouldSuppressThreadStatusFallback,
  };
}

function hasPersistedTurnEntries(data) {
  if (!data || typeof data !== "object") {
    return false;
  }
  if (Array.isArray(data.completedTurns) && data.completedTurns.length > 0) {
    return true;
  }
  return Array.isArray(data.completedTurnIds) && data.completedTurnIds.length > 0;
}

function normalizePersistedEntries(data) {
  const lastPrunedStr = typeof data?.lastPruned === "string" ? data.lastPruned.trim() : "";
  const lastPrunedTs = lastPrunedStr ? Date.parse(lastPrunedStr) : 0;
  const completedTurns = Array.isArray(data?.completedTurns) ? data.completedTurns : [];
  if (completedTurns.length > 0) {
    return {
      lastPrunedTs,
      entries: completedTurns
        .map((entry) => ({
          turnId: readString(entry?.turnId),
          completedAt: entry?.completedAt,
        }))
        .filter((entry) => entry.turnId),
    };
  }

  const legacyIds = Array.isArray(data?.completedTurnIds) ? data.completedTurnIds : [];
  return {
    lastPrunedTs,
    entries: legacyIds
      .map((turnId) => ({
        turnId: readString(turnId),
        completedAt: lastPrunedTs,
      }))
      .filter((entry) => entry.turnId),
  };
}

function parseCompletedAtMs(completedAt, fallbackMs) {
  if (typeof completedAt === "number" && Number.isFinite(completedAt)) {
    return completedAt;
  }
  if (typeof completedAt === "string" && completedAt.trim()) {
    const parsed = Date.parse(completedAt);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return fallbackMs || 0;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function extractTurnIdFromDedupeKey(key) {
  const normalized = readString(key);
  if (!normalized) return "";
  const parts = normalized.split("|");
  // turn key shape: [sessionId, threadId, turnId, result] => turnId at [2] if present and not "no-turn"
  if (parts.length >= 3 && parts[2] && parts[2] !== "no-turn") {
    return readString(parts[2]);
  }
  return "";
}

module.exports = {
  COMPLETION_DEDUPE_STORE_KEY,
  createPushNotificationCompletionDedupe,
};