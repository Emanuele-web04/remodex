// FILE: push-notification-completion-dedupe.js
// Purpose: Owns duplicate-suppression state for completion pushes emitted by the bridge.
// Layer: Bridge helper
// Exports: createPushNotificationCompletionDedupe
// Depends on: none

const DEFAULT_SENT_DEDUPE_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_STATUS_FALLBACK_TTL_MS = 5_000;

function createPushNotificationCompletionDedupe({
  now = () => Date.now(),
  sentDedupeTTLms = DEFAULT_SENT_DEDUPE_TTL_MS,
  statusFallbackTTLms = DEFAULT_STATUS_FALLBACK_TTL_MS,
} = {}) {
  const sentDedupeKeys = new Map();
  const pendingDedupeKeys = new Set();
  const recentTurnScopedCompletionsByThread = new Map();

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
    return sentDedupeKeys.has(normalizedKey) || pendingDedupeKeys.has(normalizedKey);
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

    if (readString(turnId)) {
      rememberTurnScopedCompletion(threadId, result);
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

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  createPushNotificationCompletionDedupe,
};
