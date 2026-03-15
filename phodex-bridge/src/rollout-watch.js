// FILE: rollout-watch.js
// Purpose: Shared rollout-file lookup/watch helpers for CLI inspection, desktop refresh, and usage fallbacks.
// Layer: CLI helper
// Exports: watchThreadRollout, createThreadRolloutActivityWatcher
// Depends on: fs, os, path, ./session-state

const fs = require("fs");
const os = require("os");
const path = require("path");
const { readLastActiveThread } = require("./session-state");

const DEFAULT_WATCH_INTERVAL_MS = 1_000;
const DEFAULT_LOOKUP_TIMEOUT_MS = 5_000;
const DEFAULT_IDLE_TIMEOUT_MS = 10_000;
const DEFAULT_TRANSIENT_ERROR_RETRY_LIMIT = 2;
const DEFAULT_INITIAL_USAGE_SCAN_BYTES = 128 * 1024;
const DEFAULT_TURN_LOOKUP_SCAN_BYTES = 16 * 1024;
const DEFAULT_THREAD_LOOKUP_SCAN_BYTES = 512 * 1024;
const DEFAULT_CONTEXT_READ_SCAN_BYTES = 512 * 1024;
const DEFAULT_CONTEXT_READ_CANDIDATE_LIMIT = 128;
const DEFAULT_RECENT_ROLLOUT_CANDIDATE_LIMIT = 24;
const DEFAULT_RECENT_ROLLOUT_LOOKBACK_MS = 15 * 60 * 1000;

// Polls one rollout file until it materializes and then reports size growth.
function createThreadRolloutActivityWatcher({
  threadId,
  turnId = "",
  intervalMs = DEFAULT_WATCH_INTERVAL_MS,
  lookupTimeoutMs = DEFAULT_LOOKUP_TIMEOUT_MS,
  idleTimeoutMs = DEFAULT_IDLE_TIMEOUT_MS,
  initialUsageScanBytes = DEFAULT_INITIAL_USAGE_SCAN_BYTES,
  now = () => Date.now(),
  fsModule = fs,
  transientErrorRetryLimit = DEFAULT_TRANSIENT_ERROR_RETRY_LIMIT,
  onEvent = () => {},
  onUsage = () => {},
  onIdle = () => {},
  onTimeout = () => {},
  onError = () => {},
} = {}) {
  const resolvedThreadId = resolveThreadId(threadId);
  const sessionsRoot = resolveSessionsRoot();
  const startedAt = now();

  let isStopped = false;
  let rolloutPath = null;
  let lastSize = null;
  let lastGrowthAt = startedAt;
  let transientErrorCount = 0;
  let usageScanOffset = 0;
  let partialUsageLine = "";
  let lastUsageSignature = null;

  const tick = () => {
    if (isStopped) {
      return;
    }

    try {
      const currentTime = now();

      if (!rolloutPath) {
        if (currentTime - startedAt >= lookupTimeoutMs) {
          onTimeout({ threadId: resolvedThreadId });
          stop();
          return;
        }

        rolloutPath = findRecentRolloutFileForWatch(sessionsRoot, {
          threadId: resolvedThreadId,
          fsModule,
          startedAt,
          turnId,
        });
        if (!rolloutPath) {
          transientErrorCount = 0;
          return;
        }

        lastSize = readFileSize(rolloutPath, fsModule);
        lastGrowthAt = currentTime;
        transientErrorCount = 0;
        const initialScanStart = Math.max(0, lastSize - initialUsageScanBytes);
        const initialUsageResult = readRolloutUsageChunk({
          filePath: rolloutPath,
          start: initialScanStart,
          endExclusive: lastSize,
          carry: "",
          fsModule,
          skipLeadingPartial: initialScanStart > 0,
        });
        usageScanOffset = lastSize;
        partialUsageLine = initialUsageResult.partialLine;
        emitUsageIfChanged(initialUsageResult.usage, "materialized");
        onEvent({
          reason: "materialized",
          threadId: resolvedThreadId,
          rolloutPath,
          size: lastSize,
        });
        return;
      }

      const nextSize = readFileSize(rolloutPath, fsModule);
      transientErrorCount = 0;
      if (nextSize > lastSize) {
        lastSize = nextSize;
        lastGrowthAt = currentTime;
        const usageResult = readRolloutUsageChunk({
          filePath: rolloutPath,
          start: usageScanOffset,
          endExclusive: nextSize,
          carry: partialUsageLine,
          fsModule,
        });
        usageScanOffset = nextSize;
        partialUsageLine = usageResult.partialLine;
        emitUsageIfChanged(usageResult.usage, "growth");
        onEvent({
          reason: "growth",
          threadId: resolvedThreadId,
          rolloutPath,
          size: nextSize,
        });
        return;
      }

      if (currentTime - lastGrowthAt >= idleTimeoutMs) {
        onIdle({
          threadId: resolvedThreadId,
          rolloutPath,
          size: lastSize,
        });
        stop();
      }
    } catch (error) {
      if (isRetryableFilesystemError(error) && transientErrorCount < transientErrorRetryLimit) {
        transientErrorCount += 1;
        return;
      }

      onError(error);
      stop();
    }
  };

  const intervalId = setInterval(tick, intervalMs);
  tick();

  // Emits only when the rollout produced a newer token-count snapshot.
  function emitUsageIfChanged(usage, reason) {
    if (!usage) {
      return;
    }

    const nextSignature = `${usage.tokensUsed}|${usage.tokenLimit}`;
    if (nextSignature === lastUsageSignature) {
      return;
    }

    lastUsageSignature = nextSignature;
    onUsage({
      reason,
      threadId: resolvedThreadId,
      rolloutPath,
      usage,
    });
  }

  function stop() {
    if (isStopped) {
      return;
    }

    isStopped = true;
    clearInterval(intervalId);
  }

  return {
    stop,
    get threadId() {
      return resolvedThreadId;
    },
  };
}

