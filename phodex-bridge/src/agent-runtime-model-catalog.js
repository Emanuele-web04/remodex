// FILE: agent-runtime-model-catalog.js
// Purpose: Builds runtime-scoped model catalog payloads for Agent Runtime discovery and dispatch.
// Layer: Bridge core
// Exports: runtime model catalog helpers
// Depends on: child_process, fs, os, path, util

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");

const CODEX_DEFAULT_MODEL_ID = "gpt-5.5";
const OPENCODE_DEFAULT_MODEL_ID = "opencode-go/deepseek-v4-flash";
const OPENCODE_MODEL_DISCOVERY_TTL_MS = 30_000;
const execFileAsync = promisify(execFile);

function createCodexModelCatalog() {
  return {
    defaultModelId: CODEX_DEFAULT_MODEL_ID,
    models: [
      {
        id: CODEX_DEFAULT_MODEL_ID,
        model: CODEX_DEFAULT_MODEL_ID,
        displayName: "GPT-5.5",
        description: "Default Codex model; full Codex model list is refreshed through model/list.",
        isDefault: true,
        supportsFastMode: true,
        supportedReasoningEfforts: [
          { reasoningEffort: "medium", displayName: "Medium", isDefault: true },
        ],
        defaultReasoningEffort: "medium",
      },
    ],
  };
}

function createOpenCodeModelCatalog({
  modelIds = [],
  preferredModelId = "",
  status,
  statusMessage,
} = {}) {
  const discoveredIds = uniqueStrings(modelIds);
  const fallbackIds = [
    OPENCODE_DEFAULT_MODEL_ID,
    "opencode-go/qwen3.6-plus",
  ];
  const ids = discoveredIds.length > 0 ? discoveredIds : fallbackIds;
  const defaultModelId = chooseDefaultModelId(ids, preferredModelId);
  const models = ids.map((id) => createRuntimeModelOption({
    id,
    displayName: formatOpenCodeModelDisplayName(id),
    providerDisplayName: formatOpenCodeProviderDisplayName(parseProviderModelIdentifier(id)?.providerID),
    description: discoveredIds.length > 0
      ? "Discovered from this Mac's OpenCode model catalog."
      : "Recovery fallback while OpenCode model discovery is unavailable.",
    isDefault: id === defaultModelId,
  })).filter((model) => model.providerID && model.modelID);
  const providers = buildProviderOptions(models, defaultModelId);

  return {
    defaultModelId,
    defaultProviderId: parseProviderModelIdentifier(defaultModelId)?.providerID,
    ...(status ? { status } : {}),
    ...(statusMessage ? { statusMessage } : {}),
    providers,
    models,
  };
}

function createCursorModelCatalog({ statusMessage = "" } = {}) {
  return {
    defaultModelId: "",
    status: "unavailable",
    statusMessage: statusMessage || "Cursor model selection requires ACP model-setting verification.",
    models: [],
  };
}

function createRuntimeModelOption({
  id,
  displayName,
  description = "",
  isDefault = false,
  supportsFastMode = false,
  providerDisplayName = "",
}) {
  const normalized = readString(id);
  const nativeModel = parseProviderModelIdentifier(normalized);
  return {
    id: normalized,
    model: normalized,
    displayName: readString(displayName) || normalized,
    description,
    isDefault,
    supportsFastMode,
    supportedReasoningEfforts: [],
    providerID: nativeModel?.providerID,
    providerDisplayName: readString(providerDisplayName) || formatOpenCodeProviderDisplayName(nativeModel?.providerID),
    modelID: nativeModel?.modelID,
    modelDisplayName: formatOpenCodeModelDisplayName(normalized),
  };
}

