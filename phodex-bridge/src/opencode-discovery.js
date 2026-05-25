// FILE: opencode-discovery.js
// Purpose: HTTP-first OpenCode catalog discovery with CLI fallback when serve is unavailable.
// Layer: Bridge core
// Exports: discoverOpenCodeAgentsHttp, discoverOpenCodeSkillsHttp, discoverOpenCodeProvidersHttp,
//          discoverOpenCodeAgentCatalog, discoverOpenCodeSkillCatalog, discoverOpenCodeModelCatalogHttp
// Depends on: ./agent-runtime-capabilities, ./agent-runtime-model-catalog, ./opencode-agent-discovery

const {
  OPENCODE_DEFAULT_BUILD_AGENT_NAME,
  OPENCODE_DEFAULT_PLAN_AGENT_NAME,
} = require("./agent-runtime-capabilities");
const {
  discoverOpenCodeAgentCatalog: discoverOpenCodeAgentCatalogCli,
} = require("./opencode-agent-discovery");

const KNOWN_HIDDEN_NATIVE_AGENTS = new Set(["title", "compaction", "summary"]);

function isServerReady(serverManager) {
  const status = serverManager?.getStatus?.() || { state: "stopped" };
  return status.state === "ready" && Boolean(status.baseUrl);
}

async function discoverOpenCodeAgentsHttp(serverManager) {
  const payload = await serverManager.request("GET", "/agent");
  const agents = Array.isArray(payload) ? payload : [];
  const parsedAgents = agents.map((entry) => ({
    name: readString(entry?.name) || readString(entry?.identifier),
    mode: readString(entry?.mode),
    hidden: entry?.hidden === true,
  })).filter((entry) => entry.name);

  const configDefaultAgentName = "";
  const defaultBuildAgentName = chooseDefaultBuildAgentName(parsedAgents, configDefaultAgentName);
  const defaultPlanAgentName = OPENCODE_DEFAULT_PLAN_AGENT_NAME;
  const composerAgents = buildComposerAgentPayload(parsedAgents, defaultBuildAgentName, defaultPlanAgentName);

  return {
    source: "http",
    agents: composerAgents,
    defaultBuildAgentName,
    defaultPlanAgentName,
  };
}

async function discoverOpenCodeSkillsHttp(serverManager) {
  const payload = await serverManager.request("GET", "/skill");
  const skills = Array.isArray(payload) ? payload : [];
  return {
    source: "http",
    skills: skills.map((entry) => ({
      id: readString(entry?.name),
      name: readString(entry?.name),
      displayName: readString(entry?.name),
      description: readString(entry?.description),
    })).filter((skill) => skill.id),
  };
}

async function discoverOpenCodeProvidersHttp(serverManager, { fsImpl } = {}) {
  let payload;
  try {
    payload = await serverManager.request("GET", "/provider");
  } catch {
    payload = await serverManager.request("GET", "/config/providers");
  }

  const providers = Array.isArray(payload?.all)
    ? payload.all
    : Array.isArray(payload?.providers)
      ? payload.providers
      : [];
  const defaultByProvider = payload?.default && typeof payload.default === "object"
    ? payload.default
    : {};

  const modelIds = [];
  for (const provider of providers) {
    const providerID = readString(provider?.id);
    if (!providerID) {
      continue;
    }
    const models = provider?.models && typeof provider.models === "object"
      ? Object.values(provider.models)
      : [];
    for (const model of models) {
      const modelID = readString(model?.id);
      if (providerID && modelID) {
        modelIds.push(`${providerID}/${modelID}`);
      }
    }
    const configuredDefault = readString(defaultByProvider[providerID]);
    if (configuredDefault && providerID) {
      modelIds.push(`${providerID}/${configuredDefault}`);
    }
  }

  const {
    createOpenCodeModelCatalog,
    readOpenCodePreferredModelId,
  } = require("./agent-runtime-model-catalog");
  const preferredModelId = readOpenCodePreferredModelId({ fsImpl });
  return {
    source: "http",
    catalog: createOpenCodeModelCatalog({
      modelIds: uniqueStrings(modelIds),
      preferredModelId,
    }),
  };
}

async function discoverOpenCodeAgentCatalog({
  serverManager = null,
  execFileImpl,
  fsImpl,
  env,
  configDir,
  timeoutMs,
  maxBuffer,
} = {}) {
  if (isServerReady(serverManager)) {
    try {
      return await discoverOpenCodeAgentsHttp(serverManager);
    } catch (error) {
      const cliCatalog = await discoverOpenCodeAgentCatalogCli({
        execFileImpl,
        fsImpl,
        env,
        configDir,
        timeoutMs,
        maxBuffer,
      });
      return {
        ...cliCatalog,
        source: "cli",
        status: "degraded",
        statusMessage: `OpenCode HTTP agent discovery failed; using CLI fallback. ${error?.message || ""}`.trim(),
      };
    }
  }

  const cliCatalog = await discoverOpenCodeAgentCatalogCli({
    execFileImpl,
    fsImpl,
    env,
    configDir,
    timeoutMs,
    maxBuffer,
  });
  return { ...cliCatalog, source: "cli" };
}

async function discoverOpenCodeSkillCatalog({
  serverManager = null,
} = {}) {
  if (!isServerReady(serverManager)) {
    return {
      source: "none",
      skills: [],
      status: "degraded",
      statusMessage: "OpenCode server is not running; skill list unavailable.",
    };
  }

  try {
    return await discoverOpenCodeSkillsHttp(serverManager);
  } catch (error) {
    return {
      source: "none",
      skills: [],
      status: "degraded",
      statusMessage: `OpenCode skill discovery failed. ${error?.message || ""}`.trim(),
    };
  }
}

async function discoverOpenCodeModelCatalogHttp({
  serverManager = null,
  fsImpl,
} = {}) {
  if (!isServerReady(serverManager)) {
    return null;
  }
  try {
    const result = await discoverOpenCodeProvidersHttp(serverManager, { fsImpl });
    return result.catalog;
  } catch {
    return null;
  }
}

function buildComposerAgentPayload(parsedAgents, defaultBuildAgentName, defaultPlanAgentName) {
  return parsedAgents
    .filter((agent) => isComposerVisibleAgent(agent, defaultPlanAgentName))
    .map((agent) => createAgentEntry(agent.name, defaultBuildAgentName, defaultPlanAgentName));
}

function isComposerVisibleAgent(agent, defaultPlanAgentName) {
  if (agent.hidden) {
    return false;
  }
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
      && !agent.hidden
      && agent.name !== OPENCODE_DEFAULT_PLAN_AGENT_NAME,
  );
  if (firstPrimary) {
    return firstPrimary.name;
  }
  return OPENCODE_DEFAULT_BUILD_AGENT_NAME;
}

function createAgentEntry(id, defaultBuildAgentName, defaultPlanAgentName) {
  return {
    id,
    displayName: id,
    isDefaultBuild: id === defaultBuildAgentName,
    isDefaultPlan: id === defaultPlanAgentName,
  };
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function uniqueStrings(values) {
  return [...new Set(values.map((value) => readString(value)).filter(Boolean))];
}

module.exports = {
  discoverOpenCodeAgentCatalog,
  discoverOpenCodeAgentsHttp,
  discoverOpenCodeModelCatalogHttp,
  discoverOpenCodeProvidersHttp,
  discoverOpenCodeSkillCatalog,
  discoverOpenCodeSkillsHttp,
  isServerReady,
};