function watchThreadRollout(threadId = "") {
  const resolvedThreadId = resolveThreadId(threadId);
  const sessionsRoot = resolveSessionsRoot();
  const rolloutPath = findRolloutFileForThread(sessionsRoot, resolvedThreadId);

  if (!rolloutPath) {
    throw new Error(`No rollout file found for thread ${resolvedThreadId}.`);
  }

  let offset = fs.statSync(rolloutPath).size;
  let partialLine = "";

  console.log(`[remodex] Watching thread ${resolvedThreadId}`);
  console.log(`[remodex] Rollout file: ${rolloutPath}`);
  console.log("[remodex] Waiting for new persisted events... (Ctrl+C to stop)");

  const onChange = (current, previous) => {
    if (current.size <= previous.size) {
      return;
    }

    const stream = fs.createReadStream(rolloutPath, {
      start: offset,
      end: current.size - 1,
      encoding: "utf8",
    });

    let chunkBuffer = "";
    stream.on("data", (chunk) => {
      chunkBuffer += chunk;
    });

    stream.on("end", () => {
      offset = current.size;
      const combined = partialLine + chunkBuffer;
      const lines = combined.split("\n");
      partialLine = lines.pop() || "";

      for (const line of lines) {
        const formatted = formatRolloutLine(line);
        if (formatted) {
          console.log(formatted);
        }
      }
    });
  };

  fs.watchFile(rolloutPath, { interval: 700 }, onChange);

  const cleanup = () => {
    fs.unwatchFile(rolloutPath, onChange);
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);
}

function resolveThreadId(threadId) {
  if (threadId && typeof threadId === "string") {
    return threadId;
  }

  const last = readLastActiveThread();
  if (last?.threadId) {
    return last.threadId;
  }

  throw new Error("No thread id provided and no remembered Remodex thread found.");
}

function resolveSessionsRoot() {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  return path.join(codexHome, "sessions");
}

function findRolloutFileForThread(root, threadId, { fsModule = fs } = {}) {
  if (!fsModule.existsSync(root)) {
    return null;
  }

  const stack = [root];

  while (stack.length > 0) {
    const current = stack.pop();
    const entries = fsModule.readdirSync(current, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }

      if (!entry.isFile()) {
        continue;
      }

      if (entry.name.includes(threadId) && entry.name.startsWith("rollout-") && entry.name.endsWith(".jsonl")) {
        return fullPath;
      }
    }
  }

  return null;
}

