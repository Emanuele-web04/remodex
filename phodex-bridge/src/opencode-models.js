// FILE: opencode-models.js
// Purpose: Normalizes OpenCode CLI model metadata into Remodex provider-aware model entries.
//          Also provides shared serialization, turn parsing, and comparator helpers
//          used by the bridge and provider harness.
// Layer: Bridge runtime provider helper
// Exports: OpenCode provider constants plus model/provider parsing, serialization, and sort helpers.
// Depends on: ./normalize

const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");
const { readString, resolvedParam } = require("./normalize");
const { MAX_IMAGES_PER_TURN } = require("./attachment-store");
const { resolveDefaultOpenCodeAgent } = require("./opencode-runtime-policy");

const CODEX_PROVIDER_ID = "codex";
const OPENCODE_PROVIDER_ID = "opencode";
const DEFAULT_OPENCODE_MODEL = "opencode/gpt-5.5";

function normalizeRuntimeProvider(value) {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  switch (normalized) {
    case "":
      return CODEX_PROVIDER_ID;
    case "open-code":
    case "open_code":
      return OPENCODE_PROVIDER_ID;
    default:
      return normalized;
  }
}

function readModelProvider(value = {}) {
  if (!value || typeof value !== "object") {
    return CODEX_PROVIDER_ID;
  }

  return normalizeRuntimeProvider(
    value.modelProvider ||
      value.model_provider ||
      value.provider ||
      value.runtimeProvider ||
      value.runtime_provider ||
      value.harness ||
      value.collaborationMode?.settings?.modelProvider ||
      value.collaborationMode?.settings?.model_provider ||
      value.collaborationMode?.settings?.provider ||
      value.collaboration_mode?.settings?.modelProvider ||
      value.collaboration_mode?.settings?.model_provider ||
      value.collaboration_mode?.settings?.provider,
  );
}

function isOpenCodeProvider(value) {
  return normalizeRuntimeProvider(value) === OPENCODE_PROVIDER_ID;
}

function isCodexProvider(value) {
  return normalizeRuntimeProvider(value) === CODEX_PROVIDER_ID;
}

function buildOpenCodeModelOption(modelReference, { isDefault = false } = {}) {
  const normalizedReference = normalizeOpenCodeModelReference(modelReference);
  if (!normalizedReference) {
    return null;
  }

  return {
    id: normalizedReference,
    model: normalizedReference,
    modelProvider: OPENCODE_PROVIDER_ID,
    provider: OPENCODE_PROVIDER_ID,
    displayName: displayNameForOpenCodeModel(normalizedReference),
    description: `OpenCode local provider model (${normalizedReference})`,
    isDefault,
    supportsFastMode: false,
    supportedReasoningEfforts: [],
    defaultReasoningEffort: null,
  };
}

function parseOpenCodeModelsOutput(output) {
  const seen = new Set();
  const models = [];
  const lines = String(output || "").split(/\r?\n/);

  for (const line of lines) {
    const modelReference = normalizeOpenCodeModelReference(line);
    if (!modelReference || seen.has(modelReference)) {
      continue;
    }

    seen.add(modelReference);
    models.push(
      buildOpenCodeModelOption(modelReference, {
        isDefault: modelReference === DEFAULT_OPENCODE_MODEL,
      }),
    );
  }

  return models.filter(Boolean);
}

function normalizeOpenCodeModelReference(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const providerId = readString(value.providerID || value.providerId || value.provider);
    const modelId = readString(value.id || value.modelID || value.modelId);
    if (providerId && modelId) {
      value = `${providerId}/${modelId}`;
    } else {
      return "";
    }
  }
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized || normalized.startsWith("{") || normalized.startsWith("[")) {
    return "";
  }
  if (!/^[A-Za-z0-9._:-]+\/[A-Za-z0-9._:-]+$/.test(normalized)) {
    return "";
  }
  return normalized;
}

