// FILE: runtime-provider-router.test.js
// Purpose: Verifies provider-aware model/thread routing helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/runtime-provider-router

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  mergeModelListResult,
  mergeThreadListResult,
  shouldRouteToClaude,
} = require("../src/runtime-provider-router");

test("mergeModelListResult tags Codex models and appends Claude models", () => {
  const result = mergeModelListResult({
    items: [
      { id: "gpt-5.5", model: "gpt-5.5", displayName: "GPT-5.5" },
    ],
  }, [
    { id: "claude-opus-4-7", model: "claude-opus-4-7", modelProvider: "claude" },
  ]);

  assert.equal(result.items[0].modelProvider, "codex");
  assert.equal(result.items[0].provider, "codex");
  assert.equal(result.items[1].modelProvider, "claude");
});

test("mergeThreadListResult keeps newest provider threads first", () => {
  const result = mergeThreadListResult({
    data: [
      { id: "codex-old", updatedAt: "2026-01-01T00:00:00.000Z" },
    ],
  }, [
    { id: "claude-new", updatedAt: "2026-01-02T00:00:00.000Z", modelProvider: "claude" },
  ]);

  assert.deepEqual(result.data.map((thread) => thread.id), ["claude-new", "codex-old"]);
});

test("shouldRouteToClaude uses request provider or stored thread ownership", () => {
  const provider = {
    ownsThread(threadId) {
      return threadId === "claude-thread";
    },
  };

  assert.equal(shouldRouteToClaude({
    method: "thread/start",
    params: { modelProvider: "claude" },
  }, provider), true);
  assert.equal(shouldRouteToClaude({
    method: "turn/start",
    params: { threadId: "claude-thread" },
  }, provider), true);
  assert.equal(shouldRouteToClaude({
    method: "turn/start",
    params: { threadId: "codex-thread" },
  }, provider), false);
});
