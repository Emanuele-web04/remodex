// FILE: agent-runtime-capabilities.js
// Purpose: Defines the capability matrix each agent runtime exposes to bridge and iOS gating.
// Layer: Bridge core
// Exports: runtime ids, capability lookup, runtime metadata helpers
// Depends on: none

const AGENT_RUNTIME_IDS = Object.freeze(["codex", "opencode", "cursor"]);
const DEFAULT_AGENT_RUNTIME = "codex";

const RUNTIME_DISPLAY_NAMES = Object.freeze({
  codex: "Codex",
  opencode: "OpenCode",
  cursor: "Cursor",
});

const RUNTIME_CAPABILITIES = Object.freeze({
  codex: Object.freeze({
    queue: true,
    steer: true,
    photos: true,
    planMode: true,
    permissions: true,
    desktopHandoff: true,
    subagents: true,
  }),
  opencode: Object.freeze({
    queue: false,
    steer: false,
    photos: false,
    planMode: true,
    permissions: true,
    desktopHandoff: false,
    subagents: false,
  }),
  cursor: Object.freeze({
    queue: false,
    steer: false,
    photos: false,
    planMode: true,
    permissions: true,
    desktopHandoff: false,
    subagents: false,
  }),
});

const OPENCODE_DEFAULT_BUILD_AGENT_NAME = "build";
const OPENCODE_DEFAULT_PLAN_AGENT_NAME = "plan";

function normalizeAgentRuntimeId(value) {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  return AGENT_RUNTIME_IDS.includes(normalized) ? normalized : "";
}

function getAgentRuntimeCapabilities(runtimeId) {
  const normalizedRuntimeId = normalizeAgentRuntimeId(runtimeId);
  if (!normalizedRuntimeId) {
    return null;
  }

  return RUNTIME_CAPABILITIES[normalizedRuntimeId];
}

function getAgentRuntimeDisplayName(runtimeId) {
  const normalizedRuntimeId = normalizeAgentRuntimeId(runtimeId);
  return normalizedRuntimeId ? RUNTIME_DISPLAY_NAMES[normalizedRuntimeId] : "";
}

function buildRuntimeListEntry({
  id,
  status,
  statusMessage = "",
  capabilities = getAgentRuntimeCapabilities(id),
  modelCatalog = null,
  openCodeAgents = null,
  openCodeSkills = null,
  defaultBuildAgentName = null,
  defaultPlanAgentName = null,
}) {
  const entry = {
    id,
    displayName: getAgentRuntimeDisplayName(id),
    status,
    capabilities: capabilities || getAgentRuntimeCapabilities(id),
  };

  if (statusMessage) {
    entry.statusMessage = statusMessage;
  }

  if (modelCatalog && typeof modelCatalog === "object") {
    entry.modelCatalog = modelCatalog;
  }

  if (id === "opencode") {
    entry.defaultBuildAgentName = readString(defaultBuildAgentName) || OPENCODE_DEFAULT_BUILD_AGENT_NAME;
    entry.defaultPlanAgentName = readString(defaultPlanAgentName) || OPENCODE_DEFAULT_PLAN_AGENT_NAME;
    if (Array.isArray(openCodeAgents) && openCodeAgents.length > 0) {
      entry.openCodeAgents = openCodeAgents;
    }
    if (Array.isArray(openCodeSkills) && openCodeSkills.length > 0) {
      entry.openCodeSkills = openCodeSkills;
    }
  }

  return entry;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  AGENT_RUNTIME_IDS,
  DEFAULT_AGENT_RUNTIME,
  OPENCODE_DEFAULT_BUILD_AGENT_NAME,
  OPENCODE_DEFAULT_PLAN_AGENT_NAME,
  buildRuntimeListEntry,
  getAgentRuntimeCapabilities,
  getAgentRuntimeDisplayName,
  normalizeAgentRuntimeId,
};
