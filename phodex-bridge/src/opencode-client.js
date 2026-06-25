// FILE: opencode-client.js
// Purpose: Wraps @opencode-ai/sdk/v2 into a bridge-specific interface for
//          model/agent discovery, session lifecycle, turn execution,
//          event streaming, and permission handling.
// Layer: Transport adapter
// Exports: createOpenCodeClient
// Depends on: @opencode-ai/sdk/v2 (dynamic ESM import), ./opencode-models, ./provider-capabilities

const { readString } = require("./normalize");
const { mapSdkCommandToBridge } = require("./opencode-command-arguments");
const {
  OPENCODE_PROVIDER_ID,
  DEFAULT_OPENCODE_MODEL,
  compareThreadsByUpdatedAt,
  displayNameForOpenCodeModel,
  publicThread,
  sessionV2InfoToDiscoveredThread,
} = require("./opencode-models");
const { resolveModelCapabilities } = require("./provider-capabilities");
const { parseOpenCodeModelSlug } = require("./opencode-model-slug");
const { resolveLogoProviderId } = require("./opencode-provider-inventory");

// TUI/CLI builtins not auto-returned by current SDK command.list (which focuses on Service/agent/skill-derived per vendored command + acp); keep manually in sync on vendored updates or future sync PR. Union deduped by token before return. Always test under default DISABLE=1 that codex paths unaffected.
const BUILTINS = ['/undo','/redo','/share','/help','/init','/compact','/login','/logout','/models','/agents','/skills','/mcp','/config','/clear','/exit'];

function normalizeCommandNameForSdk(token) {
  const trimmed = readString(token).trim();
  return trimmed.startsWith("/") ? trimmed.slice(1) : trimmed;
}

function normalizeCommandTokenForAllowlist(token) {
  const trimmed = readString(token).trim().toLowerCase();
  if (!trimmed) {
    return "";
  }
  return trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
}

function buildStaticSlashCommands() {
  return BUILTINS.map((token) => {
    const base = token.slice(1);
    const title = token === "/mcp" ? "MCP" : base.replace(/^\w/, (c) => c.toUpperCase());
    return { token, title, description: "", requiresArguments: false };
  });
}

let _createOpencodeClient = null;

async function getSdkClient() {
  if (_createOpencodeClient) return _createOpencodeClient;
  const sdk = await import("@opencode-ai/sdk/v2");
  _createOpencodeClient = sdk.createOpencodeClient;
  return _createOpencodeClient;
}

const REQUEST_TIMEOUT_MS = 90_000;

function validateLocalhostBaseUrl(baseUrl) {
  try {
    const url = new URL(baseUrl);
    const hostname = url.hostname.toLowerCase();

    // Allow localhost, 127.0.0.1, and ::1 (IPv6 localhost)
    const allowedHostnames = ['localhost', '127.0.0.1', '::1'];

    if (!allowedHostnames.includes(hostname)) {
      throw new Error(
        `OpenCode baseUrl must be localhost or 127.0.0.1 for security. Received: ${hostname}`
      );
    }

    // Ensure HTTPS or HTTP for localhost (HTTP is acceptable for localhost)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw new Error(
        `OpenCode baseUrl must use http or https protocol. Received: ${url.protocol}`
      );
    }
  } catch (error) {
    if (error.message.includes('baseUrl must')) {
      throw error;
    }
    throw new Error(`Invalid OpenCode baseUrl format: ${error.message}`);
  }
}

function resolveSessionIdFromCreateResponse(response) {
  if (!response || typeof response !== "object") {
    return "";
  }

  const data = response.data;
  if (data && typeof data === "object" && !Array.isArray(data)) {
    const fromData = readString(data.id || data.sessionID || data.sessionId);
    if (fromData) {
      return fromData;
    }
  }

  return readString(response.sessionID || response.sessionId || response.id);
}

