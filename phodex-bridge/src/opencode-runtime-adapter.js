// FILE: opencode-runtime-adapter.js
// Purpose: Adapts Remodex runtime requests to a local OpenCode server.
// Layer: Bridge adapter
// Exports: createOpenCodeRuntimeAdapter
// Depends on: ./agent-runtime-capabilities, ./canonical-events

const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  OPENCODE_DEFAULT_BUILD_AGENT_NAME,
  OPENCODE_DEFAULT_PLAN_AGENT_NAME,
  buildRuntimeListEntry,
  getAgentRuntimeCapabilities,
} = require("./agent-runtime-capabilities");
const {
  createOpenCodeModelCatalogProvider,
  createOpenCodeModelCatalog,
  discoverOpenCodeModelCatalog,
  openCodeModelPayloadForSelection,
  resolveRuntimeModelSelection,
} = require("./agent-runtime-model-catalog");
const {
  CANONICAL_EVENT_TYPES,
  createCanonicalEvent,
} = require("./canonical-events");
const {
  PERMISSION_REQUEST_METHOD,
  convertOpenCodeEventToCanonical,
  createOpenCodeCanonicalState,
} = require("./opencode-to-canonical-adapter");
const {
  createOpenCodeAgentCatalogProvider,
} = require("./opencode-agent-discovery");
const {
  discoverOpenCodeAgentCatalog,
  discoverOpenCodeSkillCatalog,
} = require("./opencode-discovery");

