// FILE: thread-ownership-store.js
// Purpose: Persists durable thread → provider mappings so a thread created in OpenCode
//          remains owned by OpenCode across bridge restarts.
// Layer: Persistence helper
// Exports: createThreadOwnershipStore
// Depends on: os, json-file-store, normalize

const os = require("os");
const { readString } = require("./normalize");
const { createJsonFileStore } = require("./json-file-store");

const OWNERSHIP_WRITE_DEBOUNCE_MS = 500;
const THREAD_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/;

function isValidThreadId(threadId) {
  return typeof threadId === "string" && THREAD_ID_PATTERN.test(threadId);
}

function sanitizeOwnershipEntries(entries) {
  const sanitized = {};
  for (const [threadId, entry] of Object.entries(entries || {})) {
    if (!isValidThreadId(threadId)) {
      continue;
    }
    const providerId = readString(entry?.providerId);
    if (!providerId) {
      continue;
    }
    sanitized[threadId] = {
      providerId,
      assignedAt: readString(entry?.assignedAt) || new Date(0).toISOString(),
    };
  }
  return sanitized;
}

function createThreadOwnershipStore({
  storagePath = "",
  homeDir = os.homedir(),
  fsImpl,
  nowMs = Date.now,
  writeDebounceMs = OWNERSHIP_WRITE_DEBOUNCE_MS,
} = {}) {
  const resolvedDebounceMs = writeDebounceMs === undefined
    ? OWNERSHIP_WRITE_DEBOUNCE_MS
    : writeDebounceMs;
  const store = createJsonFileStore({
    filePath: storagePath,
    defaultFileName: "thread-ownership.json",
    homeDir,
    key: "ownership",
    fsImpl,
    writeDebounceMs: resolvedDebounceMs,
  });

  let ownership = sanitizeOwnershipEntries(store.read());
  pruneStaleEntries();

  function setOwnership(threadId, providerId) {
    const normalizedThreadId = readString(threadId);
    const normalizedProviderId = readString(providerId);
    if (!normalizedThreadId || !normalizedProviderId || !isValidThreadId(normalizedThreadId)) {
      return false;
    }

    ownership[normalizedThreadId] = {
      providerId: normalizedProviderId,
      assignedAt: new Date(nowMs()).toISOString(),
    };
    store.write(ownership);
    return true;
  }

  function getOwnership(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !isValidThreadId(normalizedThreadId)) {
      return null;
    }
    return ownership[normalizedThreadId]?.providerId || null;
  }

  function ownsThread(threadId, providerId) {
    const owner = getOwnership(threadId);
    return owner !== null && owner === readString(providerId);
  }

  function removeOwnership(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !isValidThreadId(normalizedThreadId) || !ownership[normalizedThreadId]) {
      return false;
    }

    delete ownership[normalizedThreadId];
    store.write(ownership);
    return true;
  }

  function getAllOwnedBy(providerId) {
    const normalizedProviderId = readString(providerId);
    if (!normalizedProviderId) {
      return [];
    }

    return Object.entries(ownership)
      .filter(([threadId, entry]) => isValidThreadId(threadId) && entry?.providerId === normalizedProviderId)
      .map(([threadId, entry]) => ({
        threadId,
        providerId: entry.providerId,
        assignedAt: entry.assignedAt,
      }));
  }

  function pruneStaleEntries(staleMs = 30 * 24 * 60 * 60 * 1000) {
    const cutoff = nowMs() - staleMs;
    let didChange = false;
    for (const [threadId, entry] of Object.entries(ownership)) {
      if (!isValidThreadId(threadId)) {
        delete ownership[threadId];
        didChange = true;
        continue;
      }
      const assignedTime = Date.parse(entry?.assignedAt || "");
      if (Number.isFinite(assignedTime) && assignedTime < cutoff) {
        delete ownership[threadId];
        didChange = true;
      }
    }

    if (didChange) {
      store.write(ownership);
    }
    return didChange;
  }

  function size() {
    return Object.keys(ownership).length;
  }

  function flush() {
    store.flush();
  }

  return {
    flush,
    getOwnership,
    getAllOwnedBy,
    ownsThread,
    pruneStaleEntries,
    removeOwnership,
    setOwnership,
    size,
  };
}

module.exports = {
  createThreadOwnershipStore,
  isValidThreadId,
};