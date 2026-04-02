// FILE: git-handler.js
// Purpose: Intercepts git/* JSON-RPC methods and executes git commands locally on the Mac.
// Layer: Bridge handler
// Exports: handleGitRequest
// Depends on: child_process, fs, os, path, crypto

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomBytes } = require("crypto");
const { promisify } = require("util");

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 30_000;
const EMPTY_TREE_HASH = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/**
 * Intercepts git/* JSON-RPC methods and executes git commands locally.
 * @param {string} rawMessage - Raw WebSocket message
 * @param {(response: string) => void} sendResponse - Callback to send response back
 * @returns {boolean} true if message was handled, false if it should pass through
 */
function handleGitRequest(rawMessage, sendResponse) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method.startsWith("git/")) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleGitMethod(method, params)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "git_error";
      const message = err.userMessage || err.message || "Unknown git error";
      sendResponse(
        JSON.stringify({
          id,
          error: {
            code: -32000,
            message,
            data: { errorCode },
          },
        })
      );
    });

  return true;
}

async function handleGitMethod(method, params) {
  const cwd = await resolveGitCwd(params);

  switch (method) {
    case "git/status":
      return gitStatus(cwd);
    case "git/diff":
      return gitDiff(cwd);
    case "git/commit":
      return gitCommit(cwd, params);
    case "git/push":
      return gitPush(cwd);
    case "git/pull":
      return gitPull(cwd);
    case "git/branches":
      return gitBranches(cwd);
    case "git/checkout":
      return gitCheckout(cwd, params);
    case "git/log":
      return gitLog(cwd);
    case "git/createBranch":
      return gitCreateBranch(cwd, params);
    case "git/createWorktree":
      return gitCreateWorktree(cwd, params);
    case "git/createManagedWorktree":
      return gitCreateManagedWorktree(cwd, params);
    case "git/transferManagedHandoff":
      return gitTransferManagedHandoff(cwd, params);
    case "git/removeWorktree":
      return gitRemoveWorktree(cwd, params);
    case "git/stash":
      return gitStash(cwd);
    case "git/stashPop":
      return gitStashPop(cwd);
    case "git/resetToRemote":
      return gitResetToRemote(cwd, params);
    case "git/remoteUrl":
      return gitRemoteUrl(cwd);
    case "git/branchesWithStatus":
      return gitBranchesWithStatus(cwd);
    default:
      throw gitError("unknown_method", `Unknown git method: ${method}`);
  }
}

// ─── Git Status ───────────────────────────────────────────────

async function gitStatus(cwd) {
  const [porcelain, branchInfo, repoRoot] = await Promise.all([
    git(cwd, "status", "--porcelain=v1", "-b"),
    revListCounts(cwd).catch(() => ({ ahead: 0, behind: 0 })),
    resolveRepoRoot(cwd).catch(() => null),
  ]);

  const lines = porcelain.trim().split("\n").filter(Boolean);
  const branchLine = lines[0] || "";
  const fileLines = lines.slice(1);

  const branch = parseBranchFromStatus(branchLine);
  const tracking = parseTrackingFromStatus(branchLine);
  const files = fileLines.map((line) => ({
    path: line.substring(3).trim(),
    status: line.substring(0, 2).trim(),
  }));

  const dirty = files.length > 0;
  const { ahead, behind } = branchInfo;
  const detached = branchLine.includes("HEAD detached") || branchLine.includes("no branch");
  const noUpstream = tracking === null && !detached;
  const publishedToRemote = !detached && !!branch && await remoteBranchExists(cwd, branch).catch(() => false);
  const localOnlyCommitCount = await countLocalOnlyCommits(cwd, { detached }).catch(() => 0);
  const state = computeState(dirty, ahead, behind, detached, noUpstream);
  const canPush = (ahead > 0 || noUpstream) && !detached;
  const diff = await repoDiffTotals(cwd, {
    tracking,
    fileLines,
  }).catch(() => ({ additions: 0, deletions: 0, binaryFiles: 0 }));

  return {
    repoRoot,
    branch,
    tracking,
    dirty,
    ahead,
    behind,
    localOnlyCommitCount,
    state,
    canPush,
    publishedToRemote,
    files,
    diff,
  };
}

// ─── Git Diff ─────────────────────────────────────────────────

async function gitDiff(cwd) {
  const porcelain = await git(cwd, "status", "--porcelain=v1", "-b");
  const lines = porcelain.trim().split("\n").filter(Boolean);
  const branchLine = lines[0] || "";
  const fileLines = lines.slice(1);
  const tracking = parseTrackingFromStatus(branchLine);
  const baseRef = await resolveRepoDiffBase(cwd, tracking);
  const trackedPatch = await gitDiffAgainstBase(cwd, baseRef);
  const untrackedPaths = fileLines
    .filter((line) => line.startsWith("?? "))
    .map((line) => line.substring(3).trim())
    .filter(Boolean);
  const untrackedPatch = await diffPatchForUntrackedFiles(cwd, untrackedPaths);
  const patch = [trackedPatch.trim(), untrackedPatch.trim()].filter(Boolean).join("\n\n").trim();
  return { patch };
}

// ─── Git Commit ───────────────────────────────────────────────

async function gitCommit(cwd, params) {
  const message =
    typeof params.message === "string" && params.message.trim()
      ? params.message.trim()
      : "Changes from Codex";

  // Check for changes first
  const statusCheck = await git(cwd, "status", "--porcelain");
  if (!statusCheck.trim()) {
    throw gitError("nothing_to_commit", "Nothing to commit.");
  }

  await git(cwd, "add", "-A");
  const output = await git(cwd, "commit", "-m", message);

  const hashMatch = output.match(/\[(\S+)\s+([a-f0-9]+)\]/);
  const hash = hashMatch ? hashMatch[2] : "";
  const branch = hashMatch ? hashMatch[1] : "";
  const summaryMatch = output.match(/\d+ files? changed/);
  const summary = summaryMatch ? summaryMatch[0] : output.split("\n").pop()?.trim() || "";

  return { hash, branch, summary };
}

