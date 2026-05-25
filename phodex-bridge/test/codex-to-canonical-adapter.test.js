// FILE: codex-to-canonical-adapter.test.js
// Purpose: Verifies fixture-style Codex notification conversion into canonical Remodex events.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/codex-to-canonical-adapter, ../src/canonical-events

const test = require("node:test");
const assert = require("node:assert/strict");

const { convertCodexNotificationToCanonical } = require("../src/codex-to-canonical-adapter");
const { validateCanonicalEvent } = require("../src/canonical-events");

test("codex adapter maps turn lifecycle notifications to canonical events", () => {
  const canonical = convertFixture({
    method: "turn/started",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
    },
  });

  assert.equal(canonical.method, "remodex/event/turn_started");
  assert.equal(canonical.params.threadId, "thread-1");
  assert.equal(canonical.params.agentSessionId, "agent-session-thread-1");
  assert.deepEqual(validateCanonicalEvent(canonical), { valid: true });
});

test("codex adapter maps assistant deltas to canonical assistant_delta", () => {
  const canonical = convertFixture({
    method: "codex/event/agent_message_content_delta",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      delta: "Hello",
    },
  });

  assert.equal(canonical.method, "remodex/event/assistant_delta");
  assert.equal(canonical.params.itemId, "item-1");
  assert.equal(canonical.params.payload.delta, "Hello");
  assert.equal(canonical.params.payload.sourceMethod, "codex/event/agent_message_content_delta");
});

test("codex adapter maps assistant item completions to canonical assistant_completed", () => {
  const canonical = convertFixture({
    method: "item/completed",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
      item: {
        id: "assistant-1",
        type: "agent_message",
        role: "assistant",
        text: "Done.",
      },
    },
  });

  assert.equal(canonical.method, "remodex/event/assistant_completed");
  assert.equal(canonical.params.itemId, "assistant-1");
  assert.equal(canonical.params.payload.text, "Done.");
});

test("codex adapter maps tool activity and diffs to canonical events", () => {
  const toolStarted = convertFixture({
    method: "codex/event/exec_command_begin",
    params: {
      threadId: "thread-tools",
      turnId: "turn-tools",
      itemId: "tool-1",
      command: "git status",
    },
  });
  const toolDelta = convertFixture({
    method: "codex/event/exec_command_output_delta",
    params: {
      threadId: "thread-tools",
      turnId: "turn-tools",
      itemId: "tool-1",
      chunk: "On branch main",
    },
  });
  const diff = convertFixture({
    method: "turn/diff/updated",
    params: {
      threadId: "thread-tools",
      turnId: "turn-tools",
      diff: "diff --git a/file b/file",
    },
  });

  assert.equal(toolStarted.method, "remodex/event/tool_started");
  assert.equal(toolStarted.params.payload.command, "git status");
  assert.equal(toolDelta.method, "remodex/event/tool_delta");
  assert.equal(toolDelta.params.payload.chunk, "On branch main");
  assert.equal(diff.method, "remodex/event/diff_updated");
});

test("codex adapter ignores responses and unknown notifications", () => {
  assert.equal(convertFixture({
    id: "thread-list-1",
    result: { data: [] },
  }), null);
  assert.equal(convertFixture({
    method: "session/unknown",
    params: {},
  }), null);
});

function convertFixture(message) {
  return convertCodexNotificationToCanonical(JSON.stringify(message), {
    now: () => "2026-05-23T00:00:00.000Z",
    resolveAgentSessionId({ threadId }) {
      return threadId ? `agent-session-${threadId}` : "";
    },
  });
}
