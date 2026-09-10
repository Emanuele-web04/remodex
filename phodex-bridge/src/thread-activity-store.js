// FILE: thread-activity-store.js
// Purpose: Owns Activity snapshots, revisions, opt-in delivery, and bounded retention.
// Layer: CLI helper
// Exports: createThreadActivityStore
// Depends on: crypto

const { randomUUID } = require("crypto");

const ACTIVITY_SCHEMA_VERSION = 1;
const ACTIVITY_SUBSCRIBE_METHOD = "remodex/activity/subscribe";
const ACTIVITY_UNSUBSCRIBE_METHOD = "remodex/activity/unsubscribe";
const ACTIVITY_UPDATED_METHOD = "remodex/activity/updated";
const DEFAULT_MAX_INACTIVE_ENTRIES = 200;
const DEFAULT_COALESCE_MS = 225;

function createThreadActivityStore({
  sendApplicationResponse,
  createEpoch = randomUUID,
  maxInactiveEntries = DEFAULT_MAX_INACTIVE_ENTRIES,
  coalesceMs = DEFAULT_COALESCE_MS,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
  onEvict = () => {},
} = {}) {
  const epoch = createEpoch();
  const entriesByThreadId = new Map();
  const serializedEntriesByThreadId = new Map();
  const pendingUpsertsByThreadId = new Map();
  const pendingRemovedThreadIds = new Set();
  let revision = 0;
  let deliveredRevision = 0;
  let subscribed = false;
  let flushTimer = null;
  let disposed = false;

  function handleRequest(message) {
    if (disposed) {
      return false;
    }
    if (message?.method === ACTIVITY_SUBSCRIBE_METHOD) {
      handleSubscribe(message);
      return true;
    }
    if (message?.method === ACTIVITY_UNSUBSCRIBE_METHOD) {
      handleUnsubscribe(message);
      return true;
    }
    return false;
  }

  function handleSubscribe(message) {
    if (!validRequest(message)) {
      sendInvalidParams(message?.id);
      return;
    }
    clearPendingDelivery();
    sendResponse(message.id, snapshot());
    deliveredRevision = revision;
    subscribed = true;
  }

  function handleUnsubscribe(message) {
    if (!validRequest(message)) {
      sendInvalidParams(message?.id);
      return;
    }
    resetSubscriber();
    sendResponse(message.id, { schemaVersion: ACTIVITY_SCHEMA_VERSION });
  }

  function upsert(entry) {
    if (disposed || !validEntry(entry)) {
      return false;
    }
    const previous = entriesByThreadId.get(entry.threadId) || null;
    const serialized = JSON.stringify(entry);
    if (serializedEntriesByThreadId.get(entry.threadId) === serialized) {
      return false;
    }

    entriesByThreadId.delete(entry.threadId);
    entriesByThreadId.set(entry.threadId, entry);
    serializedEntriesByThreadId.set(entry.threadId, serialized);
    const removedThreadIds = evictInactiveEntries();
    commitChanges({
      upserts: [entry],
      removedThreadIds,
      urgent: isUrgentChange(previous, entry) || removedThreadIds.length > 0,
    });
    return true;
  }

  function remove(threadId, { source = "" } = {}) {
    const entry = entriesByThreadId.get(threadId);
    if (!entry || (source && entry.source !== source)) {
      return false;
    }
    entriesByThreadId.delete(threadId);
    serializedEntriesByThreadId.delete(threadId);
    commitChanges({ removedThreadIds: [threadId], urgent: true });
    return true;
  }

  function markSourceStale(source, sourceGeneration = null) {
    const staleEntries = [];
    for (const entry of entriesByThreadId.values()) {
      if (entry.source !== source
          || (sourceGeneration != null && entry.sourceGeneration !== sourceGeneration)
          || entry.freshness === "stale") {
        continue;
      }
      staleEntries.push({ ...entry, freshness: "stale" });
    }
    if (staleEntries.length === 0) {
      return false;
    }
    for (const entry of staleEntries) {
      entriesByThreadId.set(entry.threadId, entry);
      serializedEntriesByThreadId.set(entry.threadId, JSON.stringify(entry));
    }
    commitChanges({ upserts: staleEntries, urgent: true });
    return true;
  }

  function resetSubscriber() {
    subscribed = false;
    clearPendingDelivery();
    deliveredRevision = revision;
  }

  function dispose() {
    disposed = true;
    resetSubscriber();
    entriesByThreadId.clear();
    serializedEntriesByThreadId.clear();
  }

  function snapshot() {
    return {
      schemaVersion: ACTIVITY_SCHEMA_VERSION,
      epoch,
      revision,
      coverage: "observedThreads",
      entries: [...entriesByThreadId.values()]
        .slice()
        .sort((left, right) => left.threadId.localeCompare(right.threadId)),
    };
  }

  function evictInactiveEntries() {
    let inactiveCount = [...entriesByThreadId.values()].filter(isInactiveEntry).length;
    const removedThreadIds = [];
    if (inactiveCount <= maxInactiveEntries) {
      return removedThreadIds;
    }
    for (const [threadId, entry] of entriesByThreadId) {
      if (!isInactiveEntry(entry)) {
        continue;
      }
      entriesByThreadId.delete(threadId);
      serializedEntriesByThreadId.delete(threadId);
      removedThreadIds.push(threadId);
      onEvict(threadId, entry.source);
      inactiveCount -= 1;
      if (inactiveCount <= maxInactiveEntries) {
        break;
      }
    }
    return removedThreadIds;
  }

  function commitChanges({ upserts = [], removedThreadIds = [], urgent = false }) {
    revision += 1;
    if (!subscribed) {
      return;
    }
    for (const entry of upserts) {
      pendingRemovedThreadIds.delete(entry.threadId);
      pendingUpsertsByThreadId.set(entry.threadId, entry);
    }
    for (const threadId of removedThreadIds) {
      pendingUpsertsByThreadId.delete(threadId);
      pendingRemovedThreadIds.add(threadId);
    }
    if (urgent) {
      flushPendingDelivery();
    } else {
      scheduleFlush();
    }
  }

  function scheduleFlush() {
    if (flushTimer) {
      return;
    }
    flushTimer = setTimeoutFn(flushPendingDelivery, coalesceMs);
    flushTimer?.unref?.();
  }

  function flushPendingDelivery() {
    clearFlushTimer();
    if (!subscribed || !hasPendingDelivery()) {
      return;
    }
    const notification = {
      method: ACTIVITY_UPDATED_METHOD,
      params: {
        schemaVersion: ACTIVITY_SCHEMA_VERSION,
        epoch,
        baseRevision: deliveredRevision,
        revision,
        upserts: [...pendingUpsertsByThreadId.values()]
          .sort((left, right) => left.threadId.localeCompare(right.threadId)),
        removedThreadIds: [...pendingRemovedThreadIds].sort(),
      },
    };
    clearPendingCollections();
    deliveredRevision = revision;
    sendApplicationResponse(JSON.stringify(notification));
  }

  function clearPendingDelivery() {
    clearFlushTimer();
    clearPendingCollections();
  }

  function clearPendingCollections() {
    pendingUpsertsByThreadId.clear();
    pendingRemovedThreadIds.clear();
  }

  function clearFlushTimer() {
    if (!flushTimer) {
      return;
    }
    clearTimeoutFn(flushTimer);
    flushTimer = null;
  }

  function hasPendingDelivery() {
    return pendingUpsertsByThreadId.size > 0 || pendingRemovedThreadIds.size > 0;
  }

  function sendResponse(id, result) {
    if (id == null) {
      return;
    }
    sendApplicationResponse(JSON.stringify({ id, result }));
  }

  function sendInvalidParams(id) {
    if (id == null) {
      return;
    }
    sendApplicationResponse(JSON.stringify({
      id,
      error: {
        code: -32602,
        message: "Activity requests support schemaVersion 1.",
      },
    }));
  }

  return {
    get(threadId) { return entriesByThreadId.get(threadId) || null; },
    dispose,
    flush: flushPendingDelivery,
    handleRequest,
    markSourceStale,
    remove,
    resetSubscriber,
    snapshot,
    upsert,
  };
}

