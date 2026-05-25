// FILE: thread-agent-state.js
// Purpose: Persists per-thread agent runtime metadata for bridge-owned routing state.
// Layer: Bridge core
// Exports: thread runtime state store helpers
// Depends on: fs, path, ./daemon-state, ./agent-runtime-capabilities

const fs = require("fs");
const path = require("path");
const {
  ensureRemodexStateDir,
  resolveRemodexStateDir,
} = require("./daemon-state");
const {
  DEFAULT_AGENT_RUNTIME,
  OPENCODE_DEFAULT_BUILD_AGENT_NAME,
  OPENCODE_DEFAULT_PLAN_AGENT_NAME,
  normalizeAgentRuntimeId,
} = require("./agent-runtime-capabilities");

const THREAD_AGENT_STATE_FILE = "thread-agent-state.json";
const STATE_VERSION = 1;

function resolveThreadAgentStatePath(options = {}) {
  return path.join(resolveRemodexStateDir(options), THREAD_AGENT_STATE_FILE);
}

function createEmptyState() {
  return {
    version: STATE_VERSION,
    threads: {},
  };
}

function readStateFile(options = {}) {
  const statePath = resolveThreadAgentStatePath(options);
  const fsImpl = options.fsImpl || fs;

  if (!fsImpl.existsSync(statePath)) {
    return createEmptyState();
  }

  try {
    const parsed = JSON.parse(fsImpl.readFileSync(statePath, "utf8"));
    if (!parsed || typeof parsed !== "object") {
      return createEmptyState();
    }

    return {
      version: STATE_VERSION,
      threads: parsed.threads && typeof parsed.threads === "object" ? parsed.threads : {},
    };
  } catch {
    return createEmptyState();
  }
}

function writeStateFile(state, options = {}) {
  const fsImpl = options.fsImpl || fs;
  ensureRemodexStateDir({ fsImpl, ...options });
  const statePath = resolveThreadAgentStatePath(options);
  const payload = {
    version: STATE_VERSION,
    threads: state.threads && typeof state.threads === "object" ? state.threads : {},
  };
  fsImpl.writeFileSync(statePath, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  try {
    fsImpl.chmodSync(statePath, 0o600);
  } catch {
    // Best-effort only on filesystems without POSIX mode support.
  }
}

function normalizeThreadRecord(threadId, record = {}, { now = () => new Date().toISOString() } = {}) {
  const timestamp = now();
  const agentRuntime = normalizeAgentRuntimeId(record.agentRuntime) || DEFAULT_AGENT_RUNTIME;
  const agentSessionId = normalizeNonEmptyString(record.agentSessionId)
    || (agentRuntime === DEFAULT_AGENT_RUNTIME ? threadId : "");

  return {
    agentRuntime,
    agentSessionId,
    cwd: normalizeNonEmptyString(record.cwd),
    opencodeBuildAgentName: normalizeNonEmptyString(record.opencodeBuildAgentName)
      || OPENCODE_DEFAULT_BUILD_AGENT_NAME,
    opencodePlanAgentName: normalizeNonEmptyString(record.opencodePlanAgentName)
      || OPENCODE_DEFAULT_PLAN_AGENT_NAME,
    runtimeLocked: record.runtimeLocked === true,
    createdAt: normalizeNonEmptyString(record.createdAt) || timestamp,
    updatedAt: timestamp,
  };
}

function createThreadAgentStateStore(options = {}) {
  let state = readStateFile(options);

  function persist() {
    writeStateFile(state, options);
  }

  function get(threadId) {
    const normalizedThreadId = normalizeNonEmptyString(threadId);
    if (!normalizedThreadId) {
      return null;
    }

    const record = state.threads[normalizedThreadId];
    return record ? { ...record } : null;
  }

  function getOrBackfillCodex(threadId, { cwd = "" } = {}) {
    const normalizedThreadId = normalizeNonEmptyString(threadId);
    if (!normalizedThreadId) {
      return null;
    }

    const existing = get(normalizedThreadId);
    if (existing) {
      return existing;
    }

    const backfilled = normalizeThreadRecord(normalizedThreadId, {
      agentRuntime: DEFAULT_AGENT_RUNTIME,
      agentSessionId: normalizedThreadId,
      cwd,
      runtimeLocked: false,
    }, options);
    state.threads[normalizedThreadId] = backfilled;
    persist();
    return { ...backfilled };
  }

  function upsert(threadId, patch = {}) {
    const normalizedThreadId = normalizeNonEmptyString(threadId);
    if (!normalizedThreadId) {
      return null;
    }

    const existing = state.threads[normalizedThreadId] || {};
    const next = normalizeThreadRecord(normalizedThreadId, {
      ...existing,
      ...patch,
      createdAt: existing.createdAt,
    }, options);
    state.threads[normalizedThreadId] = next;
    persist();
    return { ...next };
  }

  function lockRuntime(threadId, patch = {}) {
    return upsert(threadId, {
      ...patch,
      runtimeLocked: true,
    });
  }

  function inherit(fromThreadId, toThreadId, { agentSessionId = "" } = {}) {
    const normalizedSourceId = normalizeNonEmptyString(fromThreadId);
    const normalizedDestinationId = normalizeNonEmptyString(toThreadId);
    if (!normalizedSourceId || !normalizedDestinationId || normalizedSourceId === normalizedDestinationId) {
      return null;
    }

    const source = get(normalizedSourceId);
    if (!source) {
      return null;
    }

    return upsert(normalizedDestinationId, {
      agentRuntime: source.agentRuntime,
      agentSessionId: normalizeNonEmptyString(agentSessionId) || normalizedDestinationId,
      cwd: source.cwd,
      opencodeBuildAgentName: source.opencodeBuildAgentName,
      opencodePlanAgentName: source.opencodePlanAgentName,
      runtimeLocked: source.runtimeLocked,
      createdAt: source.createdAt,
    });
  }

  function isRuntimeLocked(threadId) {
    return get(threadId)?.runtimeLocked === true;
  }

  function reload() {
    state = readStateFile(options);
  }

  return {
    get,
    getOrBackfillCodex,
    upsert,
    inherit,
    lockRuntime,
    isRuntimeLocked,
    reload,
    readSnapshot() {
      return {
        version: state.version,
        threads: { ...state.threads },
      };
    },
  };
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  THREAD_AGENT_STATE_FILE,
  createThreadAgentStateStore,
  normalizeThreadRecord,
  readStateFile,
  resolveThreadAgentStatePath,
  writeStateFile,
};