function createOpenCodeRuntimeAdapter({
  id = "opencode",
  displayName = "OpenCode",
  serverManager,
  threadAgentState,
  modelCatalogProvider = createOpenCodeModelCatalogProvider({
    discover: (options = {}) => discoverOpenCodeModelCatalog({
      serverManager,
      fsImpl,
      ...options,
    }),
  }),
  agentCatalogProvider = createOpenCodeAgentCatalogProvider({
    discover: (options = {}) => discoverOpenCodeAgentCatalog({
      serverManager,
      ...options,
    }),
  }),
  completionGraceMs = 1_500,
  fsImpl = fs,
  discoverAgents = null,
} = {}) {
  if (!serverManager) {
    throw new Error("OpenCode runtime adapter requires a serverManager.");
  }
  if (!threadAgentState) {
    throw new Error("OpenCode runtime adapter requires threadAgentState.");
  }

  const activeTurnsBySessionId = new Map();
  const pendingPermissionsById = new Map();
  let eventSubscription = null;

  return {
    id,
    displayName,
    getCapabilities() {
      return getAgentRuntimeCapabilities(id);
    },
    async getRuntimeListEntry() {
      const serverStatus = serverManager.getStatus?.() || { state: "stopped" };
      const mappedStatus = mapOpenCodeRuntimeStatus(serverStatus.state, fsImpl);
      const [modelCatalog, agentCatalog, skillCatalog] = await Promise.all([
        resolveOpenCodeModelCatalog(),
        resolveOpenCodeAgentCatalog(),
        discoverOpenCodeSkillCatalog({ serverManager }),
      ]);
      return buildRuntimeListEntry({
        id,
        status: mappedStatus.status,
        statusMessage: mappedStatus.statusMessage,
        capabilities: getAgentRuntimeCapabilities(id),
        modelCatalog,
        openCodeAgents: agentCatalog.agents,
        openCodeSkills: skillCatalog.skills,
        defaultBuildAgentName: agentCatalog.defaultBuildAgentName,
        defaultPlanAgentName: agentCatalog.defaultPlanAgentName,
      });
    },
    async handleRuntimeRequest(context = {}) {
      const method = typeof context.parsed?.method === "string" ? context.parsed.method.trim() : "";
      if (method === "thread/start") {
        return handleThreadStart(context);
      }
      if (method === "thread/resume") {
        return handleThreadResume(context);
      }
      if (method === "turn/start") {
        return handleTurnStart(context);
      }
      if (method === "turn/interrupt" || method === "turn/stop") {
        return handleTurnStop(context);
      }
      throw new Error(`OpenCode runtime does not support ${method} yet.`);
    },
    async handleRuntimeResponse(context = {}) {
      return handleRuntimeResponse(context);
    },
    stopAll() {
      eventSubscription?.close?.();
      eventSubscription = null;
      for (const activeTurn of activeTurnsBySessionId.values()) {
        clearCompletionTimer(activeTurn);
      }
      activeTurnsBySessionId.clear();
      pendingPermissionsById.clear();
    },
  };

  async function handleThreadResume({ parsed, sendResponse }) {
    await ensureServerReady(parsed.params);
    const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
    const threadId = extractThreadId(params);
    if (!threadId) {
      throw new Error("OpenCode thread/resume requires a thread id.");
    }

    const record = threadAgentState.get(threadId);
    const agentSessionId = readString(record?.agentSessionId)
      || readString(params.agentSessionId)
      || readString(params.agent_session_id);
    if (!agentSessionId) {
      return handleThreadStart({ parsed, sendResponse });
    }

    const session = await serverManager.request(
      "GET",
      `/session/${encodeURIComponent(agentSessionId)}`,
    );

    threadAgentState.upsert(threadId, {
      agentRuntime: id,
      agentSessionId,
      cwd: readString(record?.cwd) || readString(params.cwd) || readString(params.workingDirectory),
      opencodeBuildAgentName: readString(record?.opencodeBuildAgentName)
        || readString(params.opencodeBuildAgentName)
        || readString(params.opencode_build_agent_name)
        || OPENCODE_DEFAULT_BUILD_AGENT_NAME,
      opencodePlanAgentName: readString(record?.opencodePlanAgentName)
        || readString(params.opencodePlanAgentName)
        || readString(params.opencode_plan_agent_name)
        || OPENCODE_DEFAULT_PLAN_AGENT_NAME,
      runtimeLocked: true,
    });

    ensureEventSubscription();
    sendJsonRpcResult(sendResponse, parsed.id, {
      thread: {
        id: threadId,
        title: readString(session?.title) || readString(params.title),
        agentRuntime: id,
        agentSessionId,
      },
    });
    return { responded: true };
  }

  async function handleThreadStart({ parsed, sendResponse }) {
    await ensureServerReady(parsed.params);
    const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
    const threadId = extractThreadId(params) || `opencode-${Date.now()}`;
    const session = await serverManager.request("POST", "/session", {
      body: {
        title: readString(params.title) || readString(params.prompt) || "Remodex",
      },
    });
    const agentSessionId = readString(session?.id);
    if (!agentSessionId) {
      throw new Error("OpenCode did not return a session id.");
    }

    threadAgentState.upsert(threadId, {
      agentRuntime: id,
      agentSessionId,
      cwd: readString(params.cwd) || readString(params.workingDirectory),
      opencodeBuildAgentName: readString(params.opencodeBuildAgentName)
        || readString(params.opencode_build_agent_name)
        || OPENCODE_DEFAULT_BUILD_AGENT_NAME,
      opencodePlanAgentName: readString(params.opencodePlanAgentName)
        || readString(params.opencode_plan_agent_name)
        || OPENCODE_DEFAULT_PLAN_AGENT_NAME,
      runtimeLocked: true,
    });

    sendJsonRpcResult(sendResponse, parsed.id, {
      thread: {
        id: threadId,
        title: readString(session.title) || readString(params.title),
        agentRuntime: id,
        agentSessionId,
      },
    });
    sendCanonical(sendResponse, CANONICAL_EVENT_TYPES.THREAD_STARTED, {
      threadId,
      agentSessionId,
      payload: {
        thread: {
          id: threadId,
          agentRuntime: id,
          agentSessionId,
        },
      },
    });
    return { responded: true };
  }

  async function handleTurnStart({ parsed, threadId, sendResponse }) {
    await ensureServerReady(parsed.params);
    const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
    const record = threadId ? threadAgentState.get(threadId) : null;
    const agentSessionId = readString(record?.agentSessionId) || readString(params.agentSessionId);
    if (!threadId || !agentSessionId) {
      throw new Error("OpenCode turn/start requires a known thread and agent session.");
    }
    const turnId = extractTurnId(params) || `opencode-turn-${Date.now()}`;
    const parts = buildOpenCodePromptParts(params);
    if (parts.length === 0) {
      throw new Error("OpenCode turn/start requires non-empty prompt text.");
    }
    ensureEventSubscription();
    const activeTurn = {
      threadId,
      agentSessionId,
      turnId,
      sendResponse,
      accepted: false,
      completed: false,
      lastErrorMessage: "",
      bufferedMessages: [],
      state: createOpenCodeCanonicalState(),
      completionTimer: null,
      pendingCompletion: null,
    };
    activeTurnsBySessionId.set(agentSessionId, activeTurn);

    const modelCatalog = await resolveOpenCodeModelCatalog();
    const modelSelection = resolveRuntimeModelSelection(params, record || {}, modelCatalog);
    if (!modelSelection) {
      throw new Error("OpenCode turn/start requires an available OpenCode model.");
    }
    const nativeModel = openCodeModelPayloadForSelection(modelSelection);
    if (!nativeModel) {
      throw new Error(`OpenCode model "${modelSelection.id}" is missing provider/model identity.`);
    }

    try {
      await serverManager.request("POST", `/session/${encodeURIComponent(agentSessionId)}/prompt_async`, {
        body: {
          parts,
          agent: chooseOpenCodeAgentName(params, record),
          model: nativeModel,
        },
      });
    } catch (error) {
      if (activeTurnsBySessionId.get(agentSessionId) === activeTurn) {
        activeTurnsBySessionId.delete(agentSessionId);
      }
      throw error;
    }

    sendJsonRpcResult(sendResponse, parsed.id, {
      turnId,
      agentRuntime: id,
      agentSessionId,
    });
    sendCanonical(sendResponse, CANONICAL_EVENT_TYPES.TURN_STARTED, {
      threadId,
      agentSessionId,
      turnId,
      payload: {},
    });
    activeTurn.accepted = true;
    await flushBufferedMessages(activeTurn);
    return { responded: true };
  }

  async function handleTurnStop({ parsed, threadId, sendResponse }) {
    await ensureServerReady(parsed.params);
    const params = parsed.params && typeof parsed.params === "object" ? parsed.params : {};
    const record = threadId ? threadAgentState.get(threadId) : null;
    const agentSessionId = readString(record?.agentSessionId) || readString(params.agentSessionId);
    if (!agentSessionId) {
      throw new Error("OpenCode stop requires a known agent session.");
    }
    const aborted = await serverManager.request("POST", `/session/${encodeURIComponent(agentSessionId)}/abort`);
    sendJsonRpcResult(sendResponse, parsed.id, {
      aborted: aborted !== false,
      agentRuntime: id,
      agentSessionId,
    });
    return { responded: true };
  }

  async function handleRuntimeResponse({ rawMessage, parsed, sendResponse } = {}) {
    const message = parsed || parseJsonRpcMessage(rawMessage);
    if (!message || message.method || message.id == null) {
      return false;
    }
    const pendingPermission = pendingPermissionsById.get(String(message.id));
    if (!pendingPermission) {
      return false;
    }

    const response = openCodePermissionResponseForResult(message.result);
    await serverManager.request(
      "POST",
      `/session/${encodeURIComponent(pendingPermission.agentSessionId)}/permissions/${encodeURIComponent(pendingPermission.permissionId)}`,
      { body: { response } }
    );
    pendingPermissionsById.delete(String(message.id));
    sendResponse?.(JSON.stringify({
      method: "serverRequest/resolved",
      params: {
        threadId: pendingPermission.threadId,
        requestId: pendingPermission.permissionId,
      },
    }));
    return true;
  }

  function ensureEventSubscription() {
    if (eventSubscription) {
      return;
    }
    if (typeof serverManager.subscribeEvents !== "function") {
      throw new Error("OpenCode runtime requires an event stream subscription.");
    }

    eventSubscription = serverManager.subscribeEvents({
      onEvent(event) {
        void handleOpenCodeEvent(event);
      },
      onError(error) {
        for (const activeTurn of activeTurnsBySessionId.values()) {
          activeTurn.lastErrorMessage = error?.message || "OpenCode event stream failed.";
          sendCanonical(activeTurn.sendResponse, CANONICAL_EVENT_TYPES.ERROR, {
            threadId: activeTurn.threadId,
            agentSessionId: activeTurn.agentSessionId,
            turnId: activeTurn.turnId,
            payload: {
              message: activeTurn.lastErrorMessage,
            },
          });
        }
      },
    });
    eventSubscription?.closed?.catch?.(() => {
      if (eventSubscription?.closed) {
        eventSubscription = null;
      }
    });
  }

  async function handleOpenCodeEvent(event) {
    const sessionId = extractOpenCodeEventSessionId(event);
    if (!sessionId) {
      return;
    }
    const activeTurn = activeTurnsBySessionId.get(sessionId);
    if (!activeTurn) {
      return;
    }

    const canonicalMessages = convertOpenCodeEventToCanonical(event, {
      threadId: activeTurn.threadId,
      agentSessionId: activeTurn.agentSessionId,
      turnId: activeTurn.turnId,
      state: activeTurn.state,
    });
    if (canonicalMessages.length === 0) {
      return;
    }
    if (!activeTurn.accepted) {
      activeTurn.bufferedMessages.push(...canonicalMessages);
      return;
    }
    for (const canonicalMessage of canonicalMessages) {
      await processCanonicalMessage(activeTurn, canonicalMessage);
    }
  }

  async function flushBufferedMessages(activeTurn) {
    const messages = activeTurn.bufferedMessages.splice(0);
    for (const message of messages) {
      await processCanonicalMessage(activeTurn, message);
    }
  }

  async function processCanonicalMessage(activeTurn, canonicalMessage) {
    if (canonicalMessage.method === PERMISSION_REQUEST_METHOD) {
      const permissionId = readString(canonicalMessage.params?.permissionId) || readString(canonicalMessage.id);
      if (permissionId) {
        pendingPermissionsById.set(String(canonicalMessage.id || permissionId), {
          agentSessionId: activeTurn.agentSessionId,
          permissionId,
          threadId: activeTurn.threadId,
        });
      }
      sendCanonicalMessage(activeTurn.sendResponse, canonicalMessage);
      return;
    }

    sendCanonicalMessage(activeTurn.sendResponse, canonicalMessage);
    if (canonicalMessage.method === "remodex/event/assistant_completed") {
      scheduleActiveTurnCompletion(activeTurn, { status: "completed" });
    } else if (canonicalMessage.method === "remodex/event/error") {
      activeTurn.lastErrorMessage = readString(canonicalMessage.params?.payload?.message)
        || readString(canonicalMessage.params?.error?.message)
        || activeTurn.lastErrorMessage;
      await completeActiveTurn(activeTurn, { status: "failed", skipDiff: true });
    } else if (activeTurn.pendingCompletion) {
      scheduleActiveTurnCompletion(activeTurn, activeTurn.pendingCompletion);
    }
  }

  async function resolveOpenCodeModelCatalog() {
    try {
      return await modelCatalogProvider.get();
    } catch (error) {
      return createOpenCodeModelCatalog({
        status: "degraded",
        statusMessage: `OpenCode model discovery failed; showing recovery fallbacks. ${error?.message || ""}`.trim(),
      });
    }
  }

  async function resolveOpenCodeAgentCatalog() {
    if (typeof discoverAgents === "function") {
      return {
        agents: discoverAgents({ fsImpl }),
        defaultBuildAgentName: OPENCODE_DEFAULT_BUILD_AGENT_NAME,
        defaultPlanAgentName: OPENCODE_DEFAULT_PLAN_AGENT_NAME,
      };
    }
    try {
      return await agentCatalogProvider.get();
    } catch (error) {
      return {
        status: "degraded",
        statusMessage: `OpenCode agent discovery failed; showing recovery fallbacks. ${error?.message || ""}`.trim(),
        agents: [
          {
            id: OPENCODE_DEFAULT_BUILD_AGENT_NAME,
            displayName: "Build",
            isDefaultBuild: true,
            isDefaultPlan: false,
          },
        ],
        defaultBuildAgentName: OPENCODE_DEFAULT_BUILD_AGENT_NAME,
        defaultPlanAgentName: OPENCODE_DEFAULT_PLAN_AGENT_NAME,
      };
    }
  }

  function scheduleActiveTurnCompletion(activeTurn, completion) {
    if (activeTurn.completed) {
      return;
    }
    activeTurn.pendingCompletion = completion;
    clearCompletionTimer(activeTurn);
    if (completionGraceMs <= 0) {
      void completeActiveTurn(activeTurn, completion);
      return;
    }
    activeTurn.completionTimer = setTimeout(() => {
      activeTurn.completionTimer = null;
      const pendingCompletion = activeTurn.pendingCompletion;
      activeTurn.pendingCompletion = null;
      void completeActiveTurn(activeTurn, pendingCompletion);
    }, completionGraceMs);
  }

  function clearCompletionTimer(activeTurn) {
    if (activeTurn?.completionTimer) {
      clearTimeout(activeTurn.completionTimer);
      activeTurn.completionTimer = null;
    }
  }

  async function completeActiveTurn(activeTurn, { status, skipDiff = false } = {}) {
    if (activeTurn.completed) {
      return;
    }
    clearCompletionTimer(activeTurn);
    activeTurn.pendingCompletion = null;
    activeTurn.completed = true;
    if (!skipDiff) {
      await emitSessionDiff(activeTurn);
    }
    sendCanonical(activeTurn.sendResponse, CANONICAL_EVENT_TYPES.TURN_COMPLETED, {
      threadId: activeTurn.threadId,
      agentSessionId: activeTurn.agentSessionId,
      turnId: activeTurn.turnId,
      payload: {
        status: readString(status) || "completed",
        ...(readString(status) === "failed" && activeTurn.lastErrorMessage
          ? { error: { message: activeTurn.lastErrorMessage } }
          : {}),
      },
    });
    if (activeTurnsBySessionId.get(activeTurn.agentSessionId) === activeTurn) {
      activeTurnsBySessionId.delete(activeTurn.agentSessionId);
    }
  }

  async function emitSessionDiff(activeTurn) {
    try {
      const diff = await serverManager.request("GET", `/session/${encodeURIComponent(activeTurn.agentSessionId)}/diff`);
      sendCanonical(activeTurn.sendResponse, CANONICAL_EVENT_TYPES.DIFF_UPDATED, {
        threadId: activeTurn.threadId,
        agentSessionId: activeTurn.agentSessionId,
        turnId: activeTurn.turnId,
        payload: {
          diff: diff ?? null,
        },
      });
    } catch (error) {
      sendCanonical(activeTurn.sendResponse, CANONICAL_EVENT_TYPES.ERROR, {
        threadId: activeTurn.threadId,
        agentSessionId: activeTurn.agentSessionId,
        turnId: activeTurn.turnId,
        payload: {
          message: error?.message || "OpenCode diff refresh failed.",
        },
      });
    }
  }

  async function ensureServerReady(params = {}) {
    const status = serverManager.getStatus?.() || { state: "stopped" };
    if (status.state === "ready" && status.baseUrl) {
      return;
    }
    serverManager.start?.({
      cwd: readString(params.cwd) || readString(params.workingDirectory),
    });
    const nextStatus = await waitForServerReady();
    if (nextStatus.state !== "ready" || !nextStatus.baseUrl) {
      throw new Error("OpenCode server is not ready.");
    }
  }

  async function waitForServerReady({
    timeoutMs = 5_000,
    intervalMs = 50,
  } = {}) {
    const startedAt = Date.now();
    let latestStatus = serverManager.getStatus?.() || {};
    while (Date.now() - startedAt <= timeoutMs) {
      latestStatus = serverManager.getStatus?.() || {};
      if (latestStatus.state === "ready" && latestStatus.baseUrl) {
        return latestStatus;
      }
      if (["error", "not_installed", "stopped"].includes(latestStatus.state)) {
        return latestStatus;
      }
      await delay(intervalMs);
    }
    return latestStatus;
  }

  function chooseOpenCodeAgentName(params, record) {
    const collaborationMode = params.collaborationMode && typeof params.collaborationMode === "object"
      ? params.collaborationMode
      : params.collaboration_mode && typeof params.collaboration_mode === "object"
        ? params.collaboration_mode
        : {};
    const mode = readString(params.mode)
      || readString(params.turnMode)
      || readString(params.turn_mode)
      || readString(collaborationMode.mode)
      || readString(collaborationMode.kind);
    if (mode === "plan") {
      return readString(record?.opencodePlanAgentName) || OPENCODE_DEFAULT_PLAN_AGENT_NAME;
    }
    return readString(record?.opencodeBuildAgentName) || OPENCODE_DEFAULT_BUILD_AGENT_NAME;
  }

  function sendCanonical(sendResponse, type, {
    threadId,
    agentSessionId,
    turnId,
    itemId,
    payload,
  }) {
    if (typeof sendResponse !== "function") {
      return;
    }
    sendResponse(JSON.stringify(createCanonicalEvent({
      type,
      agentRuntime: id,
      threadId,
      agentSessionId,
      turnId,
      itemId,
      payload,
    })));
  }
}

