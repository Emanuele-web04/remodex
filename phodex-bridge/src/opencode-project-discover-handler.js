// FILE: opencode-project-discover-handler.js
// Purpose: Serves project/discover by syncing OpenCode project.list into the bridge registry.
// Layer: Bridge handler
// Exports: handleOpenCodeProjectDiscoverRequest, projectDiscoverFromOpenCode
// Depends on: ./normalize, ./opencode-runtime-policy

const { readString } = require("./normalize");
const { validateDirectory } = require("./project-path-policy");
const { isOpenCodeRuntimeDisabled } = require("./opencode-runtime-policy");
const { safeParseJSON } = require("./safe-json");

function handleOpenCodeProjectDiscoverRequest(
  rawMessage,
  sendResponse,
  { homeDir, opencodeProvider, projectRegistry } = {},
) {
  const parsed = safeParseJSON(rawMessage);
  if (!parsed) {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (method !== "project/discover") {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  projectDiscoverFromOpenCode(params, { homeDir, opencodeProvider, projectRegistry })
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "project_discover_failed";
      const message = err.userMessage || err.message || "OpenCode project discovery failed";
      sendResponse(
        JSON.stringify({
          id,
          error: {
            code: -32000,
            message,
            data: { errorCode },
          },
        }),
      );
    });

  return true;
}

async function projectDiscoverFromOpenCode(params, { homeDir, opencodeProvider, projectRegistry } = {}) {
  if (isOpenCodeRuntimeDisabled(process.env)) {
    return { projects: [], source: "opencode", disabled: true };
  }

  if (!opencodeProvider || typeof opencodeProvider.discoverProjects !== "function") {
    throw projectDiscoverError("opencode_unavailable", "OpenCode provider is not available.");
  }

  const directory = readString(params.directory || params.cwd);
  const discoverParams = {};
  if (directory) {
    const validation = await validateDirectory(directory, { homeDir });
    if (!validation.isAllowed) {
      throw projectDiscoverError(
        "path_not_allowed",
        "That folder is outside the allowed local project locations.",
      );
    }
    discoverParams.directory = validation.path;
  }

  const discoveredProjects = await opencodeProvider.discoverProjects(discoverParams);
  const projects = [];

  if (Array.isArray(discoveredProjects)) {
    for (const project of discoveredProjects) {
      const projectPath = readString(project.path || project.directory || project.cwd);
      if (!projectPath) {
        continue;
      }
      const validation = await validateDirectory(projectPath, { homeDir });
      if (!validation.isAllowed) {
        continue;
      }
      if (projectRegistry) {
        projectRegistry.rememberProjectPath(validation.path, {
          source: "opencode-project-discover",
          provider: "opencode",
          projectId: readString(project.id || project.projectID || project.projectId),
          label: readString(project.name || project.title || project.label),
        });
      }
      projects.push(project);
    }
  }

  return {
    projects,
    source: "opencode",
    count: projects.length,
  };
}

function projectDiscoverError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handleOpenCodeProjectDiscoverRequest,
  projectDiscoverFromOpenCode,
};
