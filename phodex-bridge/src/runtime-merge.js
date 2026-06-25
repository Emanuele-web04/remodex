// FILE: runtime-merge.js
// Purpose: Merges Codex and OpenCode catalog/list payloads and strips provider fields for Codex fallback.
// Layer: Bridge runtime routing
// Exports: mergeModelListResult, mergeThreadListResult, stripRuntimeProviderFieldsForCodex, dedupeMergedThreads, firstArrayKey
// Depends on: ./normalize, ./opencode-models, ./provider-capabilities, ./safe-json

const { readString, resolvedParam } = require("./normalize");
const {
  CODEX_PROVIDER_ID,
  OPENCODE_PROVIDER_ID,
  compareThreadsByUpdatedAt,
  DISCOVERED_THREAD_ID_PREFIX,
  parseDiscoveredThreadSessionId,
  readModelProvider,
} = require("./opencode-models");
const { resolveModelCapabilities } = require("./provider-capabilities");
const { safeParseJSON } = require("./safe-json");

const PROVIDER_FIELD_KEYS = [
  "modelProvider",
  "model_provider",
  "provider",
  "runtimeProvider",
  "runtime_provider",
  "harness",
];

function firstArrayKey(value, keys) {
  return keys.find((key) => Array.isArray(value?.[key])) || "";
}

function readThreadIdentifier(thread = {}) {
  return resolvedParam(thread, "id", "threadId", "thread_id");
}

function readThreadSessionId(thread) {
  const metadata = thread?.metadata;
  const fromMetadata = metadata && typeof metadata === "object" ? metadata.sessionId : null;
  const threadId = readThreadIdentifier(thread);
  return (
    readString(fromMetadata) ||
    readString(thread?.sessionId) ||
    parseDiscoveredThreadSessionId(threadId)
  );
}

function isDiscoveredExternalThreadRow(thread) {
  const metadata = thread?.metadata;
  if (metadata && typeof metadata === "object" && metadata.discoveredExternally === true) {
    return true;
  }
  const threadId = readThreadIdentifier(thread);
  return Boolean(threadId && threadId.startsWith(DISCOVERED_THREAD_ID_PREFIX));
}

function hasProviderThreadMetadata(thread) {
  return readModelProvider(thread) !== CODEX_PROVIDER_ID;
}

function threadMergePreferenceScore(thread) {
  const threadId = readThreadIdentifier(thread);
  let score = 0;
  if (threadId && threadId.startsWith("opencode-thread-")) {
    score += 4;
  }
  if (hasProviderThreadMetadata(thread)) {
    score += 2;
  }
  if (isDiscoveredExternalThreadRow(thread)) {
    score -= 8;
  }
  const updatedAt = Date.parse(readString(thread?.updatedAt) || "") || 0;
  return { score, updatedAt };
}

function shouldReplaceThreadForSessionId(existingThread, candidateThread) {
  const existing = threadMergePreferenceScore(existingThread);
  const candidate = threadMergePreferenceScore(candidateThread);
  if (candidate.score !== existing.score) {
    return candidate.score > existing.score;
  }
  return candidate.updatedAt >= existing.updatedAt;
}

function dedupeMergedThreads(codexThreads, providerThreads) {
  const mergedById = new Map();
  const ownedSessionIds = new Set();
  const sessionIdToThreadId = new Map();

  const rememberOwnedSession = (thread) => {
    const sessionId = readThreadSessionId(thread);
    if (!sessionId || isDiscoveredExternalThreadRow(thread)) {
      return;
    }
    ownedSessionIds.add(sessionId);
    const threadId = readThreadIdentifier(thread);
    if (threadId) {
      sessionIdToThreadId.set(sessionId, threadId);
    }
  };

  const upsertThread = (thread) => {
    const threadId = readThreadIdentifier(thread);
    if (!threadId) {
      return;
    }
    const sessionId = readThreadSessionId(thread);
    if (sessionId && !isDiscoveredExternalThreadRow(thread)) {
      const existingThreadId = sessionIdToThreadId.get(sessionId);
      if (existingThreadId && existingThreadId !== threadId) {
        const existingThread = mergedById.get(existingThreadId);
        if (existingThread && !shouldReplaceThreadForSessionId(existingThread, thread)) {
          return;
        }
        mergedById.delete(existingThreadId);
      }
      sessionIdToThreadId.set(sessionId, threadId);
      ownedSessionIds.add(sessionId);
    }
    if (!mergedById.has(threadId) || hasProviderThreadMetadata(thread)) {
      mergedById.set(threadId, thread);
    }
  };

  for (const thread of codexThreads) {
    upsertThread(thread);
    rememberOwnedSession(thread);
  }

  for (const thread of providerThreads) {
    rememberOwnedSession(thread);
  }

  for (const thread of providerThreads) {
    const threadId = readThreadIdentifier(thread);
    if (!threadId) {
      continue;
    }

    if (isDiscoveredExternalThreadRow(thread)) {
      const sessionId = readThreadSessionId(thread);
      if (sessionId && ownedSessionIds.has(sessionId)) {
        continue;
      }
    }

    upsertThread(thread);
  }
  return Array.from(mergedById.values());
}