// ─── Git Push ─────────────────────────────────────────────────

async function gitPush(cwd) {
  try {
    const branchOutput = await git(cwd, "rev-parse", "--abbrev-ref", "HEAD");
    const branch = branchOutput.trim();

    // Try normal push first; if no upstream, set it
    try {
        await git(cwd, "push");
    } catch (pushErr) {
      if (
        pushErr.message?.includes("no upstream") ||
        pushErr.message?.includes("has no upstream branch")
      ) {
        await git(cwd, "push", "--set-upstream", "origin", branch);
      } else {
        throw pushErr;
      }
    }

    const remote = "origin";
    const status = await gitStatus(cwd);
    return { branch, remote, status };
  } catch (err) {
    if (err.errorCode) throw err;
    if (err.message?.includes("rejected")) {
      throw gitError("push_rejected", "Push rejected. Pull changes first.");
    }
    throw gitError("push_failed", err.message || "Push failed.");
  }
}

// ─── Git Pull ─────────────────────────────────────────────────

async function gitPull(cwd) {
  try {
    await git(cwd, "pull", "--rebase");
    const status = await gitStatus(cwd);
    return { success: true, status };
  } catch (err) {
    // Abort rebase on conflict
    try {
      await git(cwd, "rebase", "--abort");
    } catch {
      // ignore abort errors
    }
    if (err.errorCode) throw err;
    throw gitError("pull_conflict", "Pull failed due to conflicts. Rebase aborted.");
  }
}

// ─── Git Branches ─────────────────────────────────────────────

async function gitBranches(cwd) {
  const [output, repoRoot, localCheckoutRoot] = await Promise.all([
    git(cwd, "branch", "--no-color"),
    resolveRepoRoot(cwd).catch(() => null),
    resolveLocalCheckoutRoot(cwd).catch(() => null),
  ]);
  const projectRelativePath = resolveProjectRelativePath(cwd, repoRoot);
  const worktreePathByBranch = await gitWorktreePathByBranch(cwd, { projectRelativePath }).catch(() => ({}));
  const localCheckoutPath = scopedLocalCheckoutPath(localCheckoutRoot || repoRoot, projectRelativePath);
  const lines = output
    .trim()
    .split("\n")
    .filter(Boolean);

  let current = "";
  const branchSet = new Set();
  const branchesCheckedOutElsewhere = new Set();

  for (const line of lines) {
    const entry = normalizeBranchListEntry(line);
    if (!entry) {
      continue;
    }

    const { isCurrent, isCheckedOutElsewhere, name } = entry;

    if (name.includes("HEAD detached") || name === "(no branch)") {
      if (isCurrent) current = "HEAD";
      continue;
    }

    branchSet.add(name);
    if (isCheckedOutElsewhere) {
      branchesCheckedOutElsewhere.add(name);
    }

    if (isCurrent) current = name;
  }

  const branches = [...branchSet].sort();
  const defaultBranch = await detectDefaultBranch(cwd, branches);

  return {
    branches,
    branchesCheckedOutElsewhere: [...branchesCheckedOutElsewhere].sort(),
    worktreePathByBranch,
    localCheckoutPath,
    current,
    default: defaultBranch,
  };
}

// ─── Git Checkout ─────────────────────────────────────────────

async function gitCheckout(cwd, params) {
  const branch = typeof params.branch === "string" ? params.branch.trim() : "";
  if (!branch) {
    throw gitError("missing_branch", "Branch name is required.");
  }

  try {
    await git(cwd, "checkout", branch);
  } catch (err) {
    if (err.message?.includes("would be overwritten")) {
      throw gitError(
        "checkout_conflict_dirty_tree",
        "Cannot switch branches: you have uncommitted changes."
      );
    }
    if (err.message?.includes("already used by worktree")) {
      throw gitError(
        "checkout_branch_in_other_worktree",
        "Cannot switch branches: this branch is already open in another worktree."
      );
    }
    throw gitError("checkout_failed", err.message || "Checkout failed.");
  }

  const status = await gitStatus(cwd);
  return { current: status.branch || branch, tracking: status.tracking, status };
}

// ─── Git Log ──────────────────────────────────────────────────

async function gitLog(cwd) {
  const output = await git(
    cwd,
    "log",
    "-20",
    "--format=%H%x00%s%x00%an%x00%aI"
  );

  const commits = output
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [hash, message, author, date] = line.split("\0");
      return {
        hash: hash?.substring(0, 7) || "",
        message: message || "",
        author: author || "",
        date: date || "",
      };
    });

  return { commits };
}

// ─── Git Create Branch ────────────────────────────────────────

async function gitCreateBranch(cwd, params) {
  const name = normalizeCreatedBranchName(params.name);
  if (!name) {
    throw gitError("missing_branch_name", "Branch name is required.");
  }
  await assertValidCreatedBranchName(cwd, name);

  // Keep create-branch local-first so we never fork history under a remote-only name.
  if (!(await localBranchExists(cwd, name)) && await remoteBranchExists(cwd, name)) {
    throw gitError(
      "branch_exists",
      `Branch '${name}' already exists on origin. Check it out locally instead of creating a new branch.`
    );
  }

  try {
    await git(cwd, "checkout", "-b", name);
  } catch (err) {
    if (err.message?.includes("already exists")) {
      throw gitError("branch_exists", `Branch '${name}' already exists.`);
    }
    throw gitError("create_branch_failed", err.message || "Failed to create branch.");
  }

  const status = await gitStatus(cwd);
  return { branch: name, status };
}