function createOpenCodeModelCatalogProvider({
  discover = discoverOpenCodeModelCatalog,
  ttlMs = OPENCODE_MODEL_DISCOVERY_TTL_MS,
} = {}) {
  let cachedCatalog = null;
  let cachedAt = 0;
  let inFlight = null;

  return {
    async get({ forceRefresh = false } = {}) {
      const now = Date.now();
      if (!forceRefresh && cachedCatalog && now - cachedAt < ttlMs) {
        return cachedCatalog;
      }
      if (!forceRefresh && inFlight) {
        return inFlight;
      }
      inFlight = Promise.resolve()
        .then(() => discover())
        .then((catalog) => {
          cachedCatalog = catalog;
          cachedAt = Date.now();
          return cachedCatalog;
        })
        .finally(() => {
          inFlight = null;
        });
      return inFlight;
    },
    clear() {
      cachedCatalog = null;
      cachedAt = 0;
      inFlight = null;
    },
  };
}

async function discoverOpenCodeModelCatalog({
  serverManager = null,
  execFileImpl = execFileAsync,
  fsImpl = fs,
  env = process.env,
  timeoutMs = 5_000,
  maxBuffer = 2 * 1024 * 1024,
} = {}) {
  const { discoverOpenCodeModelCatalogHttp } = require("./opencode-discovery");
  const httpCatalog = await discoverOpenCodeModelCatalogHttp({ serverManager, fsImpl });
  if (httpCatalog) {
    return httpCatalog;
  }

  try {
    const result = await execFileImpl("opencode", ["models"], {
      timeout: timeoutMs,
      maxBuffer,
      env,
    });
    const stdout = typeof result === "string" ? result : result?.stdout || "";
    const modelIds = parseOpenCodeModelsOutput(stdout);
    const preferredModelId = readOpenCodePreferredModelId({ fsImpl });
    return createOpenCodeModelCatalog({ modelIds, preferredModelId });
  } catch (error) {
    return createOpenCodeModelCatalog({
      status: "degraded",
      statusMessage: `OpenCode model discovery failed; showing recovery fallbacks. ${error?.message || ""}`.trim(),
    });
  }
}

function resolveRuntimeModelSelection(params = {}, record = {}, catalog = {}) {
  const rawModel = readString(params.runtimeModel)
    || readString(params.runtime_model)
    || readString(params.model)
    || readString(record.runtimeModel)
    || readString(record.selectedModel)
    || readString(catalog.defaultModelId);
  return findRuntimeModelOption(rawModel, catalog) || null;
}

function findRuntimeModelOption(rawModel, catalog = {}) {
  const normalized = readString(rawModel);
  if (!normalized) {
    return null;
  }
  const models = Array.isArray(catalog.models) ? catalog.models : [];
  return models.find((model) => {
    return readString(model.id) === normalized
      || readString(model.model) === normalized
      || runtimeModelNativeIdentifier(model) === normalized;
  }) || null;
}

function runtimeModelNativeIdentifier(model = {}) {
  const providerID = readString(model.providerID);
  const modelID = readString(model.modelID);
  return providerID && modelID ? `${providerID}/${modelID}` : "";
}

function openCodeModelPayloadForSelection(selection) {
  if (!selection) {
    return null;
  }
  const providerID = readString(selection.providerID);
  const modelID = readString(selection.modelID);
  if (providerID && modelID) {
    return { providerID, modelID };
  }
  const parsed = parseProviderModelIdentifier(readString(selection.model));
  return parsed ? { providerID: parsed.providerID, modelID: parsed.modelID } : null;
}

function parseOpenCodeModelsOutput(output) {
  const lines = typeof output === "string" ? output.split(/\r?\n/) : [];
  return uniqueStrings(lines.map((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("opencode models") || trimmed.startsWith("Usage:")) {
      return "";
    }
    const firstToken = trimmed.split(/\s+/)[0];
    return parseProviderModelIdentifier(firstToken) ? firstToken : "";
  }));
}

function parseProviderModelIdentifier(value) {
  const normalized = readString(value);
  const slashIndex = normalized.indexOf("/");
  if (slashIndex <= 0 || slashIndex === normalized.length - 1) {
    return null;
  }
  return {
    providerID: normalized.slice(0, slashIndex),
    modelID: normalized.slice(slashIndex + 1),
  };
}