async function createOpenCodeClient({
  baseUrl,
  logPrefix = "[remodex]",
  createOpencodeClientImpl = null,
} = {}) {
  if (!baseUrl) {
    throw new Error("OpenCode SDK client requires a baseUrl.");
  }

  const resolvedBaseUrl = readString(baseUrl);

  // Security: Validate that baseUrl is localhost only
  // Allow override for testing with REMODEX_OPENCODE_ALLOW_REMOTE_BASEURL=1
  if (process.env.REMODEX_OPENCODE_ALLOW_REMOTE_BASEURL !== '1') {
    validateLocalhostBaseUrl(resolvedBaseUrl);
  }
  const createOpencodeClient = createOpencodeClientImpl || (await getSdkClient());
  const client = createOpencodeClient({ baseUrl: resolvedBaseUrl });

  let inventoryCache = null;
  let inventoryRefreshPromise = null;

  async function listProviderInventory({
    force = false,
    credentialProviderIDs = [],
    authDiscoveryReasonCode = "ok",
    providerInventoryPartial = false,
  } = {}) {
    const cacheTtlMs = boundedProviderCacheTtlMs(process.env);
    if (inventoryRefreshPromise && !force) {
      return inventoryRefreshPromise;
    }
    const { refreshProviderInventory } = require("./opencode-provider-inventory");
    const run = refreshProviderInventory(client, {
      force,
      cached: inventoryCache,
      cacheTtlMs,
      credentialProviderIDs,
      authDiscoveryReasonCode,
      providerInventoryPartial,
    }).then((result) => {
      inventoryCache = {
        inventory: result.inventory,
        models: result.models,
        meta: result.meta,
        connectedProviders: result.connectedProviders,
        providerInventory: result.providerInventory,
        authDiscoveryReasonCode: result.authDiscoveryReasonCode,
        providerInventoryPartial: result.providerInventoryPartial,
        fetchedAt: Date.parse(result.meta?.fetchedAt) || Date.now(),
      };
      return result;
    });
    if (!force) {
      inventoryRefreshPromise = run.finally(() => {
        inventoryRefreshPromise = null;
      });
      return inventoryRefreshPromise;
    }
    return run;
  }

  async function listModels({
    force = false,
    credentialProviderIDs = [],
    authDiscoveryReasonCode = "ok",
  } = {}) {
    try {
      const result = await listProviderInventory({
        force,
        credentialProviderIDs,
        authDiscoveryReasonCode,
      });
      return {
        models: result.models || [],
        meta: result.meta || {
          reasonCode: "unknown",
          connectedProviderIds: [],
          fetchedAt: new Date().toISOString(),
          stale: false,
          modelCountBeforeCap: 0,
          modelCountAfterCap: 0,
        },
        connectedProviders: result.connectedProviders || [],
        providerInventory: result.providerInventory || [],
        authDiscoveryReasonCode: result.authDiscoveryReasonCode || authDiscoveryReasonCode,
        providerInventoryPartial: result.providerInventoryPartial === true,
      };
    } catch (error) {
      console.warn(`${logPrefix} OpenCode provider inventory failed: ${error.message}`);
      return {
        models: [],
        meta: {
          reasonCode: "provider_list_failed",
          connectedProviderIds: [],
          fetchedAt: new Date().toISOString(),
          stale: false,
          modelCountBeforeCap: 0,
          modelCountAfterCap: 0,
        },
      };
    }
  }

  async function listAgents() {
    try {
      const response = await withTimeout(client.app.agents(), REQUEST_TIMEOUT_MS);
      return resolveAgentsList(response).map((a) => ({
        id: readString(a.id || a.name || a),
        label: readString(a.label || a.name || a.displayName || a.id || a),
        description: readString(a.description) || "",
      }));
    } catch (error) {
      console.warn(`${logPrefix} OpenCode app.agents() failed: ${error.message}`);
      return [];
    }
  }

  async function createSession({ cwd }) {
    const response = await withTimeout(
      client.session.create({ directory: readString(cwd) || process.cwd() }),
      REQUEST_TIMEOUT_MS,
    );
    const sessionId = resolveSessionIdFromCreateResponse(response);
    if (!readString(sessionId)) {
      throw new Error(
        "OpenCode session.create returned no session id (empty or missing id/sessionID in response).",
      );
    }
    return sessionId;
  }

  async function getSession(sessionId, { directory } = {}) {
    return withTimeout(
      client.session.get({
        sessionID: sessionId,
        directory: readString(directory) || undefined,
      }),
      REQUEST_TIMEOUT_MS,
    );
  }

  async function listProjects({ directory } = {}) {
    if (typeof client.project?.list !== "function") {
      return [];
    }
    try {
      const response = await withTimeout(
        client.project.list({
          directory: readString(directory) || process.cwd(),
        }),
        REQUEST_TIMEOUT_MS,
      );
      return resolveProjectList(response);
    } catch (error) {
      console.warn(`${logPrefix} OpenCode project.list() failed: ${error.message}`);
      return [];
    }
  }

  async function directGlobalSessionList(query = {}) {
    if (!resolvedBaseUrl) {
      return emptySessionListResult();
    }
    const url = new URL(`${resolvedBaseUrl.replace(/\/$/, "")}/experimental/session`);
    if (Number.isFinite(query.limit) && query.limit > 0) {
      url.searchParams.set("limit", String(Math.floor(query.limit)));
    }
    if (query.archived === true) {
      url.searchParams.set("archived", "true");
    }
    if (query.cursor != null) {
      url.searchParams.set("cursor", String(query.cursor));
    }
    const response = await fetch(url.href);
    if (!response.ok) {
      throw new Error(`experimental session.list HTTP ${response.status}`);
    }
    const data = await response.json();
    const nextCursor = response.headers.get("x-next-cursor") || null;
    return resolveSessionList({
      data: Array.isArray(data) ? data : [],
      nextCursor,
    });
  }

  async function listSessions({ directory, limit, cursor, archived } = {}) {
    const normalizedDirectory = readString(directory);
    const pagination = resolveSessionListCursor(cursor);
    const baseQuery = {};
    const normalizedLimit = Number(limit);
    if (Number.isFinite(normalizedLimit) && normalizedLimit > 0) {
      baseQuery.limit = Math.floor(normalizedLimit);
    }
    if (archived === true) {
      baseQuery.archived = true;
    }

    try {
      if (!normalizedDirectory && typeof client.experimental?.session?.list === "function") {
        const query = { ...baseQuery };
        if (pagination.numeric !== null) {
          query.cursor = pagination.numeric;
        }
        const response = await withTimeout(
          client.experimental.session.list(query),
          REQUEST_TIMEOUT_MS,
        );
        return resolveSessionList(response);
      }

      if (!normalizedDirectory && typeof fetch === "function") {
        const query = { ...baseQuery };
        if (pagination.numeric !== null) {
          query.cursor = pagination.numeric;
        }
        return await withTimeout(directGlobalSessionList(query), REQUEST_TIMEOUT_MS);
      }

      if (typeof client.session?.list !== "function") {
        return emptySessionListResult();
      }

      const query = { ...baseQuery };
      if (normalizedDirectory) {
        query.directory = normalizedDirectory;
      }
      if (pagination.numeric !== null) {
        query.start = pagination.numeric;
      }

      const response = await withTimeout(client.session.list(query), REQUEST_TIMEOUT_MS);
      return resolveSessionList(response);
    } catch (error) {
      console.warn(`${logPrefix} OpenCode session.list() failed: ${error.message}`);
      return emptySessionListResult();
    }
  }

  async function prompt({ sessionID, prompt, parts, cwd, model, agent, variant, threadId, turnId, skills }) {
    const resolvedParts =
      Array.isArray(parts) && parts.length > 0
        ? parts
        : [{ type: "text", text: readString(prompt) || "" }];
    const bodyParts = resolvedParts.filter(
      (part) =>
        part &&
        (part.type === "file" ||
          part.type === "agent" ||
          part.type === "subtask" ||
          readString(part.text)),
    );
    if (bodyParts.length === 0) {
      throw new Error("OpenCode prompt requires at least one part.");
    }

    let parsedModel = null;
    if (model && typeof model === "object" && model.providerID && model.modelID) {
      parsedModel = {
        providerID: readString(model.providerID),
        modelID: readString(model.modelID),
      };
    } else {
      parsedModel = parseOpenCodeModelSlug(model);
    }

    const promptBody = {
      sessionID,
      directory: readString(cwd) || process.cwd(),
      parts: bodyParts,
    };
    if (parsedModel?.providerID && parsedModel?.modelID) {
      promptBody.model = parsedModel;
    }
    const normalizedAgent = readString(agent);
    if (normalizedAgent) {
      promptBody.agent = normalizedAgent;
    }
    const normalizedVariant = readString(variant);
    if (normalizedVariant) {
      promptBody.variant = normalizedVariant;
    }

    // RP-SKILL-3: conditional skills[] in the turn prompt payload to SDK (only when structured skill items
    // were present in the iOS turn/start "input" -- which iOS does only if supportsStructuredSkillInput flag true
    // for the runtime). This is gated; see verification in PR14: no skills:[] support in current SDK PromptInput
    // (only parts or V2 Prompt's files/agents/references), so flag kept false for OC + doc in opencode-sdk.md.
    if (Array.isArray(skills) && skills.length > 0) {
      promptBody.skills = skills
        .map((s) => {
          const id = readString(s?.id || s?.name);
          if (!id) return null;
          const entry = { id, name: readString(s?.name || s?.id) || id };
          const p = readString(s?.path);
          if (p) entry.path = p;
          return entry;
        })
        .filter(Boolean);
    }

    console.log(
      JSON.stringify({
        event: "opencode_turn_prompt",
        providerID: parsedModel?.providerID || null,
        modelID: parsedModel?.modelID || null,
        agent: normalizedAgent || null,
        variant: normalizedVariant || null,
        threadId: readString(threadId) || null,
        turnId: readString(turnId) || null,
        sessionId: readString(sessionID) || null,
      }),
    );

    return withTimeout(client.session.prompt(promptBody), REQUEST_TIMEOUT_MS);
  }

  async function abort(sessionId) {
    return withTimeout(client.session.abort({ sessionID: sessionId }), REQUEST_TIMEOUT_MS);
  }

  async function getMessages(sessionId, options = {}) {
    const request = { sessionID: sessionId };
    const limit = Number(options?.limit);
    if (Number.isFinite(limit) && limit > 0) {
      request.limit = limit;
    }
    const response = await withTimeout(
      client.session.messages(request),
      REQUEST_TIMEOUT_MS,
    );
    return normalizeSessionMessagesResponse(response);
  }

  async function replyToPermission(requestId, allow) {
    return withTimeout(
      client.permission.reply({ requestID: requestId, reply: { allow: Boolean(allow) } }),
      REQUEST_TIMEOUT_MS,
    );
  }

  function subscribeToEvents(handler, options = {}) {
    let active = true;
    let releaseStream = null;
    let reconnectTimer = null;
    const reconnectEnabled = options.reconnectEnabled !== false;
    const maxAttempts = Number.isFinite(options.maxReconnectAttempts)
      ? options.maxReconnectAttempts
      : 8;
    const baseDelayMs = Number.isFinite(options.reconnectBaseDelayMs)
      ? options.reconnectBaseDelayMs
      : 500;

    const clearReconnectTimer = () => {
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
    };

    const streamTask = (async () => {
      let attempt = 0;
      let stableConnectionTimer = null;
      const clearStableConnectionTimer = () => {
        if (stableConnectionTimer) {
          clearTimeout(stableConnectionTimer);
          stableConnectionTimer = null;
        }
      };
      const resetAttemptAfterStableConnection = () => {
        attempt = 0;
        clearStableConnectionTimer();
      };
      const scheduleStableConnectionReset = () => {
        clearStableConnectionTimer();
        stableConnectionTimer = setTimeout(() => {
          resetAttemptAfterStableConnection();
        }, 30_000);
        if (typeof stableConnectionTimer?.unref === "function") {
          stableConnectionTimer.unref();
        }
      };
      const notifyResubscribe = (details = {}) => {
        if (typeof options.onResubscribe === "function") {
          options.onResubscribe(details);
        }
      };
      while (active) {
        try {
          const sseClient = await client.event.subscribe();
          releaseStream =
            typeof sseClient.close === "function"
              ? () => sseClient.close()
              : typeof sseClient.abort === "function"
                ? () => sseClient.abort()
                : null;
          const subscription = sseClient.stream;
          let receivedFirstEvent = false;
          scheduleStableConnectionReset();
          try {
            for await (const event of subscription) {
              if (!active) {
                break;
              }
              if (!receivedFirstEvent) {
                receivedFirstEvent = true;
                resetAttemptAfterStableConnection();
              }
              dispatchEvent(event, handler);
            }
          } finally {
            if (typeof subscription?.return === "function") {
              try {
                await subscription.return();
              } catch {
                // Stream may already be closed when unsubscribing.
              }
            }
          }

          if (!active) {
            break;
          }
        } catch (error) {
          if (!active) {
            break;
          }
          console.error(`${logPrefix} OpenCode event stream error: ${error.message}`);
          handler("event/streamError", { message: error.message, attempt });
          if (!reconnectEnabled || attempt >= maxAttempts) {
            break;
          }
          attempt += 1;
          const delayMs = Math.min(baseDelayMs * Math.pow(2, attempt - 1), 15_000);
          console.log(
            JSON.stringify({
              event: "opencode_sse_resubscribe",
              attempt,
              delayMs,
              message: error.message,
            }),
          );
          notifyResubscribe({ attempt, delayMs, reason: "error", message: error.message });
          clearReconnectTimer();
          await new Promise((resolve) => {
            reconnectTimer = setTimeout(resolve, delayMs);
          });
          if (!active) {
            break;
          }
          continue;
        }

        if (!active || !reconnectEnabled) {
          break;
        }
        attempt += 1;
        if (attempt >= maxAttempts) {
          break;
        }
        const delayMs = Math.min(baseDelayMs * Math.pow(2, attempt - 1), 15_000);
        console.log(
          JSON.stringify({
            event: "opencode_sse_resubscribe",
            attempt,
            delayMs,
            reason: "stream_closed",
          }),
        );
        notifyResubscribe({ attempt, delayMs, reason: "stream_closed" });
        clearReconnectTimer();
        await new Promise((resolve) => {
          reconnectTimer = setTimeout(resolve, delayMs);
        });
        if (!active) {
          break;
        }
      }
      clearStableConnectionTimer();
      clearReconnectTimer();
    })();

    return () => {
      active = false;
      clearReconnectTimer();
      if (releaseStream) {
        try {
          releaseStream();
        } catch {
          // Best-effort teardown so node:test can exit.
        }
        releaseStream = null;
      }
      void streamTask.catch((error) => {
        console.warn(`${logPrefix} OpenCode SSE stream cleanup error: ${error.message}`);
      });
    };
  }

  async function sessionCommand({
    sessionID,
    command,
    arguments: args = "",
    cwd,
    model,
    agent,
  } = {}) {
    const sdkName = normalizeCommandNameForSdk(command);
    if (!sdkName) {
      throw new Error("OpenCode session.command requires a command name.");
    }

    const body = {
      sessionID,
      command: sdkName,
      arguments: readString(args) || "",
    };
    const directory = readString(cwd);
    if (directory) {
      body.directory = directory;
    }
    const normalizedAgent = readString(agent);
    if (normalizedAgent) {
      body.agent = normalizedAgent;
    }
    let parsedModel = null;
    if (model && typeof model === "object" && model.providerID && model.modelID) {
      parsedModel = {
        providerID: readString(model.providerID),
        modelID: readString(model.modelID),
      };
    } else if (model) {
      parsedModel = parseOpenCodeModelSlug(model);
    }
    if (parsedModel?.providerID && parsedModel?.modelID) {
      body.model = `${parsedModel.providerID}/${parsedModel.modelID}`;
    }

    return withTimeout(client.session.command(body), REQUEST_TIMEOUT_MS);
  }

  async function fork(sessionId) {
    const response = await withTimeout(
      client.session.fork({ sessionID: sessionId }),
      REQUEST_TIMEOUT_MS,
    );
    const forkedSessionId = resolveSessionIdFromCreateResponse(response);
    if (!readString(forkedSessionId)) {
      throw new Error(
        "OpenCode session.fork returned no session id (empty or missing id/sessionID in response).",
      );
    }
    return forkedSessionId;
  }

  async function listCommands(directory) {
    let derived = [];
    try {
      const commands = await withTimeout(
        client.command.list({ query: { directory: readString(directory) || process.cwd() } }),
        REQUEST_TIMEOUT_MS,
      );
      derived = (Array.isArray(commands) ? commands : []).map((c) => mapSdkCommandToBridge(c));
    } catch (error) {
      console.warn(`${logPrefix} OpenCode command.list() failed: ${error.message}`);
      derived = [];
    }
    const seen = new Set();
    const out = [];
    for (const builtin of buildStaticSlashCommands()) {
      const token = readString(builtin.token);
      if (token && !seen.has(token)) {
        seen.add(token);
        out.push(builtin);
      }
    }
    for (const c of derived) {
      const token = readString(c.token);
      if (token && !seen.has(token)) {
        seen.add(token);
        out.push(c);
      }
    }
    return out;
  }

  async function selectTuiSession(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId || typeof client.tui?.selectSession !== "function") {
      return false;
    }

    try {
      await withTimeout(
        client.tui.selectSession({ sessionID: normalizedSessionId }),
        REQUEST_TIMEOUT_MS,
      );
      return true;
    } catch (error) {
      console.warn(
        `${logPrefix} OpenCode tui.selectSession failed: ${error?.message || error}`,
      );
      return false;
    }
  }

  async function listSkills(directory) {
    if (typeof client.app?.skills !== "function") {
      return [];
    }
    try {
      const response = await withTimeout(
        client.app.skills({ query: { directory: readString(directory) || process.cwd() } }),
        REQUEST_TIMEOUT_MS,
      );
      const skills = resolveSkillsList(response);
      return skills.map((skill) => mapOpenCodeSkill(skill, directory));
    } catch (error) {
      console.warn(`${logPrefix} OpenCode app.skills() failed: ${error?.message || error}`);
      return [];
    }
  }

  async function probeProviderAuthState() {
    try {
      const response = await withTimeout(client.provider.auth(), REQUEST_TIMEOUT_MS);
      return inferAuthConfiguredFromProviderAuth(response);
    } catch (error) {
      console.warn(`${logPrefix} OpenCode provider.auth() failed: ${error.message}`);
      return null;
    }
  }

  async function listAuthProviderIds() {
    try {
      const response = await withTimeout(client.provider.auth(), REQUEST_TIMEOUT_MS);
      const { authProviderIdsFromProbe } = require("./opencode-auth-providers");
      return authProviderIdsFromProbe(response);
    } catch {
      return [];
    }
  }

  async function probeConnectedProviders() {
    try {
      const response = await withTimeout(client.provider.list(), REQUEST_TIMEOUT_MS);
      const payload = resolveProviderListPayload(response);
      const connected = Array.isArray(payload?.connected) ? payload.connected : [];
      if (connected.length === 0) {
        return false;
      }
      return true;
    } catch {
      return null;
    }
  }

  return {
    listModels,
    listProviderInventory,
    listAgents,
    createSession,
    getSession,
    listProjects,
    listSessions,
    prompt,
    abort,
    getMessages,
    replyToPermission,
    subscribeToEvents,
    fork,
    sessionCommand,
    listCommands,
    listSkills,
    selectTuiSession,
    probeProviderAuthState,
    probeConnectedProviders,
    listAuthProviderIds,
  };
}

