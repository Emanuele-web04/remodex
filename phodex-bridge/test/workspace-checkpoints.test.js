// FILE: workspace-checkpoints.test.js
// Purpose: Verifies git checkpoint capture, copy, diff, restore preview, and
//          destructive restore safety against real temporary git repos.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, child_process, fs, os, path,
//             ../src/workspace-checkpoints

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  workspaceCheckpointCapture,
  workspaceCheckpointCopy,
  workspaceCheckpointDiff,
  workspaceCheckpointRestorePreview,
  workspaceCheckpointRestoreApply,
} = require("../src/workspace-checkpoints");

const tempDirs = [];

function makeRepo({ withInitialCommit = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkpoint-test-"));
  tempDirs.push(dir);
  gitIn(dir, "init", "--quiet");
  gitIn(dir, "config", "user.email", "test@example.com");
  gitIn(dir, "config", "user.name", "Test");
  if (withInitialCommit) {
    fs.writeFileSync(path.join(dir, "base.txt"), "base\n");
    gitIn(dir, "add", "-A");
    gitIn(dir, "commit", "--quiet", "-m", "initial");
  }
  return dir;
}

function gitIn(dir, ...args) {
  return execFileSync("git", args, { cwd: dir, encoding: "utf8" });
}

test.after(() => {
  for (const dir of tempDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("capture creates a checkpoint ref containing the working tree", async () => {
  const repo = makeRepo();
  fs.writeFileSync(path.join(repo, "new.txt"), "hello\n");
  const result = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });

  assert.equal(result.repoRoot, repo);
  assert.equal(result.checkpointKind, "turnEnd");
  assert.equal(result.threadId, "t1");
  assert.equal(result.turnId, "turn-1");
  assert.match(result.checkpointRef, /^refs\/remodex\/checkpoints\//);
  assert.match(result.commit, /^[0-9a-f]{40}$/);

  const listing = gitIn(repo, "ls-tree", "--name-only", result.commit);
  assert.ok(listing.includes("new.txt"));
  assert.ok(listing.includes("base.txt"));
});

test("capture works in a repo without any HEAD commit", async () => {
  const repo = makeRepo({ withInitialCommit: false });
  fs.writeFileSync(path.join(repo, "only.txt"), "x\n");
  const result = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-0" });
  assert.match(result.commit, /^[0-9a-f]{40}$/);
  const listing = gitIn(repo, "ls-tree", "--name-only", result.commit);
  assert.ok(listing.includes("only.txt"));
});

test("capture does not disturb the working tree index", async () => {
  const repo = makeRepo();
  fs.writeFileSync(path.join(repo, "unstaged.txt"), "u\n");
  await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  const staged = gitIn(repo, "diff", "--name-only", "--cached").trim();
  assert.equal(staged, "");
});

test("capture supports messageStart and turnStart kinds with distinct refs", async () => {
  const repo = makeRepo();
  const a = await workspaceCheckpointCapture(repo, {
    threadId: "t1",
    kind: "messageStart",
    messageId: "m1",
  });
  const b = await workspaceCheckpointCapture(repo, {
    threadId: "t1",
    kind: "turnStart",
    turnId: "turn-1",
  });
  assert.ok(a.checkpointRef.includes("/message-start/"));
  assert.ok(b.checkpointRef.includes("/turn-start/"));
  assert.notEqual(a.checkpointRef, b.checkpointRef);
});

test("capture rejects missing threadId and unsupported kinds", async () => {
  const repo = makeRepo();
  await assert.rejects(
    () => workspaceCheckpointCapture(repo, { turnId: "turn-1" }),
    (err) => err.errorCode === "missing_checkpoint_identifier"
  );
  await assert.rejects(
    () => workspaceCheckpointCapture(repo, { threadId: "t1", kind: "bogus" }),
    (err) => err.errorCode === "invalid_checkpoint_kind"
  );
  await assert.rejects(
    () => workspaceCheckpointCapture(repo, { threadId: "t1", kind: "turnEnd" }),
    (err) => err.errorCode === "missing_checkpoint_identifier"
  );
});

test("capture rejects explicit refs outside the checkpoint namespace", async () => {
  const repo = makeRepo();
  await assert.rejects(
    () => workspaceCheckpointCapture(repo, { checkpointRef: "refs/heads/main" }),
    (err) => err.errorCode === "invalid_checkpoint_ref"
  );
  await assert.rejects(
    () => workspaceCheckpointCapture(repo, {
      checkpointRef: "refs/remodex/checkpoints/../heads/main",
    }),
    (err) => err.errorCode === "invalid_checkpoint_ref"
  );
  await assert.rejects(
    () => workspaceCheckpointCapture(repo, {
      checkpointRef: "refs/remodex/checkpoints/has space",
    }),
    (err) => err.errorCode === "invalid_checkpoint_ref"
  );
});

test("copy duplicates an existing checkpoint to a new ref", async () => {
  const repo = makeRepo();
  const source = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  const result = await workspaceCheckpointCopy(repo, {
    sourceCheckpointRef: source.checkpointRef,
    targetCheckpointRef: "refs/remodex/checkpoints/custom/copy-target",
  });

  assert.equal(result.copied, true);
  assert.equal(result.commit, source.commit);
  assert.equal(result.checkpointRef, "refs/remodex/checkpoints/custom/copy-target");
  const resolved = gitIn(repo, "rev-parse", "refs/remodex/checkpoints/custom/copy-target").trim();
  assert.equal(resolved, source.commit);
});

test("copy of a missing source checkpoint reports copied=false", async () => {
  const repo = makeRepo();
  const result = await workspaceCheckpointCopy(repo, {
    sourceCheckpointRef: "refs/remodex/checkpoints/none/missing",
    targetCheckpointRef: "refs/remodex/checkpoints/none/target",
  });
  assert.equal(result.copied, false);
  assert.equal(result.sourceCheckpointRef, "refs/remodex/checkpoints/none/missing");
});

test("diff reports the patch between two checkpoints", async () => {
  const repo = makeRepo();
  const from = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  fs.writeFileSync(path.join(repo, "base.txt"), "changed\n");
  fs.writeFileSync(path.join(repo, "added.txt"), "added\n");
  const to = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-2" });

  const result = await workspaceCheckpointDiff(repo, {
    fromCheckpointRef: from.checkpointRef,
    toCheckpointRef: to.checkpointRef,
  });
  assert.ok(result.diff.includes("base.txt"));
  assert.ok(result.diff.includes("added.txt"));
  assert.ok(result.diff.includes("+changed"));
  assert.ok(result.diff.includes("-base"));
});

test("diff throws checkpoint_missing when a side is unavailable", async () => {
  const repo = makeRepo();
  const from = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  await assert.rejects(
    () => workspaceCheckpointDiff(repo, {
      fromCheckpointRef: from.checkpointRef,
      toCheckpointRef: "refs/remodex/checkpoints/none/missing",
    }),
    (err) => err.errorCode === "checkpoint_missing"
  );
});

test("restore preview lists affected, staged, and untracked files", async () => {
  const repo = makeRepo();
  const checkpoint = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  fs.writeFileSync(path.join(repo, "base.txt"), "dirty\n");
  fs.writeFileSync(path.join(repo, "staged.txt"), "s\n");
  gitIn(repo, "add", "staged.txt");
  fs.writeFileSync(path.join(repo, "loose.txt"), "l\n");

  const preview = await workspaceCheckpointRestorePreview(repo, {
    targetCheckpointRef: checkpoint.checkpointRef,
  });
  assert.equal(preview.canRestore, true);
  assert.equal(preview.commit, checkpoint.commit);
  assert.deepEqual(preview.affectedFiles, ["base.txt", "loose.txt", "staged.txt"]);
  assert.deepEqual(preview.stagedFiles, ["staged.txt"]);
  assert.deepEqual(preview.untrackedFiles, ["loose.txt"]);
});

test("restore preview throws checkpoint_missing for unknown refs", async () => {
  const repo = makeRepo();
  await assert.rejects(
    () => workspaceCheckpointRestorePreview(repo, {
      targetCheckpointRef: "refs/remodex/checkpoints/none/missing",
    }),
    (err) => err.errorCode === "checkpoint_missing"
  );
});

test("restore apply requires explicit destructive confirmation", async () => {
  const repo = makeRepo();
  const checkpoint = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  for (const confirm of [undefined, false, "true", 1]) {
    await assert.rejects(
      () => workspaceCheckpointRestoreApply(repo, {
        threadId: "t1",
        targetCheckpointRef: checkpoint.checkpointRef,
        confirmDestructiveRestore: confirm,
      }),
      (err) => err.errorCode === "restore_confirmation_required"
    );
  }
});

test("restore apply rewinds tracked edits and removes new untracked files", async () => {
  const repo = makeRepo();
  const checkpoint = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  fs.writeFileSync(path.join(repo, "base.txt"), "dirty\n");
  fs.writeFileSync(path.join(repo, "junk.txt"), "junk\n");
  fs.mkdirSync(path.join(repo, "subdir"));
  fs.writeFileSync(path.join(repo, "subdir", "deep.txt"), "deep\n");

  const result = await workspaceCheckpointRestoreApply(repo, {
    threadId: "t1",
    targetCheckpointRef: checkpoint.checkpointRef,
    confirmDestructiveRestore: true,
  });

  assert.equal(result.success, true);
  assert.equal(result.checkpointRef, checkpoint.checkpointRef);
  assert.match(result.backupCheckpointRef, /\/restore-backup\//);
  assert.match(result.backupCommit, /^[0-9a-f]{40}$/);
  assert.equal(fs.readFileSync(path.join(repo, "base.txt"), "utf8"), "base\n");
  assert.equal(fs.existsSync(path.join(repo, "junk.txt")), false);
  assert.equal(fs.existsSync(path.join(repo, "subdir")), false);
  assert.ok(result.restoredFiles.includes("base.txt"));
  assert.ok(result.restoredFiles.includes("junk.txt"));
});

test("restore apply backup preserves the pre-restore dirty state", async () => {
  const repo = makeRepo();
  const checkpoint = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  fs.writeFileSync(path.join(repo, "pre-restore.txt"), "keep me\n");

  const result = await workspaceCheckpointRestoreApply(repo, {
    threadId: "t1",
    targetCheckpointRef: checkpoint.checkpointRef,
    confirmDestructiveRestore: true,
  });

  assert.equal(fs.existsSync(path.join(repo, "pre-restore.txt")), false);
  const listing = gitIn(repo, "ls-tree", "--name-only", result.backupCommit);
  assert.ok(listing.includes("pre-restore.txt"));
});

test("restore apply does not delete files outside the repo", async () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkpoint-outer-"));
  tempDirs.push(outer);
  const outsideFile = path.join(outer, "outside.txt");
  fs.writeFileSync(outsideFile, "outside\n");
  const repo = path.join(outer, "repo");
  fs.mkdirSync(repo);
  gitIn(repo, "init", "--quiet");
  gitIn(repo, "config", "user.email", "test@example.com");
  gitIn(repo, "config", "user.name", "Test");
  fs.writeFileSync(path.join(repo, "base.txt"), "base\n");
  gitIn(repo, "add", "-A");
  gitIn(repo, "commit", "--quiet", "-m", "initial");

  const checkpoint = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  fs.writeFileSync(path.join(repo, "inside.txt"), "inside\n");
  await workspaceCheckpointRestoreApply(repo, {
    threadId: "t1",
    targetCheckpointRef: checkpoint.checkpointRef,
    confirmDestructiveRestore: true,
  });

  assert.equal(fs.existsSync(path.join(repo, "inside.txt")), false);
  assert.equal(fs.readFileSync(outsideFile, "utf8"), "outside\n");
});

test("restore apply rejects when expectedTargetCommit no longer matches", async () => {
  const repo = makeRepo();
  const checkpoint = await workspaceCheckpointCapture(repo, { threadId: "t1", turnId: "turn-1" });
  fs.writeFileSync(path.join(repo, "drift.txt"), "drift\n");
  const moved = await workspaceCheckpointCapture(repo, {
    checkpointRef: checkpoint.checkpointRef,
  });
  assert.notEqual(moved.commit, checkpoint.commit);

  await assert.rejects(
    () => workspaceCheckpointRestoreApply(repo, {
      threadId: "t1",
      targetCheckpointRef: checkpoint.checkpointRef,
      confirmDestructiveRestore: true,
      expectedTargetCommit: checkpoint.commit,
    }),
    (err) => err.errorCode === "checkpoint_changed"
  );
});

test("restore apply on a missing checkpoint fails before touching the tree", async () => {
  const repo = makeRepo();
  fs.writeFileSync(path.join(repo, "keep.txt"), "keep\n");
  await assert.rejects(
    () => workspaceCheckpointRestoreApply(repo, {
      threadId: "t1",
      targetCheckpointRef: "refs/remodex/checkpoints/none/missing",
      confirmDestructiveRestore: true,
    }),
    (err) => err.errorCode === "checkpoint_missing"
  );
  assert.equal(fs.readFileSync(path.join(repo, "keep.txt"), "utf8"), "keep\n");
});

test("operations on a non-git directory surface git_failed", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkpoint-nogit-"));
  tempDirs.push(dir);
  await assert.rejects(
    () => workspaceCheckpointCapture(dir, { threadId: "t1", turnId: "turn-1" }),
    (err) => err.errorCode === "git_failed"
  );
});