async function gitCreateWorktree(cwd, params) {
  const branch = normalizeCreatedBranchName(params.name);
  if (!branch) {
    throw gitError("missing_branch_name", "Branch name is required.");
  }
  await assertValidCreatedBranchName(cwd, branch);

  const branchResult = await gitBranches(cwd);
  const repoRoot = await resolveRepoRoot(cwd);
  const status = await gitStatus(cwd);
  const projectRelativePath = resolveProjectRelativePath(cwd, repoRoot);
  const baseBranch = resolveBaseBranchName(params.baseBranch, branchResult.defaultBranch);
  const changeTransfer = resolveWorktreeChangeTransfer(params.changeTransfer);
  if (!baseBranch) {
    throw gitError("missing_base_branch", "Base branch is required.");
  }
  if (!(await localBranchExists(cwd, baseBranch))) {
    throw gitError(
      "missing_base_branch",
      `Base branch '${baseBranch}' is not available locally. Create or check out that branch first.`
    );
  }

  const currentBranch = typeof status.branch === "string" ? status.branch.trim() : "";
  const canCarryLocalChanges = status.dirty && !!currentBranch && currentBranch === baseBranch;
  if (status.dirty && changeTransfer !== "none" && !canCarryLocalChanges) {
    const currentBranchLabel = currentBranch || "the current branch";
    const transferVerb = changeTransfer === "copy" ? "copy" : "move";
    throw gitError(
      "dirty_worktree_base_mismatch",
      `Uncommitted changes can ${transferVerb} into a new worktree only from ${currentBranchLabel}. Switch the base branch to match or clean up local changes first.`
    );
  }

  const existingWorktreePath = branchResult.worktreePathByBranch[branch];
  if (existingWorktreePath) {
    if (sameFilePath(existingWorktreePath, cwd)) {
      throw gitError(
        "branch_already_open_here",
        `Branch '${branch}' is already open in this project.`
      );
    }

    return {
      branch,
      worktreePath: existingWorktreePath,
      alreadyExisted: true,
    };
  }

  const branchExists = await localBranchExists(cwd, branch);
  if (branchExists) {
    throw gitError(
      "branch_exists",
      `Branch '${branch}' already exists locally. Choose another name or open that branch instead.`
    );
  }

  const worktreeRootPath = allocateManagedWorktreePath(repoRoot);
  let handoffStashRef = null;
  let copiedLocalChangesPatch = "";
  let didCreateWorktree = false;

  try {
    if (canCarryLocalChanges) {
      if (changeTransfer === "copy") {
        copiedLocalChangesPatch = await captureLocalChangesPatch(repoRoot);
      } else if (changeTransfer === "move") {
        handoffStashRef = await stashChangesForWorktreeHandoff(repoRoot);
      }
    }

    await git(repoRoot, "worktree", "add", "-b", branch, worktreeRootPath, baseBranch);
    didCreateWorktree = true;

    if (handoffStashRef) {
      await applyWorktreeHandoffStash(worktreeRootPath, handoffStashRef);
    }
    if (copiedLocalChangesPatch) {
      await applyCopiedLocalChangesToWorktree(worktreeRootPath, copiedLocalChangesPatch);
    }
  } catch (err) {
    if (didCreateWorktree) {
      await cleanupManagedWorktree(repoRoot, worktreeRootPath, branch);
    } else {
      fs.rmSync(path.dirname(worktreeRootPath), { recursive: true, force: true });
    }

    if (handoffStashRef) {
      await restoreWorktreeHandoffStash(repoRoot, handoffStashRef);
    }

    if (err.message?.includes("invalid reference")) {
      throw gitError("missing_base_branch", `Base branch '${baseBranch}' does not exist.`);
    }
    if (err.message?.includes("already exists")) {
      throw gitError("branch_exists", `Branch '${branch}' already exists.`);
    }
    if (err.message?.includes("already used by worktree") || err.message?.includes("already checked out at")) {
      throw gitError(
        "branch_in_other_worktree",
        `Branch '${branch}' is already open in another worktree.`
      );
    }
    throw gitError("create_worktree_failed", err.message || "Failed to create worktree.");
  }

  const worktreePath = scopedWorktreePath(worktreeRootPath, projectRelativePath);
  return {
    branch,
    worktreePath,
    alreadyExisted: false,
  };
}

async function gitCreateManagedWorktree(cwd, params) {
  const branchResult = await gitBranches(cwd);
  const repoRoot = await resolveRepoRoot(cwd);
  const status = await gitStatus(cwd);
  const projectRelativePath = resolveProjectRelativePath(cwd, repoRoot);
  const baseBranch = resolveBaseBranchName(params.baseBranch, branchResult.defaultBranch);
  const changeTransfer = resolveWorktreeChangeTransfer(params.changeTransfer);
  if (!baseBranch) {
    throw gitError("missing_base_branch", "Base branch is required.");
  }
  if (!(await localBranchExists(cwd, baseBranch))) {
    throw gitError(
      "missing_base_branch",
      `Base branch '${baseBranch}' is not available locally. Create or check out that branch first.`
    );
  }

  const currentBranch = typeof status.branch === "string" ? status.branch.trim() : "";
  const canCarryLocalChanges = status.dirty && !!currentBranch && currentBranch === baseBranch;
  if (status.dirty && changeTransfer !== "none" && !canCarryLocalChanges) {
    const currentBranchLabel = currentBranch || "the current branch";
    const transferVerb = changeTransfer === "copy" ? "copy" : "move";
    throw gitError(
      "dirty_worktree_base_mismatch",
      `Uncommitted changes can ${transferVerb} into a managed worktree only from ${currentBranchLabel}. Switch the base branch to match or clean up local changes first.`
    );
  }

  const worktreeRootPath = allocateManagedWorktreePath(repoRoot);
  let handoffStashRef = null;
  let copiedLocalChangesPatch = "";
  let didCreateWorktree = false;

  try {
    if (canCarryLocalChanges) {
      if (changeTransfer === "copy") {
        copiedLocalChangesPatch = await captureLocalChangesPatch(repoRoot);
      } else if (changeTransfer === "move") {
        handoffStashRef = await stashChangesForWorktreeHandoff(repoRoot);
      }
    }

    await git(repoRoot, "worktree", "add", "--detach", worktreeRootPath, baseBranch);
    didCreateWorktree = true;

    if (handoffStashRef) {
      await applyWorktreeHandoffStash(worktreeRootPath, handoffStashRef);
    }
    if (copiedLocalChangesPatch) {
      await applyCopiedLocalChangesToWorktree(worktreeRootPath, copiedLocalChangesPatch);
    }
  } catch (err) {
    if (didCreateWorktree) {
      await cleanupManagedWorktree(repoRoot, worktreeRootPath);
    } else {
      fs.rmSync(path.dirname(worktreeRootPath), { recursive: true, force: true });
    }

    if (handoffStashRef) {
      await restoreWorktreeHandoffStash(repoRoot, handoffStashRef);
    }

    if (err.message?.includes("invalid reference")) {
      throw gitError("missing_base_branch", `Base branch '${baseBranch}' does not exist.`);
    }
    throw gitError("create_worktree_failed", err.message || "Failed to create managed worktree.");
  }

  const worktreePath = scopedWorktreePath(worktreeRootPath, projectRelativePath);
  return {
    worktreePath,
    alreadyExisted: false,
    baseBranch,
    headMode: "detached",
    transferredChanges: Boolean(handoffStashRef || copiedLocalChangesPatch),
  };
}