function inferAuthConfiguredFromProviderAuth(response) {
  if (!response || typeof response !== "object") {
    return null;
  }
  const entries = Object.entries(response).filter(([key]) => key !== "data");
  if (entries.length === 0) {
    return null;
  }
  return entries.some(([, methods]) => Array.isArray(methods) && methods.length > 0);
}

function resolveSkillsList(response) {
  if (Array.isArray(response)) {
    return response;
  }
  if (Array.isArray(response?.data)) {
    return response.data;
  }
  if (Array.isArray(response?.skills)) {
    return response.skills;
  }
  return [];
}

function mapOpenCodeSkill(skill, directory) {
  const name = readString(skill?.name || skill?.id);
  const location = readString(skill?.location || skill?.path);
  const path = location || "";
  const scope =
    path.includes("/.codex/skills/") || path.includes("/.agents/skills/")
      ? path.includes("/.codex/skills/")
        ? "global"
        : "project"
      : directory && path.startsWith(directory)
        ? "project"
        : "global";
  return {
    name,
    description: readString(skill?.description) || "",
    path,
    scope,
    enabled: skill?.enabled !== false,
    provider: "opencode",
  };
}

function normalizeOpenCodeEventType(type) {
  const normalized = readString(type);
  if (!normalized) {
    return "";
  }
  return normalized.endsWith(".1") ? normalized.slice(0, -2) : normalized;
}

