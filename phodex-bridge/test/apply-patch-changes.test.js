// FILE: apply-patch-changes.test.js
// Purpose: Verifies apply_patch transcript parsing into fileChange-compatible records.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/apply-patch-changes

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildApplyPatchFileChangeItem,
  parseApplyPatchChanges,
} = require("../src/apply-patch-changes");

test("parseApplyPatchChanges converts add and update patch blocks", () => {
  const patch = [
    "*** Begin Patch",
    "*** Add File: src/new.js",
    "+export const ready = true;",
    "*** Update File: src/existing.js",
    " unchanged",
    "-old line",
    "+new line",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 2);
  assert.equal(changes[0].path, "src/new.js");
  assert.equal(changes[0].kind, "add");
  assert.equal(changes[0].additions, 1);
  assert.match(changes[0].diff, /new file mode 100644/);
  assert.equal(changes[1].path, "src/existing.js");
  assert.equal(changes[1].kind, "update");
  assert.equal(changes[1].additions, 1);
  assert.equal(changes[1].deletions, 1);
});

test("parseApplyPatchChanges handles delete and rename operations", () => {
  const patch = [
    "*** Begin Patch",
    "*** Delete File: src/remove.js",
    "*** Update File: src/old.js",
    "*** Move to: src/new.js",
    "+renamed body",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 2);
  assert.equal(changes[0].path, "src/remove.js");
  assert.equal(changes[0].kind, "delete");
  assert.equal(changes[1].path, "src/new.js");
  assert.equal(changes[1].kind, "rename");
});

test("buildApplyPatchFileChangeItem returns null for empty patches", () => {
  assert.equal(buildApplyPatchFileChangeItem({ patch: "" }), null);
  assert.equal(buildApplyPatchFileChangeItem({ patch: "*** Begin Patch\n*** End Patch" }), null);
});

test("buildApplyPatchFileChangeItem wraps parsed changes in a fileChange item", () => {
  const item = buildApplyPatchFileChangeItem({
    callId: "call-1",
    patch: "*** Begin Patch\n*** Add File: README.md\n+# Title\n*** End Patch",
    status: "completed",
  });

  assert.equal(item.id, "call-1");
  assert.equal(item.type, "fileChange");
  assert.equal(item.status, "completed");
  assert.equal(item.changes.length, 1);
  assert.equal(item.changes[0].path, "README.md");
});