function displayNameForOpenCodeModel(modelReference) {
  const normalized = normalizeOpenCodeModelReference(modelReference);
  const modelId = normalized.split("/").pop() || normalized;
  const lowered = modelId.toLowerCase();

  if (lowered.startsWith("gpt-")) {
    return `GPT-${modelId.slice(4)}`;
  }
  if (lowered.startsWith("claude-")) {
    return modelId
      .split("-")
      .map((part) => (part.length <= 2 ? part.toUpperCase() : titleCase(part)))
      .join(" ");
  }

  return modelId.split(/[-_]/).map(titleCase).join(" ");
}

function titleCase(value) {
  if (!value) {
    return "";
  }
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function normalizeOpenCodeModel(value) {
  return normalizeOpenCodeModelReference(value) || DEFAULT_OPENCODE_MODEL;
}

function publicThread(thread) {
  const metadata = {
    provider: OPENCODE_PROVIDER_ID,
    ...(thread.metadata && typeof thread.metadata === "object" ? thread.metadata : {}),
  };
  if (thread.discoveredExternally === true) {
    metadata.discoveredExternally = true;
  }
  if (readString(thread.sessionId)) {
    metadata.sessionId = readString(thread.sessionId);
  }

  return {
    id: thread.id,
    title: thread.title,
    name: thread.title,
    cwd: thread.hasProjectCwd !== false ? thread.cwd : null,
    model: thread.model || DEFAULT_OPENCODE_MODEL,
    modelProvider: OPENCODE_PROVIDER_ID,
    provider: OPENCODE_PROVIDER_ID,
    agent: thread.agent || "",
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    metadata,
  };
}

function readSessionTimestamp(session, field) {
  const time = session?.time;
  if (!time || typeof time !== "object") {
    return "";
  }
  const value = time[field];
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(value).toISOString();
  }
  return readString(value);
}

function sessionHasDiscoverySignal(session) {
  return Boolean(
    readString(session?.title) ||
      readSessionTimestamp(session, "updated") ||
      readSessionTimestamp(session, "created"),
  );
}

function sessionV2InfoToDiscoveredThread(session) {
  if (!session || typeof session !== "object") {
    return null;
  }

  const sessionId = readString(session.id || session.sessionID || session.sessionId);
  if (!sessionId) {
    return null;
  }
  if (readString(session.parentID)) {
    return null;
  }
  if (session.time?.archived) {
    return null;
  }
  if (!sessionHasDiscoverySignal(session)) {
    return null;
  }

  const cwd = readString(
    session.location?.directory || session.directory || session.path || session.cwd || session.project?.worktree,
  );
  const projectName = readString(session.project?.name);
  const title = readString(session.title);
  const displayTitle = title || (projectName ? `${projectName} · OpenCode chat` : "OpenCode chat");
  const createdAt =
    readSessionTimestamp(session, "created") || new Date().toISOString();
  const updatedAt = readSessionTimestamp(session, "updated") || createdAt;
  const threadId = `opencode-session-${sessionId}`;

  return {
    id: threadId,
    title: displayTitle,
    name: title || "",
    cwd: cwd || "",
    hasProjectCwd: Boolean(cwd),
    model: normalizeOpenCodeModel(session.model),
    agent: readString(session.agent) || resolveDefaultOpenCodeAgent(),
    createdAt,
    updatedAt,
    sessionId,
    discoveredExternally: true,
    metadata: {
      provider: OPENCODE_PROVIDER_ID,
      discoveredExternally: true,
      sessionId,
      projectName: projectName || undefined,
    },
  };
}

function readSkillName(item) {
  return readString(item?.name || item?.id);
}

function fileUrlForPath(filePath) {
  const resolved = path.isAbsolute(filePath) ? filePath : path.resolve(filePath);
  return pathToFileURL(resolved).href;
}