function readOpenCodeEventProperties(event) {
  if (event?.properties && typeof event.properties === "object" && !Array.isArray(event.properties)) {
    return event.properties;
  }
  return event || {};
}

function normalizeSessionMessagesResponse(response) {
  if (Array.isArray(response)) {
    return response;
  }
  if (Array.isArray(response?.data)) {
    return response.data;
  }
  if (Array.isArray(response?.messages)) {
    return response.messages;
  }
  if (Array.isArray(response?.items)) {
    return response.items;
  }
  return [];
}

function openCodeToolContentText(content) {
  if (!Array.isArray(content)) {
    return "";
  }
  return content
    .map((part) => readString(part?.text))
    .filter(Boolean)
    .join("\n");
}

function dispatchEvent(event, handler) {
  const type = normalizeOpenCodeEventType(event?.type);
  if (!type) return;
  const properties = readOpenCodeEventProperties(event);

  switch (type) {
    case "turn.started":
      handler("turn/started", {
        turnId: readString(event.turnID || event.turnId),
        sessionId: readString(event.sessionID || event.sessionId),
      });
      break;

    case "message.part.added": {
      const props = readOpenCodeEventProperties(event);
      const part = props.part && typeof props.part === "object" ? props.part : event.part || {};
      const partType = readString(part.type || event.partType);
      const turnId = readString(props.turnID || props.turnId || event.turnID || event.turnId);
      const itemId =
        readString(part.id || props.partID || props.partId || event.partID || event.partId) ||
        `part-${Date.now()}`;
      const text = readString(part.text || props.text || event.text || event.content);
      if (partType === "tool_call" || partType === "tool") {
        handler("item/toolCall", {
          turnId,
          itemId,
          toolName: readString(event.part?.tool?.name || event.toolName),
          args: event.part?.tool?.args || event.args || {},
          status: "running",
        });
      } else if (text) {
        handler("item/agentMessage/delta", {
          turnId,
          itemId,
          delta: text,
          textDelta: text,
          assistantPhase: "final",
        });
      }
      break;
    }

    case "message.part.delta": {
      const props = readOpenCodeEventProperties(event);
      const field = readString(props.field).toLowerCase();
      const partType = readString(props.partType || event.partType || field);
      const turnId = readString(props.turnID || props.turnId || event.turnID || event.turnId);
      const itemId =
        readString(props.partID || props.partId || event.partID || event.partId) ||
        `agent-${Date.now()}`;
      const delta = readString(props.delta || event.delta || event.text || event.textDelta);

      if (partType === "reasoning" || field === "reasoning" || event.isReasoning) {
        if (delta) {
          handler("item/reasoning/textDelta", {
            turnId,
            itemId,
            delta,
            textDelta: delta,
            sessionId: readString(props.sessionID || props.sessionId),
          });
        }
      } else if (partType === "tool_call" || partType === "tool") {
        const toolName = readString(props.tool || event.tool?.name || event.toolName || event.name);
        const toolId =
          readString(props.callID || props.callId || event.tool?.id || event.toolID || event.toolId) ||
          `tool-${Date.now()}`;
        const state = readString(props.state || event.state || event.status);
        const args = props.input || props.args || event.args || event.tool?.args || {};
        const output = readString(props.output || props.delta || event.output || delta);

        if (output) {
          handler("item/toolCallUpdate", {
            turnId,
            itemId: toolId,
            toolName,
            args,
            output,
            status: state || "running",
            sessionId: readString(props.sessionID || props.sessionId),
          });
        } else {
          handler("item/toolCall", {
            turnId,
            itemId: toolId,
            toolName,
            args,
            status: state || "running",
            sessionId: readString(props.sessionID || props.sessionId),
          });
        }
      } else if (delta) {
        handler("item/agentMessage/delta", {
          turnId,
          itemId,
          delta,
          textDelta: delta,
          assistantPhase: "final",
          sessionId: readString(props.sessionID || props.sessionId),
        });
      }
      break;
    }

    case "message.part.updated": {
      const props = readOpenCodeEventProperties(event);
      const part = props.part && typeof props.part === "object" ? props.part : {};
      const partType = readString(part.type);
      const turnId = readString(props.turnID || props.turnId || event.turnID || event.turnId);
      const itemId = readString(part.id || props.partID || props.partId || event.partID || event.partId);
      const sessionId = readString(props.sessionID || props.sessionId || part.sessionID);

      if (partType === "text") {
        const text = readString(part.text);
        if (text) {
          handler("item/agentMessage/delta", {
            turnId,
            itemId,
            delta: text,
            textDelta: text,
            assistantPhase: "final",
            sessionId,
          });
          if (part.time?.end != null || part.time?.completed != null) {
            handler("item/completed", {
              turnId,
              itemId,
              message: text,
              assistantPhase: "final_answer",
              sessionId,
            });
          }
        }
        break;
      }

      if (partType === "reasoning") {
        const text = readString(part.text);
        if (text) {
          handler("item/reasoning/textDelta", {
            turnId,
            itemId,
            delta: text,
            textDelta: text,
            sessionId,
          });
        }
        break;
      }

      const state = readString(part.state?.status || part.state || event.state);
      if (state === "pending" || state === "in_progress" || state === "running") {
        handler("item/toolCall", {
          turnId,
          itemId,
          toolName: readString(part.name || part.tool?.name || event.toolName),
          status: state === "in_progress" || state === "running" ? "running" : "pending",
          sessionId,
        });
      } else if (state === "completed") {
        handler("item/toolCallUpdate", {
          turnId,
          itemId,
          status: "completed",
          sessionId,
        });
      } else if (state === "error" || state === "failed") {
        handler("item/toolCallUpdate", {
          turnId,
          itemId,
          status: "failed",
          sessionId,
        });
      }
      break;
    }

    case "message.completed":
      handler("item/completed", {
        turnId: readString(event.turnID || event.turnId),
        itemId: readString(event.messageID || event.messageId),
        message: readString(event.text || event.content),
        assistantPhase: "final_answer",
      });
      break;

    case "turn.completed":
      handler("turn/completed", {
        turnId: readString(event.turnID || event.turnId),
        status: readString(event.status) || "completed",
        sessionId: readString(event.sessionID || event.sessionId),
        completionSource: "turn.completed",
      });
      break;

    case "permission.asked":
      handler("permission/request", {
        permissionId: readString(event.requestID || event.requestId),
        tool: readString(event.tool || event.toolName),
        args: event.args || {},
      });
      break;

    case "session.idle":
      handler("turn/completed", {
        turnId: readString(event.turnID || event.turnId || event.properties?.turnID),
        status: "completed",
        sessionId: readString(event.sessionID || event.sessionId || event.properties?.sessionID),
        completionSource: "session.idle",
      });
      break;

    case "session.error": {
      const properties = readOpenCodeEventProperties(event);
      const errObject = properties.error && typeof properties.error === "object" ? properties.error : event.error;
      const errMsg = readString(errObject?.message || event.message || properties.message);
      handler("turn/failed", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID || event.turnId),
        sessionId: readString(properties.sessionID || properties.sessionId || event.sessionID || event.sessionId),
        message: errMsg || "OpenCode session error",
        error: errObject || properties,
      });
      handler("runtime/auth/error", {
        threadId: readString(properties.threadId || properties.thread_id),
        turnId: readString(properties.turnID || properties.turnId || event.turnID || event.turnId),
        sessionId: readString(properties.sessionID || properties.sessionId || event.sessionID || event.sessionId),
        message: errMsg || "OpenCode session error",
        error: errObject || properties,
        source: "session.error",
      });
      break;
    }

    case "session.compacted":
      handler("thread/context/compacted", {
        sessionId: readString(event.sessionID || event.sessionId),
        turnId: readString(event.turnID || event.turnId),
      });
      break;

    case "todo.updated":
      handler("turn/tasks/updated", {
        turnId: readString(event.turnID || event.turnId),
        sessionId: readString(event.sessionID || event.sessionId),
        todos: event.todos || event.properties?.todos || [],
      });
      break;

    case "session.status": {
      const status = readString(properties.status || event.status);
      if (status) {
        handler("runtime/warning", {
          sessionId: readString(properties.sessionID || properties.sessionId || event.sessionID),
          turnId: readString(properties.turnID || properties.turnId || event.turnID),
          message: `OpenCode session status: ${status}`,
          reasonCode: "opencode_session_status",
        });
      }
      break;
    }

    case "session.next.text.delta": {
      const delta = readString(properties.delta);
      if (!delta) {
        break;
      }
      const sessionId = readString(properties.sessionID || properties.sessionId);
      const itemId =
        readString(properties.partID || properties.partId) ||
        `oc-text-${sessionId || "session"}-${Date.now()}`;
      handler("item/agentMessage/delta", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId,
        delta,
        textDelta: delta,
        assistantPhase: "final",
        sessionId,
      });
      break;
    }

    case "session.next.text.ended": {
      const text = readString(properties.text);
      const sessionId = readString(properties.sessionID || properties.sessionId);
      const itemId =
        readString(properties.partID || properties.partId) ||
        `oc-text-${sessionId || "session"}-${Date.now()}`;
      if (text) {
        handler("item/agentMessage/delta", {
          turnId: readString(properties.turnID || properties.turnId || event.turnID),
          itemId,
          delta: text,
          textDelta: text,
          assistantPhase: "final",
          sessionId,
        });
      }
      handler("item/completed", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId,
        message: text,
        assistantPhase: "final_answer",
        sessionId,
      });
      break;
    }

    case "session.next.reasoning.delta": {
      const delta = readString(properties.delta);
      if (!delta) {
        break;
      }
      handler("item/reasoning/textDelta", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId: readString(properties.reasoningID || properties.reasoningId) || `reasoning-${Date.now()}`,
        delta,
        textDelta: delta,
        sessionId: readString(properties.sessionID || properties.sessionId),
      });
      break;
    }

    case "session.next.reasoning.ended": {
      const reasoningText = readString(properties.text);
      handler("item/completed", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId: readString(properties.reasoningID || properties.reasoningId) || `reasoning-${Date.now()}`,
        message: reasoningText,
        assistantPhase: "reasoning",
        sessionId: readString(properties.sessionID || properties.sessionId),
      });
      break;
    }

    case "session.next.tool.called": {
      const toolName = readString(properties.tool || properties.name);
      const callId = readString(properties.callID || properties.callId) || `tool-${Date.now()}`;
      handler("item/toolCall", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId: callId,
        toolName,
        args: properties.input || properties.args || {},
        status: "running",
        sessionId: readString(properties.sessionID || properties.sessionId),
      });
      break;
    }

    case "session.next.tool.progress":
    case "session.next.tool.success": {
      const callId = readString(properties.callID || properties.callId);
      const output = openCodeToolContentText(properties.content);
      const status = type === "session.next.tool.success" ? "completed" : "running";
      handler("item/toolCallUpdate", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId: callId || `tool-${Date.now()}`,
        output,
        status,
        sessionId: readString(properties.sessionID || properties.sessionId),
      });
      if (type === "session.next.tool.success") {
        handler("item/completed", {
          turnId: readString(properties.turnID || properties.turnId || event.turnID),
          itemId: callId,
          status: "completed",
          sessionId: readString(properties.sessionID || properties.sessionId),
        });
      }
      break;
    }

    case "session.next.tool.failed": {
      const callId = readString(properties.callID || properties.callId);
      const errMsg = readString(properties.error?.message || properties.message) || "Tool failed";
      handler("item/toolCallUpdate", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        itemId: callId || `tool-${Date.now()}`,
        output: errMsg,
        status: "failed",
        sessionId: readString(properties.sessionID || properties.sessionId),
      });
      break;
    }

    case "session.next.step.failed": {
      const errMsg =
        readString(properties.error?.message || properties.message) || "OpenCode step failed";
      handler("turn/failed", {
        turnId: readString(properties.turnID || properties.turnId || event.turnID),
        sessionId: readString(properties.sessionID || properties.sessionId),
        message: errMsg,
      });
      break;
    }

    default:
      break;
  }
}

