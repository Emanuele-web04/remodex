const assert = require("node:assert/strict");
const test = require("node:test");

const { forEachThreadRowInResponse } = require("../src/thread-row-enrichment");

test("visits every thread row shape app-server can return", () => {
  for (const key of ["data", "items", "threads"]) {
    const envelope = { result: { [key]: [{ id: "a" }, { id: "b" }] } };
    const seen = [];
    forEachThreadRowInResponse("thread/list", envelope, (thread) => seen.push(thread.id));
    assert.deepEqual(seen, ["a", "b"], `thread/list rows under result.${key}`);
  }

  for (const method of ["thread/read", "thread/resume"]) {
    const envelope = { result: { thread: { id: "single" } } };
    const seen = [];
    forEachThreadRowInResponse(method, envelope, (thread) => seen.push(thread.id));
    assert.deepEqual(seen, ["single"], method);
  }
});

test("skips errors, unrelated methods, and non-object rows", () => {
  const visits = [];
  const visit = (thread) => visits.push(thread);

  forEachThreadRowInResponse("thread/list", { error: { code: -32000 }, result: { data: [{ id: "a" }] } }, visit);
  forEachThreadRowInResponse("thread/start", { result: { data: [{ id: "a" }] } }, visit);
  forEachThreadRowInResponse("thread/list", { result: null }, visit);
  forEachThreadRowInResponse("thread/list", { result: { data: [null, "row", 7] } }, visit);
  forEachThreadRowInResponse("thread/read", { result: { thread: null } }, visit);
  forEachThreadRowInResponse("thread/list", { result: { data: [{ id: "a" }] } }, null);

  assert.deepEqual(visits, []);
});