function skillItemToPromptPart(item) {
  const name = readSkillName(item);
  const skillPath = resolvedParam(item, "path");
  if (skillPath) {
    return {
      type: "file",
      mime: "text/markdown",
      url: fileUrlForPath(skillPath),
      filename: name || path.basename(skillPath),
    };
  }
  if (name) {
    return { type: "text", text: `$${name}` };
  }
  return null;
}

function mentionItemToPromptPart(item) {
  const name = readString(item?.name);
  const mentionPath = resolvedParam(item, "path");
  if (mentionPath && name) {
    return {
      type: "file",
      mime: "text/plain",
      url: fileUrlForPath(mentionPath),
      filename: name,
    };
  }
  if (name) {
    return { type: "text", text: `@${name}` };
  }
  return null;
}

function imageItemToPromptPart(item, { attachmentStore = null, attachmentsEnabled = true } = {}) {
  if (!attachmentsEnabled) {
    return null;
  }

  const imagePath = resolvedParam(item, "path", "url", "image_url", "dataURL");
  if (!imagePath) {
    return null;
  }

  if (imagePath.startsWith("data:") && attachmentStore?.storeFromDataUrl) {
    try {
      const stored = attachmentStore.storeFromDataUrl(imagePath, {
        filename: readString(item.filename || item.name) || "attachment",
      });
      return {
        type: "file",
        mime: stored.mime,
        url: fileUrlForPath(stored.path),
        filename: stored.filename,
      };
    } catch {
      return null;
    }
  }

  if (!attachmentStore?.resolveExistingPath) {
    return null;
  }

  try {
    const storedPath = attachmentStore.resolveExistingPath(imagePath);
    if (!storedPath || !fs.existsSync(storedPath)) {
      return null;
    }
    return {
      type: "file",
      mime: readString(item.mime || item.contentType) || "application/octet-stream",
      url: fileUrlForPath(storedPath),
      filename: readString(item.filename || item.name) || "attachment",
    };
  } catch {
    return null;
  }
}

function buildPromptFromTurnInput(input, options = {}) {
  if (typeof input === "string") {
    const text = input.trim();
    return {
      inputText: text,
      prompt: text,
      parts: text ? [{ type: "text", text }] : [],
      skills: [],
    };
  }
  if (!Array.isArray(input)) {
    return { inputText: "", prompt: "", parts: [], skills: [] };
  }

  const textParts = [];
  const parts = [];
  const skills = [];
  let imageCount = 0;

  for (const item of input) {
    if (typeof item === "string") {
      appendNonEmpty(textParts, item);
      continue;
    }
    if (!item || typeof item !== "object") continue;

    const type = readString(item.type).toLowerCase();
    if (type === "skill") {
      const part = skillItemToPromptPart(item);
      if (part) {
        parts.push(part);
        if (part.type === "text") {
          appendNonEmpty(textParts, part.text);
        }
      }
      const skillId = readSkillName(item);
      if (skillId) {
        const skillEntry = { id: skillId, name: readString(item.name || item.id) || skillId };
        const p = resolvedParam(item, "path");
        if (p) skillEntry.path = p;
        skills.push(skillEntry);
      }
      continue;
    }
    if (type === "mention") {
      const part = mentionItemToPromptPart(item);
      if (part) {
        parts.push(part);
        if (part.type === "text") {
          appendNonEmpty(textParts, part.text);
        }
      }
      continue;
    }
    if (type.includes("image")) {
      if (imageCount >= MAX_IMAGES_PER_TURN) {
        continue;
      }
      const part = imageItemToPromptPart(item, options);
      if (part) {
        parts.push(part);
        imageCount += 1;
      }
      const imagePath = resolvedParam(item, "path", "url", "image_url", "dataURL");
      appendNonEmpty(textParts, imagePath ? `[image attached: ${imagePath}]` : "[image attached]");
      continue;
    }

    const text = readString(item.text || item.content || item.message);
    if (text) {
      appendNonEmpty(textParts, text);
      parts.push({ type: "text", text });
    }
  }

  const userText = textParts.join("\n\n").trim();
  const hasTextPart = parts.some((part) => part.type === "text");
  if (userText && !hasTextPart) {
    parts.push({ type: "text", text: userText });
  } else if (!hasTextPart && parts.length > 0) {
    parts.unshift({ type: "text", text: userText || " " });
  }

  const prompt = userText || parts.filter((part) => part.type === "text").map((part) => part.text).join("\n\n").trim();
  return { inputText: prompt, prompt, parts, skills };
}