// Chooses the rollout file for the active bridge turn, preferring turn_id and then the thread-scoped file.
function findRecentRolloutFileForWatch(
  root,
  {
    threadId = "",
    turnId = "",
    startedAt = 0,
    fsModule = fs,
    candidateLimit = DEFAULT_RECENT_ROLLOUT_CANDIDATE_LIMIT,
    lookbackMs = DEFAULT_RECENT_ROLLOUT_LOOKBACK_MS,
    turnLookupScanBytes = DEFAULT_TURN_LOOKUP_SCAN_BYTES,
  } = {}
) {
  const candidates = collectRecentRolloutFiles(root, {
    fsModule,
    candidateLimit,
    modifiedAfterMs: startedAt > 0 ? (startedAt - lookbackMs) : 0,
  });
  if (candidates.length === 0) {
    return null;
  }

  if (turnId) {
    for (const candidate of candidates) {
      if (rolloutFileContainsTurnId(candidate.filePath, turnId, {
        fsModule,
        scanBytes: turnLookupScanBytes,
      })) {
        return candidate.filePath;
      }
    }
  }

  if (threadId) {
    const threadScopedRollout = findRolloutFileForThread(root, threadId, { fsModule });
    if (threadScopedRollout) {
      return threadScopedRollout;
    }
  }

  return null;
}

// Picks the rollout file tied back to a thread/turn for on-demand reads without crossing into another thread.
function findRecentRolloutFileForContextRead(
  root,
  {
    threadId = "",
    turnId = "",
    fsModule = fs,
    candidateLimit = DEFAULT_CONTEXT_READ_CANDIDATE_LIMIT,
    lookbackMs = DEFAULT_RECENT_ROLLOUT_LOOKBACK_MS,
    now = () => Date.now(),
    turnLookupScanBytes = DEFAULT_TURN_LOOKUP_SCAN_BYTES,
    threadLookupScanBytes = DEFAULT_THREAD_LOOKUP_SCAN_BYTES,
  } = {}
) {
  const candidates = collectRecentRolloutFiles(root, {
    fsModule,
    candidateLimit,
    modifiedAfterMs: 0,
  });
  if (candidates.length === 0) {
    return null;
  }

  if (turnId) {
    for (const candidate of candidates) {
      if (rolloutFileContainsTurnId(candidate.filePath, turnId, {
        fsModule,
        scanBytes: turnLookupScanBytes,
      })) {
        return candidate.filePath;
      }
    }
  }

  if (threadId) {
    const threadScopedRollout = findRolloutFileForThread(root, threadId, { fsModule });
    if (threadScopedRollout) {
      return threadScopedRollout;
    }

    for (const candidate of candidates) {
      if (rolloutFileContainsThreadId(candidate.filePath, threadId, {
        fsModule,
        scanBytes: threadLookupScanBytes,
      })) {
        return candidate.filePath;
      }
    }
  }

  return null;
}

function collectRecentRolloutFiles(
  root,
  {
    fsModule = fs,
    candidateLimit = DEFAULT_RECENT_ROLLOUT_CANDIDATE_LIMIT,
    modifiedAfterMs = 0,
  } = {}
) {
  if (!fsModule.existsSync(root)) {
    return [];
  }

  const stack = [root];
  const candidates = [];

  while (stack.length > 0) {
    const current = stack.pop();
    const entries = fsModule.readdirSync(current, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }

      if (!entry.isFile()
        || !entry.name.startsWith("rollout-")
        || !entry.name.endsWith(".jsonl")) {
        continue;
      }

      const stat = fsModule.statSync(fullPath);
      if (modifiedAfterMs > 0 && stat.mtimeMs < modifiedAfterMs) {
        continue;
      }

      candidates.push({
        filePath: fullPath,
        mtimeMs: stat.mtimeMs,
      });
    }
  }

  candidates.sort((lhs, rhs) => rhs.mtimeMs - lhs.mtimeMs);
  return candidates.slice(0, candidateLimit);
}