async function gitTransferManagedHandoff(cwd, params) {
  const targetPath = firstNonEmptyString([params.targetPath, params.targetProjectPath]);
  if (!targetPath) {
    throw gitError("missing_handoff_target", "A handoff target path is required.");
  }
  if (!isExistingDirectory(cwd)) {
    throw gitError(
      "missing_handoff_source",
      "The current handoff source is not available on this Mac."
    );
  }
  if (!isExistingDirectory(targetPath)) {
    throw gitError(
      "missing_handoff_target",
      "The destination for this handoff is not available on this Mac."
    );
  }

  const [sourceRepoRoot, sourceLocalCheckoutRoot, targetRepoRoot, targetLocalCheckoutRoot] = await Promise.all([
    resolveRepoRoot(cwd),
    resolveLocalCheckoutRoot(cwd),
    resolveRepoRoot(targetPath),
    resolveLocalCheckoutRoot(targetPath),
  ]);

  const sourceCheckoutRoot = sourceLocalCheckoutRoot || sourceRepoRoot;
  const targetCheckoutRoot = targetLocalCheckoutRoot || targetRepoRoot;
  if (!sameFilePath(sourceCheckoutRoot, targetCheckoutRoot)) {
    throw gitError(
      "handoff_target_mismatch",
      "The selected handoff destination belongs to a different checkout."
    );
  }

  if (sameFilePath(cwd, targetPath)) {
    return {
      success: true,
      targetPath: normalizeExistingPath(targetPath) ?? targetPath,
      transferredChanges: false,
    };
  }

  const [sourceStatus, targetStatus] = await Promise.all([
    gitStatus(cwd),
    gitStatus(targetPath),
  ]);

  if (!sourceStatus.dirty) {
    return {
      success: true,
      targetPath: normalizeExistingPath(targetPath) ?? targetPath,
      transferredChanges: false,
    };
  }

  if (targetStatus.dirty) {
    throw gitError(
      "handoff_target_dirty",
      "The handoff destination already has uncommitted changes. Clean it up before moving this thread there."
    );
  }

  const stashRef = await stashChangesForWorktreeHandoff(sourceRepoRoot);
  if (!stashRef) {
    return {
      success: true,
      targetPath: normalizeExistingPath(targetPath) ?? targetPath,
      transferredChanges: false,
    };
  }

  try {
    await applyWorktreeHandoffStash(targetRepoRoot, stashRef, { dropAfterApply: true });
  } catch (err) {
    await rollbackFailedHandoffTransfer(targetRepoRoot);
    await restoreWorktreeHandoffStash(sourceRepoRoot, stashRef);
    throw gitError(
      "handoff_transfer_failed",
      err.userMessage || err.message || "Could not move local changes into the handoff destination."
    );
  }

  return {
    success: true,
    targetPath: normalizeExistingPath(targetPath) ?? targetPath,
    transferredChanges: true,
  };
}

async function gitRemoveWorktree(cwd, params) {
  const worktreeRootPath = await resolveRepoRoot(cwd).catch(() => null);
  const localCheckoutRoot = await resolveLocalCheckoutRoot(cwd).catch(() => null);
  const branch = typeof params.branch === "string" ? params.branch.trim() : "";

  if (!worktreeRootPath || !localCheckoutRoot) {
    throw gitError("missing_working_directory", "Could not resolve the worktree roots for cleanup.");
  }
  if (sameFilePath(worktreeRootPath, localCheckoutRoot)) {
    throw gitError("cannot_remove_local_checkout", "Cannot remove the main local checkout.");
  }
  if (!isManagedWorktreePath(worktreeRootPath)) {
    throw gitError("unmanaged_worktree", "Only managed worktrees can be removed automatically.");
  }

  await cleanupManagedWorktree(localCheckoutRoot, worktreeRootPath, branch || null);
  if (branch && await localBranchExists(localCheckoutRoot, branch)) {
    throw gitError(
      "worktree_cleanup_failed",
      `The temporary worktree was removed, but branch '${branch}' could not be deleted automatically.`
    );
  }
  return { success: true };
}

// ─── Git Stash ────────────────────────────────────────────────

async function gitStash(cwd) {
  const output = await git(cwd, "stash");
  const saved = !output.includes("No local changes");
  return { success: saved, message: output.trim() };
}

// ─── Git Stash Pop ────────────────────────────────────────────

