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

const { __test, gitStatus } = require("../src/git-handler");

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
  fs.mkdirSync(path.join(repoDir, "phodex-bridge", "src"), { recursive: true });
  fs.writeFileSync(path.join(repoDir, "phodex-bridge", "src", "index.js"), "export const ready = true;\n");
  git(repoDir, "add", "README.md");
  git(repoDir, "add", "phodex-bridge/src/index.js");
  git(repoDir, "commit", "-m", "Initial commit");
  git(repoDir, "branch", "feature/clean-switch");
  return repoDir;
}

function canonicalPath(candidatePath) {
  return fs.realpathSync.native(candidatePath);
}

function makeBareRemote() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-git-handler-remote-"));
}

// Publishes a branch to origin, then deletes the local ref so the bridge sees it as remote-only.
function pushRemoteOnlyBranch(repoDir, remoteDir, branchName) {
  git(remoteDir, "init", "--bare");
  git(repoDir, "remote", "add", "origin", remoteDir);
  git(repoDir, "push", "-u", "origin", "main");
  git(repoDir, "branch", branchName);
  git(repoDir, "push", "-u", "origin", branchName);
  git(repoDir, "branch", "-D", branchName);
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
    assert.equal(result.worktreePathByBranch["feature/clean-switch"], canonicalPath(siblingWorktree));
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
  }
});

test("gitBranches scopes worktree paths to the current project subdirectory", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-feature`);

  try {
    git(repoDir, "worktree", "add", siblingWorktree, "feature/clean-switch");

    const result = await __test.gitBranches(projectDir);

    assert.equal(
      result.worktreePathByBranch["feature/clean-switch"],
      canonicalPath(path.join(siblingWorktree, "phodex-bridge"))
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
  }
});

test("gitBranches exposes the true local checkout path even when called from a worktree", async () => {
  const repoDir = makeTempRepo();
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-feature`);

  try {
    git(repoDir, "worktree", "add", siblingWorktree, "feature/clean-switch");

    const result = await __test.gitBranches(siblingWorktree);

    assert.equal(result.localCheckoutPath, canonicalPath(repoDir));
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
  }
});

