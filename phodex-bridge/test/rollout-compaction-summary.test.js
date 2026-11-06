const test = require("node:test");
const assert = require("node:assert/strict");
const { createCompactionSummaryFilter } = require("../src/rollout-compaction-summary");

const prefix = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:";
function final(id, text = "## Current progress\nCompleted.") {
  return { type: "response_item", payload: { id, type: "message", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text }] } };
}
const compacted = (message) => ({ type: "compacted", payload: { message } });

test("confirmed compaction matches the full handoff body across telemetry, not a title or suffix", () => {
  for (const [message, suppressed] of [
    ["## Current progress\nCompleted.", true],
    [`${prefix}\n## Current progress\nCompleted.`, true],
    [`${prefix}\r\n## Current progress\r\nCompleted.`, true],
    ["## Current progress\nDifferent content.", false],
    ["Unrecognized wrapper\n## Current progress\nCompleted.", false],
    [`${prefix}\nLonger summary ending in\n## Current progress\nCompleted.`, false],
    [undefined, false],
  ]) {
    const filter = createCompactionSummaryFilter();
    const reply = final("candidate");
    assert.deepEqual(filter.push(reply).entries, []);
    filter.push({ type: "event_msg", payload: { type: "token_count" } });
    filter.push({ type: "token_usage_record", payload: {} });
    const result = filter.push(compacted(message));
    assert.deepEqual(result.suppressedItemIds, suppressed ? ["candidate"] : []);
    assert.equal(result.entries.includes(reply), !suppressed);
  }
});

test("normal final is released before terminal and never suppressed by a later compaction", () => {
  const filter = createCompactionSummaryFilter();
  const reply = final("normal");
  filter.push(reply);
  const terminal = { type: "event_msg", payload: { type: "task_complete", turn_id: "turn" } };
  assert.deepEqual(filter.push(terminal).entries, [reply, terminal]);
  assert.deepEqual(filter.push(compacted("## Current progress\nCompleted.")).suppressedItemIds, []);
});

test("timeout or EOF releases an unconfirmed final once while late compaction can retract its exact ID", () => {
  const filter = createCompactionSummaryFilter();
  const reply = final("late-summary");
  filter.push(reply);
  assert.deepEqual(filter.flush(), [reply]);
  assert.deepEqual(filter.flush(), []);
  assert.deepEqual(filter.push(compacted("## Current progress\nCompleted.")).suppressedItemIds, ["late-summary"]);
});

test("parallel activity and unknown records break adjacency and fail open", () => {
  for (const boundary of [
    { type: "event_msg", payload: { type: "task_started", turn_id: "other-turn" } },
    { type: "response_item", payload: { type: "function_call", name: "test" } },
    { type: "future_record", payload: {} },
  ]) {
    const filter = createCompactionSummaryFilter();
    const reply = final("normal");
    filter.push(reply);
    assert.equal(filter.push(boundary).entries[0], reply);
    assert.deepEqual(filter.push(compacted("## Current progress\nCompleted.")).suppressedItemIds, []);
  }
});

test("successive compactions suppress only their own candidates and preserve a real final", () => {
  const filter = createCompactionSummaryFilter();
  for (const id of ["summary-one", "summary-two"]) {
    filter.push(final(id));
    assert.deepEqual(filter.push(compacted("## Current progress\nCompleted.")).suppressedItemIds, [id]);
  }
  const reply = final("real-final");
  filter.push(reply);
  assert.deepEqual(filter.flush(), [reply]);
});

test("a provider item already confirmed as user-visible is not suppressed by matching compaction text", () => {
  const filter = createCompactionSummaryFilter();
  filter.push({ type: "event_msg", payload: { type: "item_completed", item: { type: "agentMessage", id: "visible-final", text: "## Current progress\nCompleted." } } });
  const reply = final("visible-final");
  assert.deepEqual(filter.push(reply).entries, [reply]);
  assert.deepEqual(filter.push(compacted("## Current progress\nCompleted.")).suppressedItemIds, []);
});

test("event and response copies share compaction evidence and both IDs are retracted", () => {
  const filter = createCompactionSummaryFilter();
  const event = { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "Internal summary" } };
  assert.deepEqual(filter.push(event, { eventItemId: "synthetic-event-id" }).entries, [event]);
  assert.deepEqual(filter.flush(), []);
  assert.deepEqual(filter.push(final("provider-id", "Internal summary")).entries, []);
  const result = filter.push(compacted("Internal summary"));
  assert.deepEqual(result.suppressedItemIds, ["synthetic-event-id", "provider-id"]);
});
