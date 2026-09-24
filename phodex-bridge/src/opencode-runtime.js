// FILE: opencode-runtime.js
// Purpose: Adapts the local OpenCode server API to Remodex's Codex-shaped JSON-RPC contract.
// Layer: CLI service
// Exports: createOpenCodeRuntime

const net = require("node:net");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { randomBytes } = require("node:crypto");
const { spawn } = require("node:child_process");

const THREAD_PREFIX = "opencode:";
const REQUEST_PREFIX = "opencode-";
const TURN_CURSOR_PREFIX = "opencode-turn-cursor:";
const MESSAGE_PAGE_SIZE = 50;
// OpenCode defaults /session to 100 rows. Worktree safety checks must inspect
// every binding, including archived sessions and child sessions.
const COMPLETE_SESSION_LIST_LIMIT = 1_000_000;

function encodeThreadId(sessionID) {
  if (typeof sessionID !== "string" || !sessionID.startsWith("ses")) {
    throw new Error("OpenCode returned an invalid session id");
  }
  return `${THREAD_PREFIX}${sessionID}`;
}

function decodeThreadId(threadId) {
  if (typeof threadId !== "string" || !threadId.startsWith(THREAD_PREFIX)) return null;
  const sessionID = threadId.slice(THREAD_PREFIX.length);
  return sessionID.startsWith("ses") ? sessionID : null;
}

