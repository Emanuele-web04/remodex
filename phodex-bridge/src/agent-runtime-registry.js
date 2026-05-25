// FILE: agent-runtime-registry.js
// Purpose: Dispatches bridge runtime routing, status, initialize payloads, and thread runtime projection.
// Layer: Bridge core
// Exports: createAgentRuntimeRegistry
// Depends on: child_process, util, ./agent-runtime-capabilities, ./codex-runtime-adapter, ./thread-agent-state

const { execFile } = require("child_process");
const { promisify } = require("util");
const {
  DEFAULT_AGENT_RUNTIME,
  OPENCODE_DEFAULT_BUILD_AGENT_NAME,
  OPENCODE_DEFAULT_PLAN_AGENT_NAME,
  buildRuntimeListEntry,
  normalizeAgentRuntimeId,
} = require("./agent-runtime-capabilities");
const {
  createCodexModelCatalog,
  createCursorModelCatalog,
  createOpenCodeModelCatalog,
} = require("./agent-runtime-model-catalog");
const { createCodexRuntimeAdapter } = require("./codex-runtime-adapter");
const { createThreadAgentStateStore } = require("./thread-agent-state");

const execFileAsync = promisify(execFile);

const RUNTIME_REQUEST_METHOD_PREFIXES = [
  "thread/",
  "turn/",
];

