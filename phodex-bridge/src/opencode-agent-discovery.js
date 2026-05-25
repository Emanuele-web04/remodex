// FILE: opencode-agent-discovery.js
// Purpose: Discovers OpenCode agents via CLI for runtime list payloads.
// Layer: Bridge core
//
// Source of truth: `opencode agent list` (mirrors `opencode models` in agent-runtime-model-catalog.js).
// OpenCode merges config `agent`, markdown globs, and plugins before listing; Remodex does not read
// plugin-specific agent config (e.g. oh-my-openagent.json). Degraded mode = build/plan defaults only.
// Reference: anomalyco/opencode packages/opencode/src/agent/agent.ts
//
// Exports: parseOpenCodeAgentListOutput, discoverOpenCodeAgentCatalog, createOpenCodeAgentCatalogProvider,
//          readOpenCodeDefaultAgentName
// Depends on: child_process, fs, os, path, util, ./agent-runtime-capabilities

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");
const {
  OPENCODE_DEFAULT_BUILD_AGENT_NAME,
  OPENCODE_DEFAULT_PLAN_AGENT_NAME,
} = require("./agent-runtime-capabilities");

const OPENCODE_AGENT_DISCOVERY_TTL_MS = 30_000;
const KNOWN_HIDDEN_NATIVE_AGENTS = new Set(["title", "compaction", "summary"]);
const AGENT_LIST_HEADER_PATTERN = /^(.+?)\s+\((primary|subagent|all)\)\s*$/;

const execFileAsync = promisify(execFile);

function parseOpenCodeAgentListOutput(output) {
  const lines = typeof output === "string" ? output.split(/\r?\n/) : [];
  const agents = [];

  for (const line of lines) {
    const match = line.match(AGENT_LIST_HEADER_PATTERN);
    if (!match) {
      continue;
    }
    agents.push({
      name: match[1].trim(),
      mode: match[2],
    });
  }

  return agents;
}

function readOpenCodeDefaultAgentName({
  fsImpl = fs,
  env = process.env,
  configDir = path.join(env.HOME || os.homedir(), ".config", "opencode"),
} = {}) {
  for (const fileName of ["opencode.json", "opencode.jsonc"]) {
    const value = readDefaultAgentFromConfigFile(path.join(configDir, fileName), fsImpl);
    if (value) {
      return value;
    }
  }
  return "";
}

async function discoverOpenCodeAgentCatalog({
  execFileImpl = execFileAsync,
  fsImpl = fs,
  env = process.env,
  configDir = path.join(env.HOME || os.homedir(), ".config", "opencode"),
  timeoutMs = 5_000,
  maxBuffer = 2 * 1024 * 1024,
} = {}) {
  const defaultPlanAgentName = OPENCODE_DEFAULT_PLAN_AGENT_NAME;

  try {
    const result = await execFileImpl("opencode", ["agent", "list"], {
      timeout: timeoutMs,
      maxBuffer,
      env,
    });
    const stdout = typeof result === "string" ? result : result?.stdout || "";
    const parsedAgents = parseOpenCodeAgentListOutput(stdout);
    const configDefaultAgentName = readOpenCodeDefaultAgentName({ fsImpl, env, configDir });
    const defaultBuildAgentName = chooseDefaultBuildAgentName(
      parsedAgents,
      configDefaultAgentName,
    );
    const agents = buildComposerAgentPayload(parsedAgents, defaultBuildAgentName, defaultPlanAgentName);

    return {
      agents,
      defaultBuildAgentName,
      defaultPlanAgentName,
    };
  } catch (error) {
    return createDegradedAgentCatalog(error);
  }
}

function createOpenCodeAgentCatalogProvider({
  discover = discoverOpenCodeAgentCatalog,
  ttlMs = OPENCODE_AGENT_DISCOVERY_TTL_MS,
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

function buildComposerAgentPayload(parsedAgents, defaultBuildAgentName, defaultPlanAgentName) {
  return parsedAgents
    .filter((agent) => isComposerVisibleAgent(agent, defaultPlanAgentName))
    .map((agent) => createAgentEntry(agent.name, defaultBuildAgentName, defaultPlanAgentName));
}

function isComposerVisibleAgent(agent, defaultPlanAgentName) {
  if (agent.mode !== "primary" && agent.mode !== "all") {
    return false;
  }
  if (KNOWN_HIDDEN_NATIVE_AGENTS.has(agent.name)) {
    return false;
  }
  if (agent.name === defaultPlanAgentName) {
    return false;
  }
  return true;
}

function chooseDefaultBuildAgentName(parsedAgents, configDefaultAgentName) {
  const configured = readString(configDefaultAgentName);
  if (configured) {
    return configured;
  }
  const firstPrimary = parsedAgents.find(
    (agent) => (agent.mode === "primary" || agent.mode === "all")
      && !KNOWN_HIDDEN_NATIVE_AGENTS.has(agent.name)
      && agent.name !== OPENCODE_DEFAULT_PLAN_AGENT_NAME,
  );
  if (firstPrimary) {
    return firstPrimary.name;
  }
  return OPENCODE_DEFAULT_BUILD_AGENT_NAME;
}

function createDegradedAgentCatalog(error) {
  const defaultBuildAgentName = OPENCODE_DEFAULT_BUILD_AGENT_NAME;
  const defaultPlanAgentName = OPENCODE_DEFAULT_PLAN_AGENT_NAME;
  return {
    status: "degraded",
    statusMessage: `OpenCode agent discovery failed; showing recovery fallbacks. ${error?.message || ""}`.trim(),
    agents: [
      createAgentEntry(defaultBuildAgentName, defaultBuildAgentName, defaultPlanAgentName),
    ],
    defaultBuildAgentName,
    defaultPlanAgentName,
  };
}

function createAgentEntry(id, defaultBuildAgentName, defaultPlanAgentName) {
  return {
    id,
    displayName: formatOpenCodeAgentDisplayName(id),
    isDefaultBuild: id === defaultBuildAgentName,
    isDefaultPlan: id === defaultPlanAgentName,
  };
}

function readDefaultAgentFromConfigFile(filePath, fsImpl) {
  try {
    const raw = fsImpl.readFileSync(filePath, "utf8");
    const parsed = JSON.parse(stripJsonComments(raw));
    return readString(parsed?.default_agent);
  } catch {
    return "";
  }
}

function stripJsonComments(raw) {
  return raw
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "");
}

function formatOpenCodeAgentDisplayName(id) {
  const normalized = readString(id);
  if (!normalized) {
    return "";
  }
  if (normalized === OPENCODE_DEFAULT_BUILD_AGENT_NAME || normalized === OPENCODE_DEFAULT_PLAN_AGENT_NAME) {
    return normalized.charAt(0).toUpperCase() + normalized.slice(1);
  }
  if (normalized.includes(" - ") || normalized.includes(" ")) {
    return normalized;
  }
  return normalized
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  KNOWN_HIDDEN_NATIVE_AGENTS,
  createOpenCodeAgentCatalogProvider,
  discoverOpenCodeAgentCatalog,
  formatOpenCodeAgentDisplayName,
  parseOpenCodeAgentListOutput,
  readOpenCodeDefaultAgentName,
};