function asMillis(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function modelIdentity(session) {
  const providerID = session?.metadata?.remodexModelProvider || session?.model?.providerID || "";
  const modelID = session?.metadata?.remodexModelID || session?.model?.id || "";
  return { providerID, modelID, full: providerID && modelID ? `${providerID}/${modelID}` : "" };
}

function modelVariant(session) {
  // OpenCode writes `default` when a prompt omits variant. That is not a
  // selectable effort and must take precedence over creation-time metadata.
  if (session?.model && Object.hasOwn(session.model, "variant")) {
    return normalizedVariant(session.model.variant);
  }
  if (session?.metadata && Object.hasOwn(session.metadata, "remodexObservedVariant")) {
    return normalizedVariant(session.metadata.remodexObservedVariant);
  }
  return normalizedVariant(session?.metadata?.remodexVariant);
}

function latestMessageVariant(messages) {
  for (let index = (messages || []).length - 1; index >= 0; index -= 1) {
    const info = messages[index]?.info || {};
    const variant = info.variant || info.model?.variant;
    if (typeof variant === "string" && variant.trim()) return variant;
  }
  return null;
}

function latestMessageModel(messages) {
  for (let index = (messages || []).length - 1; index >= 0; index -= 1) {
    const info = messages[index]?.info || {};
    const providerID = info.model?.providerID || info.providerID;
    const modelID = info.model?.modelID || info.modelID;
    if (providerID && modelID) return { providerID, modelID };
  }
  return null;
}

function normalizeThread(session, turns) {
  const model = modelIdentity(session);
  return {
    id: encodeThreadId(session.id),
    runtimeProvider: "opencode",
    model: model.full,
    modelProvider: model.providerID,
    ...(modelVariant(session) ? { reasoningEffort: modelVariant(session) } : {}),
    cwd: session.directory || session.path || "",
    title: session.title || "OpenCode session",
    createdAt: asMillis(session.time?.created),
    updatedAt: asMillis(session.time?.updated),
    ...(session.time?.archived ? { syncState: "archivedLocal" } : {}),
    ...(Array.isArray(turns) ? { turns } : {}),
  };
}

function partsFromInput(input) {
  const items = typeof input === "string" ? [input] : input;
  if (!Array.isArray(items)) throw new Error("OpenCode prompt input is invalid");
  const parts = [];
  for (const item of items) {
    if (typeof item === "string" || item?.type === "text" || (!item?.type && typeof item?.text === "string")) {
      const text = typeof item === "string" ? item : item.text;
      if (typeof text !== "string") throw new Error("OpenCode text input is invalid");
      if (text) parts.push({ type: "text", text });
    } else if (item?.type === "image") {
      const url = item.url || item.image_url;
      const mime = typeof url === "string" && /^data:([^;,]+);base64,/.exec(url)?.[1];
      if (!mime?.startsWith("image/")) throw new Error("OpenCode image input needs an image data URL");
      parts.push({ type: "file", mime, url });
    } else if (item?.type === "skill" || item?.type === "mention") {
      // The iOS composer also includes these references as text tokens.
    } else {
      throw new Error(`OpenCode does not support input type: ${item?.type || "unknown"}`);
    }
  }
  if (parts.length === 0) throw new Error("OpenCode prompt is empty");
  return parts;
}

function normalizePart(part, role, messageCreatedAt) {
  const id = part?.id || `${part?.messageID || role}-part`;
  const timestamp = asMillis(part?.time?.start || part?.time?.created || messageCreatedAt);
  const identity = { id, ...(timestamp > 0 ? { createdAt: timestamp } : {}) };
  if (part?.type === "text") {
    return role === "user"
      ? { ...identity, type: "message", role: "user", content: [{ type: "input_text", text: part.text || "" }] }
      : { ...identity, type: "agentMessage", text: part.text || "" };
  }
  if (part?.type === "reasoning") return { ...identity, type: "reasoning", summary: [], content: part.text || "" };
  if (part?.type === "tool") {
    return {
      ...identity,
      type: "commandExecution",
      command: part.tool || "tool",
      status: part.state?.status || "in_progress",
      aggregatedOutput: typeof part.state?.output === "string" ? part.state.output : "",
    };
  }
  if (part?.type === "file") {
    if (role === "user" && part.mime?.startsWith("image/") && part.url) {
      return { ...identity, type: "message", role: "user", content: [{ type: "input_image", image_url: part.url }] };
    }
    return { ...identity, type: "agentMessage", text: part.filename || part.url || part.mime || "File attachment" };
  }
  return null;
}

function normalizeTurns(messages, running = false) {
  const turns = [];
  let current = null;
  for (const message of Array.isArray(messages) ? messages : []) {
    const info = message?.info || {};
    const role = info.role;
    const createdAt = asMillis(info.time?.created);
    if (role === "user" || !current) {
      current = {
        id: `opencode-turn:${info.id || turns.length}`,
        status: "completed",
        ...(createdAt > 0 ? { createdAt } : {}),
        items: [],
      };
      turns.push(current);
    }
    for (const part of message?.parts || []) {
      const item = normalizePart(part, role, createdAt);
      if (item) current.items.push(item);
    }
  }
  if (running && current) current.status = "inProgress";
  return turns;
}

function freeModel(modelID, model) {
  if (modelID.endsWith("-free")) return true;
  const input = model?.cost?.input;
  const output = model?.cost?.output;
  return Number.isFinite(input) && Number.isFinite(output) && input === 0 && output === 0;
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function normalizedVariant(value) {
  const variant = nonEmptyString(value);
  return variant === "default" ? null : variant;
}

function reasoningEffortFromVariant(variant) {
  const thinking = variant.thinkingConfig || variant.thinking_config || {};
  const reasoning = variant.reasoning || {};
  const reasoningConfig = variant.reasoningConfig || variant.reasoning_config || {};
  return nonEmptyString(variant.reasoningEffort)
    || nonEmptyString(variant.reasoning_effort)
    || nonEmptyString(variant.effort)
    || nonEmptyString(thinking.thinkingLevel)
    || nonEmptyString(thinking.thinking_level)
    || nonEmptyString(reasoning.effort)
    || nonEmptyString(reasoningConfig.maxReasoningEffort)
    || nonEmptyString(reasoningConfig.max_reasoning_effort);
}

function reasoningVariants(model) {
  // A present, empty variants record is authoritative: the server may have
  // disabled every variant for this model.
  if (model && Object.hasOwn(model, "variants")) {
    if (!model.variants || typeof model.variants !== "object" || Array.isArray(model.variants)) return [];
    return Object.entries(model.variants).flatMap(([id, config]) => {
      if (!nonEmptyString(id) || !config || typeof config !== "object" || Array.isArray(config)) return [];
      const effort = reasoningEffortFromVariant(config);
      const hasReasoningConfig = ["thinking", "thinkingConfig", "thinking_config", "reasoning", "reasoningConfig", "reasoning_config"]
        .some((key) => Object.hasOwn(config, key));
      if (!effort && !hasReasoningConfig && Object.keys(config).length > 0) return [];
      // The key is the OpenCode wire id. A custom `deep` key can mean high effort.
      return [{ id, ...(effort ? { reasoningEffort: effort } : {}) }];
    });
  }
  const raw = model?.reasoning_options ?? model?.reasoningOptions
    ?? model?.options?.reasoning_options ?? model?.options?.reasoningOptions;
  if (!Array.isArray(raw)) return [];
  const ids = new Set();
  for (const option of raw) {
    if (option?.type !== "effort" || !Array.isArray(option.values)) continue;
    for (const value of option.values) {
      const id = value === null ? "none" : nonEmptyString(value);
      if (id) ids.add(id);
    }
  }
  return [...ids].map((id) => ({ id, reasoningEffort: id }));
}

function defaultVariant(model, variants) {
  const configured = nonEmptyString(model?.options?.reasoningEffort)
    || nonEmptyString(model?.options?.reasoning_effort)
    || nonEmptyString(model?.options?.effort);
  const matching = variants.find((variant) => variant.id === configured || variant.reasoningEffort === configured);
  if (matching) return matching.id;
  return null;
}

function normalizeModels(catalog) {
  const items = [];
  for (const provider of catalog?.all || []) {
    if (provider?.id !== "opencode" && provider?.id !== "opencode-go") continue;
    for (const [modelID, model] of Object.entries(provider.models || {})) {
      const tier = provider.id === "opencode-go" ? "go" : freeModel(modelID, model) ? "free" : "zen";
      const variants = reasoningVariants(model);
      const preferredVariant = defaultVariant(model, variants);
      items.push({
        id: `${provider.id}/${modelID}`,
        name: model?.name || modelID,
        providerID: provider.id,
        providerName: provider.name || (provider.id === "opencode-go" ? "OpenCode Go" : "OpenCode Zen"),
        tier,
        variants,
        ...(preferredVariant ? { defaultVariant: preferredVariant } : {}),
      });
    }
  }
  return items;
}

function splitModel(full) {
  const slash = typeof full === "string" ? full.indexOf("/") : -1;
  if (slash <= 0 || slash === full.length - 1) throw new Error("OpenCode model must be provider/model");
  const providerID = full.slice(0, slash);
  if (providerID !== "opencode" && providerID !== "opencode-go") {
    throw new Error(`Unsupported OpenCode provider: ${providerID}`);
  }
  return { providerID, modelID: full.slice(slash + 1) };
}

async function availablePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function createOpenCodeRuntime({
  onNotification = () => {},
  fetchImpl = globalThis.fetch,
  spawnImpl = spawn,
  findPort = availablePort,
  passwordFactory = () => randomBytes(24).toString("base64url"),
  baseUrl: configuredBaseUrl,
  opencodeBin,
  startupTimeoutMs = 8_000,
  reconnectDelayMs = 1_000,
  completedTurnStateGraceMs = 60_000,
  variantCatchupMs = 5_000,
  turnPollIntervalMs = 750,
} = {}) {
  if (typeof fetchImpl !== "function") throw new Error("OpenCode runtime requires fetch");
  let baseUrl = configuredBaseUrl || "";
  let password = configuredBaseUrl ? "" : passwordFactory();
  let child = null;
  let startPromise = null;
  let ownedServerExit = null;
  let stopped = false;
  let eventAbort = null;
  let eventTask = null;
  let restartEventsAfterCurrentTask = false;
  let requestSequence = 0;
  const sessionCache = new Map();
  // prompt_async acknowledges before OpenCode's session model is updated.
  // Keep the accepted choice until a subsequent server snapshot confirms it.
  const pendingAcceptedVariants = new Map();
  const running = new Map();
  const polledTurns = new Map();
  const completedTurnIds = new Set();
  const pendingRequests = new Map();
  const streamedParts = new Map();
  const messageRoles = new Map();
  const messageTurnIds = new Map();
  const messageIDsByTurn = new Map();
  const partIDsByTurn = new Map();
  const completedTurnCleanupTimers = new Map();
  const phoneTurnIds = new Set();
  const pendingUnknownParts = new Map();
  const resolvingUnknownMessages = new Map();
  const sessionStatuses = new Map();
  const sessionEventRevisions = new Map();
  let eventConnectionRevision = 0;

  function withVariant(session, variant) {
    const metadata = { ...session.metadata };
    delete metadata.remodexObservedVariant;
    if (variant) metadata.remodexVariant = variant;
    else delete metadata.remodexVariant;
    return {
      ...session,
      model: { ...session.model, variant: variant || "default" },
      metadata,
    };
  }

  function cacheSession(session) {
    const pending = pendingAcceptedVariants.get(session.id);
    if (!pending) {
      sessionCache.set(session.id, session);
      return session;
    }
    const serverVariant = session.model && Object.hasOwn(session.model, "variant")
      ? normalizedVariant(session.model.variant)
      : undefined;
    if (serverVariant !== undefined && serverVariant === pending.variant) {
      pendingAcceptedVariants.delete(session.id);
      sessionCache.set(session.id, session);
      return session;
    }
    if (Date.now() - pending.acceptedAt >= variantCatchupMs) {
      pendingAcceptedVariants.delete(session.id);
      sessionCache.set(session.id, session);
      return session;
    }
    const corrected = withVariant(session, pending.variant);
    sessionCache.set(session.id, corrected);
    return corrected;
  }

  function resolveOpenCodeBin() {
    const pathCandidates = String(process.env.PATH || "").split(path.delimiter)
      .filter(Boolean).map((directory) => path.join(directory, "opencode"));
    const candidates = [
      opencodeBin,
      process.env.REMODEX_OPENCODE_BIN,
      path.join(os.homedir(), ".opencode", "bin", "opencode"),
      ...pathCandidates,
    ]
      .filter(Boolean);
    for (const candidate of candidates) {
      try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch {}
    }
    throw new Error("OpenCode is not installed. Install it or set REMODEX_OPENCODE_BIN to its executable path.");
  }

  function headers(extra = {}) {
    return {
      Accept: "application/json",
      ...(password ? { Authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}` } : {}),
      ...extra,
    };
  }

  async function request(path, { method = "GET", body, signal, accept, includeHeaders = false } = {}) {
    const response = await fetchImpl(`${baseUrl}${path}`, {
      method,
      headers: headers({
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        ...(accept ? { Accept: accept } : {}),
      }),
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      ...(signal ? { signal } : {}),
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      const error = new Error(`OpenCode ${method} ${path} failed (${response.status})${detail ? `: ${detail.slice(0, 240)}` : ""}`);
      error.status = response.status;
      throw error;
    }
    if (response.status === 204) return includeHeaders ? { data: null, headers: response.headers } : null;
    const type = response.headers?.get?.("content-type") || "";
    const data = await (type.includes("json") ? response.json() : response.text());
    return includeHeaders ? { data, headers: response.headers } : data;
  }

  async function probe() {
    const health = await request("/global/health");
    const version = String(health?.version || "");
    if (!version) throw new Error("OpenCode health response did not include a version");
    const [providers, projects] = await Promise.all([request("/provider"), request("/project")]);
    if (!Array.isArray(providers?.all) || !Array.isArray(projects)) {
      throw new Error(`OpenCode ${version} does not expose the released server API contract`);
    }
  }

  async function waitForProbe() {
    const deadline = Date.now() + startupTimeoutMs;
    let lastError;
    while (Date.now() < deadline) {
      if (ownedServerExit) throw ownedServerExit;
      if (child?.exitCode != null) throw new Error(`OpenCode server exited with code ${child.exitCode}`);
      try { await probe(); return; } catch (error) { lastError = error; }
      await new Promise((resolve) => setTimeout(resolve, 75));
    }
    throw new Error(`OpenCode server did not become ready: ${lastError?.message || "timeout"}`);
  }

  async function ensureStarted() {
    if (startPromise) return startPromise;
    stopped = false;
    let launchedChild = null;
    const attempt = (async () => {
      if (!baseUrl) {
        const port = await findPort();
        baseUrl = `http://127.0.0.1:${port}`;
        ownedServerExit = null;
        launchedChild = spawnImpl(resolveOpenCodeBin(), ["serve", "--hostname", "127.0.0.1", "--port", String(port)], {
          env: { ...process.env, OPENCODE_SERVER_PASSWORD: password },
          stdio: "ignore",
        });
        child = launchedChild;
        launchedChild.once?.("exit", (code, signal) => {
          if (child !== launchedChild || stopped) return;
          ownedServerExit = new Error(`OpenCode server exited (${signal ?? code ?? "unknown"})`);
          child = null;
          baseUrl = "";
          startPromise = null;
          eventConnectionRevision += 1;
          eventAbort?.abort();
          for (const sessionID of [...running.keys()]) {
            finishTurn(sessionID, "failed", "OpenCode server stopped. Send again to reconnect.");
          }
          sessionStatuses.clear();
          for (const [id, pending] of pendingRequests) {
            emit("serverRequest/resolved", { requestId: id, threadId: encodeThreadId(pending.properties.sessionID) });
          }
          pendingRequests.clear();
        });
        launchedChild.once?.("error", (error) => {
          ownedServerExit = error;
        });
      }
      await waitForProbe();
      startEvents();
      return { baseUrl };
    })();
    const guarded = attempt.catch((error) => {
      if (startPromise === guarded) startPromise = null;
      if (child === launchedChild) {
        if (child?.exitCode == null) child?.kill?.();
        child = null;
        if (!configuredBaseUrl) baseUrl = "";
      }
      throw error;
    });
    startPromise = guarded;
    return startPromise;
  }

  function emit(method, params, id) {
    onNotification(id === undefined ? { method, params } : { id, method, params });
  }

  function retainTurnMessage(turnId, messageID) {
    let ids = messageIDsByTurn.get(turnId);
    if (!ids) {
      ids = new Set();
      messageIDsByTurn.set(turnId, ids);
    }
    ids.add(messageID);
  }

  function retainTurnPart(turnId, partID) {
    let ids = partIDsByTurn.get(turnId);
    if (!ids) {
      ids = new Set();
      partIDsByTurn.set(turnId, ids);
    }
    ids.add(partID);
  }

  function releaseTurnEventState(turnId) {
    for (const messageID of messageIDsByTurn.get(turnId) || []) {
      if (messageTurnIds.get(messageID) === turnId) {
        messageTurnIds.delete(messageID);
        messageRoles.delete(messageID);
        pendingUnknownParts.delete(messageID);
      }
    }
    for (const partID of partIDsByTurn.get(turnId) || []) {
      if (streamedParts.get(partID)?.turnId === turnId) streamedParts.delete(partID);
    }
    messageIDsByTurn.delete(turnId);
    partIDsByTurn.delete(turnId);
    phoneTurnIds.delete(turnId);
    completedTurnCleanupTimers.delete(turnId);
  }

  function scheduleTurnEventStateCleanup(turnId) {
    if (completedTurnCleanupTimers.has(turnId)) return;
    const timer = setTimeout(() => releaseTurnEventState(turnId), completedTurnStateGraceMs);
    timer.unref?.();
    completedTurnCleanupTimers.set(turnId, timer);
  }

  function finishTurn(sessionID, status, errorMessage) {
    const active = running.get(sessionID);
    running.delete(sessionID);
    stopTurnPoll(sessionID);
    if (!active?.turnId || completedTurnIds.has(active.turnId)) return;
    completedTurnIds.add(active.turnId);
    if (completedTurnIds.size > 512) completedTurnIds.delete(completedTurnIds.values().next().value);
    scheduleTurnEventStateCleanup(active.turnId);
    emit("turn/completed", {
      threadId: encodeThreadId(sessionID),
      turnId: active.turnId,
      turn: {
        id: active.turnId,
        status,
        ...(errorMessage ? { error: { message: errorMessage } } : {}),
        items: [],
      },
    });
  }

  function stopTurnPoll(sessionID) {
    const state = polledTurns.get(sessionID);
    if (!state) return;
    if (state.timer) clearTimeout(state.timer);
    polledTurns.delete(sessionID);
  }

  async function pollTurnMessages(session, turnId) {
    const anchor = turnId.startsWith("opencode-turn:") ? turnId.slice("opencode-turn:".length) : null;
    const pages = [];
    const seenCursors = new Set();
    let before;
    while (true) {
      if (stopped || running.get(session.id)?.turnId !== turnId) return [];
      const page = await request(messagePath(session, { limit: 20, before }), {
        includeHeaders: true,
        signal: AbortSignal.timeout(3_000),
      });
      if (!Array.isArray(page.data)) throw new Error("OpenCode returned invalid turn messages");
      pages.unshift(page.data);
      if (!anchor || page.data.some((message) => message?.info?.id === anchor)) break;
      const next = page.headers?.get?.("x-next-cursor");
      if (!next || seenCursors.has(next)) break;
      seenCursors.add(next);
      before = next;
    }
    return pages.flat();
  }

  // The released server does not broadcast every CLI-created session's events
  // through this serve process. Reconcile only phone-started turns, and share
  // the item identity maps with SSE so either source can win without duplicates.
  function watchTurn(session, turnId) {
    stopTurnPoll(session.id);
    const state = {
      turnId, seenBusy: false, timer: null,
    };
    polledTurns.set(session.id, state);
    const poll = async () => {
      if (stopped || polledTurns.get(session.id) !== state || running.get(session.id)?.turnId !== turnId) return;
      try {
        const [messages, statuses] = await Promise.all([
          pollTurnMessages(session, turnId),
          request(`/session/status?directory=${encodeURIComponent(session.directory)}`, {
            signal: AbortSignal.timeout(3_000),
          }),
        ]);
        if (polledTurns.get(session.id) !== state || running.get(session.id)?.turnId !== turnId) return;
        if (!statuses || typeof statuses !== "object" || Array.isArray(statuses)) {
          throw new Error("OpenCode returned invalid session status");
        }
        let assistantCompleted = false;
        let assistantFailure = null;
        let assistantInterrupted = false;
        for (const message of Array.isArray(messages) ? messages : []) {
          const info = message?.info;
          const belongsToTurn = info?.role === "user" && turnId === `opencode-turn:${info.id}`
            || info?.role === "assistant" && turnId === `opencode-turn:${info.parentID}`;
          if (!belongsToTurn) continue;
          rememberMessageInfo(session.id, info, { allowStart: false });
          for (const part of message.parts || []) {
            emitItem({ ...part, sessionID: part.sessionID || session.id, messageID: part.messageID || info.id });
          }
          if (info.role === "assistant") {
            // The latest assistant message determines the result. A retry can
            // succeed after an earlier assistant message failed.
            assistantCompleted = Boolean(info.time?.completed);
            assistantFailure = info.error
              ? info.error?.data?.message || info.error?.message || info.error?.name || "OpenCode turn failed"
              : null;
            assistantInterrupted = Boolean(info.error && /abort|interrupt/i.test(info.error?.name || ""));
          }
        }
        const statusEntry = statuses[session.id];
        const status = statusEntry?.type;
        if (status === "busy" || status === "retry") {
          state.seenBusy = true;
        }
        if (status === "error") {
          assistantFailure = assistantFailure || statusEntry?.error?.message || "OpenCode turn failed";
        }
        // A missing status entry is not an idle signal. The assistant's
        // terminal message or an explicit idle/error status must end the turn.
        if (status !== "busy" && status !== "retry"
          && ((status === "idle" && state.seenBusy) || assistantCompleted
            || (assistantFailure && status == null) || status === "error")) {
          finishTurn(session.id,
            assistantInterrupted ? "interrupted" : assistantFailure ? "failed" : "completed",
            assistantFailure);
          return;
        }
      } catch { /* A failed poll cannot prove a turn ended; SSE and the next poll can recover. */ }
      if (polledTurns.get(session.id) !== state) return;
      state.timer = setTimeout(poll, turnPollIntervalMs);
      state.timer.unref?.();
    };
    void poll();
  }

  function emitItem(part) {
    if (!part?.sessionID || !part?.messageID || !part?.id) return false;
    const threadId = encodeThreadId(part.sessionID);
    const turnId = messageTurnIds.get(part.messageID) || running.get(part.sessionID)?.turnId;
    const role = messageRoles.get(part.messageID);
    if (!role || !turnId) return false;
    if (running.get(part.sessionID)?.turnId !== turnId && !completedTurnIds.has(turnId)) return false;
    if (completedTurnIds.has(turnId) && !streamedParts.has(part.id)) return false;
    const item = normalizePart(part, role);
    if (!item) return true;
    const itemParams = {
      threadId,
      turnId,
      item,
      ...(role === "user" && !phoneTurnIds.has(turnId) ? { remodexDesktopMirror: true } : {}),
    };
    const previous = streamedParts.get(part.id);
    if (!previous) {
      streamedParts.set(part.id, { text: part.text || "", part, completed: false, turnId });
      retainTurnPart(turnId, part.id);
      emit("item/started", itemParams);
    } else if ((part.type === "text" || part.type === "reasoning") && (part.text || "").startsWith(previous.text)) {
      const delta = (part.text || "").slice(previous.text.length);
      if (delta) {
        emit(part.type === "reasoning" ? "item/reasoning/textDelta" : "item/agentMessage/delta", {
          threadId, turnId, itemId: part.id, delta,
        });
      }
      previous.text = part.text || "";
    }
    const completed = role === "user" || Boolean(part.time?.end)
      || (part.type === "tool" && ["completed", "error"].includes(part.state?.status));
    const state = streamedParts.get(part.id);
    if (state) state.part = { ...part, text: state.text };
    if (completed && state && !state.completed) {
      state.completed = true;
      emit("item/completed", itemParams);
    }
    return true;
  }

  function rememberMessageInfo(sessionID, info, { allowStart = true } = {}) {
    if (!sessionID || !info?.id || !info.role) return;
    const turnId = info.role === "user" ? `opencode-turn:${info.id}`
      : info.parentID ? `opencode-turn:${info.parentID}`
        : running.get(sessionID)?.turnId;
    if (!turnId) return;
    if (completedTurnIds.has(turnId) && !completedTurnCleanupTimers.has(turnId)) return;
    if (!allowStart && !completedTurnIds.has(turnId) && running.get(sessionID)?.turnId !== turnId) return;
    messageRoles.set(info.id, info.role);
    messageTurnIds.set(info.id, turnId);
    retainTurnMessage(turnId, info.id);
    if (!allowStart || completedTurnIds.has(turnId)) return;
    const previous = running.get(sessionID);
    if (info.role === "user" && previous?.turnId && previous.turnId !== turnId) {
      finishTurn(sessionID, "completed");
    }
    if (!running.get(sessionID)?.turnId) {
      running.set(sessionID, { turnId });
      emit("turn/started", { threadId: encodeThreadId(sessionID), turnId, turn: { id: turnId, status: "inProgress", items: [] } });
    }
  }

  function flushUnknownParts(messageID) {
    const pending = pendingUnknownParts.get(messageID);
    if (!pending || !messageRoles.has(messageID) || !messageTurnIds.has(messageID)) return;
    pendingUnknownParts.delete(messageID);
    for (const part of pending.parts.values()) emitItem(part);
  }

  async function fetchUnknownMessageInfo(sessionID, messageID) {
    const path = `/session/${encodeURIComponent(sessionID)}/message/${encodeURIComponent(messageID)}`;
    try {
      return await request(path);
    } catch (error) {
      if (error.status !== 404) throw error;
      const session = await sessionFor(encodeThreadId(sessionID));
      if (!session.directory) throw error;
      return request(`${path}?directory=${encodeURIComponent(session.directory)}`);
    }
  }

  function queueUnknownPart(part) {
    if (!part?.sessionID || !part?.messageID || !part?.id) return;
    let pending = pendingUnknownParts.get(part.messageID);
    if (!pending) {
      pending = { sessionID: part.sessionID, parts: new Map() };
      pendingUnknownParts.set(part.messageID, pending);
    }
    pending.parts.set(part.id, part);
    if (resolvingUnknownMessages.has(part.messageID)) return;
    const task = fetchUnknownMessageInfo(part.sessionID, part.messageID)
      .then((message) => {
        rememberMessageInfo(part.sessionID, message?.info, {
          allowStart: sessionStatuses.get(part.sessionID) !== "idle",
        });
        flushUnknownParts(part.messageID);
        pendingUnknownParts.delete(part.messageID);
      })
      .catch(() => { pendingUnknownParts.delete(part.messageID); })
      .finally(() => { resolvingUnknownMessages.delete(part.messageID); });
    resolvingUnknownMessages.set(part.messageID, task);
  }

  function emitPartDelta(properties) {
    const { sessionID, messageID, partID, field, delta } = properties;
    if (!sessionID || !messageID || !partID || field !== "text" || typeof delta !== "string" || !delta) return;
    const state = streamedParts.get(partID);
    const part = state?.part || pendingUnknownParts.get(messageID)?.parts.get(partID);
    if (part) {
      if (part.sessionID !== sessionID || part.messageID !== messageID
        || (part.type !== "text" && part.type !== "reasoning")) return;
      const updated = { ...part, text: (state?.text ?? part.text ?? "") + delta };
      if (!emitItem(updated)) queueUnknownPart(updated);
      return;
    }
    // After a disconnect the initial part may be missing. Wait for its full
    // snapshot: a delta alone does not identify the role, type or prior text.
  }

  function applySessionStatus(sessionID, status) {
    const active = status === "busy" || status === "retry";
    sessionStatuses.set(sessionID, active ? "busy" : "idle");
    if (active && !running.has(sessionID)) running.set(sessionID, { turnId: null });
    else if (!active && running.has(sessionID) && !polledTurns.has(sessionID)) finishTurn(sessionID, "completed");
  }

  async function refreshSessionStatuses(sessionIDs, connectionRevision = eventConnectionRevision) {
    const groups = new Map();
    await Promise.all(sessionIDs.map(async (sessionID) => {
      try {
        const session = sessionCache.get(sessionID) || await sessionFor(encodeThreadId(sessionID));
        if (!session.directory) return;
        const group = groups.get(session.directory) || [];
        group.push(sessionID);
        groups.set(session.directory, group);
      } catch { /* Unknown directories cannot safely use another project's status. */ }
    }));
    await Promise.all([...groups].map(async ([directory, ids]) => {
      // A newer read also invalidates an older in-flight snapshot, even if no
      // live event arrived between the two requests.
      const revisions = new Map(ids.map((id) => {
        const revision = (sessionEventRevisions.get(id) || 0) + 1;
        sessionEventRevisions.set(id, revision);
        return [id, revision];
      }));
      const isCurrent = (id) => !stopped && connectionRevision === eventConnectionRevision
        && revisions.get(id) === sessionEventRevisions.get(id);
      try {
        const statuses = await request(`/session/status?directory=${encodeURIComponent(directory)}`, {
          signal: AbortSignal.timeout(2_000),
        });
        if (!statuses || typeof statuses !== "object" || Array.isArray(statuses)) return;
        await Promise.all(ids.map(async (id) => {
          if (!isCurrent(id)) return;
          const status = statuses[id]?.type || "idle";
          if (status === "busy" || status === "retry") {
            applySessionStatus(id, status);
            const messages = await request(messagePath(sessionCache.get(id), { limit: 1 }), {
              signal: AbortSignal.timeout(2_000),
            });
            if (!isCurrent(id)) return;
            const latest = messages?.[messages.length - 1];
            if (latest?.info) {
              const parentID = latest.info.role === "user" ? latest.info.id : latest.info.parentID;
              const activeTurnID = running.get(id)?.turnId;
              if (parentID && activeTurnID && activeTurnID !== `opencode-turn:${parentID}`) {
                finishTurn(id, "completed");
                applySessionStatus(id, status);
              }
              rememberMessageInfo(id, latest.info);
            }
          } else {
            applySessionStatus(id, status);
          }
        }));
      } catch { /* A failed status read is not evidence that an active turn ended. */ }
    }));
  }

  function requestClient(method, properties) {
    const existing = [...pendingRequests].find(([, pending]) =>
      pending.method === method && pending.properties.id === properties.id);
    const id = existing?.[0] || `${REQUEST_PREFIX}${++requestSequence}-${properties.id}`;
    pendingRequests.set(id, { method, properties });
    if (method === "permission") {
      emit("item/commandExecution/requestApproval", {
        threadId: encodeThreadId(properties.sessionID),
        turnId: running.get(properties.sessionID)?.turnId,
        itemId: properties.tool?.callID || properties.id,
        reason: properties.permission,
        command: properties.patterns?.join(" ") || properties.permission,
      }, id);
    } else {
      const questions = (properties.questions || []).map((question, index) => ({
        ...question,
        id: question.id || `opencode-question-${index}`,
      }));
      pendingRequests.get(id).questions = questions;
      emit("item/tool/requestUserInput", {
        threadId: encodeThreadId(properties.sessionID),
        turnId: running.get(properties.sessionID)?.turnId,
        itemId: properties.tool?.callID || properties.id,
        questions,
      }, id);
    }
  }

  function resolveRemoteRequest(method, properties) {
    for (const [id, pending] of pendingRequests) {
      if (pending.method !== method || pending.properties.id !== properties.id) continue;
      pendingRequests.delete(id);
      emit("serverRequest/resolved", { requestId: id, threadId: encodeThreadId(pending.properties.sessionID) });
    }
  }

  function processEvent(envelope) {
    const event = envelope?.payload || envelope;
    const properties = event?.properties || {};
    const sessionID = properties.sessionID || properties.info?.sessionID || properties.part?.sessionID;
    if (sessionID) sessionEventRevisions.set(sessionID, (sessionEventRevisions.get(sessionID) || 0) + 1);
    switch (event?.type) {
      case "session.created":
        if (properties.info) {
          const session = cacheSession(properties.info);
          emit("thread/started", { thread: normalizeThread(session), remodexDesktopMirror: true });
        }
        break;
      case "session.updated":
        if (properties.info) {
          const previous = sessionCache.get(properties.info.id);
          cacheSession(properties.info);
          emit("thread/name/updated", { threadId: encodeThreadId(properties.info.id), name: properties.info.title });
          if (Boolean(previous?.time?.archived) !== Boolean(properties.info.time?.archived)) {
            emit(properties.info.time?.archived ? "thread/archived" : "thread/unarchived", {
              threadId: encodeThreadId(properties.info.id),
            });
          }
        }
        break;
      case "session.status": {
        if (!sessionID) break;
        const status = properties.status?.type || properties.status;
        applySessionStatus(sessionID, status);
        break;
      }
      case "session.error": {
        const message = properties.error?.data?.message || properties.error?.message || "OpenCode turn failed";
        if (running.get(sessionID)?.turnId) finishTurn(sessionID, "failed", message);
        else if (sessionID) emit("error", { threadId: encodeThreadId(sessionID), message });
        break;
      }
      case "message.updated": {
        const info = properties.info;
        rememberMessageInfo(sessionID, info);
        if (info?.id) flushUnknownParts(info.id);
        break;
      }
      case "message.part.updated":
        if (!emitItem(properties.part)) queueUnknownPart(properties.part);
        break;
      case "message.part.delta":
        emitPartDelta(properties);
        break;
      case "permission.asked": case "permission.updated": requestClient("permission", properties); break;
      case "question.asked": case "question.updated": requestClient("question", properties); break;
      case "permission.replied": resolveRemoteRequest("permission", properties); break;
      case "question.replied": case "question.rejected": resolveRemoteRequest("question", properties); break;
      default: break;
    }
  }

  async function consumeEvents(signal) {
    const response = await fetchImpl(`${baseUrl}/global/event`, { headers: headers({ Accept: "text/event-stream" }), signal });
    if (!response.ok) throw new Error(`OpenCode event stream failed (${response.status})`);
    const connectionRevision = ++eventConnectionRevision;
    // Read after subscribing, while consuming events concurrently. Revision
    // checks keep a slow snapshot from overwriting a newer live status.
    void refreshSessionStatuses([...running.keys()], connectionRevision).catch(() => {});
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true });
      buffer = buffer.replace(/\r\n/g, "\n");
      let boundary;
      while ((boundary = buffer.indexOf("\n\n")) >= 0) {
        const frame = buffer.slice(0, boundary).replace(/\r/g, "");
        buffer = buffer.slice(boundary + 2);
        const data = frame.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
        if (data) { try { processEvent(JSON.parse(data)); } catch {} }
      }
    }
  }

  function startEvents() {
    if (stopped) return;
    if (eventTask) {
      restartEventsAfterCurrentTask = true;
      return;
    }
    const abort = new AbortController();
    eventAbort = abort;
    const task = (async () => {
      while (!stopped && !abort.signal.aborted) {
        try { await consumeEvents(abort.signal); } catch (error) {
          if (abort.signal.aborted || stopped) break;
        }
        if (!stopped) await new Promise((resolve) => {
          const finish = () => { clearTimeout(timer); resolve(); };
          const timer = setTimeout(finish, reconnectDelayMs);
          timer.unref?.();
          abort.signal.addEventListener("abort", finish, { once: true });
        });
      }
    })();
    eventTask = task;
    void task.finally(() => {
      if (eventTask === task) eventTask = null;
      if (eventAbort === abort) eventAbort = null;
      if (restartEventsAfterCurrentTask && !stopped && baseUrl) {
        restartEventsAfterCurrentTask = false;
        startEvents();
      }
    });
  }

  async function listModels() {
    await ensureStarted();
    return { items: normalizeModels(await request("/provider")) };
  }

  async function validatedVariant(model, value) {
    if (value == null) return null;
    const variant = nonEmptyString(value);
    if (!variant) throw new Error("OpenCode variant must be a nonempty string");
    const { items } = await listModels();
    const selected = items.find((item) => item.id === model);
    if (!selected?.variants.some((item) => item.id === variant)) {
      throw new Error(`OpenCode variant ${variant} is unavailable for ${model}`);
    }
    return variant;
  }

  async function listAllSessions() {
    await ensureStarted();
    const projects = await request("/project");
    const roots = new Set();
    for (const project of projects || []) {
      if (project?.worktree) roots.add(project.worktree);
      for (const root of project?.roots || []) roots.add(root);
      for (const root of project?.directories || []) roots.add(root);
    }
    const batches = await Promise.all([...roots].map((root) => request(
      `/session?scope=project&directory=${encodeURIComponent(root)}&limit=${COMPLETE_SESSION_LIST_LIMIT}`
    )));
    const unique = new Map();
    for (const batch of batches) {
      if (!Array.isArray(batch) || batch.length >= COMPLETE_SESSION_LIST_LIMIT) {
        throw new Error("OpenCode session catalog is incomplete; worktree bindings cannot be verified");
      }
      for (const session of batch) {
        if (!session?.id) continue;
        unique.set(session.id, cacheSession(session));
      }
    }
    return [...unique.values()].sort((a, b) => asMillis(b.time?.updated) - asMillis(a.time?.updated));
  }

  async function listSessions({ archived = false } = {}) {
    return (await listAllSessions()).filter((session) =>
      !session.parentID && Boolean(session.time?.archived) === archived
    );
  }

  async function listThreads({ archived = false } = {}) {
    return (await listSessions({ archived })).map((session) => normalizeThread(session));
  }

  async function listThreadCatalog() {
    const active = [];
    const archived = [];
    for (const session of await listAllSessions()) {
      if (session.parentID) continue;
      (session.time?.archived ? archived : active).push(normalizeThread(session));
    }
    return { active, archived };
  }

  async function sessionFor(threadId) {
    const sessionID = decodeThreadId(threadId);
    if (!sessionID) throw new Error(`Not an OpenCode thread: ${threadId}`);
    await ensureStarted();
    let cached = sessionCache.get(sessionID);
    let fresh;
    try {
      // Session IDs are globally addressable in the released server. A cache miss
      // must not scan every project before opening one chat.
      fresh = await request(`/session/${encodeURIComponent(sessionID)}`);
    } catch (error) {
      if (error.status !== 404) throw error;
      if (!cached) {
        await listAllSessions();
        cached = sessionCache.get(sessionID);
      }
      if (!cached?.directory) throw error;
      fresh = await request(`/session/${encodeURIComponent(sessionID)}?directory=${encodeURIComponent(cached.directory)}`);
    }
    const session = cached?.metadata?.remodexModelID
      ? { ...fresh, metadata: { ...fresh.metadata, ...cached.metadata } }
      : fresh;
    return cacheSession(session);
  }

  function messagePath(session, { limit, before } = {}) {
    const query = [];
    if (session.directory) query.push(`directory=${encodeURIComponent(session.directory)}`);
    if (limit) query.push(`limit=${encodeURIComponent(limit)}`);
    if (before) query.push(`before=${encodeURIComponent(before)}`);
    return `/session/${encodeURIComponent(session.id)}/message${query.length ? `?${query.join("&")}` : ""}`;
  }

  async function readThread(threadId, includeTurns = true) {
    let session = await sessionFor(threadId);
    if (includeTurns) await refreshSessionStatuses([session.id]);
    // Resume usually asks for metadata; fetch at most one message only when a
    // Mac-created session has no model in its session record.
    const messages = includeTurns
      ? await request(messagePath(session))
      : modelIdentity(session).full ? null : await request(messagePath(session, { limit: 1 }));
    const observed = latestMessageModel(messages);
    if (!modelIdentity(session).full && observed) {
      session = {
        ...session,
        metadata: {
          ...session.metadata,
          remodexModelProvider: observed.providerID,
          remodexModelID: observed.modelID,
        },
      };
      cacheSession(session);
    }
    const observedVariant = latestMessageVariant(messages);
    if (observedVariant) {
      session = {
        ...session,
        metadata: { ...session.metadata, remodexObservedVariant: observedVariant },
      };
    }
    return normalizeThread(session, includeTurns ? normalizeTurns(messages, running.has(session.id)) : undefined);
  }

  function parseTurnCursor(cursor, direction) {
    if (!cursor) return null;
    const prefix = `${TURN_CURSOR_PREFIX}${direction}:`;
    if (typeof cursor === "string" && cursor.startsWith(prefix)) {
      const payload = cursor.slice(prefix.length);
      const separator = payload.indexOf(":");
      let anchor;
      let nativeBefore;
      try {
        anchor = decodeURIComponent(separator < 0 ? payload : payload.slice(0, separator));
        nativeBefore = separator < 0 ? null : decodeURIComponent(payload.slice(separator + 1));
      } catch {
        throw new Error("Invalid OpenCode history cursor");
      }
      if (!anchor) throw new Error("Invalid OpenCode history cursor");
      return { anchor, nativeBefore: nativeBefore || null };
    }
    return null;
  }

  function turnPageStart(cursor, direction, turns) {
    if (!cursor) return 0;
    const parsed = parseTurnCursor(cursor, direction);
    if (parsed) {
      const anchor = parsed.anchor;
      const index = turns.findIndex((turn) => turn.id === anchor);
      return index < 0 ? null : index + 1;
    }
    // Accept cursors issued by earlier bridge versions while the phone cache
    // still has them. New cursors use durable turn IDs so Mac additions do not
    // shift the older-page boundary.
    if (typeof cursor === "string" && cursor.startsWith("opencode-offset:")) {
      const raw = cursor.slice("opencode-offset:".length);
      if (/^\d+$/.test(raw)) return Number(raw);
    }
    throw new Error("Invalid OpenCode history cursor");
  }

  function turnPage(turns, params, hasOlder = false) {
    const direction = params.sortDirection === "asc" ? "asc" : "desc";
    const ordered = direction === "asc" ? turns : turns.slice().reverse();
    const requestedLimit = Number(params.limit);
    const limit = Number.isSafeInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : ordered.length || 1;
    const start = turnPageStart(params.cursor, direction, ordered);
    if (start == null) return null;
    const data = ordered.slice(start, start + limit);
    const more = start + data.length < ordered.length || hasOlder;
    return {
      data,
      nextCursor: more && data.length > 0
        ? `${TURN_CURSOR_PREFIX}${direction}:${encodeURIComponent(data[data.length - 1].id)}`
        : null,
    };
  }

  async function nativeCursorAfterTurn(session, turn, batches) {
    const prefix = "opencode-turn:";
    if (typeof turn?.id !== "string" || !turn.id.startsWith(prefix)) return null;
    const messageID = turn.id.slice(prefix.length);
    const batch = batches.find((candidate) => candidate.data.some((message) => (
      message?.info?.id === messageID && message.info.role === "user"
    )));
    if (!batch) return null;
    const index = batch.data.findIndex((message) => message?.info?.id === messageID);
    // Ask OpenCode itself for a cursor whose tail is exactly the oldest turn
    // returned to the phone. Its cursor encoding stays opaque to this bridge.
    const limit = batch.data.length - index;
    try {
      const aligned = await request(messagePath(session, { limit, before: batch.before }), { includeHeaders: true });
      if (!Array.isArray(aligned.data) || aligned.data[0]?.info?.id !== messageID) return null;
      return aligned.headers?.get?.("x-next-cursor") || null;
    } catch {
      // The anchor is still sufficient for the slower, stable fallback path.
      return null;
    }
  }

  async function readDescendingTurnPage(threadId, params) {
    const session = await sessionFor(threadId);
    if (!params.cursor) await refreshSessionStatuses([session.id]);
    const cursor = parseTurnCursor(params.cursor, "desc");
    const nativeBefore = cursor?.nativeBefore;
    const messages = [];
    const batches = [];
    let before = nativeBefore || undefined;
    while (true) {
      let page;
      try {
        page = await request(messagePath(session, { limit: MESSAGE_PAGE_SIZE, before }), { includeHeaders: true });
      } catch (error) {
        if (nativeBefore && before === nativeBefore && error.status === 400) {
          return readDescendingTurnPage(threadId, {
            ...params, cursor: `${TURN_CURSOR_PREFIX}desc:${encodeURIComponent(cursor.anchor)}`,
          });
        }
        throw error;
      }
      if (!Array.isArray(page.data)) throw new Error("OpenCode returned invalid session messages");
      if (nativeBefore && batches.length === 0 && page.data.length === 0) {
        return readDescendingTurnPage(threadId, {
          ...params, cursor: `${TURN_CURSOR_PREFIX}desc:${encodeURIComponent(cursor.anchor)}`,
        });
      }
      batches.push({ before, data: page.data });
      messages.unshift(...page.data);
      const nextBefore = page.headers?.get?.("x-next-cursor") || null;
      const hasOlder = Boolean(nextBefore);
      if (!hasOlder || messages[0]?.info?.role === "user") {
        const turns = normalizeTurns(messages, running.has(session.id) && !nativeBefore);
        const result = turnPage(turns, nativeBefore ? { ...params, cursor: null } : params, hasOlder);
        const requestedLimit = Number(params.limit);
        const limit = Number.isSafeInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : turns.length || 1;
        if (result && (result.data.length >= limit || !hasOlder)) {
          if (result.nextCursor) {
            const nativeCursor = await nativeCursorAfterTurn(session, result.data[result.data.length - 1], batches);
            if (nativeCursor) result.nextCursor += `:${encodeURIComponent(nativeCursor)}`;
          }
          return result;
        }
        if (!result && !hasOlder) throw new Error("OpenCode history cursor no longer matches this chat");
      }
      if (!hasOlder || page.data.length === 0 || nextBefore === before) {
        throw new Error("OpenCode message pagination stopped before a complete turn");
      }
      before = nextBefore;
    }
  }

  async function handleRequest(parsed) {
    const method = parsed?.method;
    const params = parsed?.params || {};
    if (!shouldHandleRequest(parsed)) throw new Error(`Unsupported OpenCode request: ${method || "unknown"}`);
    if (method === "remodex/opencode/models") return listModels();
    if (method === "thread/start") {
      if (params.runtimeProvider !== "opencode") throw new Error("thread/start is not for OpenCode");
      await ensureStarted();
      const selected = splitModel(params.model);
      const variant = await validatedVariant(params.model, params.effort);
      const cwd = params.cwd || process.cwd();
      const session = await request(`/session?directory=${encodeURIComponent(cwd)}`, {
        method: "POST",
        body: {
          ...(params.title ? { title: params.title } : {}),
          model: { id: selected.modelID, providerID: selected.providerID, ...(variant ? { variant } : {}) },
          metadata: { remodexModelID: selected.modelID, remodexModelProvider: selected.providerID,
            ...(variant ? { remodexVariant: variant } : {}) },
        },
      });
      cacheSession(session);
      return { thread: normalizeThread({ ...session, model: session.model || { id: selected.modelID, providerID: selected.providerID } }) };
    }
    const threadId = params.threadId || params.id;
    if (method === "thread/read" || method === "thread/resume") {
      if (method === "thread/resume" && params.cwd) {
        const session = await sessionFor(threadId);
        if (path.resolve(params.cwd) !== path.resolve(session.directory || "")) {
          throw new Error("OpenCode cannot move an existing chat to another folder. Start a new chat in the target folder instead.");
        }
      }
      return { thread: await readThread(threadId, params.excludeTurns !== true && params.includeTurns !== false) };
    }
    if (method === "thread/turns/list") {
      if (params.sortDirection !== "asc" && Number.isSafeInteger(Number(params.limit)) && Number(params.limit) > 0) {
        return readDescendingTurnPage(threadId, params);
      }
      const thread = await readThread(threadId);
      const result = turnPage(thread.turns || [], params);
      if (!result) throw new Error("OpenCode history cursor no longer matches this chat");
      return result;
    }
    const session = await sessionFor(threadId);
    const directory = session.directory ? `?directory=${encodeURIComponent(session.directory)}` : "";
    if (method === "turn/start") {
      let identity = modelIdentity(session);
      if (!identity.providerID || !identity.modelID) {
        const messages = await request(messagePath(session, { limit: 1 }));
        const observed = latestMessageModel(messages);
        if (observed) {
          identity = { ...observed, full: `${observed.providerID}/${observed.modelID}` };
          session.metadata = {
            ...session.metadata,
            remodexModelProvider: observed.providerID,
            remodexModelID: observed.modelID,
          };
          cacheSession(session);
        }
      }
      if (!identity.providerID || !identity.modelID) throw new Error("OpenCode session has no pinned model");
      // A client that does not send effort inherits the session's pinned
      // variant. An explicit null clears it and lets OpenCode use its default.
      const hasEffort = Object.hasOwn(params, "effort");
      const inheritedVariant = hasEffort ? params.effort : modelVariant(session);
      const variant = !hasEffort && inheritedVariant && identity.providerID !== "opencode" && identity.providerID !== "opencode-go"
        ? nonEmptyString(inheritedVariant)
        : await validatedVariant(identity.full, inheritedVariant);
      const parts = partsFromInput(params.input);
      const messageID = `msg_${randomBytes(12).toString("hex")}`;
      const turnId = `opencode-turn:${messageID}`;
      phoneTurnIds.add(turnId);
      sessionEventRevisions.set(session.id, (sessionEventRevisions.get(session.id) || 0) + 1);
      try {
        await request(`/session/${encodeURIComponent(session.id)}/prompt_async${directory}`, {
          method: "POST",
          body: { messageID, model: { providerID: identity.providerID, modelID: identity.modelID },
            ...(variant ? { variant } : {}), parts },
        });
      } catch (error) {
        phoneTurnIds.delete(turnId);
        if (running.get(session.id)?.turnId === turnId) running.delete(session.id);
        throw error;
      }
      pendingAcceptedVariants.set(session.id, { variant, acceptedAt: Date.now() });
      sessionEventRevisions.set(session.id, (sessionEventRevisions.get(session.id) || 0) + 1);
      sessionCache.set(session.id, withVariant(session, variant));
      if (completedTurnIds.has(turnId)) {
        return { turn: { id: turnId, status: "completed" } };
      }
      if (running.get(session.id)?.turnId !== turnId) {
        running.set(session.id, { turnId });
        emit("turn/started", { threadId, turnId, turn: { id: turnId, status: "inProgress", items: [] } });
      }
      watchTurn(session, turnId);
      return { turn: { id: turnId, status: "inProgress" } };
    }
    if (method === "turn/interrupt") {
      await request(`/session/${encodeURIComponent(session.id)}/abort${directory}`, { method: "POST" });
      finishTurn(session.id, "interrupted");
      return {};
    }
    if (method === "thread/archive" || method === "thread/unarchive") {
      const archived = method === "thread/archive" ? Date.now() : 0;
      const updated = await request(`/session/${encodeURIComponent(session.id)}${directory}`, {
        method: "PATCH", body: { time: { archived } },
      });
      cacheSession(updated);
      return {};
    }
    if (method === "thread/name/set") {
      const title = params.name || params.title;
      if (!title) throw new Error("OpenCode thread title is empty");
      const updated = await request(`/session/${encodeURIComponent(session.id)}${directory}`, { method: "PATCH", body: { title } });
      return { thread: normalizeThread(cacheSession(updated)) };
    }
    if (method === "thread/generateTitle") return { title: session.title || "" };
    throw new Error(`Unsupported OpenCode request: ${method}`);
  }

  function shouldHandleRequest(parsed) {
    if (parsed.method === "remodex/opencode/models") return true;
    if (parsed.method === "thread/start") return parsed.params?.runtimeProvider === "opencode";
    return Boolean(decodeThreadId(parsed.params?.threadId || parsed.params?.id));
  }

  function ownsClientResponse(parsed) {
    return typeof parsed?.id === "string" && parsed.id.startsWith(REQUEST_PREFIX) && pendingRequests.has(parsed.id);
  }

  async function handleClientResponse(parsed) {
    if (!ownsClientResponse(parsed)) return false;
    const pending = pendingRequests.get(parsed.id);
    const properties = pending.properties;
    const directory = sessionCache.get(properties.sessionID)?.directory;
    const suffix = directory ? `?directory=${encodeURIComponent(directory)}` : "";
    if (pending.method === "permission") {
      const raw = parsed.result?.decision ?? parsed.result?.response?.decision ?? parsed.result;
      const token = String(raw || "").toLowerCase();
      const reply = token === "acceptforsession" || token === "always" ? "always"
        : token.includes("accept") || token.includes("approve") || token === "once" ? "once" : "reject";
      await request(`/permission/${encodeURIComponent(properties.id)}/reply${suffix}`, { method: "POST", body: { reply } });
    } else {
      if (parsed.error) {
        await request(`/question/${encodeURIComponent(properties.id)}/reject${suffix}`, { method: "POST" });
      } else {
        const answerSource = parsed.result?.answers ?? parsed.result?.response?.answers ?? parsed.result;
        const questions = pending.questions || properties.questions || [];
        const answers = Array.isArray(answerSource)
          ? answerSource.map((answer) => Array.isArray(answer) ? answer.map(String) : [String(answer)])
          : questions.map((question) => {
            const value = answerSource?.[question.id]?.answers ?? answerSource?.[question.id] ?? [];
            return (Array.isArray(value) ? value : [value]).map(String);
          });
        await request(`/question/${encodeURIComponent(properties.id)}/reply${suffix}`, { method: "POST", body: { answers } });
      }
    }
    pendingRequests.delete(parsed.id);
    emit("serverRequest/resolved", { requestId: parsed.id, threadId: encodeThreadId(properties.sessionID) });
    return true;
  }

  async function shutdown() {
    stopped = true;
    eventAbort?.abort();
    if (child && child.exitCode == null) child.kill("SIGTERM");
    child = null;
    startPromise = null;
    pendingRequests.clear();
    running.clear();
    for (const sessionID of polledTurns.keys()) stopTurnPoll(sessionID);
    for (const timer of completedTurnCleanupTimers.values()) clearTimeout(timer);
    completedTurnCleanupTimers.clear();
    phoneTurnIds.clear();
    streamedParts.clear();
    messageRoles.clear();
    messageTurnIds.clear();
    messageIDsByTurn.clear();
    partIDsByTurn.clear();
    pendingUnknownParts.clear();
    resolvingUnknownMessages.clear();
    sessionStatuses.clear();
    sessionEventRevisions.clear();
    if (!configuredBaseUrl) baseUrl = "";
    if (eventTask) await Promise.race([eventTask, new Promise((resolve) => setTimeout(resolve, 250))]);
  }

  return {
    ensureStarted,
    shutdown,
    listModels,
    listThreads,
    listThreadCatalog,
    listAllSessions,
    handlesThreadId: (threadId) => Boolean(decodeThreadId(threadId)),
    shouldHandleRequest,
    ownsClientResponse,
    handleClientResponse,
    handleRequest,
    processEvent,
  };
}

module.exports = {
  createOpenCodeRuntime,
  decodeThreadId,
  encodeThreadId,
  normalizeModels,
  normalizeTurns,
};