async function gitStashPop(cwd) {
  try {
    const output = await git(cwd, "stash", "pop");
    return { success: true, message: output.trim() };
  } catch (err) {
    throw gitError("stash_pop_conflict", err.message || "Stash pop failed due to conflicts.");
  }
}

// ─── Git Reset to Remote ──────────────────────────────────────

async function gitResetToRemote(cwd, params) {
  if (params.confirm !== "discard_runtime_changes") {
    throw gitError(
      "confirmation_required",
      'This action requires params.confirm === "discard_runtime_changes".'
    );
  }

  let hasUpstream = true;
  try {
    await git(cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}");
  } catch {
    hasUpstream = false;
  }

  if (hasUpstream) {
    await git(cwd, "fetch");
    await git(cwd, "reset", "--hard", "@{u}");
  } else {
    await git(cwd, "checkout", "--", ".");
  }
  await git(cwd, "clean", "-fd");

  const status = await gitStatus(cwd);
  return { success: true, status };
}

// ─── Git Remote URL ───────────────────────────────────────────

async function gitRemoteUrl(cwd) {
  const raw = (await git(cwd, "config", "--get", "remote.origin.url")).trim();
  const ownerRepo = parseOwnerRepo(raw);
  return { url: raw, ownerRepo };
}

function parseOwnerRepo(remoteUrl) {
  const match = remoteUrl.match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
  return match ? match[1] : null;
}

// ─── Git Branches With Status ─────────────────────────────────

async function gitBranchesWithStatus(cwd) {
  const [branchResult, statusResult] = await Promise.all([
    gitBranches(cwd),
    gitStatus(cwd),
  ]);
  return { ...branchResult, status: statusResult };
}

async function gitWorktreePathByBranch(cwd, options = {}) {
  const output = await git(cwd, "worktree", "list", "--porcelain");
  return parseWorktreePathByBranch(output, options);
}

async function stashChangesForWorktreeHandoff(cwd) {
  const stashLabel = `remodex-worktree-handoff-${randomBytes(6).toString("hex")}`;
  const output = await git(cwd, "stash", "push", "--include-untracked", "--message", stashLabel);
  if (output.includes("No local changes")) {
    return null;
  }

  const stashRef = await findStashRefByLabel(cwd, stashLabel);
  if (!stashRef) {
    throw gitError("create_worktree_failed", "Could not prepare local changes for the worktree handoff.");
  }

  return stashRef;
}

async function captureLocalChangesPatch(cwd) {
  const trackedPatch = await git(cwd, "diff", "--binary", "--find-renames", "HEAD");
  const porcelain = await git(cwd, "status", "--porcelain=v1");
  const untrackedPaths = porcelain
    .trim()
    .split("\n")
    .filter((line) => line.startsWith("?? "))
    .map((line) => line.substring(3).trim())
    .filter(Boolean);
  const untrackedPatch = await diffPatchForUntrackedFiles(cwd, untrackedPaths);
  return [trackedPatch, untrackedPatch]
    .filter((patch) => typeof patch === "string" && patch.trim())
    .map(ensureTrailingNewline)
    .join("\n");
}

async function findStashRefByLabel(cwd, stashLabel) {
  const output = await git(cwd, "stash", "list", "--format=%gd%x00%s");
  const records = output
    .trim()
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  for (const record of records) {
    const [ref, summary] = record.split("\0");
    if (ref && summary?.includes(stashLabel)) {
      return ref.trim();
    }
  }

  return null;
}

async function applyWorktreeHandoffStash(cwd, stashRef, options = {}) {
  const dropAfterApply = options.dropAfterApply === true;
  try {
    if (dropAfterApply) {
      await git(cwd, "stash", "apply", stashRef);
      await git(cwd, "stash", "drop", stashRef);
    } else {
      await git(cwd, "stash", "pop", stashRef);
    }
  } catch (err) {
    throw gitError(
      "create_worktree_failed",
      err.message || "Could not apply local changes in the new worktree."
    );
  }
}

async function applyCopiedLocalChangesToWorktree(cwd, patch) {
  if (!patch.trim()) {
    return;
  }

  const patchFilePath = path.join(os.tmpdir(), `remodex-worktree-copy-${randomBytes(6).toString("hex")}.patch`);
  fs.writeFileSync(patchFilePath, ensureTrailingNewline(patch), "utf8");

  try {
    await git(cwd, "apply", "--binary", "--whitespace=nowarn", patchFilePath);
  } catch (err) {
    throw gitError(
      "create_worktree_failed",
      err.message || "Could not copy local changes into the new worktree."
    );
  } finally {
    fs.rmSync(patchFilePath, { force: true });
  }
}

async function restoreWorktreeHandoffStash(cwd, stashRef) {
  try {
    await git(cwd, "stash", "pop", stashRef);
  } catch {
    // Best effort: if restore fails we prefer surfacing the original worktree error without masking it.
  }
}

async function rollbackFailedHandoffTransfer(cwd) {
  try {
    await git(cwd, "reset", "--hard", "HEAD");
  } catch {
    // Best effort: leave the original transfer error as the primary failure.
  }

  try {
    await git(cwd, "clean", "-fd");
  } catch {
    // Best effort: leave the original transfer error as the primary failure.
  }
}

async function cleanupManagedWorktree(repoRoot, worktreeRootPath, branchName = null) {
  try {
    await git(repoRoot, "worktree", "remove", "--force", worktreeRootPath);
  } catch {
    // Fall back to directory cleanup below.
  }

  if (branchName) {
    try {
      await git(repoRoot, "branch", "-D", branchName);
    } catch {
      // Best effort: leave the branch around if Git refuses deletion for any reason.
    }
  }

  fs.rmSync(path.dirname(worktreeRootPath), { recursive: true, force: true });
}

