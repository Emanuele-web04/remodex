// FILE: thread-runtime-settings-store.js
// Purpose: Persists the last accepted model, reasoning effort, and service tier for each local thread.
// Layer: CLI helper
// Exports: createThreadRuntimeSettingsStore, runtimeSettingsFromTurnParams
// Depends on: fs, os, path, ./thread-row-enrichment

const fs = require("fs");
const os = require("os");
const path = require("path");
const { forEachThreadRowInResponse } = require("./thread-row-enrichment");

const { randomUUID } = require("crypto");
const { runtimeSettingsPatch, runtimeSettingsFromConversation } = require("./codex-runtime-settings");

const STORE_VERSION = 2;
const DEFAULT_MAX_THREADS = 500;
const DEFAULT_MAX_AGE_MS = 180 * 24 * 60 * 60 * 1_000;
const DEFAULT_STORE_DIR = path.join(os.homedir(), ".remodex");

function createThreadRuntimeSettingsStore({
  storeFile = process.env.REMODEX_THREAD_RUNTIME_STATE_FILE
    || path.join(process.env.REMODEX_DEVICE_STATE_DIR || DEFAULT_STORE_DIR, "thread-runtime-settings.json"),
  fsImpl = fs,
  now = () => Date.now(),
  maxThreads = DEFAULT_MAX_THREADS,
  maxAgeMs = DEFAULT_MAX_AGE_MS,
  onChange = () => {},
  onError = (error) => console.warn(`[remodex] runtime settings persistence failed: ${error.message}`),
} = {}) {
  let state = readState({ storeFile, fsImpl });

  function get(threadId) {
    const normalizedThreadId = normalizeString(threadId);
    if (!normalizedThreadId) {
      return null;
    }
    const settings = state.threads[normalizedThreadId];
    return settings?.confirmed ? cloneSettings(settings) : null;
  }

  function commit(threadId, turnParams, { source = "unknown", turnId = "" } = {}) {
    const normalizedThreadId = normalizeString(threadId);
    const nextSource = normalizeString(source) || "unknown";
    if (!normalizedThreadId || !["phone", "desktop", "runtime"].includes(nextSource)) {
      return null;
    }
    const previous = get(normalizedThreadId);
    const nextValues = runtimeSettingsFromTurnParams(turnParams, previous, { authoritative: source === "runtime" });
    if (Object.keys(nextValues).length === 0) {
      return null;
    }

    const normalizedTurnId = normalizeString(turnId);
    if (previous
      && previous.model === nextValues.model
      && previous.reasoningEffort === nextValues.reasoningEffort
      && previous.serviceTier === nextValues.serviceTier) {
      return cloneSettings(previous);
    }

    const next = {
      ...nextValues,
      revision: Math.max(0, Number(previous?.revision) || 0) + 1,
      updatedAt: Math.max(now(), (previous?.updatedAt || 0) + 1),
      epoch: previous?.epoch || randomUUID(),
      confirmed: true,
      source: nextSource,
      turnId: normalizedTurnId || null,
    };
    const nextState = { ...state, threads: { ...state.threads, [normalizedThreadId]: next } };
    pruneState(nextState, { now: now(), maxThreads, maxAgeMs });
    writeState(nextState, { storeFile, fsImpl });
    state = nextState;
    onChange(normalizedThreadId, cloneSettings(next));
    return cloneSettings(next);
  }

  // Unsolicited owner notifications must not interrupt the live event stream
  // when the local settings cache cannot be written. A later snapshot retries.
  function observe(threadId, settings, source = "runtime") {
    try {
      return commit(threadId, settings, { source });
    } catch (error) {
      onError(error);
      return get(threadId);
    }
  }

  function attachToConversation(threadId, conversation) {
    if (!conversation || typeof conversation !== "object") {
      return conversation;
    }
    const settings = get(threadId);
    if (!settings) {
      return conversation;
    }
    conversation.remodexRuntimeSettings = settings;
    return conversation;
  }

  function enrichResponse(method, envelope) {
    return forEachThreadRowInResponse(method, envelope, attachToThread);
  }

  function attachToThread(thread) {
    const threadId = normalizeString(thread?.id) || normalizeString(thread?.threadId);
    const settings = get(threadId);
    if (!settings || !thread || typeof thread !== "object") {
      return thread;
    }
    thread.runtimeSettings = settings;
    // Legacy phone fields remain readable, while the v2 object explicitly
    // represents next-turn choices rather than an executing turn's metadata.
    thread.model ||= settings.model;
    if (Object.hasOwn(settings, "reasoningEffort")) thread.reasoningEffort = settings.reasoningEffort;
    if (Object.hasOwn(settings, "serviceTier")) thread.serviceTier = settings.serviceTier === "priority" ? "fast" : settings.serviceTier;
    thread.runtimeSettingsRevision = settings.revision;
    thread.runtimeSettingsUpdatedAt = settings.updatedAt;
    thread.runtimeSettingsSource = settings.source;
    return thread;
  }

  return {
    get,
    commit,
    observe,
    attachToConversation,
    attachToThread,
    enrichResponse,
    observeConversation(threadId, conversation) {
      const patch = runtimeSettingsFromConversation(conversation);
      if (!patch.model) return get(threadId);
      const settings = observe(threadId, patch, "desktop");
      attachToConversation(threadId, conversation);
      return settings;
    },
  };
}

