// FILE: canonical-events.test.js
// Purpose: Verifies runtime-neutral Remodex canonical event builders.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/canonical-events

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  CANONICAL_EVENT_TYPES,
  CANONICAL_SCHEMA_VERSION,
  createCanonicalEvent,
  validateCanonicalEvent,
} = require("../src/canonical-events");

test("createCanonicalEvent builds the stable Remodex event envelope", () => {
  const event = createCanonicalEvent({
    type: CANONICAL_EVENT_TYPES.ASSISTANT_DELTA,
    agentRuntime: "opencode",
    threadId: "thread-1",
    agentSessionId: "session-1",
    turnId: "turn-1",
    itemId: "item-1",
    createdAt: "2026-05-23T00:00:00.000Z",
    payload: { delta: "hello" },
  });

  assert.equal(event.jsonrpc, "2.0");
  assert.equal(event.method, "remodex/event/assistant_delta");
  assert.equal(event.params.schemaVersion, CANONICAL_SCHEMA_VERSION);
  assert.equal(event.params.agentRuntime, "opencode");
  assert.equal(event.params.threadId, "thread-1");
  assert.equal(event.params.payload.delta, "hello");
  assert.deepEqual(validateCanonicalEvent(event), { valid: true });
});

test("validateCanonicalEvent rejects raw Codex notifications", () => {
  assert.deepEqual(validateCanonicalEvent({
    method: "codex/event/agent_message_delta",
    params: { delta: "hello" },
  }), {
    valid: false,
    reason: "not_canonical_event",
  });
});