test("gitBranches scopes local checkout path for subdirectory worktrees", async () => {
  const repoDir = makeTempRepo();
  const localProjectDir = path.join(repoDir, "phodex-bridge");
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-feature`);
  const siblingProjectDir = path.join(siblingWorktree, "phodex-bridge");

  try {
    git(repoDir, "worktree", "add", siblingWorktree, "feature/clean-switch");

    const result = await __test.gitBranches(siblingProjectDir);

    assert.equal(result.localCheckoutPath, canonicalPath(localProjectDir));
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
  }
});

test("gitBranches leaves local checkout path empty when the matching local subdirectory is missing", async () => {
  const repoDir = makeTempRepo();
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-feature`);
  const siblingProjectDir = path.join(siblingWorktree, "packages", "newpkg");

  try {
    git(repoDir, "worktree", "add", siblingWorktree, "feature/clean-switch");
    fs.mkdirSync(siblingProjectDir, { recursive: true });

    const result = await __test.gitBranches(siblingProjectDir);

    assert.equal(result.localCheckoutPath, null);
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

test("gitCreateBranch normalizes bare names into remodex/* and checks out the new branch", async () => {
  const repoDir = makeTempRepo();

  try {
    const result = await __test.gitCreateBranch(repoDir, { name: "new-branch" });

    assert.equal(result.branch, "remodex/new-branch");
    assert.equal(result.status?.branch, "remodex/new-branch");
    assert.equal(git(repoDir, "rev-parse", "--abbrev-ref", "HEAD"), "remodex/new-branch");
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test("normalizeCreatedBranchName avoids double-prefixing remodex branches", () => {
  assert.equal(__test.normalizeCreatedBranchName("feature/foo"), "remodex/feature/foo");
  assert.equal(__test.normalizeCreatedBranchName("remodex/feature/foo"), "remodex/feature/foo");
  assert.equal(__test.normalizeCreatedBranchName("my new branch"), "remodex/my-new-branch");
  assert.equal(__test.normalizeCreatedBranchName("feature / login page"), "remodex/feature/login-page");
  assert.equal(__test.normalizeCreatedBranchName("   "), "");
});

test("gitCreateBranch rejects invalid Git branch names before checkout", async () => {
  const repoDir = makeTempRepo();

  try {
    await assert.rejects(
      __test.gitCreateBranch(repoDir, { name: "feature..oops" }),
      (error) =>
        error?.errorCode === "invalid_branch_name"
          && error?.userMessage === "Branch 'remodex/feature..oops' is not a valid Git branch name."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test("gitStatus reports local-only commits when remotes exist but upstream is missing", async () => {
  const repoDir = makeTempRepo();
  const remoteDir = makeBareRemote();

  try {
    git(remoteDir, "init", "--bare");
    git(repoDir, "remote", "add", "origin", remoteDir);
    git(repoDir, "push", "-u", "origin", "main");

    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\n\nlocal\n");
    git(repoDir, "add", "README.md");
    git(repoDir, "commit", "-m", "Local commit");
    git(repoDir, "config", "--unset", "branch.main.remote");
    git(repoDir, "config", "--unset", "branch.main.merge");

    const result = await gitStatus(repoDir);

    assert.equal(result.tracking, null);
    assert.equal(result.state, "no_upstream");
    assert.equal(result.localOnlyCommitCount, 1);
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  }
});

test("gitCreateBranch rejects duplicate branch names with a specific error", async () => {
  const repoDir = makeTempRepo();

  try {
    git(repoDir, "branch", "remodex/already-there");

    await assert.rejects(
      __test.gitCreateBranch(repoDir, { name: "already-there" }),
      (error) =>
        error?.errorCode === "branch_exists"
          && error?.userMessage === "Branch 'remodex/already-there' already exists."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test("gitBranches hides remote-only branches from the local selector list", async () => {
  const repoDir = makeTempRepo();
  const remoteDir = makeBareRemote();

  try {
    pushRemoteOnlyBranch(repoDir, remoteDir, "remodex/remote-only");

    const result = await __test.gitBranches(repoDir);

    assert.ok(!result.branches.includes("remodex/remote-only"));
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  }
});

test("gitBranches preserves the repo default branch even when it is not checked out locally", async () => {
  const repoDir = makeTempRepo();
  const remoteDir = makeBareRemote();

  try {
    git(remoteDir, "init", "--bare");
    git(repoDir, "remote", "add", "origin", remoteDir);
    git(repoDir, "push", "-u", "origin", "main");
    git(repoDir, "checkout", "-b", "remodex/topic");
    git(repoDir, "branch", "-D", "main");

    const result = await __test.gitBranches(repoDir);

    assert.equal(result.default, "main");
    assert.ok(!result.branches.includes("main"));
    assert.ok(result.branches.includes("remodex/topic"));
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  }
});

test("gitCreateBranch rejects names that already exist only on origin", async () => {
  const repoDir = makeTempRepo();
  const remoteDir = makeBareRemote();

  try {
    pushRemoteOnlyBranch(repoDir, remoteDir, "remodex/remote-only");

    await assert.rejects(
      __test.gitCreateBranch(repoDir, { name: "remote-only" }),
      (error) =>
        error?.errorCode === "branch_exists"
          && error?.userMessage === "Branch 'remodex/remote-only' already exists on origin. Check it out locally instead of creating a new branch."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  }
});

test("gitStatus marks a branch as published when origin has it even without local upstream", async () => {
  const repoDir = makeTempRepo();
  const remoteDir = makeBareRemote();

  try {
    git(remoteDir, "init", "--bare");
    git(repoDir, "remote", "add", "origin", remoteDir);
    git(repoDir, "push", "-u", "origin", "main");
    git(repoDir, "checkout", "-b", "remodex/published-no-upstream");
    git(repoDir, "push", "origin", "HEAD");

    const result = await gitStatus(repoDir);

    assert.equal(result.tracking, null);
    assert.equal(result.publishedToRemote, true);
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  }
});

test("gitCreateWorktree creates a managed worktree under CODEX_HOME/worktrees", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    const result = await __test.gitCreateWorktree(projectDir, {
      name: "new-worktree",
      baseBranch: "main",
    });
    const managedWorktreesRoot = canonicalPath(path.join(codexHome, "worktrees"));

    assert.equal(result.branch, "remodex/new-worktree");
    assert.equal(result.alreadyExisted, false);
    assert.ok(result.worktreePath.startsWith(managedWorktreesRoot));
    assert.equal(path.basename(result.worktreePath), "phodex-bridge");
    assert.equal(git(result.worktreePath, "rev-parse", "--abbrev-ref", "HEAD"), "remodex/new-worktree");

    git(repoDir, "worktree", "remove", "--force", path.dirname(result.worktreePath));
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateManagedWorktree creates a detached managed worktree under CODEX_HOME/worktrees", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    const result = await __test.gitCreateManagedWorktree(projectDir, {
      baseBranch: "main",
    });
    const managedWorktreesRoot = canonicalPath(path.join(codexHome, "worktrees"));

    assert.equal(result.alreadyExisted, false);
    assert.equal(result.baseBranch, "main");
    assert.equal(result.headMode, "detached");
    assert.ok(result.worktreePath.startsWith(managedWorktreesRoot));
    assert.equal(path.basename(result.worktreePath), "phodex-bridge");
    assert.equal(git(result.worktreePath, "rev-parse", "--abbrev-ref", "HEAD"), "HEAD");
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateWorktree reuses an existing worktree for the same remodex branch", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;
  const siblingWorktree = path.join(path.dirname(repoDir), `${path.basename(repoDir)}-wt-remodex-existing`);

  process.env.CODEX_HOME = codexHome;

  try {
    git(repoDir, "branch", "remodex/existing");
    git(repoDir, "worktree", "add", siblingWorktree, "remodex/existing");

    const result = await __test.gitCreateWorktree(projectDir, {
      name: "existing",
      baseBranch: "main",
    });

    assert.equal(result.branch, "remodex/existing");
    assert.equal(result.alreadyExisted, true);
    assert.equal(result.worktreePath, canonicalPath(path.join(siblingWorktree, "phodex-bridge")));
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(siblingWorktree, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateWorktree rejects a reused local branch name before ignoring the chosen base branch", async () => {
  const repoDir = makeTempRepo();

  try {
    git(repoDir, "branch", "remodex/already-there");

    await assert.rejects(
      __test.gitCreateWorktree(repoDir, {
        name: "already-there",
        baseBranch: "main",
      }),
      (error) =>
        error?.errorCode === "branch_exists"
          && error?.userMessage === "Branch 'remodex/already-there' already exists locally. Choose another name or open that branch instead."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test("gitCreateWorktree rejects invalid Git branch names before creating a worktree", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");

  try {
    await assert.rejects(
      __test.gitCreateWorktree(projectDir, {
        name: "feature..oops",
        baseBranch: "main",
        changeTransfer: "copy",
      }),
      (error) =>
        error?.errorCode === "invalid_branch_name"
          && error?.userMessage === "Branch 'remodex/feature..oops' is not a valid Git branch name."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test("gitCreateWorktree rejects remote-only base branches because worktrees start from local refs", async () => {
  const repoDir = makeTempRepo();
  const remoteDir = makeBareRemote();

  try {
    pushRemoteOnlyBranch(repoDir, remoteDir, "feature/remote-base");

    await assert.rejects(
      __test.gitCreateWorktree(repoDir, {
        name: "new-worktree",
        baseBranch: "feature/remote-base",
      }),
      (error) =>
        error?.errorCode === "missing_base_branch"
          && error?.userMessage === "Base branch 'feature/remote-base' is not available locally. Create or check out that branch first."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  }
});

test("gitCreateWorktree carries tracked and untracked changes into the new worktree and cleans local", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\nmoved\n");
    fs.writeFileSync(path.join(repoDir, "phodex-bridge", "scratch.txt"), "carry me\n");

    const result = await __test.gitCreateWorktree(projectDir, {
      name: "dirty-worktree",
      baseBranch: "main",
    });

    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "..", "README.md"), "utf8"),
      "# Test\nmoved\n"
    );
    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "scratch.txt"), "utf8"),
      "carry me\n"
    );
    assert.equal(git(repoDir, "status", "--short"), "");
    assert.equal(fs.existsSync(path.join(repoDir, "phodex-bridge", "scratch.txt")), false);

    git(repoDir, "worktree", "remove", "--force", path.dirname(result.worktreePath));
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateWorktree can copy tracked and untracked changes into the new worktree without cleaning local", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\ncopied\n");
    fs.writeFileSync(path.join(repoDir, "phodex-bridge", "scratch.txt"), "keep me too\n");

    const result = await __test.gitCreateWorktree(projectDir, {
      name: "copied-worktree",
      baseBranch: "main",
      changeTransfer: "copy",
    });

    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "..", "README.md"), "utf8"),
      "# Test\ncopied\n"
    );
    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "scratch.txt"), "utf8"),
      "keep me too\n"
    );
    assert.match(git(repoDir, "status", "--short"), /README\.md/);
    assert.equal(
      fs.readFileSync(path.join(repoDir, "phodex-bridge", "scratch.txt"), "utf8"),
      "keep me too\n"
    );

    git(repoDir, "worktree", "remove", "--force", path.dirname(result.worktreePath));
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateWorktree leaves ignored files in the local checkout during handoff", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, ".gitignore"), "ignored.log\n");
    git(repoDir, "add", ".gitignore");
    git(repoDir, "commit", "-m", "Add ignore rule");
    fs.writeFileSync(path.join(repoDir, "ignored.log"), "stay local\n");
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\nmoved\n");

    const result = await __test.gitCreateWorktree(projectDir, {
      name: "ignored-files",
      baseBranch: "main",
    });

    assert.equal(fs.existsSync(path.join(repoDir, "ignored.log")), true);
    assert.equal(fs.existsSync(path.join(path.dirname(result.worktreePath), "ignored.log")), false);

    git(repoDir, "worktree", "remove", "--force", path.dirname(result.worktreePath));
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateWorktree leaves ignored files only in Local when copying changes for a fork", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, ".gitignore"), "ignored.log\n");
    git(repoDir, "add", ".gitignore");
    git(repoDir, "commit", "-m", "Add ignore rule");
    fs.writeFileSync(path.join(repoDir, "ignored.log"), "stay local\n");
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\ncopied\n");

    const result = await __test.gitCreateWorktree(projectDir, {
      name: "ignored-copy",
      baseBranch: "main",
      changeTransfer: "copy",
    });

    assert.equal(fs.existsSync(path.join(repoDir, "ignored.log")), true);
    assert.equal(fs.existsSync(path.join(path.dirname(result.worktreePath), "ignored.log")), false);
    assert.match(git(repoDir, "status", "--short"), /README\.md/);

    git(repoDir, "worktree", "remove", "--force", path.dirname(result.worktreePath));
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateManagedWorktree moves tracked changes into the detached worktree and cleans Local", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\nmoved\n");
    fs.writeFileSync(path.join(repoDir, "phodex-bridge", "scratch.txt"), "carry me\n");

    const result = await __test.gitCreateManagedWorktree(projectDir, {
      baseBranch: "main",
      changeTransfer: "move",
    });

    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "..", "README.md"), "utf8"),
      "# Test\nmoved\n"
    );
    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "scratch.txt"), "utf8"),
      "carry me\n"
    );
    assert.equal(git(repoDir, "status", "--short"), "");
    assert.equal(fs.existsSync(path.join(repoDir, "phodex-bridge", "scratch.txt")), false);
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateManagedWorktree copies tracked changes into the detached worktree and keeps Local dirty", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\ncopied\n");
    fs.writeFileSync(path.join(repoDir, "phodex-bridge", "scratch.txt"), "keep me too\n");

    const result = await __test.gitCreateManagedWorktree(projectDir, {
      baseBranch: "main",
      changeTransfer: "copy",
    });

    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "..", "README.md"), "utf8"),
      "# Test\ncopied\n"
    );
    assert.equal(
      fs.readFileSync(path.join(result.worktreePath, "scratch.txt"), "utf8"),
      "keep me too\n"
    );
    assert.match(git(repoDir, "status", "--short"), /README\.md/);
    assert.equal(
      fs.readFileSync(path.join(repoDir, "phodex-bridge", "scratch.txt"), "utf8"),
      "keep me too\n"
    );
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateManagedWorktree leaves ignored files only in Local", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    fs.writeFileSync(path.join(repoDir, ".gitignore"), "ignored.log\n");
    git(repoDir, "add", ".gitignore");
    git(repoDir, "commit", "-m", "Add ignore rule");
    fs.writeFileSync(path.join(repoDir, "ignored.log"), "stay local\n");
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\ncopied\n");

    const result = await __test.gitCreateManagedWorktree(projectDir, {
      baseBranch: "main",
      changeTransfer: "copy",
    });

    assert.equal(fs.existsSync(path.join(repoDir, "ignored.log")), true);
    assert.equal(fs.existsSync(path.join(path.dirname(result.worktreePath), "ignored.log")), false);
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitTransferManagedHandoff moves tracked changes from Local into an existing managed worktree", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    const managed = await __test.gitCreateManagedWorktree(projectDir, {
      baseBranch: "main",
    });

    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\nhandoff local\n");
    fs.writeFileSync(path.join(projectDir, "scratch.txt"), "from local\n");

    const result = await __test.gitTransferManagedHandoff(projectDir, {
      targetPath: managed.worktreePath,
    });

    assert.equal(result.success, true);
    assert.equal(git(repoDir, "status", "--short"), "");
    assert.equal(
      fs.readFileSync(path.join(managed.worktreePath, "..", "README.md"), "utf8"),
      "# Test\nhandoff local\n"
    );
    assert.equal(
      fs.readFileSync(path.join(managed.worktreePath, "scratch.txt"), "utf8"),
      "from local\n"
    );
    assert.equal(fs.existsSync(path.join(projectDir, "scratch.txt")), false);
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitTransferManagedHandoff moves tracked changes from a managed worktree back to Local", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    const managed = await __test.gitCreateManagedWorktree(projectDir, {
      baseBranch: "main",
    });

    fs.writeFileSync(path.join(managed.worktreePath, "..", "README.md"), "# Test\nhandoff back\n");
    fs.writeFileSync(path.join(managed.worktreePath, "scratch.txt"), "from worktree\n");

    const result = await __test.gitTransferManagedHandoff(managed.worktreePath, {
      targetPath: projectDir,
    });

    assert.equal(result.success, true);
    assert.equal(git(path.join(managed.worktreePath, ".."), "status", "--short"), "");
    assert.equal(
      fs.readFileSync(path.join(repoDir, "README.md"), "utf8"),
      "# Test\nhandoff back\n"
    );
    assert.equal(
      fs.readFileSync(path.join(projectDir, "scratch.txt"), "utf8"),
      "from worktree\n"
    );
    assert.equal(fs.existsSync(path.join(managed.worktreePath, "scratch.txt")), false);
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitRemoveWorktree removes a managed worktree and its freshly created branch", async () => {
  const repoDir = makeTempRepo();
  const projectDir = path.join(repoDir, "phodex-bridge");
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;

  process.env.CODEX_HOME = codexHome;

  try {
    const result = await __test.gitCreateWorktree(projectDir, {
      name: "cleanup-me",
      baseBranch: "main",
      changeTransfer: "copy",
    });

    await __test.gitRemoveWorktree(result.worktreePath, { branch: result.branch });

    assert.equal(fs.existsSync(path.dirname(result.worktreePath)), false);
    assert.equal(git(repoDir, "branch", "--list", result.branch), "");
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("gitCreateWorktree rejects dirty handoff when the chosen base branch is not the current branch", async () => {
  const repoDir = makeTempRepo();

  try {
    fs.writeFileSync(path.join(repoDir, "README.md"), "# Test\nmismatch\n");

    await assert.rejects(
      __test.gitCreateWorktree(repoDir, {
        name: "mismatch",
        baseBranch: "feature/clean-switch",
      }),
      (error) =>
        error?.errorCode === "dirty_worktree_base_mismatch"
          && error?.userMessage === "Uncommitted changes can move into a new worktree only from main. Switch the base branch to match or clean up local changes first."
    );
  } finally {
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});
