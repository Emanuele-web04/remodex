// FILE: git-handler.test.js
// Purpose: Covers branch parsing and checkout regressions for the local git bridge.
// Layer: Unit Test
// Exports: node:test cases
// Depends on: node:test, assert, child_process, fs, os, git-handler

const assert = require("node:assert/strict");
const test = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const { __test } = require("../src/git-handler");

function git(cwd, ...args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
  }).trim();
}

function makeTempRepo() {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-git-handler-"));
  git(repoDir, "init", "-b", "main");
  git(repoDir, "config", "user.name", "Remodex Tests");
  git(repoDir, "config", "user.email", "tests@example.com");
  fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\n");
  git(repoDir, "add", "README.md");
  git(repoDir, "commit", "-m", "Initial commit");
  git(repoDir, "branch", "feature/clean-switch");
  return repoDir;
}

test("normalizeBranchListEntry strips linked-worktree markers from branch labels", () => {
  assert.deepEqual(__test.normalizeBranchListEntry("+ main"), {
    isCurrent: false,
    isCheckedOutElsewhere: true,
    name: "main",
  });
  assert.deepEqual(__test.normalizeBranchListEntry("* feature/mobile"), {
    isCurrent: true,
    isCheckedOutElsewhere: false,
    name: "feature/mobile",
  });
});

test("gitBranches marks branches that are checked out in another worktree", async () => {
  const repoDir = makeTempRepo();
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-feature`);

  try {
    git(repoDir, "worktree", "add", siblingWorktree, "feature/clean-switch");

    const result = await __test.gitBranches(repoDir);

    assert.deepEqual(result.branchesCheckedOutElsewhere, ["feature/clean-switch"]);
    assert.ok(result.branches.includes("feature/clean-switch"));
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
  }
});

test("gitCheckout switches to the requested branch instead of treating it like a path", async () => {
  const repoDir = makeTempRepo();

  try {
    const result = await __test.gitCheckout(repoDir, { branch: "feature/clean-switch" });

    assert.equal(result.current, "feature/clean-switch");
    assert.equal(git(repoDir, "rev-parse", "--abbrev-ref", "HEAD"), "feature/clean-switch");
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test("gitCheckout surfaces a specific error when the branch is open in another worktree", async () => {
  const repoDir = makeTempRepo();
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-feature`);

  try {
    git(repoDir, "worktree", "add", siblingWorktree, "feature/clean-switch");

    await assert.rejects(
      __test.gitCheckout(repoDir, { branch: "feature/clean-switch" }),
      (error) =>
        error?.errorCode === "checkout_branch_in_other_worktree"
          && error?.userMessage === "Cannot switch branches: this branch is already open in another worktree."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
  }
});