function sendCanonicalMessage(sendResponse, canonicalMessage) {
  if (typeof sendResponse !== "function") {
    return;
  }
  sendResponse(JSON.stringify(canonicalMessage));
}

function sendJsonRpcResult(sendResponse, requestId, result) {
  if (typeof sendResponse !== "function" || requestId == null) {
    return;
  }
  sendResponse(JSON.stringify({
    id: requestId,
    result,
  }));
}

function mapOpenCodeRuntimeStatus(state, fsImpl) {
  const mapped = mapServerStatus(state);
  if (mapped.status === "ready" && !hasOpenCodeAuthConfigured(fsImpl)) {
    return {
      status: "needs_auth",
      statusMessage: "Sign in to OpenCode on this Mac before starting OpenCode threads.",
    };
  }
  return mapped;
}

function hasOpenCodeAuthConfigured(fsImpl = fs) {
  const authPath = path.join(os.homedir(), ".local", "share", "opencode", "auth.json");
  if (!fsImpl.existsSync(authPath)) {
    return false;
  }
  try {
    const parsed = JSON.parse(fsImpl.readFileSync(authPath, "utf8"));
    return Boolean(parsed && typeof parsed === "object" && Object.keys(parsed).length > 0);
  } catch {
    return false;
  }
}

function mapServerStatus(state) {
  if (state === "ready") {
    return { status: "ready", statusMessage: "" };
  }
  if (state === "stopped") {
    return {
      status: "degraded",
      statusMessage: "OpenCode server is not running; it will start on first use.",
    };
  }
  if (state === "starting") {
    return { status: "starting", statusMessage: "OpenCode server is starting." };
  }
  if (state === "not_installed") {
    return { status: "not_installed", statusMessage: "Install OpenCode on this Mac to enable the OpenCode runtime." };
  }
  if (state === "error") {
    return { status: "error", statusMessage: "OpenCode server failed on this Mac." };
  }
  return { status: "degraded", statusMessage: "OpenCode server status could not be verified on this Mac." };
}