function rolloutFileContainsTurnId(
  filePath,
  turnId,
  {
    fsModule = fs,
    scanBytes = DEFAULT_TURN_LOOKUP_SCAN_BYTES,
  } = {}
) {
  if (!filePath || !turnId) {
    return false;
  }

  const stat = fsModule.statSync(filePath);
  const chunk = readFileSlice(
    filePath,
    0,
    Math.min(stat.size, scanBytes),
    fsModule
  );
  if (!chunk) {
    return false;
  }

  return chunk.includes(`"turn_id":"${turnId}"`) || chunk.includes(`"turnId":"${turnId}"`);
}

function rolloutFileContainsThreadId(
  filePath,
  threadId,
  {
    fsModule = fs,
    scanBytes = DEFAULT_THREAD_LOOKUP_SCAN_BYTES,
  } = {}
) {
  if (!filePath || !threadId) {
    return false;
  }

  const stat = fsModule.statSync(filePath);
  const chunk = readFileSlice(
    filePath,
    Math.max(0, stat.size - Math.min(stat.size, scanBytes)),
    stat.size,
    fsModule
  );
  if (!chunk) {
    return false;
  }

  return (
    chunk.includes(`"thread_id":"${threadId}"`)
      || chunk.includes(`"threadId":"${threadId}"`)
      || chunk.includes(`"conversation_id":"${threadId}"`)
      || chunk.includes(`"conversationId":"${threadId}"`)
  );
}

function formatRolloutLine(rawLine) {
  const trimmed = rawLine.trim();
  if (!trimmed) {
    return null;
  }

  let parsed = null;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }

  const timestamp = formatTimestamp(parsed.timestamp);
  const payload = parsed.payload || {};

  if (parsed.type === "event_msg") {
    const eventType = payload.type;
    if (eventType === "user_message") {
      return `${timestamp} Phone: ${previewText(payload.message)}`;
    }
    if (eventType === "agent_message") {
      return `${timestamp} Codex: ${previewText(payload.message)}`;
    }
    if (eventType === "task_started") {
      return `${timestamp} Task started`;
    }
    if (eventType === "task_complete") {
      return `${timestamp} Task complete`;
    }
  }

  return null;
}

// Extracts the latest usable context-window numbers from persisted token_count lines.
function readRolloutUsageChunk({
  filePath,
  start,
  endExclusive,
  carry = "",
  fsModule = fs,
  skipLeadingPartial = false,
} = {}) {
  if (!filePath || endExclusive <= start) {
    return { partialLine: carry, usage: null };
  }

  const chunk = readFileSlice(filePath, start, endExclusive, fsModule);
  if (!chunk) {
    return { partialLine: carry, usage: null };
  }

  const combined = `${carry}${chunk}`;
  const lines = combined.split("\n");
  const partialLine = lines.pop() || "";

  if (skipLeadingPartial && lines.length > 0) {
    lines.shift();
  }

  let latestUsage = null;
  for (const line of lines) {
    const usage = extractContextUsageFromRolloutLine(line);
    if (usage) {
      latestUsage = usage;
    }
  }

  return {
    partialLine,
    usage: latestUsage,
  };
}

function readFileSlice(filePath, start, endExclusive, fsModule = fs) {
  const length = Math.max(0, endExclusive - start);
  if (length === 0) {
    return "";
  }

  const fileHandle = fsModule.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytesRead = fsModule.readSync(fileHandle, buffer, 0, length, start);
    return buffer.toString("utf8", 0, bytesRead);
  } finally {
    fsModule.closeSync(fileHandle);
  }
}

function extractContextUsageFromRolloutLine(rawLine) {
  const trimmed = rawLine.trim();
  if (!trimmed) {
    return null;
  }

  let parsed = null;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }

  if (parsed?.type !== "event_msg") {
    return null;
  }

  const payload = parsed.payload;
  if (!payload || typeof payload !== "object" || payload.type !== "token_count") {
    return null;
  }

  return contextUsageFromTokenCountPayload(payload);
}