function createAgentRuntimeRegistry({
  threadAgentState = createThreadAgentStateStore(),
  codexAdapter = createCodexRuntimeAdapter(),
  runtimeAdapters = [],
  execFileImpl = execFileAsync,
  logPrefix = "[remodex]",
  logImpl = console,
} = {}) {
  let cachedRuntimeStatuses = new Map();
  let cachedInitializeResult = null;
  const pendingThreadStartRequestIds = new Set();
  const pendingForkSourceByRequestId = new Map();
  const adaptersByRuntime = new Map();
  for (const adapter of [codexAdapter, ...runtimeAdapters]) {
    const runtimeId = normalizeAgentRuntimeId(adapter?.id);
    if (runtimeId) {
      adaptersByRuntime.set(runtimeId, adapter);
    }
  }

  async function resolveOpenCodeStatus({ forceRefresh = false } = {}) {
    const openCodeAdapter = adaptersByRuntime.get("opencode");
    if (openCodeAdapter && typeof openCodeAdapter.getRuntimeListEntry === "function") {
      if (!forceRefresh && cachedRuntimeStatuses.has("opencode")) {
        return cachedRuntimeStatuses.get("opencode");
      }
      const entry = await openCodeAdapter.getRuntimeListEntry();
      cachedRuntimeStatuses.set("opencode", entry);
      return entry;
    }

    if (!forceRefresh && cachedRuntimeStatuses.has("opencode")) {
      return cachedRuntimeStatuses.get("opencode");
    }

    let openCodeStatus;
    try {
      await execFileImpl("opencode", ["--version"], {
        timeout: 3_000,
        maxBuffer: 256 * 1024,
      });
      openCodeStatus = buildRuntimeListEntry({
        id: "opencode",
        status: "degraded",
        statusMessage: "OpenCode is installed; status reported via runtime adapter when registered.",
        modelCatalog: createOpenCodeModelCatalog(),
      });
    } catch (error) {
      if (isMissingCommandError(error)) {
        openCodeStatus = buildRuntimeListEntry({
          id: "opencode",
          status: "not_installed",
          statusMessage: "Install OpenCode on this Mac to enable the OpenCode runtime.",
          modelCatalog: createOpenCodeModelCatalog(),
        });
      } else {
        logImpl.warn?.(`${logPrefix} OpenCode status probe failed without affecting Codex: ${error?.message || error}`);
        openCodeStatus = buildRuntimeListEntry({
          id: "opencode",
          status: "error",
          statusMessage: "Could not determine OpenCode status on this Mac.",
          modelCatalog: createOpenCodeModelCatalog(),
        });
      }
    }

    cachedRuntimeStatuses.set("opencode", openCodeStatus);
    return openCodeStatus;
  }

  async function refreshInitializeCache() {
    cachedInitializeResult = {
      ...buildInitializePayload(),
      agentRuntimes: await listAgentRuntimes(),
    };
    return cachedInitializeResult;
  }

  function buildCachedInitializeResult() {
    if (cachedInitializeResult) {
      return cachedInitializeResult;
    }

    return {
      ...buildInitializePayload(),
      agentRuntimes: [
        buildRuntimeListEntry({ id: "codex", status: "ready" }),
        buildRuntimeListEntry({
          id: "opencode",
          status: "not_installed",
          statusMessage: "Install OpenCode on this Mac to enable the OpenCode runtime.",
          modelCatalog: createOpenCodeModelCatalog(),
        }),
        buildRuntimeListEntry({
          id: "cursor",
          status: "not_installed",
          statusMessage: "Install Cursor Agent on this Mac to enable the Cursor runtime.",
          modelCatalog: createCursorModelCatalog(),
        }),
      ],
    };
  }

  async function listAgentRuntimes() {
    const [codexEntry, openCodeEntry, cursorEntry] = await Promise.all([
      resolveRuntimeListEntry("codex"),
      resolveOpenCodeStatus(),
      resolveRuntimeListEntry("cursor"),
    ]);

    return [
      codexEntry,
      openCodeEntry,
      cursorEntry,
    ];
  }

  async function resolveRuntimeListEntry(runtimeId) {
    const adapter = adaptersByRuntime.get(runtimeId);
    if (adapter && typeof adapter.getRuntimeListEntry === "function") {
      const entry = await adapter.getRuntimeListEntry();
      cachedRuntimeStatuses.set(runtimeId, entry);
      return entry;
    }

    if (runtimeId === "cursor") {
      return buildRuntimeListEntry({
        id: "cursor",
        status: "not_installed",
        statusMessage: "Install Cursor Agent on this Mac to enable the Cursor runtime.",
        modelCatalog: createCursorModelCatalog(),
      });
    }

    return buildRuntimeListEntry({
      id: runtimeId,
      status: "ready",
      modelCatalog: runtimeId === "codex" ? createCodexModelCatalog() : null,
    });
  }

  function buildInitializePayload() {
    return {
      bridgeManaged: true,
      defaultAgentRuntime: DEFAULT_AGENT_RUNTIME,
    };
  }

  async function buildInitializeResult() {
    return refreshInitializeCache();
  }

  function buildWarmInitializeResult() {
    if (cachedInitializeResult) {
      return cachedInitializeResult;
    }
    return buildCachedInitializeResult();
  }

  function parseJsonRpcMessage(rawMessage) {
    try {
      return JSON.parse(rawMessage);
    } catch {
      return null;
    }
  }

  function createJsonRpcResultResponse(requestId, result) {
    return JSON.stringify({
      id: requestId,
      result,
    });
  }

  function createJsonRpcErrorResponse(requestId, message, errorCode = "agent_runtime_error") {
    return JSON.stringify({
      id: requestId,
      error: {
        code: -32000,
        message,
        data: { errorCode },
      },
    });
  }

  async function handleInboundRequest(rawMessage, sendResponse) {
    const parsed = parseJsonRpcMessage(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "agent/runtime/list" || parsed.id == null) {
      return false;
    }

    sendResponse(createJsonRpcResultResponse(parsed.id, {
      defaultAgentRuntime: DEFAULT_AGENT_RUNTIME,
      agentRuntimes: await listAgentRuntimes(),
    }));
    return true;
  }

  async function handleRuntimeRequest(rawMessage, {
    sendResponse,
    sendToRuntime,
  } = {}) {
    const parsed = parseJsonRpcMessage(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (!isRuntimeRequestMethod(method)) {
      return false;
    }

    const routing = resolveRuntimeRouting(parsed);
    if (!routing.routed) {
      return false;
    }

    if (method === "thread/start") {
      const validation = validateThreadStartRequest(rawMessage);
      if (!validation.allowed) {
        sendRuntimeError(sendResponse, validation.requestId, validation.message, validation.errorCode);
        return true;
      }
      routing.agentRuntime = validation.requestedRuntime || routing.agentRuntime;
    }

    const adapter = adaptersByRuntime.get(routing.agentRuntime);
    if (!adapter || typeof adapter.handleRuntimeRequest !== "function") {
      sendRuntimeError(
        sendResponse,
        parsed.id,
        `Agent runtime "${routing.agentRuntime}" is not available on this bridge yet.`,
        "agent_runtime_unavailable"
      );
      return true;
    }

    try {
      await adapter.handleRuntimeRequest({
        rawMessage,
        parsed,
        agentRuntime: routing.agentRuntime,
        threadId: routing.threadId,
        sendResponse,
        sendToRuntime: (message) => {
          if (typeof sendToRuntime !== "function") {
            throw new Error("Runtime dispatch requires a sendToRuntime callback.");
          }
          sendToRuntime(routing.agentRuntime, message);
        },
      });
    } catch (error) {
      logImpl.warn?.(`${logPrefix} ${routing.agentRuntime} runtime request failed: ${error?.message || error}`);
      sendRuntimeError(
        sendResponse,
        parsed.id,
        `Agent runtime "${routing.agentRuntime}" failed to handle ${method}.`,
        "agent_runtime_dispatch_failed"
      );
    }

    return true;
  }

  async function handleRuntimeResponse(rawMessage, {
    sendResponse,
  } = {}) {
    const parsed = parseJsonRpcMessage(rawMessage);
    if (!parsed || parsed.method || parsed.id == null) {
      return false;
    }

    for (const adapter of adaptersByRuntime.values()) {
      if (typeof adapter.handleRuntimeResponse !== "function") {
        continue;
      }
      try {
        if (await adapter.handleRuntimeResponse({ rawMessage, parsed, sendResponse })) {
          return true;
        }
      } catch (error) {
        logImpl.warn?.(`${logPrefix} runtime response routing failed: ${error?.message || error}`);
        sendRuntimeError(
          sendResponse,
          parsed.id,
          "Agent runtime failed to handle this response.",
          "agent_runtime_response_failed"
        );
        return true;
      }
    }

    return false;
  }

  function extractRequestedAgentRuntime(params = {}) {
    return normalizeAgentRuntimeId(params.agentRuntime)
      || normalizeAgentRuntimeId(params.agent_runtime)
      || DEFAULT_AGENT_RUNTIME;
  }

  function extractThreadIdFromParams(params = {}) {
    return readString(params.threadId)
      || readString(params.thread_id)
      || readString(params.thread?.id)
      || readString(params.thread?.threadId)
      || readString(params.thread?.thread_id);
  }

  function extractThreadCwd(params = {}) {
    return readString(params.cwd)
      || readString(params.workingDirectory)
      || readString(params.working_directory)
      || readString(params.thread?.cwd);
  }

  function isRuntimeRequestMethod(method) {
    return RUNTIME_REQUEST_METHOD_PREFIXES.some((prefix) => method.startsWith(prefix));
  }

  function resolveRuntimeRouting(parsed) {
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    const params = parsed?.params && typeof parsed.params === "object" ? parsed.params : {};
    if (!isRuntimeRequestMethod(method)) {
      return { routed: false };
    }

    if (method === "thread/list") {
      return {
        routed: true,
        agentRuntime: DEFAULT_AGENT_RUNTIME,
        threadId: "",
      };
    }

    if (method === "thread/start") {
      return {
        routed: true,
        agentRuntime: extractRequestedAgentRuntime(params),
        threadId: extractThreadIdFromParams(params),
      };
    }

    const threadId = extractThreadIdFromParams(params);
    const runtimeRecord = threadId ? threadAgentState.getOrBackfillCodex(threadId, {
      cwd: extractThreadCwd(params),
    }) : null;

    return {
      routed: true,
      agentRuntime: runtimeRecord?.agentRuntime || DEFAULT_AGENT_RUNTIME,
      threadId,
    };
  }

  function sendRuntimeError(sendResponse, requestId, message, errorCode) {
    if (typeof sendResponse !== "function" || requestId == null) {
      return;
    }
    sendResponse(createJsonRpcErrorResponse(requestId, message, errorCode));
  }

  function hasRuntimeAdapter(agentRuntime) {
    const adapter = adaptersByRuntime.get(agentRuntime);
    return Boolean(adapter && typeof adapter.handleRuntimeRequest === "function");
  }

  function validateThreadStartRequest(rawMessage) {
    const parsed = parseJsonRpcMessage(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "thread/start") {
      return { allowed: true };
    }

    const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
    const threadId = extractThreadIdFromParams(params);
    const requestedRuntime = extractRequestedAgentRuntime(params);

    if (parsed.id != null) {
      pendingThreadStartRequestIds.add(String(parsed.id));
    }

    if (threadId) {
      const existing = threadAgentState.get(threadId) || threadAgentState.getOrBackfillCodex(threadId, {
        cwd: extractThreadCwd(params),
      });

      if (existing?.runtimeLocked && existing.agentRuntime !== requestedRuntime) {
        return {
          allowed: false,
          requestId: parsed.id,
          message: `Thread ${threadId} is locked to agent runtime "${existing.agentRuntime}".`,
          errorCode: "agent_runtime_locked",
        };
      }
    }

    if (!hasRuntimeAdapter(requestedRuntime)) {
      return {
        allowed: false,
        requestId: parsed.id,
        message: `Agent runtime "${requestedRuntime}" is not available on this bridge yet.`,
        errorCode: "agent_runtime_unavailable",
      };
    }

    if (!threadId) {
      return { allowed: true, requestedRuntime };
    }

    const existing = threadAgentState.get(threadId) || threadAgentState.getOrBackfillCodex(threadId, {
      cwd: extractThreadCwd(params),
    });

    const explicitSessionId = readString(params.agentSessionId)
      || readString(params.agent_session_id);
    const upsertPatch = {
      agentRuntime: requestedRuntime,
      cwd: extractThreadCwd(params) || existing?.cwd || "",
      opencodeBuildAgentName: readString(params.opencodeBuildAgentName)
        || readString(params.opencode_build_agent_name)
        || existing?.opencodeBuildAgentName
        || OPENCODE_DEFAULT_BUILD_AGENT_NAME,
      opencodePlanAgentName: readString(params.opencodePlanAgentName)
        || readString(params.opencode_plan_agent_name)
        || existing?.opencodePlanAgentName
        || OPENCODE_DEFAULT_PLAN_AGENT_NAME,
      runtimeLocked: existing?.runtimeLocked === true,
    };
    if (explicitSessionId) {
      upsertPatch.agentSessionId = explicitSessionId;
    } else if (requestedRuntime === DEFAULT_AGENT_RUNTIME) {
      upsertPatch.agentSessionId = threadId;
    }
    threadAgentState.upsert(threadId, upsertPatch);

    return { allowed: true, requestedRuntime, threadId };
  }

  function trackForwardedRequest(rawMessage) {
    const parsed = parseJsonRpcMessage(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "thread/fork" || parsed?.id == null) {
      return;
    }

    const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
    const sourceThreadId = readString(params.sourceThreadId)
      || readString(params.source_thread_id)
      || readString(params.threadId)
      || readString(params.thread_id);
    if (sourceThreadId) {
      pendingForkSourceByRequestId.set(String(parsed.id), sourceThreadId);
    }
  }

  function observeOutboundMessage(rawMessage) {
    const parsed = parseJsonRpcMessage(rawMessage);
    if (!parsed) {
      return;
    }

    const responseId = parsed.id != null ? String(parsed.id) : "";
    if (responseId && pendingThreadStartRequestIds.has(responseId)) {
      pendingThreadStartRequestIds.delete(responseId);
      if (parsed.result != null) {
        lockRuntimeFromThreadStartResult(parsed.result);
      }
    }

    if (responseId && pendingForkSourceByRequestId.has(responseId) && parsed.result != null) {
      const sourceThreadId = pendingForkSourceByRequestId.get(responseId);
      pendingForkSourceByRequestId.delete(responseId);
      const forkedThread = parsed.result?.thread && typeof parsed.result.thread === "object"
        ? parsed.result.thread
        : parsed.result;
      const destinationThreadId = readString(forkedThread?.id)
        || readString(forkedThread?.threadId)
        || readString(forkedThread?.thread_id)
        || readString(parsed.result?.threadId)
        || readString(parsed.result?.thread_id);
      const agentSessionId = readString(forkedThread?.agentSessionId)
        || readString(forkedThread?.agent_session_id)
        || destinationThreadId;
      if (sourceThreadId && destinationThreadId) {
        threadAgentState.inherit(sourceThreadId, destinationThreadId, { agentSessionId });
      }
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method === "thread/started") {
      lockRuntimeFromThreadStartedNotification(parsed.params);
    }
  }

  function lockRuntimeFromThreadStartResult(result) {
    const thread = result?.thread && typeof result.thread === "object" ? result.thread : result;
    const threadId = readString(thread?.id)
      || readString(thread?.threadId)
      || readString(thread?.thread_id)
      || readString(result?.threadId)
      || readString(result?.thread_id);
    if (!threadId) {
      return;
    }

    const existing = threadAgentState.get(threadId) || threadAgentState.getOrBackfillCodex(threadId);
    const fallbackSessionId = existing?.agentRuntime === "opencode"
      ? readString(existing?.agentSessionId)
      : (existing?.agentSessionId || threadId);
    threadAgentState.lockRuntime(threadId, {
      agentRuntime: existing?.agentRuntime || DEFAULT_AGENT_RUNTIME,
      agentSessionId: fallbackSessionId || threadId,
      cwd: existing?.cwd || readString(thread?.cwd) || "",
      opencodeBuildAgentName: existing?.opencodeBuildAgentName || OPENCODE_DEFAULT_BUILD_AGENT_NAME,
      opencodePlanAgentName: existing?.opencodePlanAgentName || OPENCODE_DEFAULT_PLAN_AGENT_NAME,
    });
  }

  function lockRuntimeFromThreadStartedNotification(params = {}) {
    const threadId = extractThreadIdFromParams(params);
    if (!threadId) {
      return;
    }

    const existing = threadAgentState.get(threadId) || threadAgentState.getOrBackfillCodex(threadId);
    threadAgentState.lockRuntime(threadId, existing || {});
  }

  function enrichOutboundResponse(rawMessage, requestContext = {}) {
    const parsed = parseJsonRpcMessage(rawMessage);
    if (!parsed || parsed.id == null || parsed.result == null) {
      return rawMessage;
    }

    const requestMethod = readString(requestContext?.method);
    if (requestMethod === "initialize") {
      return enrichInitializeResponse(rawMessage, parsed);
    }

    if (requestMethod === "thread/list") {
      return enrichThreadListResponse(rawMessage, parsed);
    }

    return rawMessage;
  }

  function enrichInitializeResponse(rawMessage, parsed) {
    const mergedResult = {
      ...(parsed.result && typeof parsed.result === "object" ? parsed.result : {}),
      ...buildCachedInitializeResult(),
    };

    return JSON.stringify({
      ...parsed,
      result: mergedResult,
    });
  }

  function enrichThreadListResponse(rawMessage, parsed) {
    const result = parsed.result;
    const threads = extractThreadListEntries(result);
    if (!threads) {
      return rawMessage;
    }

    for (const thread of threads) {
      projectRuntimeFieldsIntoThread(thread);
    }

    return JSON.stringify({
      ...parsed,
      result: rewrapThreadListResult(result, threads),
    });
  }

  function projectRuntimeFieldsIntoThread(thread) {
    if (!thread || typeof thread !== "object") {
      return thread;
    }

    const threadId = readString(thread.id)
      || readString(thread.threadId)
      || readString(thread.thread_id);
    if (!threadId) {
      return thread;
    }

    const runtime = threadAgentState.getOrBackfillCodex(threadId, {
      cwd: readString(thread.cwd),
    });
    thread.agentRuntime = runtime.agentRuntime;
    thread.agentSessionId = runtime.agentSessionId;
    thread.opencodeBuildAgentName = runtime.opencodeBuildAgentName;
    thread.opencodePlanAgentName = runtime.opencodePlanAgentName;
    return thread;
  }

  function simulateOpenCodeStatusFailureForTests() {
    cachedRuntimeStatuses.delete("opencode");
    return resolveOpenCodeStatus({
      forceRefresh: true,
    });
  }

  return {
    buildInitializePayload,
    buildInitializeResult,
    buildWarmInitializeResult,
    enrichOutboundResponse,
    handleInboundRequest,
    handleRuntimeResponse,
    handleRuntimeRequest,
    listAgentRuntimes,
    observeOutboundMessage,
    trackForwardedRequest,
    projectRuntimeFieldsIntoThread,
    refreshInitializeCache,
    resolveOpenCodeStatus,
    simulateOpenCodeStatusFailureForTests,
    threadAgentState,
    validateThreadStartRequest,
  };
}

function extractThreadListEntries(result) {
  if (!result) {
    return null;
  }

  if (Array.isArray(result)) {
    return result;
  }

  if (Array.isArray(result.data)) {
    return result.data;
  }

  if (Array.isArray(result.items)) {
    return result.items;
  }

  if (Array.isArray(result.threads)) {
    return result.threads;
  }

  return null;
}

function rewrapThreadListResult(result, threads) {
  if (Array.isArray(result)) {
    return threads;
  }

  if (Array.isArray(result.data)) {
    return { ...result, data: threads };
  }

  if (Array.isArray(result.items)) {
    return { ...result, items: threads };
  }

  if (Array.isArray(result.threads)) {
    return { ...result, threads };
  }

  return result;
}

function isMissingCommandError(error) {
  return error?.code === "ENOENT"
    || (typeof error?.message === "string" && error.message.includes("ENOENT"));
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  createAgentRuntimeRegistry,
  extractThreadListEntries,
};
