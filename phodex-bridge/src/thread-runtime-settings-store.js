// FILE: thread-runtime-settings-store.js
// Purpose: Persists the last accepted model, reasoning effort, and service tier for each local thread.
// Layer: CLI helper
// Exports: createThreadRuntimeSettingsStore, runtimeSettingsFromTurnParams
// Depends on: fs, os, path, ./thread-row-enrichment

const fs = require("fs");
const os = require("os");
const path = require("path");
const { forEachThreadRowInResponse } = require("./thread-row-enrichment");

const STORE_VERSION = 1;
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
} = {}) {
  let state = readState({ storeFile, fsImpl });

  function get(threadId) {
    const normalizedThreadId = normalizeString(threadId);
    if (!normalizedThreadId) {
      return null;
    }
    return cloneSettings(state.threads[normalizedThreadId]);
  }

  function commit(threadId, turnParams, { source = "unknown", turnId = "" } = {}) {
    const normalizedThreadId = normalizeString(threadId);
    const nextSource = normalizeString(source) || "unknown";
    // Runtime choices are intentionally one-way: the phone may configure the
    // runtime that executes its turn, while Desktop choices stay local.
    if (!normalizedThreadId || nextSource !== "phone") {
      return null;
    }
    const previous = state.threads[normalizedThreadId] || null;
    const nextValues = runtimeSettingsFromTurnParams(turnParams, previous);
    if (!nextValues.model && !nextValues.reasoningEffort && !previous) {
      return null;
    }

    const normalizedTurnId = normalizeString(turnId);
    if (previous
      && previous.turnId === normalizedTurnId
      && previous.model === nextValues.model
      && previous.reasoningEffort === nextValues.reasoningEffort
      && previous.serviceTier === nextValues.serviceTier) {
      return cloneSettings(previous);
    }

    const next = {
      model: nextValues.model || null,
      reasoningEffort: nextValues.reasoningEffort || null,
      serviceTier: nextValues.serviceTier,
      revision: Math.max(0, Number(previous?.revision) || 0) + 1,
      updatedAt: now(),
      source: nextSource,
      turnId: normalizedTurnId || null,
    };
    state.threads[normalizedThreadId] = next;
    pruneState(state, { now: now(), maxThreads, maxAgeMs });
    writeState(state, { storeFile, fsImpl });
    return cloneSettings(next);
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
    if (settings.model) {
      conversation.latestModel = settings.model;
    }
    if (settings.reasoningEffort) {
      conversation.latestReasoningEffort = settings.reasoningEffort;
    }
    conversation.latestServiceTier = settings.serviceTier;
    conversation.latestThreadSettings = {
      ...(conversation.latestThreadSettings && typeof conversation.latestThreadSettings === "object"
        ? conversation.latestThreadSettings
        : {}),
      model: settings.model,
      effort: settings.reasoningEffort,
      serviceTier: settings.serviceTier,
    };
    const collaborationSettings = conversation.latestCollaborationMode?.settings;
    conversation.latestCollaborationMode = {
      mode: conversation.latestCollaborationMode?.mode || "default",
      settings: {
        ...(collaborationSettings && typeof collaborationSettings === "object"
          ? collaborationSettings
          : { developer_instructions: null }),
        model: settings.model || collaborationSettings?.model || "",
        reasoning_effort: settings.reasoningEffort
          || collaborationSettings?.reasoning_effort
          || null,
      },
    };
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
    thread.model = settings.model || thread.model || null;
    thread.reasoningEffort = settings.reasoningEffort;
    thread.serviceTier = settings.serviceTier;
    thread.runtimeSettingsRevision = settings.revision;
    thread.runtimeSettingsUpdatedAt = settings.updatedAt;
    thread.runtimeSettingsSource = settings.source;
    return thread;
  }

  return {
    get,
    commit,
    attachToConversation,
    attachToThread,
    enrichResponse,
  };
}

function runtimeSettingsFromTurnParams(turnParams, previous = null) {
  const params = turnParams && typeof turnParams === "object" ? turnParams : {};
  const collaborationSettings = params.collaborationMode?.settings
    || params.collaboration_mode?.settings
    || {};
  const model = normalizeString(params.model)
    || normalizeString(collaborationSettings.model)
    || normalizeString(previous?.model)
    || null;
  const reasoningEffort = normalizeString(params.effort)
    || normalizeString(params.reasoningEffort)
    || normalizeString(collaborationSettings.reasoning_effort)
    || normalizeString(collaborationSettings.reasoningEffort)
    || normalizeString(previous?.reasoningEffort)
    || null;
  const serviceTier = normalizeString(params.serviceTier)
    || normalizeString(params.service_tier)
    || null;
  return { model, reasoningEffort, serviceTier };
}

function readState({ storeFile, fsImpl }) {
  try {
    const parsed = JSON.parse(fsImpl.readFileSync(storeFile, "utf8"));
    return normalizeState(parsed);
  } catch {
    return { version: STORE_VERSION, threads: {} };
  }
}

function normalizeState(rawState) {
  const rawThreads = rawState?.threads && typeof rawState.threads === "object"
    ? rawState.threads
    : {};
  const threads = {};
  for (const [threadId, rawSettings] of Object.entries(rawThreads)) {
    const normalizedThreadId = normalizeString(threadId);
    const source = normalizeString(rawSettings?.source) || "unknown";
    // Drop records written by older bidirectional builds so a Desktop choice
    // cannot be replayed to the phone after upgrading.
    if (!normalizedThreadId || !rawSettings || typeof rawSettings !== "object" || source !== "phone") {
      continue;
    }
    threads[normalizedThreadId] = {
      model: normalizeString(rawSettings.model) || null,
      reasoningEffort: normalizeString(rawSettings.reasoningEffort) || null,
      serviceTier: normalizeString(rawSettings.serviceTier) || null,
      revision: Math.max(0, Number(rawSettings.revision) || 0),
      updatedAt: Math.max(0, Number(rawSettings.updatedAt) || 0),
      source,
      turnId: normalizeString(rawSettings.turnId) || null,
    };
  }
  return { version: STORE_VERSION, threads };
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