function buildOpenCodePromptParts(params = {}) {
  const text = readString(params.prompt) || readString(params.input) || readString(params.message);
  if (text) {
    return [{ type: "text", text }];
  }
  if (Array.isArray(params.input)) {
    const structuredText = readStructuredInputText(params.input);
    return structuredText ? [{ type: "text", text: structuredText }] : [];
  }
  if (Array.isArray(params.parts)) {
    const structuredText = readStructuredInputText(params.parts);
    return structuredText ? [{ type: "text", text: structuredText }] : [];
  }
  return [];
}

function extractThreadId(params = {}) {
  return readString(params.threadId)
    || readString(params.thread_id)
    || readString(params.thread?.id)
    || readString(params.thread?.threadId)
    || readString(params.thread?.thread_id);
}

function extractTurnId(params = {}) {
  return readString(params.turnId)
    || readString(params.turn_id)
    || readString(params.turn?.id);
}

function readStructuredInputText(inputItems) {
  const chunks = [];
  for (const item of inputItems) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const type = readString(item.type).toLowerCase();
    if (type === "text" || type === "input_text") {
      const text = readString(item.text) || readString(item.content);
      if (text) {
        chunks.push(text);
      }
      continue;
    }
    if (type === "mention") {
      const name = readString(item.name);
      const path = readString(item.path);
      const mention = [name ? `@${name}` : "", path].filter(Boolean).join(" ");
      if (mention) {
        chunks.push(mention);
      }
      continue;
    }
    if (type === "skill") {
      const name = readString(item.name) || readString(item.id);
      if (name) {
        chunks.push(`$${name}`);
      }
      continue;
    }
    if (type === "file") {
      const path = readString(item.path) || readString(item.url);
      if (path) {
        chunks.push(path);
      }
    }
  }
  return chunks.join("\n").trim();
}