function parseWorktreePathByBranch(output, options = {}) {
  const worktreePathByBranch = {};
  const records = typeof output === "string" ? output.split("\n\n") : [];
  const projectRelativePath = typeof options.projectRelativePath === "string"
    ? options.projectRelativePath
    : "";

  for (const record of records) {
    const lines = record
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);

    if (!lines.length) {
      continue;
    }

    const worktreeLine = lines.find((line) => line.startsWith("worktree "));
    const branchLine = lines.find((line) => line.startsWith("branch "));
    const worktreePath = worktreeLine?.slice("worktree ".length).trim();
    const branchName = normalizeWorktreeBranchRef(branchLine?.slice("branch ".length).trim());

    if (!worktreePath || !branchName) {
      continue;
    }

    worktreePathByBranch[branchName] = scopedWorktreePath(worktreePath, projectRelativePath);
  }

  return worktreePathByBranch;
}

// Normalizes `git branch` output so the UI never sees worktree markers like `+ main`.
function normalizeBranchListEntry(rawLine) {
  const trimmed = typeof rawLine === "string" ? rawLine.trim() : "";
  if (!trimmed) {
    return null;
  }

  const isCurrent = trimmed.startsWith("* ");
  const isCheckedOutElsewhere = trimmed.startsWith("+ ");
  const name = trimmed.replace(/^[*+]\s+/, "").trim();

  if (!name) {
    return null;
  }

  return { isCurrent, isCheckedOutElsewhere, name };
}

function normalizeWorktreeBranchRef(rawRef) {
  const trimmed = typeof rawRef === "string" ? rawRef.trim() : "";
  if (!trimmed.startsWith("refs/heads/")) {
    return null;
  }

  const branchName = trimmed.slice("refs/heads/".length).trim();
  return branchName || null;
}

function normalizeCreatedBranchName(rawName) {
  const trimmed = typeof rawName === "string" ? rawName.trim() : "";
  if (!trimmed) {
    return "";
  }

  // Keep slash-separated branch groups, but normalize user-entered whitespace into Git-friendly dashes.
  const normalized = trimmed
    .split("/")
    .map((segment) => segment.trim().replace(/\s+/g, "-"))
    .join("/");

  if (normalized.startsWith("remodex/")) {
    return normalized;
  }
  return `remodex/${normalized}`;
}

function resolveBaseBranchName(rawBaseBranch, fallbackBranch) {
  const trimmedBaseBranch = typeof rawBaseBranch === "string" ? rawBaseBranch.trim() : "";
  if (trimmedBaseBranch) {
    return trimmedBaseBranch;
  }

  return typeof fallbackBranch === "string" && fallbackBranch.trim() ? fallbackBranch.trim() : "";
}

// Mirrors Codex-managed worktree paths under CODEX_HOME/worktrees/<token>/<repo>.
function allocateManagedWorktreePath(repoRoot) {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  const worktreesRoot = path.join(codexHome, "worktrees");
  fs.mkdirSync(worktreesRoot, { recursive: true });

  const repoName = path.basename(repoRoot) || "repo";
  for (let attempt = 0; attempt < 16; attempt += 1) {
    const token = randomBytes(2).toString("hex");
    const tokenDirectory = path.join(worktreesRoot, token);
    const worktreePath = path.join(tokenDirectory, repoName);
    if (fs.existsSync(tokenDirectory) || fs.existsSync(worktreePath)) {
      continue;
    }
    fs.mkdirSync(tokenDirectory, { recursive: true });
    return worktreePath;
  }

  throw gitError("create_worktree_failed", "Could not allocate a managed worktree path.");
}

async function localBranchExists(cwd, branchName) {
  try {
    await git(cwd, "show-ref", "--verify", "--quiet", `refs/heads/${branchName}`);
    return true;
  } catch {
    return false;
  }
}

async function assertValidCreatedBranchName(cwd, branchName) {
  try {
    await git(cwd, "check-ref-format", "--branch", branchName);
  } catch {
    throw gitError("invalid_branch_name", `Branch '${branchName}' is not a valid Git branch name.`);
  }
}

// Keeps branch creation local-only even when a same-named ref exists on origin.
async function remoteBranchExists(cwd, branchName) {
  try {
    await git(cwd, "show-ref", "--verify", "--quiet", `refs/remotes/origin/${branchName}`);
    return true;
  } catch {
    return false;
  }
}

function sameFilePath(leftPath, rightPath) {
  const normalizedLeft = normalizeExistingPath(leftPath);
  const normalizedRight = normalizeExistingPath(rightPath);
  return normalizedLeft !== null && normalizedLeft === normalizedRight;
}

function normalizeExistingPath(candidatePath) {
  if (typeof candidatePath !== "string") {
    return null;
  }

  const trimmedPath = candidatePath.trim();
  if (!trimmedPath) {
    return null;
  }

  try {
    return fs.realpathSync.native(trimmedPath);
  } catch {
    return path.resolve(trimmedPath);
  }
}

function managedWorktreesRoot() {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  return normalizeExistingPath(path.join(codexHome, "worktrees"));
}

function isManagedWorktreePath(candidatePath) {
  const normalizedCandidate = normalizeExistingPath(candidatePath);
  const normalizedRoot = managedWorktreesRoot();
  if (!normalizedCandidate || !normalizedRoot) {
    return false;
  }

  const relativePath = path.relative(normalizedRoot, normalizedCandidate);
  return !!relativePath && relativePath !== "." && !relativePath.startsWith("..") && !path.isAbsolute(relativePath);
}

function resolveProjectRelativePath(cwd, repoRoot) {
  const normalizedCwd = normalizeExistingPath(cwd);
  const normalizedRepoRoot = normalizeExistingPath(repoRoot);
  if (!normalizedCwd || !normalizedRepoRoot) {
    return "";
  }

  const relativePath = path.relative(normalizedRepoRoot, normalizedCwd);
  if (!relativePath || relativePath === ".") {
    return "";
  }

  return relativePath;
}