function validRequest(message) {
  if (message?.id == null) {
    return false;
  }
  const params = message.params;
  if (params == null) {
    return true;
  }
  return typeof params === "object"
    && !Array.isArray(params)
    && (params.schemaVersion == null || params.schemaVersion === ACTIVITY_SCHEMA_VERSION);
}

function validEntry(entry) {
  return entry
    && typeof entry === "object"
    && typeof entry.threadId === "string"
    && entry.threadId.length > 0;
}

function isInactiveEntry(entry) {
  return entry.runtime !== "active"
    && entry.runningWithoutTurnId !== true
    && entry.approvalRequired !== true
    && entry.userInputRequired !== true;
}

function isUrgentChange(previous, next) {
  if (!previous || previous.source !== next.source) {
    return true;
  }
  return previous.runtime !== next.runtime
    || previous.runningWithoutTurnId !== next.runningWithoutTurnId
    || previous.approvalRequestCount !== next.approvalRequestCount
    || previous.approvalRequired !== next.approvalRequired
    || previous.userInputRequestCount !== next.userInputRequestCount
    || previous.userInputRequired !== next.userInputRequired
    || previous.freshness !== next.freshness
    || JSON.stringify(previous.activeTurnIds) !== JSON.stringify(next.activeTurnIds)
    || JSON.stringify(previous.lastOutcome) !== JSON.stringify(next.lastOutcome);
}

module.exports = {
  ACTIVITY_SCHEMA_VERSION,
  ACTIVITY_SUBSCRIBE_METHOD,
  ACTIVITY_UNSUBSCRIBE_METHOD,
  ACTIVITY_UPDATED_METHOD,
  createThreadActivityStore,
};