function extractOpenCodeEventSessionId(event) {
  const properties = event?.properties && typeof event.properties === "object" ? event.properties : {};
  return readString(properties.sessionID)
    || readString(properties.sessionId)
    || readString(properties.info?.sessionID)
    || readString(properties.info?.sessionId)
    || readString(properties.part?.sessionID)
    || readString(properties.part?.sessionId);
}

function parseJsonRpcMessage(rawMessage) {
  try {
    return typeof rawMessage === "string" ? JSON.parse(rawMessage) : null;
  } catch {
    return null;
  }
}

function openCodePermissionResponseForResult(result = {}) {
  const explicitResponse = readString(result.response) || readString(result.reply);
  if (["once", "always", "reject"].includes(explicitResponse)) {
    return explicitResponse;
  }
  const permissions = result.permissions && typeof result.permissions === "object" ? result.permissions : {};
  return hasGrantedPermission(permissions) ? "once" : "reject";
}

function hasGrantedPermission(permissions) {
  return Object.values(permissions).some((value) => {
    if (value === true) {
      return true;
    }
    if (value && typeof value === "object") {
      return hasGrantedPermission(value);
    }
    return false;
  });
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = {
  buildOpenCodePromptParts,
  createOpenCodeRuntimeAdapter,
  hasOpenCodeAuthConfigured,
  mapOpenCodeRuntimeStatus,
  mapServerStatus,
};
