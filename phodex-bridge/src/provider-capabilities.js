// FILE: provider-capabilities.js
// Purpose: Defines capability flags for runtimes. Used by runtime/catalog and model/list
//          to drive iOS composer visibility/grey-out without hardcoded provider checks.
// Layer: Bridge runtime utility
// Exports: CAPABILITIES, resolveModelCapabilities, resolveOpenCodeCatalogCapabilities, hasReasoningEffort
// Depends on: ./opencode-models

const { CODEX_PROVIDER_ID, OPENCODE_PROVIDER_ID } = require("./opencode-models");


const CAPABILITIES = [
  "supportsAgentSelection",
  "supportsReasoningEffort",
  "supportsFastMode",
  "supportsPlanMode",
  "supportsVoice",
  "supportsDesktopHandoff",
  "supportsWorktree",
  "supportsFork",
  "supportsApprovals",
  "supportsStreamingTools",
  "supportsSlashCommands",
  "supportsSlashCommandExecute",
  "supportsMCP",
  "supportsSkillAutocomplete",
  "supportsStructuredSkillInput",
  "supportsSkillFileInjection",
  "supportsImageAttachments",
  "supportsSteer",
  "supportsQueue",
  "supportsAccessMode",
];

const CODEX_CAPABILITIES = {
  supportsAgentSelection: false,
  supportsReasoningEffort: true,
  supportsFastMode: true,
  supportsPlanMode: true,
  supportsVoice: true,
  supportsDesktopHandoff: true,
  supportsWorktree: true,
  supportsFork: true,
  supportsApprovals: true,
  supportsStreamingTools: true,
  supportsSlashCommands: true,
  supportsSlashCommandExecute: false,
  supportsMCP: true,
  supportsSkillAutocomplete: true,
  supportsStructuredSkillInput: true,
  supportsSkillFileInjection: true,
  supportsImageAttachments: true,
  supportsSteer: true,
  supportsQueue: true,
  supportsAccessMode: true,
};

const OPENCODE_CAPABILITIES = {
  supportsAgentSelection: true,
  supportsReasoningEffort: false,
  supportsFastMode: false,
  // Plan mode maps to OpenCode's built-in read-only "plan" agent for the turn
  // (opencode-provider.js resolvePlanAgentOverride); thread agent is preserved.
  supportsPlanMode: true,
  supportsVoice: false,
  supportsDesktopHandoff: true,
  supportsWorktree: false,
  supportsFork: true,
  supportsApprovals: true,
  supportsStreamingTools: true,
  supportsSlashCommands: true,
  supportsSlashCommandExecute: true,
  supportsMCP: false,
  supportsSkillAutocomplete: true,
  // RP-SKILL-3: kept false pending upstream SDK support for skills:[] (or dedicated skill parts) in
  // session.prompt / V2 prompt input. See opencode-sdk.md for shapes inspected (PromptInput uses only
  // parts: Text|File|Agent|Subtask; V2 Prompt uses text+files/agents/references; no skills array).
  // Bridge now wires conditional skills[] (gated); iOS sends structured items only when flag true.
  // Do not force-enable; catalog test + DISABLE regression cover. Flip only after SDK + device E2E.
  supportsStructuredSkillInput: false,
  supportsSkillFileInjection: true,
  supportsImageAttachments: true,
  supportsSteer: false,
  supportsQueue: true,
  supportsAccessMode: false,
};

function resolveOpenCodeCatalogCapabilities(_env = process.env) {
  return { ...OPENCODE_CAPABILITIES };
}

function resolveModelCapabilities(providerId, modelData = {}, env = process.env) {
  modelData = modelData || {};
  const base =
    providerId === CODEX_PROVIDER_ID
      ? { ...CODEX_CAPABILITIES }
      : providerId === OPENCODE_PROVIDER_ID
        ? resolveOpenCodeCatalogCapabilities(env)
        : { ...CODEX_CAPABILITIES };

  if (Array.isArray(modelData.supportedReasoningEfforts)) {
    base.supportsReasoningEffort = modelData.supportedReasoningEfforts.length > 0;
  }

  const reasoningEffortsAlt = Array.isArray(modelData.reasoningEfforts)
    ? modelData.reasoningEfforts
    : [];
  if (reasoningEffortsAlt.length > 0) {
    base.supportsReasoningEffort = true;
  }

  if (modelData.supportsFastMode === true) {
    base.supportsFastMode = true;
  }

  if (modelData.supportsReasoning !== undefined) {
    base.supportsReasoningEffort = Boolean(modelData.supportsReasoning);
  }

  if (modelData.hasReasoning !== undefined) {
    base.supportsReasoningEffort = Boolean(modelData.hasReasoning);
  }

  return base;
}

function hasReasoningEffort(capabilities) {
  return capabilities?.supportsReasoningEffort === true;
}

module.exports = {
  CAPABILITIES,
  CODEX_CAPABILITIES,
  OPENCODE_CAPABILITIES,
  resolveOpenCodeCatalogCapabilities,
  resolveModelCapabilities,
  hasReasoningEffort,
};