function readOpenCodeMessageRole(message) {
  if (!message || typeof message !== "object") {
    return "";
  }
  const type = readString(message.type).toLowerCase();
  if (type === "user" || type === "assistant") {
    return type;
  }
  if (message.info && typeof message.info === "object") {
    return readString(message.info.role).toLowerCase();
  }
  return readString(message.role).toLowerCase();
}

function extractOpenCodeMessageText(message) {
  if (!message || typeof message !== "object") {
    return "";
  }

  if (message.info && Array.isArray(message.parts)) {
    return message.parts
      .map((part) => {
        if (!part || typeof part !== "object") {
          return "";
        }
        const partType = readString(part.type);
        if (partType !== "text") {
          return "";
        }
        if (part.synthetic === true || part.ignored === true) {
          return "";
        }
        return readString(part.text);
      })
      .filter(Boolean)
      .join("\n");
  }

  const directText = readString(message.text);
  if (directText) {
    return directText;
  }

  const content = message.content;
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (!part || typeof part !== "object") {
          return "";
        }
        if (readString(part.type) && readString(part.type) !== "text") {
          return "";
        }
        return readString(part.text);
      })
      .filter(Boolean)
      .join("\n");
  }

  return readString(message.content);
}

function isOpenCodeAssistantMessage(message) {
  const role = readOpenCodeMessageRole(message);
  return role === "assistant";
}

function messagesToTurns(messages, threadId) {
  const turns = [];
  let currentTurn = null;
  for (const msg of messages) {
    if (!msg) continue;
    const role = readOpenCodeMessageRole(msg);
    const text = extractOpenCodeMessageText(msg);
    const createdAt =
      msg.createdAt ||
      (msg.info?.time?.created ? new Date(msg.info.time.created).toISOString() : null) ||
      new Date().toISOString();
    if (role === "user") {
      currentTurn = {
        id: `turn-${turns.length}`,
        model: "",
        status: "completed",
        createdAt,
        items: [
          {
            id: `user-${turns.length}`,
            type: "userMessage",
            role: "user",
            text,
            content: textContent(text),
            createdAt,
          },
        ],
        metadata: { threadId, provider: OPENCODE_PROVIDER_ID },
      };
      turns.push(currentTurn);
    } else if (role === "assistant" && currentTurn) {
      currentTurn.items.push({
        id: `assistant-${turns.length}`,
        type: "agentMessage",
        role: "assistant",
        phase: "final",
        text,
        content: textContent(text),
        createdAt,
      });
    }
  }
  return turns;
}

function textContent(text) {
  return [{ type: "text", text: text || "" }];
}

function compareThreadsByUpdatedAt(lhs, rhs) {
  const lhsTime =
    Date.parse(lhs?.updatedAt || lhs?.updated_at || lhs?.createdAt || lhs?.created_at || 0) || 0;
  const rhsTime =
    Date.parse(rhs?.updatedAt || rhs?.updated_at || rhs?.createdAt || rhs?.created_at || 0) || 0;
  return rhsTime - lhsTime;
}

function boundedPositiveInteger(value, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) return fallback;
  return Math.min(Math.floor(numeric), 200);
}

const DEFAULT_OPENCODE_MODEL_LIST_TOTAL = 120;
const DEFAULT_OPENCODE_MODEL_LIST_PER_UPSTREAM = 24;