// Preserves package-scoped threads by reopening the matching subpath inside sibling worktrees.
function scopedWorktreePath(worktreeRootPath, projectRelativePath) {
  const normalizedWorktreeRootPath = normalizeExistingPath(worktreeRootPath);
  if (!normalizedWorktreeRootPath) {
    return worktreeRootPath;
  }
  if (!projectRelativePath) {
    return normalizedWorktreeRootPath;
  }

  const candidatePath = path.join(normalizedWorktreeRootPath, projectRelativePath);
  return isExistingDirectory(candidatePath) ? normalizeExistingPath(candidatePath) ?? candidatePath : normalizedWorktreeRootPath;
}

// Resolves a Local checkout path only when the matching subpath actually exists there.
function scopedLocalCheckoutPath(checkoutRootPath, projectRelativePath) {
  const normalizedCheckoutRootPath = normalizeExistingPath(checkoutRootPath);
  if (!normalizedCheckoutRootPath) {
    return null;
  }
  if (!projectRelativePath) {
    return normalizedCheckoutRootPath;
  }

  const candidatePath = path.join(normalizedCheckoutRootPath, projectRelativePath);
  return isExistingDirectory(candidatePath) ? normalizeExistingPath(candidatePath) ?? candidatePath : null;
}

// Computes the local repo delta that still exists on this machine and is not on the remote.
async function repoDiffTotals(cwd, context) {
  const baseRef = await resolveRepoDiffBase(cwd, context.tracking);
  const trackedTotals = await diffTotalsAgainstBase(cwd, baseRef);
  const untrackedPaths = context.fileLines
    .filter((line) => line.startsWith("?? "))
    .map((line) => line.substring(3).trim())
    .filter(Boolean);
  const untrackedTotals = await diffTotalsForUntrackedFiles(cwd, untrackedPaths);

  return {
    additions: trackedTotals.additions + untrackedTotals.additions,
    deletions: trackedTotals.deletions + untrackedTotals.deletions,
    binaryFiles: trackedTotals.binaryFiles + untrackedTotals.binaryFiles,
  };
}

// Uses upstream when available; otherwise falls back to commits not yet present on any remote.
async function resolveRepoDiffBase(cwd, tracking) {
  if (tracking) {
    try {
      return (await git(cwd, "merge-base", "HEAD", "@{u}")).trim();
    } catch {
      // Fall through to the local-only commit scan if upstream metadata is stale.
    }
  }

  const firstLocalOnlyCommit = (
    await git(cwd, "rev-list", "--reverse", "--topo-order", "HEAD", "--not", "--remotes")
  )
    .trim()
    .split("\n")
    .find(Boolean);

  if (!firstLocalOnlyCommit) {
    return "HEAD";
  }

  try {
    return (await git(cwd, "rev-parse", `${firstLocalOnlyCommit}^`)).trim();
  } catch {
    return EMPTY_TREE_HASH;
  }
}

async function diffTotalsAgainstBase(cwd, baseRef) {
  const output = await git(cwd, "diff", "--numstat", baseRef);
  return parseNumstatTotals(output);
}

async function gitDiffAgainstBase(cwd, baseRef) {
  return git(cwd, "diff", "--binary", "--find-renames", baseRef);
}

async function diffTotalsForUntrackedFiles(cwd, filePaths) {
  if (!filePaths.length) {
    return { additions: 0, deletions: 0, binaryFiles: 0 };
  }

  const totals = await Promise.all(
    filePaths.map(async (filePath) => {
      const output = await gitDiffNoIndexNumstat(cwd, filePath);
      return parseNumstatTotals(output);
    })
  );

  return totals.reduce(
    (aggregate, current) => ({
      additions: aggregate.additions + current.additions,
      deletions: aggregate.deletions + current.deletions,
      binaryFiles: aggregate.binaryFiles + current.binaryFiles,
    }),
    { additions: 0, deletions: 0, binaryFiles: 0 }
  );
}

// Counts commits reachable from HEAD that are not present on any remote ref.
async function countLocalOnlyCommits(cwd, context) {
  if (context.detached) {
    return 0;
  }

  const remoteRefs = await git(cwd, "for-each-ref", "--format=%(refname)", "refs/remotes");
  const hasAnyRemoteRefs = remoteRefs
    .trim()
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .length > 0;

  if (!hasAnyRemoteRefs) {
    return 0;
  }

  const output = await git(cwd, "rev-list", "--count", "HEAD", "--not", "--remotes");
  return Number.parseInt(output.trim(), 10) || 0;
}

function parseNumstatTotals(output) {
  return output
    .trim()
    .split("\n")
    .filter(Boolean)
    .reduce(
      (aggregate, line) => {
        const [rawAdditions, rawDeletions] = line.split("\t");
        const additions = Number.parseInt(rawAdditions, 10);
        const deletions = Number.parseInt(rawDeletions, 10);
        const isBinary = !Number.isFinite(additions) || !Number.isFinite(deletions);

        return {
          additions: aggregate.additions + (Number.isFinite(additions) ? additions : 0),
          deletions: aggregate.deletions + (Number.isFinite(deletions) ? deletions : 0),
          binaryFiles: aggregate.binaryFiles + (isBinary ? 1 : 0),
        };
      },
      { additions: 0, deletions: 0, binaryFiles: 0 }
    );
}

function resolveWorktreeChangeTransfer(rawValue) {
  const normalizedValue = typeof rawValue === "string" ? rawValue.trim().toLowerCase() : "";
  if (normalizedValue === "copy") {
    return "copy";
  }
  if (normalizedValue === "none") {
    return "none";
  }
  return "move";
}

function ensureTrailingNewline(value) {
  return value.endsWith("\n") ? value : `${value}\n`;
}

async function gitDiffNoIndexNumstat(cwd, filePath) {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["diff", "--no-index", "--numstat", "--", "/dev/null", filePath],
      { cwd, timeout: GIT_TIMEOUT_MS }
    );
    return stdout;
  } catch (err) {
    if (typeof err?.code === "number" && err.code === 1) {
      return err.stdout || "";
    }
    const msg = (err.stderr || err.message || "").trim();
    throw new Error(msg || "git diff --no-index failed");
  }
}

