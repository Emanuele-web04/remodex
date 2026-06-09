// FILE: apply-patch-changes.test.js
// Purpose: Verifies apply_patch DSL parsing into fileChange records, including
//          add/update/delete/rename hunks, path normalization, and malformed input.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/apply-patch-changes

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  parseApplyPatchChanges,
  buildApplyPatchFileChangeItem,
} = require("../src/apply-patch-changes");

// --- parseApplyPatchChanges ---

test("parses an add-file hunk with additions counted", () => {
  const patch = [
    "*** Begin Patch",
    "*** Add File: src/new.js",
    "+const x = 1;",
    "+module.exports = x;",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  const change = changes[0];
  assert.equal(change.path, "src/new.js");
  assert.equal(change.kind, "add");
  assert.equal(change.additions, 2);
  assert.equal(change.deletions, 0);
  assert.ok(change.diff.includes("diff --git a/src/new.js b/src/new.js"));
  assert.ok(change.diff.includes("new file mode 100644"));
  assert.ok(change.diff.includes("--- /dev/null"));
  assert.ok(change.diff.includes("+++ b/src/new.js"));
  assert.ok(change.diff.includes("+const x = 1;"));
});

test("parses an update-file hunk with mixed additions and deletions", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: lib/util.js",
    "@@ function greet()",
    "-const greeting = 'hi';",
    "+const greeting = 'hello';",
    " return greeting;",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  const change = changes[0];
  assert.equal(change.kind, "update");
  assert.equal(change.path, "lib/util.js");
  assert.equal(change.additions, 1);
  assert.equal(change.deletions, 1);
  assert.ok(change.diff.includes("--- a/lib/util.js"));
  assert.ok(change.diff.includes("+++ b/lib/util.js"));
  assert.ok(change.diff.includes("@@ function greet()"));
});

test("update hunk without @@ markers gets a synthetic @@ header", () => {
  const patch = [
    "*** Update File: a.txt",
    "-old",
    "+new",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch);
  const lines = change.diff.split("\n");
  assert.ok(lines.includes("@@"));
  assert.ok(lines.indexOf("@@") < lines.indexOf("-old"));
});

test("parses a delete-file hunk with no body", () => {
  const patch = [
    "*** Begin Patch",
    "*** Delete File: docs/old.md",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  const change = changes[0];
  assert.equal(change.kind, "delete");
  assert.equal(change.path, "docs/old.md");
  assert.equal(change.additions, 0);
  assert.equal(change.deletions, 0);
  assert.ok(change.diff.includes("deleted file mode 100644"));
  assert.ok(change.diff.includes("--- a/docs/old.md"));
  assert.ok(change.diff.includes("+++ /dev/null"));
});

test("parses an update with move-to as a rename", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: src/old-name.js",
    "*** Move to: src/new-name.js",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  const change = changes[0];
  assert.equal(change.kind, "rename");
  assert.equal(change.path, "src/new-name.js");
  assert.ok(change.diff.includes("diff --git a/src/old-name.js b/src/new-name.js"));
  assert.ok(change.diff.includes("rename from src/old-name.js"));
  assert.ok(change.diff.includes("rename to src/new-name.js"));
  assert.equal(change.diff.includes("--- a/"), false);
});

test("rename with body edits includes file headers and counts", () => {
  const patch = [
    "*** Update File: a.js",
    "*** Move to: b.js",
    "-old line",
    "+new line",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch);
  assert.equal(change.kind, "rename");
  assert.equal(change.additions, 1);
  assert.equal(change.deletions, 1);
  assert.ok(change.diff.includes("--- a/a.js"));
  assert.ok(change.diff.includes("+++ b/b.js"));
});