function resolveAgentsList(response) {
  if (Array.isArray(response)) return response;
  if (response && Array.isArray(response.data)) return response.data;
  if (response && Array.isArray(response.agents)) return response.agents;
  return [];
}

function resolveProjectList(response) {
  if (Array.isArray(response)) {
    return response.map(mapOpenCodeProjectRow).filter(Boolean);
  }
  if (Array.isArray(response?.data)) {
    return response.data.map(mapOpenCodeProjectRow).filter(Boolean);
  }
  if (Array.isArray(response?.projects)) {
    return response.projects.map(mapOpenCodeProjectRow).filter(Boolean);
  }
  return [];
}

function emptySessionListResult() {
  return { data: [], limited: false, limit: 0, nextCursor: null };
}

function resolveSessionListCursor(cursor) {
  if (cursor === null || cursor === undefined || cursor === "") {
    return { numeric: null, opaque: "" };
  }
  const numeric = Number(cursor);
  if (Number.isFinite(numeric) && numeric >= 0 && String(cursor).trim() === String(Math.floor(numeric))) {
    return { numeric: Math.floor(numeric), opaque: "" };
  }
  return { numeric: null, opaque: readString(cursor) };
}

function resolveSessionListNextCursor(response) {
  if (response?.cursor && typeof response.cursor === "object" && !Array.isArray(response.cursor)) {
    return readString(response.cursor.next) || null;
  }
  const direct = response?.nextCursor ?? response?.cursor;
  if (typeof direct === "number" && Number.isFinite(direct)) {
    return direct;
  }
  return readString(direct) || null;
}

