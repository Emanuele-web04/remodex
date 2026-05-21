// FILE: claude-models.js
// Purpose: Declares Claude Code model metadata and provider normalization helpers.
// Layer: Runtime provider helper
// Exports: Claude model list, provider constants, selection helpers
// Depends on: fs, child_process

const fs = require("fs");
const { execFileSync } = require("child_process");

const CODEX_PROVIDER_ID = "codex";
const CLAUDE_PROVIDER_ID = "claude";

const CLAUDE_REASONING_EFFORTS = [
  { reasoningEffort: "low", description: "Low" },
  { reasoningEffort: "medium", description: "Medium" },
  { reasoningEffort: "high", description: "High" },
  { reasoningEffort: "xhigh", description: "Extra High" },
];

const CLAUDE_MODELS = [
  {
    id: "claude-opus-4-7",
    model: "claude-opus-4-7",
    displayName: "Claude Opus 4.7",
    description: "Claude Code Opus 4.7",
    isDefault: true,
  },
  {
    id: "claude-opus-4-6",
    model: "claude-opus-4-6",
    displayName: "Claude Opus 4.6",
    description: "Claude Code Opus 4.6",
    isDefault: false,
  },
  {
    id: "claude-opus-4-5-20251101",
    model: "claude-opus-4-5-20251101",
    displayName: "Claude Opus 4.5",
    description: "Claude Code Opus 4.5",
    isDefault: false,
  },
  {
    id: "claude-sonnet-4-6",
    model: "claude-sonnet-4-6",
    displayName: "Claude Sonnet 4.6",
    description: "Claude Code Sonnet 4.6",
    isDefault: false,
  },
  {
    id: "claude-haiku-4-5-20251001",
    model: "claude-haiku-4-5-20251001",
    displayName: "Claude Haiku 4.5",
    description: "Claude Code Haiku 4.5",
    isDefault: false,
  },
].map((model) => ({
  ...model,
  modelProvider: CLAUDE_PROVIDER_ID,
  provider: CLAUDE_PROVIDER_ID,
  supportsFastMode: false,
  supportedReasoningEfforts: CLAUDE_REASONING_EFFORTS,
  defaultReasoningEffort: "high",
}));

function normalizeModelProvider(value) {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (!normalized) {
    return CODEX_PROVIDER_ID;
  }
  if (normalized === "claude-code" || normalized === "claudecode") {
    return CLAUDE_PROVIDER_ID;
  }
  return normalized;
}

function readModelProvider(params) {
  if (!params || typeof params !== "object") {
    return CODEX_PROVIDER_ID;
  }
  return normalizeModelProvider(
    params.modelProvider
      || params.model_provider
      || params.provider
      || params.harness
      || params.runtimeProvider
      || params.runtime_provider
      || params.collaborationMode?.settings?.modelProvider
      || params.collaborationMode?.settings?.model_provider
  );
}

function isClaudeProvider(value) {
  return normalizeModelProvider(value) === CLAUDE_PROVIDER_ID;
}

function normalizeClaudeModel(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized) {
    return CLAUDE_MODELS[0].model;
  }
  const match = CLAUDE_MODELS.find((model) => (
    model.id === normalized
    || model.model === normalized
    || model.displayName.toLowerCase() === normalized.toLowerCase()
  ));
  return match?.model || normalized;
}

function normalizeClaudeEffort(value) {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  switch (normalized) {
    case "low":
    case "medium":
    case "high":
    case "xhigh":
      return normalized;
    case "extra_high":
    case "extra-high":
      return "xhigh";
    case "max":
      return normalized;
    default:
      return undefined;
  }
}

function isClaudeDisabled(env = process.env) {
  const rawValue = typeof env.REMODEX_CLAUDE_CODE_ENABLED === "string"
    ? env.REMODEX_CLAUDE_CODE_ENABLED.trim().toLowerCase()
    : "";
  return rawValue === "0" || rawValue === "false" || rawValue === "off" || rawValue === "no";
}

function resolveClaudeCodeExecutable({
  env = process.env,
  fsImpl = fs,
  execFileSyncImpl = execFileSync,
} = {}) {
  if (isClaudeDisabled(env)) {
    return {
      available: false,
      command: "",
      path: "",
      reason: "Claude Code is disabled by REMODEX_CLAUDE_CODE_ENABLED.",
    };
  }

  const command = normalizeNonEmptyString(env.REMODEX_CLAUDE_CODE_COMMAND) || "claude";
  if (command.includes("/") || command.includes("\\")) {
    try {
      const executableAccessMode = fsImpl.constants?.X_OK ?? 1;
      fsImpl.accessSync(command, executableAccessMode);
      return {
        available: true,
        command,
        path: command,
        reason: "",
      };
    } catch {
      return {
        available: false,
        command,
        path: "",
        reason: `Claude Code executable is not executable: ${command}`,
      };
    }
  }

  try {
    const resolved = execFileSyncImpl("which", [command], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (resolved) {
      return {
        available: true,
        command,
        path: resolved,
        reason: "",
      };
    }
  } catch {
    // Report a concise availability reason below.
  }

  return {
    available: false,
    command,
    path: "",
    reason: `Claude Code executable not found in PATH: ${command}`,
  };
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  CLAUDE_MODELS,
  CLAUDE_PROVIDER_ID,
  CODEX_PROVIDER_ID,
  isClaudeDisabled,
  isClaudeProvider,
  normalizeClaudeEffort,
  normalizeClaudeModel,
  normalizeModelProvider,
  readModelProvider,
  resolveClaudeCodeExecutable,
};
