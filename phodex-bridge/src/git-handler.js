// FILE: git-handler.js
// Purpose: Intercepts git/* JSON-RPC methods and executes git commands locally on the Mac.
// Layer: Bridge handler
// Exports: handleGitRequest
// Depends on: child_process, fs

const { execFile } = require("child_process");
const fs = require("fs");
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
  const state = computeState(dirty, ahead, behind, detached, noUpstream);
  const canPush = (ahead > 0 || noUpstream) && !detached;
  const diff = await repoDiffTotals(cwd, {
    tracking,
    fileLines,
  }).catch(() => ({ additions: 0, deletions: 0, binaryFiles: 0 }));

  return { repoRoot, branch, tracking, dirty, ahead, behind, state, canPush, files, diff };
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
  const output = await git(cwd, "branch", "-a", "--no-color");
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

    // Skip remotes/origin/HEAD -> ...
    if (name.includes("->")) continue;

    if (name.startsWith("remotes/origin/")) {
      branchSet.add(name.replace("remotes/origin/", ""));
    } else {
      branchSet.add(name);
      if (isCheckedOutElsewhere) {
        branchesCheckedOutElsewhere.add(name);
      }
    }

    if (isCurrent) current = name;
  }

  const branches = [...branchSet].sort();
  const defaultBranch = await detectDefaultBranch(cwd, branches);

  return {
    branches,
    branchesCheckedOutElsewhere: [...branchesCheckedOutElsewhere].sort(),
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
  const name = typeof params.name === "string" ? params.name.trim() : "";
  if (!name) {
    throw gitError("missing_branch_name", "Branch name is required.");
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
    if (defaultBranch && branches.includes(defaultBranch)) {
      return defaultBranch;
    }
  } catch {
    // ignore
  }

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

module.exports = {
  handleGitRequest,
  gitStatus,
  __test: {
    gitBranches,
    gitCheckout,
    normalizeBranchListEntry,
  },
};