function resolveSessionList(response) {
  const rows = [];
  if (Array.isArray(response)) {
    rows.push(...response);
  } else if (Array.isArray(response?.data)) {
    rows.push(...response.data);
  } else if (Array.isArray(response?.items)) {
    rows.push(...response.items);
  } else if (Array.isArray(response?.sessions)) {
    rows.push(...response.sessions);
  }

  const discovered = rows
    .map(sessionV2InfoToDiscoveredThread)
    .filter(Boolean)
    .toSorted(compareThreadsByUpdatedAt)
    .map(publicThread);

  return {
    data: discovered,
    limited: Boolean(response?.limited),
    limit: Number(response?.limit) || discovered.length,
    nextCursor: resolveSessionListNextCursor(response),
  };
}

function mapOpenCodeProjectRow(project) {
  if (!project || typeof project !== "object") {
    return null;
  }
  const path = readString(project.path || project.directory || project.cwd || project.worktree);
  const id = readString(project.id || project.projectID || project.projectId);
  const name = readString(project.name || project.title || project.label) || path;
  if (!path && !id) {
    return null;
  }
  return {
    id: id || path,
    name,
    path: path || null,
    directory: path || null,
    cwd: path || null,
    source: "opencode",
  };
}

function resolveProviderListPayload(response) {
  if (!response || typeof response !== "object") return response;

  if (Array.isArray(response.providers) || Array.isArray(response.all)) {
    return response;
  }

  const nested = response.data;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    return nested;
  }

  return response;
}

