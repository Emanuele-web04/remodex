// FILE: thread-list-provenance.js
// Purpose: Restores fork/automation provenance that app-server drops from thread list rows.
// Layer: CLI helper
// Exports: createThreadListProvenanceEnricher
// Depends on: fs, ./session-jsonl-history, ./thread-row-enrichment

const fs = require("fs");
const { readSessionJsonlMetadataFromFile } = require("./session-jsonl-history");
const { forEachThreadRowInResponse } = require("./thread-row-enrichment");

// An entry is two short strings, so the cache stays far cheaper than re-reading
// rollout heads. Sized well above any single thread/list page: a full unpaginated
// list must not evict rows it is still walking, or every refresh re-reads the disk.
const DEFAULT_MAX_ENTRIES = 4096;

// app-server returns `forkedFromId: null` / `threadSource: null` on thread rows even
// when the rollout's session_meta carries both. A thread forked by a desktop automation
// copies the origin's name and preview, so without this the phone shows two identical
// sidebar rows with no way to tell which is which. The rollout row already carries the
// file path, and session_meta is written once at session start, so a bounded cache keyed
// by thread id keeps this to one small head read per thread ever seen.
function createThreadListProvenanceEnricher({
  fsModule = fs,
  maxEntries = DEFAULT_MAX_ENTRIES,
} = {}) {
  const cache = new Map();

  function readProvenance(threadId, filePath) {
    if (cache.has(threadId)) {
      const cached = cache.get(threadId);
      // Refresh insertion order so the Map behaves as an LRU.
      cache.delete(threadId);
      cache.set(threadId, cached);
      return cached;
    }

    let provenance = { forkedFromId: "", threadSource: "" };
    let readSessionMeta = false;
    try {
      const metadata = readSessionJsonlMetadataFromFile(filePath, { fsModule });
      // The thread id only appears once session_meta is on disk; without it the read
      // hit a rotated, unreadable, or still-being-written rollout.
      readSessionMeta = Boolean(normalizeString(metadata?.threadId));
      provenance = {
        forkedFromId: normalizeString(metadata?.forkedFromId),
        threadSource: normalizeString(metadata?.threadSource),
      };
    } catch {
      // A rotated, half-written, or unreadable rollout simply leaves the row as-is.
    }

    // Only a real session_meta is worth remembering: it never changes again. Caching a
    // failed read instead would strand a freshly forked thread without its badge until
    // the bridge restarts, so those are retried on the next list.
    if (!readSessionMeta) {
      return provenance;
    }

    cache.set(threadId, provenance);
    while (cache.size > Math.max(1, maxEntries)) {
      cache.delete(cache.keys().next().value);
    }
    return provenance;
  }

  function attachToThread(thread) {
    const threadId = normalizeString(thread?.id) || normalizeString(thread?.threadId);
    const filePath = normalizeString(thread?.path) || normalizeString(thread?.rolloutPath);
    if (!thread || typeof thread !== "object" || !threadId || !filePath) {
      return thread;
    }
    // Never overwrite what app-server did resolve; this only fills the gaps.
    if (normalizeString(thread.forkedFromId) && normalizeString(thread.threadSource)) {
      return thread;
    }

    const provenance = readProvenance(threadId, filePath);
    if (!normalizeString(thread.forkedFromId) && provenance.forkedFromId) {
      thread.forkedFromId = provenance.forkedFromId;
    }
    if (!normalizeString(thread.threadSource) && provenance.threadSource) {
      thread.threadSource = provenance.threadSource;
    }
    return thread;
  }

  function enrichResponse(method, envelope) {
    return forEachThreadRowInResponse(method, envelope, attachToThread);
  }

  return {
    attachToThread,
    enrichResponse,
    // Exposed for focused tests so cache growth stays provable.
    cacheSize: () => cache.size,
  };
}

function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

module.exports = {
  createThreadListProvenanceEnricher,
};