function runtimeSettingsFromTurnParams(turnParams, previous = null, options = {}) {
  return {
    ...runtimeSettingsPatch(previous || {}),
    ...runtimeSettingsPatch(turnParams, options),
  };
}

function readState({ storeFile, fsImpl }) {
  try {
    const parsed = JSON.parse(fsImpl.readFileSync(storeFile, "utf8"));
    return normalizeState(parsed);
  } catch {
    return { version: STORE_VERSION, epoch: randomUUID(), threads: {} };
  }
}

function normalizeState(rawState) {
  const rawThreads = rawState?.threads && typeof rawState.threads === "object"
    ? rawState.threads
    : {};
  const threads = {};
  const epoch = normalizeString(rawState?.epoch) || randomUUID();
  for (const [threadId, rawSettings] of Object.entries(rawThreads)) {
    const normalizedThreadId = normalizeString(threadId);
    const source = normalizeString(rawSettings?.source) || "unknown";
    if (!normalizedThreadId || !rawSettings || typeof rawSettings !== "object") {
      continue;
    }
    threads[normalizedThreadId] = {
      ...runtimeSettingsFromTurnParams(rawSettings),
      epoch: normalizeString(rawSettings.epoch) || epoch,
      // Preserve old preferences on disk, but require fresh owner evidence
      // before exposing them as confirmed runtime state.
      confirmed: rawState.version === STORE_VERSION && rawSettings.confirmed === true,
      revision: Math.max(0, Number(rawSettings.revision) || 0),
      updatedAt: Math.max(0, Number(rawSettings.updatedAt) || 0),
      source,
      turnId: normalizeString(rawSettings.turnId) || null,
    };
  }
  return { version: STORE_VERSION, epoch, threads };
}

function pruneState(storeState, { now, maxThreads, maxAgeMs }) {
  const entries = Object.entries(storeState.threads)
    .filter(([, settings]) => !maxAgeMs || now - settings.updatedAt <= maxAgeMs)
    .sort((left, right) => right[1].updatedAt - left[1].updatedAt)
    .slice(0, Math.max(1, maxThreads));
  storeState.threads = Object.fromEntries(entries);
}

function writeState(storeState, { storeFile, fsImpl }) {
  const directory = path.dirname(storeFile);
  const temporaryFile = `${storeFile}.tmp`;
  fsImpl.mkdirSync(directory, { recursive: true });
  fsImpl.writeFileSync(temporaryFile, JSON.stringify(storeState, null, 2), { mode: 0o600 });
  fsImpl.renameSync(temporaryFile, storeFile);
  try {
    fsImpl.chmodSync(storeFile, 0o600);
  } catch {
    // Best-effort only on filesystems without POSIX permissions.
  }
}

function cloneSettings(settings) {
  return settings ? { ...settings } : null;
}

function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

module.exports = {
  createThreadRuntimeSettingsStore,
  runtimeSettingsFromTurnParams,
};