function providerEntriesFromPayload(payload) {
  if (!payload || typeof payload !== "object") return [];

  if (Array.isArray(payload.providers)) return payload.providers;
  if (Array.isArray(payload.all)) return payload.all;
  return [];
}

function modelsForProvider(provider) {
  const models = provider?.models;
  if (Array.isArray(models)) return models;
  if (models && typeof models === "object") return Object.values(models);
  return [];
}

function flattenProviderModels(response) {
  if (!response || typeof response !== "object") return [];

  const payload = resolveProviderListPayload(response);
  const providers = providerEntriesFromPayload(payload);
  if (providers.length > 0) {
    return providers.flatMap((provider) => {
      const providerId = readString(provider.id || provider.providerId || provider.providerID);
      return modelsForProvider(provider).map((model) => buildModelFromAny(model, providerId));
    });
  }

  const models = Array.isArray(payload.models) ? payload.models : [];
  const items = Array.isArray(payload.items) ? payload.items : [];
  const data = Array.isArray(payload.data) ? payload.data : [];
  const flat = [...models, ...items, ...data];
  if (flat.length > 0) return flat.map((m) => buildModelFromAny(m, "unknown"));
  return [];
}

function buildModelFromAny(model, upstreamProviderIdOrProvider) {
  const modelId = readString(model.id || model.model || model.name);
  let upstreamProviderId = "";
  let upstreamProviderDisplayName = "";
  if (upstreamProviderIdOrProvider && typeof upstreamProviderIdOrProvider === "object") {
    upstreamProviderId = readString(
      upstreamProviderIdOrProvider.id ||
        upstreamProviderIdOrProvider.providerId ||
        upstreamProviderIdOrProvider.providerID,
    );
    upstreamProviderDisplayName =
      readString(upstreamProviderIdOrProvider.name) ||
      formatProviderDisplayName(upstreamProviderId);
  } else {
    upstreamProviderId = readString(upstreamProviderIdOrProvider);
    upstreamProviderDisplayName = formatProviderDisplayName(upstreamProviderId);
  }
  const reference = `${upstreamProviderId}/${modelId}`;
  const capabilities = resolveModelCapabilities(OPENCODE_PROVIDER_ID, model);
  const logoProviderId = resolveLogoProviderId(upstreamProviderId, upstreamProviderDisplayName);

  return {
    id: reference,
    model: reference,
    modelProvider: OPENCODE_PROVIDER_ID,
    provider: OPENCODE_PROVIDER_ID,
    upstreamProviderId,
    upstreamProviderDisplayName,
    displayName:
      readString(model.name || model.displayName) || displayNameForOpenCodeModel(reference),
    description: readString(model.description) || "",
    isDefault: reference === DEFAULT_OPENCODE_MODEL,
    capabilities,
    contextWindow: model.contextWindow || model.context_window || null,
    status: readString(model.status) || "active",
    serveVariants:
      model.variants && typeof model.variants === "object" && !Array.isArray(model.variants)
        ? model.variants
        : null,
    ...(logoProviderId ? { logoProviderId } : {}),
  };
}