test("parses multiple hunks in one patch in order", () => {
  const patch = [
    "*** Begin Patch",
    "*** Add File: added.txt",
    "+hello",
    "*** Update File: changed.txt",
    "-x",
    "+y",
    "*** Delete File: removed.txt",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.deepEqual(
    changes.map((c) => [c.kind, c.path]),
    [["add", "added.txt"], ["update", "changed.txt"], ["delete", "removed.txt"]]
  );
});

test("normalizes absolute paths inside cwd to relative paths", () => {
  const patch = [
    "*** Add File: /repo/project/src/file.js",
    "+content",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch, { cwd: "/repo/project" });
  assert.equal(change.path, "src/file.js");
});

test("keeps absolute paths outside cwd untouched", () => {
  const patch = [
    "*** Add File: /elsewhere/file.js",
    "+content",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch, { cwd: "/repo/project" });
  assert.equal(change.path, "/elsewhere/file.js");
});

test("keeps relative paths as-is regardless of cwd", () => {
  const patch = [
    "*** Add File: nested/file.js",
    "+content",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch, { cwd: "/repo/project" });
  assert.equal(change.path, "nested/file.js");
});

test("strips leading slashes in git diff paths but not in change path", () => {
  const patch = [
    "*** Add File: /abs/file.js",
    "+content",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch);
  assert.equal(change.path, "/abs/file.js");
  assert.ok(change.diff.includes("diff --git a/abs/file.js b/abs/file.js"));
});

test("filters out body-less update hunks that change nothing", () => {
  const patch = [
    "*** Update File: untouched.txt",
    " context only",
    "*** End Patch",
  ].join("\n");

  assert.deepEqual(parseApplyPatchChanges(patch), []);
});

test("does not count +++/--- header lines as additions or deletions", () => {
  const patch = [
    "*** Update File: f.txt",
    "--- a/f.txt",
    "+++ b/f.txt",
    "+real addition",
    "*** End Patch",
  ].join("\n");

  const [change] = parseApplyPatchChanges(patch);
  assert.equal(change.additions, 1);
  assert.equal(change.deletions, 0);
});

test("ignores hunks with empty or whitespace-only paths", () => {
  const patch = [
    "*** Add File: ",
    "+orphan line",
    "*** Update File:    ",
    "+another orphan",
    "*** End Patch",
  ].join("\n");

  assert.deepEqual(parseApplyPatchChanges(patch), []);
});

test("stops parsing at End Patch and ignores trailing content", () => {
  const patch = [
    "*** Add File: a.txt",
    "+kept",
    "*** End Patch",
    "*** Add File: after.txt",
    "+ignored",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].path, "a.txt");
});

test("ignores unknown *** directives and content before any hunk", () => {
  const patch = [
    "stray prologue line",
    "*** Begin Patch",
    "*** Something Unknown: x",
    "*** Add File: a.txt",
    "+line",
    "*** End Patch",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].additions, 1);
});

test("handles CRLF line endings", () => {
  const patch = "*** Add File: win.txt\r\n+line\r\n*** End Patch\r\n";
  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].path, "win.txt");
  assert.equal(changes[0].additions, 1);
});

test("returns empty array for malformed or non-string payloads", () => {
  assert.deepEqual(parseApplyPatchChanges(""), []);
  assert.deepEqual(parseApplyPatchChanges(null), []);
  assert.deepEqual(parseApplyPatchChanges(undefined), []);
  assert.deepEqual(parseApplyPatchChanges(42), []);
  assert.deepEqual(parseApplyPatchChanges("just some random text\nno directives"), []);
});

test("patch without End Patch still flushes the trailing hunk", () => {
  const patch = [
    "*** Add File: trailing.txt",
    "+line",
  ].join("\n");

  const changes = parseApplyPatchChanges(patch);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].path, "trailing.txt");
});

// --- buildApplyPatchFileChangeItem ---

test("builds a fileChange item from a patch payload", () => {
  const item = buildApplyPatchFileChangeItem({
    callId: "call-1",
    patch: "*** Add File: a.txt\n+x\n*** End Patch",
    status: "completed",
    cwd: "/repo",
  });

  assert.equal(item.id, "call-1");
  assert.equal(item.type, "fileChange");
  assert.equal(item.status, "completed");
  assert.equal(item.changes.length, 1);
  assert.equal(item.changes[0].path, "a.txt");
});

test("falls back to idFallback and default status when fields are blank", () => {
  const item = buildApplyPatchFileChangeItem({
    callId: "   ",
    status: "",
    patch: "*** Delete File: gone.txt\n*** End Patch",
    idFallback: "fallback-id",
  });

  assert.equal(item.id, "fallback-id");
  assert.equal(item.status, "completed");
  assert.equal(item.changes[0].kind, "delete");
});

test("returns null when the patch yields no changes", () => {
  assert.equal(buildApplyPatchFileChangeItem({ patch: "" }), null);
  assert.equal(buildApplyPatchFileChangeItem({ patch: "garbage" }), null);
  assert.equal(buildApplyPatchFileChangeItem(), null);
});

test("normalizes absolute patch paths against the provided cwd", () => {
  const item = buildApplyPatchFileChangeItem({
    callId: "c",
    patch: "*** Update File: /work/dir/sub/f.js\n-a\n+b\n*** End Patch",
    cwd: "/work/dir",
  });
  assert.equal(item.changes[0].path, "sub/f.js");
});