function readOpenCodePreferredModelId({ fsImpl = fs } = {}) {
  const modelStatePath = path.join(os.homedir(), ".local", "state", "opencode", "model.json");
  try {
    const parsed = JSON.parse(fsImpl.readFileSync(modelStatePath, "utf8"));
    const favorite = Array.isArray(parsed?.favorite) ? parsed.favorite : [];
    const recent = Array.isArray(parsed?.recent) ? parsed.recent : [];
    for (const entry of [...favorite, ...recent]) {
      const modelId = runtimeModelNativeIdentifier(entry);
      if (modelId) {
        return modelId;
      }
    }
  } catch {
    return "";
  }
  return "";
}

function chooseDefaultModelId(modelIds, preferredModelId) {
  const ids = uniqueStrings(modelIds);
  const preferred = readString(preferredModelId);
  if (preferred && ids.includes(preferred)) {
    return preferred;
  }
  return ids.includes(OPENCODE_DEFAULT_MODEL_ID)
    ? OPENCODE_DEFAULT_MODEL_ID
    : ids[0] || OPENCODE_DEFAULT_MODEL_ID;
}

function buildProviderOptions(models, defaultModelId) {
  const providersById = new Map();
  for (const model of models) {
    const providerID = readString(model.providerID);
    if (!providerID) {
      continue;
    }
    if (!providersById.has(providerID)) {
      providersById.set(providerID, {
        id: providerID,
        displayName: readString(model.providerDisplayName) || formatOpenCodeProviderDisplayName(providerID),
        modelIds: [],
        isDefault: providerID === parseProviderModelIdentifier(defaultModelId)?.providerID,
      });
    }
    providersById.get(providerID).modelIds.push(model.id);
  }
  return Array.from(providersById.values());
}

function formatOpenCodeProviderDisplayName(providerID) {
  const normalized = readString(providerID);
  if (!normalized) {
    return "";
  }
  const known = {
    opencode: "OpenCode",
    "opencode-go": "OpenCode Go",
    "kimi-for-coding": "Kimi for Coding",
    openai: "OpenAI",
    vercel: "Vercel",
    xai: "xAI",
  };
  if (known[normalized]) {
    return known[normalized];
  }
  return titleizeIdentifier(normalized);
}

function formatOpenCodeModelDisplayName(identifier) {
  const parsed = parseProviderModelIdentifier(identifier);
  const modelID = parsed?.modelID || readString(identifier);
  return titleizeIdentifier(modelID.split("/").pop() || modelID)
    .replace(/\bV(\d)\b/g, "V$1")
    .replace(/\bDeepseek\b/g, "DeepSeek")
    .replace(/\bGpt\b/g, "GPT")
    .replace(/\bQwen(\d)/g, "Qwen $1")
    .replace(/\bGlm\b/g, "GLM")
    .replace(/\bK2p(\d)\b/gi, "K2.$1");
}

function titleizeIdentifier(value) {
  return readString(value)
    .replace(/[_-]+/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map((word) => {
      if (/^\d+(\.\d+)*[a-z]?$/i.test(word)) {
        return word.toUpperCase();
      }
      return word.charAt(0).toUpperCase() + word.slice(1);
    })
    .join(" ");
}

function uniqueStrings(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const normalized = readString(value);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    result.push(normalized);
  }
  return result;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  CODEX_DEFAULT_MODEL_ID,
  OPENCODE_DEFAULT_MODEL_ID,
  createOpenCodeModelCatalogProvider,
  createCodexModelCatalog,
  createCursorModelCatalog,
  createOpenCodeModelCatalog,
  discoverOpenCodeModelCatalog,
  findRuntimeModelOption,
  openCodeModelPayloadForSelection,
  parseOpenCodeModelsOutput,
  parseProviderModelIdentifier,
  readOpenCodePreferredModelId,
  resolveRuntimeModelSelection,
  runtimeModelNativeIdentifier,
};