function formatProviderDisplayName(providerId) {
  const normalized = readString(providerId).toLowerCase();
  const known = {
    anthropic: "Anthropic",
    openai: "OpenAI",
    google: "Google",
    github: "GitHub Copilot",
    "github-copilot": "GitHub Copilot",
    "amazon-bedrock": "Amazon Bedrock",
    bedrock: "Amazon Bedrock",
    openrouter: "OpenRouter",
    xai: "xAI",
    deepseek: "DeepSeek",
    opencode: "OpenCode",
    azure: "Azure",
    groq: "Groq",
  };
  return known[normalized] || normalized.charAt(0).toUpperCase() + normalized.slice(1);
}

function boundedProviderCacheTtlMs(env = process.env) {
  const raw = readString(env?.REMODEX_OPENCODE_PROVIDER_CACHE_MS);
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed > 0) {
    return parsed;
  }
  return 60_000;
}

function withTimeout(promise, ms) {
  let timeoutId;
  const timeoutPromise = new Promise((_, reject) => {
    timeoutId = setTimeout(
      () => reject(new Error(`OpenCode SDK request timed out after ${ms}ms`)),
      ms,
    );
    timeoutId.unref?.();
  });

  return Promise.race([promise, timeoutPromise]).finally(() => {
    clearTimeout(timeoutId);
  });
}

function sleep(delayMs) {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}

function resolveProviderAuthPayload(response) {
  if (!response || typeof response !== "object") return response;

  const nested = response.data;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    return nested;
  }

  return response;
}

module.exports = {
  BUILTINS,
  buildStaticSlashCommands,
  normalizeCommandNameForSdk,
  normalizeCommandTokenForAllowlist,
  mapSdkCommandToBridge,
  createOpenCodeClient,
  dispatchEvent,
  normalizeSessionMessagesResponse,
  flattenProviderModels,
  buildModelFromAny,
  resolveAgentsList,
  normalizeOpenCodeEventType,
  resolveProviderListPayload,
  resolveProviderAuthPayload,
  resolveSessionIdFromCreateResponse,
  resolveSessionList,
};