function contextUsageFromTokenCountPayload(payload) {
  const info = payload?.info;
  if (!info || typeof info !== "object") {
    return null;
  }

  // Prefer the last-turn snapshot over cumulative totals so the UI shows the
  // active context load, not the lifetime token count of the whole session file.
  const usageRoot = info.last_token_usage || info.lastTokenUsage || info.total_token_usage || info.totalTokenUsage;
  const tokenLimit = readPositiveInteger(
    info.model_context_window ?? info.modelContextWindow ?? info.context_window ?? info.contextWindow
  );
  if (!tokenLimit) {
    return null;
  }

  const tokensUsed = readPositiveInteger(usageRoot?.total_tokens ?? usageRoot?.totalTokens)
    ?? sumPositiveIntegers([
      usageRoot?.input_tokens ?? usageRoot?.inputTokens,
      usageRoot?.output_tokens ?? usageRoot?.outputTokens,
      usageRoot?.reasoning_output_tokens ?? usageRoot?.reasoningOutputTokens,
    ]);
  if (tokensUsed == null) {
    return null;
  }

  return {
    tokensUsed: Math.min(tokensUsed, tokenLimit),
    tokenLimit,
  };
}

function readPositiveInteger(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.max(0, Math.trunc(value));
  }

  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10);
    if (Number.isFinite(parsed)) {
      return Math.max(0, parsed);
    }
  }

  return null;
}

function sumPositiveIntegers(values) {
  let total = 0;
  let foundValue = false;

  for (const value of values) {
    const parsed = readPositiveInteger(value);
    if (parsed == null) {
      continue;
    }

    foundValue = true;
    total += parsed;
  }

  return foundValue ? total : null;
}

// Reads the newest usable token-count snapshot for a specific thread/turn from recent rollout files.
function readLatestContextWindowUsage({
  threadId = "",
  turnId = "",
  fsModule = fs,
  scanBytes = DEFAULT_CONTEXT_READ_SCAN_BYTES,
  candidateLimit = DEFAULT_CONTEXT_READ_CANDIDATE_LIMIT,
  lookbackMs = DEFAULT_RECENT_ROLLOUT_LOOKBACK_MS,
  now = () => Date.now(),
} = {}) {
  const rolloutRoot = resolveSessionsRoot();
  const rolloutPath = findRecentRolloutFileForContextRead(rolloutRoot, {
    threadId,
    turnId,
    fsModule,
    candidateLimit,
    lookbackMs,
    now,
  });
  if (!rolloutPath) {
    return null;
  }

  const stat = fsModule.statSync(rolloutPath);
  const boundedStart = Math.max(0, stat.size - Math.min(stat.size, scanBytes));
  let result = readRolloutUsageChunk({
    filePath: rolloutPath,
    start: boundedStart,
    endExclusive: stat.size,
    fsModule,
    skipLeadingPartial: boundedStart > 0,
  });

  if (!result.usage && boundedStart > 0) {
    result = readRolloutUsageChunk({
      filePath: rolloutPath,
      start: 0,
      endExclusive: stat.size,
      fsModule,
    });
  }

  return result.usage
    ? {
        rolloutPath,
        usage: result.usage,
      }
    : null;
}

function formatTimestamp(value) {
  if (!value || typeof value !== "string") {
    return "[time?]";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "[time?]";
  }

  return `[${date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}]`;
}

function previewText(value) {
  if (typeof value !== "string") {
    return "";
  }

  const normalized = value.replace(/\s+/g, " ").trim();
  if (normalized.length <= 120) {
    return normalized;
  }

  return `${normalized.slice(0, 117)}...`;
}

function readFileSize(filePath, fsModule = fs) {
  return fsModule.statSync(filePath).size;
}

function isRetryableFilesystemError(error) {
  return ["ENOENT", "EACCES", "EPERM", "EBUSY"].includes(error?.code);
}

module.exports = {
  watchThreadRollout,
  createThreadRolloutActivityWatcher,
  contextUsageFromTokenCountPayload,
  readLatestContextWindowUsage,
  resolveSessionsRoot,
  findRolloutFileForThread,
  findRecentRolloutFileForContextRead,
};
