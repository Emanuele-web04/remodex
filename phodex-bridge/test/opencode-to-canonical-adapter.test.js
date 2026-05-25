// FILE: opencode-to-canonical-adapter.test.js
// Purpose: Verifies OpenCode SSE fixtures convert into Remodex canonical bridge events.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-to-canonical-adapter

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  PERMISSION_REQUEST_METHOD,
  convertOpenCodeEventToCanonical,
  createOpenCodeCanonicalState,
} = require("../src/opencode-to-canonical-adapter");
const { validateCanonicalEvent } = require("../src/canonical-events");

test("OpenCode adapter maps message text and reasoning deltas to canonical assistant_delta", () => {
  const state = createOpenCodeCanonicalState();

  assert.deepEqual(convertFixture({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_123",
      part: {
        id: "prt_text",
        sessionID: "ses_123",
        messageID: "msg_assistant",
        type: "text",
        text: "",
      },
      time: 1,
    },
  }, state), []);

  const textDelta = convertFixture({
    type: "message.part.delta",
    properties: {
      sessionID: "ses_123",
      messageID: "msg_assistant",
      partID: "prt_text",
      field: "text",
      delta: "Hello",
    },
  }, state);

  assert.equal(textDelta.length, 1);
  assert.equal(textDelta[0].method, "remodex/event/assistant_delta");
  assert.equal(textDelta[0].params.itemId, "msg_assistant");
  assert.equal(textDelta[0].params.payload.delta, "Hello");
  assert.deepEqual(validateCanonicalEvent(textDelta[0]), { valid: true });

  assert.deepEqual(convertFixture({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_123",
      part: {
        id: "prt_reasoning",
        sessionID: "ses_123",
        messageID: "msg_assistant",
        type: "reasoning",
        text: "",
      },
      time: 1,
    },
  }, state), []);

  const reasoningDelta = convertFixture({
    type: "message.part.delta",
    properties: {
      sessionID: "ses_123",
      messageID: "msg_assistant",
      partID: "prt_reasoning",
      field: "text",
      delta: "Thinking",
    },
  }, state);

  assert.equal(reasoningDelta[0].method, "remodex/event/assistant_delta");
  assert.equal(reasoningDelta[0].params.itemId, "prt_reasoning");
  assert.equal(reasoningDelta[0].params.payload.reasoning, "Thinking");
});

test("OpenCode adapter preserves whitespace in streamed text deltas", () => {
  const state = createOpenCodeCanonicalState();
  convertFixture({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_123",
      part: {
        id: "prt_text",
        sessionID: "ses_123",
        messageID: "msg_spaced",
        type: "text",
        text: "",
      },
      time: 1,
    },
  }, state);

  const rendered = [
    "Hey",
    ".",
    " How",
    " can",
    " I",
    " help",
    "?",
  ].flatMap((delta) => convertFixture({
    type: "message.part.delta",
    properties: {
      sessionID: "ses_123",
      messageID: "msg_spaced",
      partID: "prt_text",
      field: "text",
      delta,
    },
  }, state));

  assert.equal(
    rendered.map((message) => message.params.payload.delta).join(""),
    "Hey. How can I help?"
  );

  const completed = convertFixture({
    type: "message.updated",
    properties: {
      sessionID: "ses_123",
      info: {
        id: "msg_spaced",
        sessionID: "ses_123",
        role: "assistant",
        time: { created: 1, completed: 2 },
        finish: "stop",
      },
    },
  }, state);

  assert.equal(completed[0].params.payload.text, "Hey. How can I help?");
});

test("OpenCode adapter maps completion, diff, tools, and errors to canonical events", () => {
  const state = createOpenCodeCanonicalState();
  convertFixture({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_123",
      part: {
        id: "prt_text",
        sessionID: "ses_123",
        messageID: "msg_done",
        type: "text",
        text: "",
      },
      time: 1,
    },
  }, state);
  convertFixture({
    type: "message.part.delta",
    properties: {
      sessionID: "ses_123",
      messageID: "msg_done",
      partID: "prt_text",
      field: "text",
      delta: "Done",
    },
  }, state);

  const completed = convertFixture({
    type: "message.updated",
    properties: {
      sessionID: "ses_123",
      info: {
        id: "msg_done",
        sessionID: "ses_123",
        role: "assistant",
        time: { created: 1, completed: 2 },
        finish: "stop",
      },
    },
  }, state);
  const diff = convertFixture({
    type: "session.diff",
    properties: {
      sessionID: "ses_123",
      diff: [{ path: "README.md", type: "modified" }],
    },
  }, state);
  const tool = convertFixture({
    type: "session.next.tool.called",
    properties: {
      sessionID: "ses_123",
      callID: "call_1",
      tool: "shell",
      input: { command: "git status" },
      provider: { executed: false },
    },
  }, state);
  const error = convertFixture({
    type: "session.error",
    properties: {
      sessionID: "ses_123",
      error: { name: "ProviderAuthError", message: "Login required" },
    },
  }, state);

  assert.equal(completed[0].method, "remodex/event/assistant_completed");
  assert.equal(completed[0].params.itemId, "msg_done");
  assert.equal(completed[0].params.payload.text, "Done");
  assert.equal(diff[0].method, "remodex/event/diff_updated");
  assert.deepEqual(diff[0].params.payload.diff, [{ path: "README.md", type: "modified" }]);
  assert.equal(tool[0].method, "remodex/event/tool_started");
  assert.equal(tool[0].params.payload.toolName, "shell");
  assert.equal(error[0].method, "remodex/event/error");
  assert.equal(error[0].params.payload.message, "Login required");
});

test("OpenCode adapter maps permission requests without auto-allowing them", () => {
  const permission = convertFixture({
    type: "permission.asked",
    properties: {
      id: "per_123",
      sessionID: "ses_123",
      permission: "edit",
      patterns: ["src/**"],
      metadata: { description: "Edit files" },
      always: ["edit"],
      tool: {
        messageID: "msg_tool",
        callID: "call_1",
      },
    },
  }, createOpenCodeCanonicalState());

  assert.equal(permission.length, 1);
  assert.equal(permission[0].method, PERMISSION_REQUEST_METHOD);
  assert.equal(permission[0].id, "per_123");
  assert.equal(permission[0].params.permissionId, "per_123");
  assert.equal(permission[0].params.payload.request.permissions.edit, true);
  assert.equal(permission[0].params.payload.request.toolName, "edit");
});

function convertFixture(event, state) {
  return convertOpenCodeEventToCanonical(event, {
    threadId: "thread-opencode",
    agentSessionId: "ses_123",
    turnId: "turn-123",
    state,
    now: () => "2026-05-24T00:00:00.000Z",
  });
}
