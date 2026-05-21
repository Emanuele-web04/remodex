// FILE: claude-models.test.js
// Purpose: Verifies Claude Code model metadata and executable resolution helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/claude-models

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  CLAUDE_MODELS,
  normalizeClaudeEffort,
  readModelProvider,
  resolveClaudeCodeExecutable,
} = require("../src/claude-models");

test("Claude model list exposes provider metadata and effort options", () => {
  assert.deepEqual(CLAUDE_MODELS.map((model) => model.displayName), [
    "Claude Opus 4.7",
    "Claude Opus 4.6",
    "Claude Opus 4.5",
    "Claude Sonnet 4.6",
    "Claude Haiku 4.5",
  ]);
  assert.equal(CLAUDE_MODELS.every((model) => model.modelProvider === "claude"), true);
  assert.equal(CLAUDE_MODELS[0].supportedReasoningEfforts.at(-1).reasoningEffort, "xhigh");
});

test("readModelProvider tolerates legacy and harness spelling", () => {
  assert.equal(readModelProvider({}), "codex");
  assert.equal(readModelProvider({ model_provider: "claude-code" }), "claude");
  assert.equal(readModelProvider({ harness: "claude" }), "claude");
});

test("normalizeClaudeEffort preserves xhigh and accepts explicit max", () => {
  assert.equal(normalizeClaudeEffort("low"), "low");
  assert.equal(normalizeClaudeEffort("xhigh"), "xhigh");
  assert.equal(normalizeClaudeEffort("extra-high"), "xhigh");
  assert.equal(normalizeClaudeEffort("max"), "max");
});

test("resolveClaudeCodeExecutable respects feature disable flag", () => {
  const result = resolveClaudeCodeExecutable({
    env: { REMODEX_CLAUDE_CODE_ENABLED: "0" },
  });
  assert.equal(result.available, false);
  assert.match(result.reason, /disabled/i);
});

test("resolveClaudeCodeExecutable resolves command through PATH", () => {
  const result = resolveClaudeCodeExecutable({
    env: { REMODEX_CLAUDE_CODE_COMMAND: "claude" },
    execFileSyncImpl(command, args) {
      assert.equal(command, "which");
      assert.deepEqual(args, ["claude"]);
      return "/usr/local/bin/claude\n";
    },
  });
  assert.deepEqual(result, {
    available: true,
    command: "claude",
    path: "/usr/local/bin/claude",
    reason: "",
  });
});

test("resolveClaudeCodeExecutable honors injected fs for path commands", () => {
  const result = resolveClaudeCodeExecutable({
    env: { REMODEX_CLAUDE_CODE_COMMAND: "/opt/bin/claude" },
    fsImpl: {
      accessSync(command, mode) {
        assert.equal(command, "/opt/bin/claude");
        assert.equal(mode, 1);
      },
    },
  });

  assert.deepEqual(result, {
    available: true,
    command: "/opt/bin/claude",
    path: "/opt/bin/claude",
    reason: "",
  });
});