function slimModelForMobileList(model) {
  if (!model || typeof model !== "object" || Array.isArray(model)) {
    return model;
  }
  const { contextWindow, context_window, ...rest } = model;
  const logoProviderId = readString(model.logoProviderId);
  if (logoProviderId) {
    rest.logoProviderId = logoProviderId;
  }
  return rest;
}

// Keeps model/list payloads small enough for relay + iOS decode on device.
function capOpenCodeModelsForMobileList(models, env = process.env, connectedProviderIds = null) {
  if (!Array.isArray(models) || models.length === 0) {
    return [];
  }

  const maxTotal = boundedPositiveInteger(
    env.REMODEX_MODEL_LIST_OPENCODE_MAX,
    DEFAULT_OPENCODE_MODEL_LIST_TOTAL,
  );
  const perUpstream = boundedPositiveInteger(
    env.REMODEX_MODEL_LIST_OPENCODE_PER_UPSTREAM,
    DEFAULT_OPENCODE_MODEL_LIST_PER_UPSTREAM,
  );
  const effectivePerUpstream =
    Array.isArray(connectedProviderIds) && connectedProviderIds.length <= 2
      ? Math.max(perUpstream, 48)
      : perUpstream;

  const defaults = [];
  const byUpstream = new Map();

  for (const model of models) {
    const slim = slimModelForMobileList(model);
    if (model?.isDefault === true) {
      defaults.push(slim);
      continue;
    }

    const upstream =
      readString(model.upstreamProviderId || model.upstream_provider_id).toLowerCase() || "other";
    if (!byUpstream.has(upstream)) {
      byUpstream.set(upstream, []);
    }
    byUpstream.get(upstream).push(slim);
  }

  const capped = [...defaults];
  for (const upstream of [...byUpstream.keys()].sort()) {
    capped.push(...(byUpstream.get(upstream) || []).slice(0, effectivePerUpstream));
    if (capped.length >= maxTotal) {
      break;
    }
  }

  const seen = new Set();
  const deduped = [];
  for (const model of capped) {
    const id = readString(model.id || model.model);
    if (!id || seen.has(id)) {
      continue;
    }
    seen.add(id);
    deduped.push(model);
    if (deduped.length >= maxTotal) {
      break;
    }
  }

  return deduped;
}

function removeUndefinedValues(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const result = {};
  for (const [key, child] of Object.entries(value)) {
    if (child !== undefined) result[key] = removeUndefinedValues(child);
  }
  return result;
}

function appendNonEmpty(target, value) {
  const text = readString(value);
  if (text) target.push(text);
}

function readThreadId(params = {}) {
  return resolvedParam(params, 'threadId', 'thread_id', 'id');
}

module.exports = {
  CODEX_PROVIDER_ID,
  DEFAULT_OPENCODE_MODEL,
  OPENCODE_PROVIDER_ID,
  appendNonEmpty,
  boundedPositiveInteger,
  capOpenCodeModelsForMobileList,
  buildOpenCodeModelOption,
  slimModelForMobileList,
  buildPromptFromTurnInput,
  mentionItemToPromptPart,
  imageItemToPromptPart,
  skillItemToPromptPart,
  compareThreadsByUpdatedAt,
  displayNameForOpenCodeModel,
  isCodexProvider,
  isOpenCodeProvider,
  messagesToTurns,
  readOpenCodeMessageRole,
  extractOpenCodeMessageText,
  isOpenCodeAssistantMessage,
  normalizeOpenCodeModel,
  normalizeOpenCodeModelReference,
  normalizeRuntimeProvider,
  parseOpenCodeModelsOutput,
  publicThread,
  sessionHasDiscoverySignal,
  sessionV2InfoToDiscoveredThread,
  readModelProvider,
  readThreadId,
  removeUndefinedValues,
  textContent,
};