async function diffPatchForUntrackedFiles(cwd, filePaths) {
  if (!filePaths.length) {
    return "";
  }

  const patches = await Promise.all(filePaths.map((filePath) => gitDiffNoIndexPatch(cwd, filePath)));
  return patches.filter(Boolean).join("\n\n");
}

async function gitDiffNoIndexPatch(cwd, filePath) {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["diff", "--no-index", "--binary", "--", "/dev/null", filePath],
      { cwd, timeout: GIT_TIMEOUT_MS }
    );
    return stdout;
  } catch (err) {
    if (typeof err?.code === "number" && err.code === 1) {
      return err.stdout || "";
    }
    const msg = (err.stderr || err.message || "").trim();
    throw new Error(msg || "git diff --no-index failed");
  }
}

// ─── Helpers ──────────────────────────────────────────────────

function git(cwd, ...args) {
  return execFileAsync("git", args, { cwd, timeout: GIT_TIMEOUT_MS })
    .then(({ stdout }) => stdout)
    .catch((err) => {
      const msg = (err.stderr || err.message || "").trim();
      const wrapped = new Error(msg || "git command failed");
      throw wrapped;
    });
}

async function revListCounts(cwd) {
  const output = await git(cwd, "rev-list", "--left-right", "--count", "HEAD...@{u}");
  const parts = output.trim().split(/\s+/);
  return {
    ahead: parseInt(parts[0], 10) || 0,
    behind: parseInt(parts[1], 10) || 0,
  };
}

function parseBranchFromStatus(line) {
  // "## main...origin/main" or "## main" or "## HEAD (no branch)"
  const match = line.match(/^## (.+?)(?:\.{3}|$)/);
  if (!match) return null;
  const branch = match[1].trim();
  if (branch === "HEAD (no branch)" || branch.includes("HEAD detached")) return null;
  return branch;
}

function parseTrackingFromStatus(line) {
  const match = line.match(/\.{3}(.+?)(?:\s|$)/);
  return match ? match[1].trim() : null;
}

function computeState(dirty, ahead, behind, detached, noUpstream) {
  if (detached) return "detached_head";
  if (noUpstream) return "no_upstream";
  if (dirty && behind > 0) return "dirty_and_behind";
  if (dirty) return "dirty";
  if (ahead > 0 && behind > 0) return "diverged";
  if (behind > 0) return "behind_only";
  if (ahead > 0) return "ahead_only";
  return "up_to_date";
}

async function detectDefaultBranch(cwd, branches) {
  // Try symbolic-ref first
  try {
    const ref = await git(cwd, "symbolic-ref", "refs/remotes/origin/HEAD");
    const defaultBranch = ref.trim().replace("refs/remotes/origin/", "");
    // Repo default is metadata about origin, not a promise that the local selector should show it.
    if (defaultBranch) {
      return defaultBranch;
    }
  } catch {
    // ignore
  }

  // Some repos never record origin/HEAD locally, so prefer the common remote defaults before local fallback.
  if (await remoteBranchExists(cwd, "main")) return "main";
  if (await remoteBranchExists(cwd, "master")) return "master";

  // Fallback: prefer main, then master
  if (branches.includes("main")) return "main";
  if (branches.includes("master")) return "master";
  return branches[0] || null;
}

function gitError(errorCode, userMessage) {
  const err = new Error(userMessage);
  err.errorCode = errorCode;
  err.userMessage = userMessage;
  return err;
}

// Resolves git commands to a concrete local directory.
async function resolveGitCwd(params) {
  const requestedCwd = firstNonEmptyString([params.cwd, params.currentWorkingDirectory]);

  if (!requestedCwd) {
    throw gitError(
      "missing_working_directory",
      "Git actions require a bound local working directory."
    );
  }

  if (!isExistingDirectory(requestedCwd)) {
    throw gitError(
      "missing_working_directory",
      "The requested local working directory does not exist on this Mac."
    );
  }

  return requestedCwd;
}

function firstNonEmptyString(candidates) {
  for (const candidate of candidates) {
    if (typeof candidate !== "string") {
      continue;
    }

    const trimmed = candidate.trim();
    if (trimmed) {
      return trimmed;
    }
  }

  return null;
}

function isExistingDirectory(candidatePath) {
  try {
    return fs.statSync(candidatePath).isDirectory();
  } catch {
    return false;
  }
}

async function resolveRepoRoot(cwd) {
  const output = await git(cwd, "rev-parse", "--show-toplevel");
  const repoRoot = output.trim();
  return repoRoot || null;
}

async function resolveLocalCheckoutRoot(cwd) {
  const output = await git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir");
  const commonDir = output.trim();
  if (!commonDir) {
    return null;
  }

  const normalizedCommonDir = normalizeExistingPath(commonDir);
  if (!normalizedCommonDir) {
    return null;
  }

  if (path.basename(normalizedCommonDir) !== ".git") {
    return await resolveRepoRoot(cwd);
  }

  const checkoutRoot = normalizeExistingPath(path.dirname(normalizedCommonDir));
  return checkoutRoot || null;
}

module.exports = {
  handleGitRequest,
  gitStatus,
  __test: {
    gitBranches,
    gitCreateBranch,
    gitCreateWorktree,
    gitCreateManagedWorktree,
    gitTransferManagedHandoff,
    gitCheckout,
    gitRemoveWorktree,
    isManagedWorktreePath,
    normalizeBranchListEntry,
    normalizeCreatedBranchName,
    parseWorktreePathByBranch,
    ensureTrailingNewline,
    resolveWorktreeChangeTransfer,
    resolveLocalCheckoutRoot,
    scopedLocalCheckoutPath,
    scopedWorktreePath,
    resolveBaseBranchName,
  },
};
