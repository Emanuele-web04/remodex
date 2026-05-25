// FILE: workspace-checkpoints.test.js
// Purpose: Verifies git checkpoint capture, diff, and missing-checkpoint handling.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, child_process, ../src/workspace-checkpoints

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("node:child_process");
const {
  workspaceCheckpointCapture,
  workspaceCheckpointCopy,
  workspaceCheckpointDiff,
} = require("../src/workspace-checkpoints");

test("workspaceCheckpointCapture stores a turn checkpoint and diffs against it", async () => {
  const repoRoot = makeTempRepo();
  const threadId = "thread-checkpoint-1";
  const turnId = "turn-1";

  const first = await workspaceCheckpointCapture(repoRoot, {
    threadId,
    turnId,
    checkpointKind: "turnStart",
  });
  assert.ok(first.commit);
  assert.match(first.checkpointRef, /refs\/remodex\/checkpoints/);

  fs.writeFileSync(path.join(repoRoot, "README.md"), "# Updated\n");
  git(repoRoot, "add", "README.md");

  const second = await workspaceCheckpointCapture(repoRoot, {
    threadId,
    turnId,
    checkpointKind: "turnEnd",
  });
  assert.ok(second.commit);
  assert.notEqual(first.commit, second.commit);

  const diff = await workspaceCheckpointDiff(repoRoot, {
    threadId,
    turnId,
    fromCheckpointKind: "turnStart",
    toCheckpointKind: "turnEnd",
  });
  assert.match(diff.diff, /Updated/);
});

test("workspaceCheckpointCopy reports missing source checkpoints without throwing", async () => {
  const repoRoot = makeTempRepo();
  const result = await workspaceCheckpointCopy(repoRoot, {
    threadId: "thread-missing",
    turnId: "turn-missing",
    sourceCheckpointKind: "turnStart",
    checkpointKind: "turnEnd",
  });

  assert.equal(result.copied, false);
  assert.match(result.sourceCheckpointRef, /refs\/remodex\/checkpoints/);
});

test("workspaceCheckpointDiff rejects missing checkpoint refs", async () => {
  const repoRoot = makeTempRepo();

  await assert.rejects(
    () => workspaceCheckpointDiff(repoRoot, {
      threadId: "thread-missing",
      turnId: "turn-missing",
      fromCheckpointKind: "turnStart",
      toCheckpointKind: "turnEnd",
    }),
    (error) => error.errorCode === "checkpoint_missing"
  );
});

function makeTempRepo() {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-workspace-checkpoints-"));
  git(repoDir, "init", "-b", "main");
  git(repoDir, "config", "user.name", "Remodex Tests");
  git(repoDir, "config", "user.email", "tests@example.com");
  fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\n");
  git(repoDir, "add", "README.md");
  git(repoDir, "commit", "-m", "Initial commit");
  return repoDir;
}

function git(cwd, ...args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
  }).trim();
}