function mergeModelListResult(codexResult, providerModels, extras = {}) {
  const result = codexResult && typeof codexResult === "object" ? codexResult : {};
  const key = firstArrayKey(result, ["items", "data", "models"]) || "items";
  const codexModels = Array.isArray(result[key]) ? result[key] : [];
  const normalizedCodexModels = codexModels.map((model) => {
    const capabilities = resolveModelCapabilities(CODEX_PROVIDER_ID, model);
    return {
      ...model,
      modelProvider: CODEX_PROVIDER_ID,
      provider: CODEX_PROVIDER_ID,
      capabilities,
    };
  });
  const normalizedProviderModels = providerModels.map((model) => {
    const provider = readModelProvider(model) || OPENCODE_PROVIDER_ID;
    return {
      ...model,
      modelProvider: provider,
      provider,
      capabilities: model.capabilities ?? resolveModelCapabilities(provider, model),
    };
  });

  const merged = {
    ...result,
    [key]: [...normalizedCodexModels, ...normalizedProviderModels],
  };
  if (extras.opencode && typeof extras.opencode === "object") {
    merged.opencode = extras.opencode;
  }
  return merged;
}

function mergeThreadListResult(codexResult, providerThreads, extras = {}) {
  const result = codexResult && typeof codexResult === "object" ? codexResult : {};
  const key = firstArrayKey(result, ["data", "items", "threads"]) || "data";
  const codexThreads = Array.isArray(result[key]) ? result[key] : [];
  const merged = dedupeMergedThreads(codexThreads, providerThreads).toSorted(
    compareThreadsByUpdatedAt,
  );
  const mergedResult = {
    ...result,
    [key]: merged,
  };
  if (extras.meta && typeof extras.meta === "object") {
    mergedResult.meta = {
      ...(result.meta && typeof result.meta === "object" ? result.meta : {}),
      ...extras.meta,
    };
  }
  return mergedResult;
}

function stripProviderFieldsFromObject(value) {
  const result = { ...value };
  for (const key of PROVIDER_FIELD_KEYS) {
    delete result[key];
  }

  for (const key of ["collaborationMode", "collaboration_mode"]) {
    if (!result[key] || typeof result[key] !== "object" || Array.isArray(result[key])) {
      continue;
    }
    const collaborationMode = { ...result[key] };
    if (collaborationMode.settings && typeof collaborationMode.settings === "object") {
      collaborationMode.settings = stripProviderFieldsFromObject(collaborationMode.settings);
    }
    result[key] = collaborationMode;
  }

  return result;
}

function stripRuntimeProviderFieldsForCodex(rawMessage) {
  const parsed = safeParseJSON(rawMessage);
  if (
    !parsed ||
    !parsed.params ||
    typeof parsed.params !== "object" ||
    Array.isArray(parsed.params)
  ) {
    return rawMessage;
  }

  const params = stripProviderFieldsFromObject(parsed.params);
  return JSON.stringify({
    ...parsed,
    params,
  });
}

module.exports = {
  PROVIDER_FIELD_KEYS,
  dedupeMergedThreads,
  firstArrayKey,
  mergeModelListResult,
  mergeThreadListResult,
  stripRuntimeProviderFieldsForCodex,
  stripProviderFieldsFromObject,
};
