// FILE: codex-runtime-adapter.js
// Purpose: Wraps the existing Codex transport as the first agent runtime adapter behind the registry.
// Layer: Bridge adapter
// Exports: createCodexRuntimeAdapter
// Depends on: ./agent-runtime-capabilities

const {
  buildRuntimeListEntry,
  getAgentRuntimeCapabilities,
} = require("./agent-runtime-capabilities");
const {
  createCodexModelCatalog,
} = require("./agent-runtime-model-catalog");

function createCodexRuntimeAdapter({
  id = "codex",
  displayName = "Codex",
} = {}) {
  return {
    id,
    displayName,
    getCapabilities() {
      return getAgentRuntimeCapabilities(id);
    },
    async getRuntimeListEntry() {
      return buildRuntimeListEntry({
        id,
        status: "ready",
        capabilities: getAgentRuntimeCapabilities(id),
        modelCatalog: createCodexModelCatalog(),
      });
    },
    shouldHandleRuntime(agentRuntime) {
      return agentRuntime === id;
    },
    async handleRuntimeRequest({
      rawMessage,
      sendToRuntime,
    } = {}) {
      if (typeof sendToRuntime !== "function") {
        throw new Error("Codex runtime adapter requires a sendToRuntime callback.");
      }
      sendToRuntime(rawMessage);
      return { forwarded: true };
    },
  };
}

module.exports = {
  createCodexRuntimeAdapter,
};
