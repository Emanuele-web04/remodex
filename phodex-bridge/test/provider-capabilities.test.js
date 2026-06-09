// FILE: provider-capabilities.test.js
// Purpose: Verifies model-level capability resolution and per-provider capability defaults.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/provider-capabilities

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  resolveModelCapabilities,
  resolveOpenCodeCatalogCapabilities,
} = require("../src/provider-capabilities");

test("Codex provider has standard capabilities (no agent selection)", () => {
  const capabilities = resolveModelCapabilities("codex", {});
  assert.equal(capabilities.supportsFastMode, true);
  assert.equal(capabilities.supportsPlanMode, true);
  assert.equal(capabilities.supportsAgentSelection, false);
  assert.equal(capabilities.supportsVoice, true);
  assert.equal(capabilities.supportsDesktopHandoff, true);
  assert.equal(capabilities.supportsWorktree, true);
  assert.equal(capabilities.supportsFork, true);
  assert.equal(capabilities.supportsApprovals, true);
  assert.equal(capabilities.supportsStreamingTools, true);
  assert.equal(capabilities.supportsSlashCommands, true);
  assert.equal(capabilities.supportsMCP, true);
});

test("OpenCode provider has agent selection, plan mode, and handoff enabled; fast/voice/worktree disabled", () => {
  const capabilities = resolveModelCapabilities("opencode", {});
  assert.equal(capabilities.supportsAgentSelection, true);
  assert.equal(capabilities.supportsFastMode, false);
  assert.equal(capabilities.supportsPlanMode, true);
  assert.equal(capabilities.supportsVoice, false);
  assert.equal(capabilities.supportsDesktopHandoff, true);
  assert.equal(capabilities.supportsWorktree, false);
  assert.equal(capabilities.supportsFork, true);
  assert.equal(capabilities.supportsApprovals, true);
  assert.equal(capabilities.supportsStreamingTools, true);
  assert.equal(capabilities.supportsSlashCommands, true);
  assert.equal(capabilities.supportsMCP, false);
  assert.equal(capabilities.supportsSkillFileInjection, true);
  assert.equal(capabilities.supportsImageAttachments, true);
});

test("reasoning effort enabled when model has supportedReasoningEfforts", () => {
  const capabilities = resolveModelCapabilities("opencode", {
    supportedReasoningEfforts: [{ reasoningEffort: "high" }],
  });
  assert.equal(capabilities.supportsReasoningEffort, true);
});

test("reasoning effort disabled when supportedReasoningEfforts is empty", () => {
  const capabilities = resolveModelCapabilities("opencode", {
    supportedReasoningEfforts: [],
  });
  assert.equal(capabilities.supportsReasoningEffort, false);
});

test("reasoning effort disabled when model data is null", () => {
  const capabilities = resolveModelCapabilities("opencode", null);
  assert.equal(capabilities.supportsReasoningEffort, false);
});

test("reasoning effort enabled from reasoningEfforts alt field", () => {
  const capabilities = resolveModelCapabilities("opencode", {
    reasoningEfforts: [{ reasoningEffort: "medium" }],
  });
  assert.equal(capabilities.supportsReasoningEffort, true);
});

test("reasoning effort enabled from boolean hasReasoning", () => {
  const capabilities = resolveModelCapabilities("opencode", {
    hasReasoning: true,
  });
  assert.equal(capabilities.supportsReasoningEffort, true);
});

test("reasoning effort enabled from boolean supportsReasoning", () => {
  const capabilities = resolveModelCapabilities("opencode", {
    supportsReasoning: true,
  });
  assert.equal(capabilities.supportsReasoningEffort, true);
});

test("unknown provider defaults to Codex capabilities", () => {
  const capabilities = resolveModelCapabilities("", {});
  assert.equal(capabilities.supportsFastMode, true);
  assert.equal(capabilities.supportsAgentSelection, false);
  assert.equal(capabilities.supportsVoice, true);
});

test("OpenCode MCP is greyed in catalog (configured on Mac, not in Remodex)", () => {
  const capabilities = resolveModelCapabilities("opencode", {});
  assert.equal(capabilities.supportsMCP, false);
});

test("Codex MCP is enabled", () => {
  const capabilities = resolveModelCapabilities("codex", {});
  assert.equal(capabilities.supportsMCP, true);
});

test("Codex supports structured skill input on turn/start", () => {
  const capabilities = resolveModelCapabilities("codex", {});
  assert.equal(capabilities.supportsStructuredSkillInput, true);
});

test("OpenCode does not enable structured skill input until SDK supports skills[] in prompt (RP-SKILL-3, gated pending upstream)", () => {
  const capabilities = resolveModelCapabilities("opencode", {});
  assert.equal(capabilities.supportsStructuredSkillInput, false);
  assert.equal(capabilities.supportsSkillAutocomplete, true);
});

test("OpenCode catalog advertises supportsDesktopHandoff after PR8 sign-off", () => {
  assert.equal(resolveOpenCodeCatalogCapabilities({}).supportsDesktopHandoff, true);
  assert.equal(
    resolveModelCapabilities("opencode", {}, {}).supportsDesktopHandoff,
    true,
  );
});

test("OpenCode advertises supportsSlashCommandExecute for command/execute RPC", () => {
  const capabilities = resolveModelCapabilities("opencode", {});
  assert.equal(capabilities.supportsSlashCommandExecute, true);
});

test("Codex does not advertise supportsSlashCommandExecute", () => {
  const capabilities = resolveModelCapabilities("codex", {});
  assert.equal(capabilities.supportsSlashCommandExecute, false);
});

test("OpenCode catalog snapshot matches docs/contracts/bridge-rpc.md example (PR1)", () => {
  const capabilities = resolveOpenCodeCatalogCapabilities({});
  const expected = {
    supportsAgentSelection: true,
    supportsReasoningEffort: false,
    supportsFastMode: false,
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
    supportsStructuredSkillInput: false,
    supportsSkillFileInjection: true,
    supportsImageAttachments: true,
    supportsSteer: false,
    supportsQueue: true,
    supportsAccessMode: false,
  };
  assert.deepEqual(capabilities, expected);
});
