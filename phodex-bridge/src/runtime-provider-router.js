// FILE: runtime-provider-router.js
// Purpose: Routes provider-aware Remodex RPCs between Codex app-server and additional local harnesses.
// Layer: Bridge runtime routing
// Exports: createRuntimeProviderRouter, mergeModelListResult, mergeThreadListResult
// Depends on: ./claude-models, ./claude-provider

const { createClaudeProvider } = require("./claude-provider");
const {
  CLAUDE_PROVIDER_ID,
  CODEX_PROVIDER_ID,
  isClaudeProvider,
  readModelProvider,
} = require("./claude-models");

const ROUTABLE_THREAD_METHODS = new Set([
  "thread/start",
  "thread/resume",
  "thread/read",
  "thread/turns/list",
  "thread/name/set",
  "thread/archive",
  "thread/unarchive",
  "turn/start",
  "turn/interrupt",
]);

function createRuntimeProviderRouter({
  sendCodexRequest,
  sendApplicationResponse,
  sendRuntimeMessage,
  claudeProvider = null,
  logPrefix = "[remodex]",
} = {}) {
  const provider = claudeProvider || createClaudeProvider({
    sendApplicationMessage: sendRuntimeMessage || sendApplicationResponse,
    logPrefix,
  });

  function handleApplicationMessage(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed) {
      return false;
    }

    if (parsed.id != null && !parsed.method && provider.handleApplicationResponse(parsed)) {
      return true;
    }

    const method = typeof parsed.method === "string" ? parsed.method.trim() : "";
    if (!method) {
      return false;
    }

    if (method === "model/list") {
      respondAsync(parsed, async () => {
        const codexResult = await sendCodexRequest("model/list", parsed.params || {});
        return mergeModelListResult(codexResult, provider.listModels());
      });
      return true;
    }

    if (method === "thread/list") {
      respondAsync(parsed, async () => {
        const codexResult = await sendCodexRequest("thread/list", parsed.params || {});
        // V1 keeps provider pagination simple: Claude local threads are merged
        // only into the first Codex page. A future composite cursor can make
        // this exact across large mixed-provider histories.
        const shouldIncludeClaude = !hasCursor(parsed.params);
        return mergeThreadListResult(
          codexResult,
          shouldIncludeClaude ? provider.listThreads(parsed.params || {}).data : []
        );
      });
      return true;
    }

    if (!ROUTABLE_THREAD_METHODS.has(method)) {
      return false;
    }

    if (!shouldRouteToClaude(parsed, provider)) {
      return false;
    }

    respondAsync(parsed, () => provider.handleRequest(parsed));
    return true;
  }

  function respondAsync(request, resolveResult) {
    Promise.resolve()
      .then(resolveResult)
      .then((result) => {
        if (request.id != null) {
          // JSON-RPC responses go back through the relay response path; runtime
          // events emitted by providers use sendRuntimeMessage so refresh/push
          // side effects still see thread-scoped lifecycle updates.
          sendApplicationResponse(JSON.stringify({
            id: request.id,
            result,
          }));
        }
      })
      .catch((error) => {
        if (request.id != null) {
          sendApplicationResponse(createJsonRpcErrorResponse(
            request.id,
            error,
            error?.errorCode || "runtime_provider_failed"
          ));
        }
      });
  }

  return {
    claudeProvider: provider,
    handleApplicationMessage,
    shutdown: () => provider.shutdown(),
  };
}

function shouldRouteToClaude(request, provider) {
  const params = request.params || {};
  const providerFromRequest = readModelProvider(params);
  if (isClaudeProvider(providerFromRequest)) {
    return true;
  }

  const threadId = readThreadId(params);
  return Boolean(threadId && provider.ownsThread(threadId));
}

function mergeModelListResult(codexResult, claudeModels) {
  const result = codexResult && typeof codexResult === "object" ? codexResult : {};
  const key = firstArrayKey(result, ["items", "data", "models"]) || "items";
  const codexModels = Array.isArray(result[key]) ? result[key] : [];
  const normalizedCodexModels = codexModels.map((model) => ({
    ...model,
    modelProvider: readModelProvider(model) || CODEX_PROVIDER_ID,
    provider: readModelProvider(model) || CODEX_PROVIDER_ID,
  }));
  return {
    ...result,
    [key]: [
      ...normalizedCodexModels,
      ...claudeModels,
    ],
  };
}

function mergeThreadListResult(codexResult, claudeThreads) {
  const result = codexResult && typeof codexResult === "object" ? codexResult : {};
  const key = firstArrayKey(result, ["data", "items", "threads"]) || "data";
  const codexThreads = Array.isArray(result[key]) ? result[key] : [];
  const merged = [
    ...codexThreads,
    ...claudeThreads,
  ].sort((lhs, rhs) => {
    const lhsTime = Date.parse(lhs?.updatedAt || lhs?.updated_at || lhs?.createdAt || lhs?.created_at || 0) || 0;
    const rhsTime = Date.parse(rhs?.updatedAt || rhs?.updated_at || rhs?.createdAt || rhs?.created_at || 0) || 0;
    return rhsTime - lhsTime;
  });
  return {
    ...result,
    [key]: merged,
  };
}

function firstArrayKey(value, keys) {
  return keys.find((key) => Array.isArray(value?.[key])) || "";
}

function hasCursor(params = {}) {
  const cursor = params.cursor ?? params.nextCursor ?? params.next_cursor;
  return cursor != null && cursor !== "" && cursor !== false;
}

function readThreadId(params = {}) {
  return readString(params.threadId || params.thread_id || params.id);
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function createJsonRpcErrorResponse(requestId, error, defaultErrorCode) {
  return JSON.stringify({
    id: requestId,
    error: {
      code: -32000,
      message: error?.userMessage || error?.message || "Runtime provider request failed.",
      data: {
        errorCode: error?.errorCode || defaultErrorCode,
      },
    },
  });
}

function safeParseJSON(rawMessage) {
  try {
    return JSON.parse(rawMessage);
  } catch {
    return null;
  }
}

module.exports = {
  createRuntimeProviderRouter,
  mergeModelListResult,
  mergeThreadListResult,
  shouldRouteToClaude,
};
