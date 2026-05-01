// FILE: workspace-checkpoints.js
// Purpose: Captures, diffs, and restores hidden Git checkpoints for turn-scoped undo.
// Layer: Bridge workspace support
// Exports: workspaceCheckpointCapture, workspaceCheckpointCopy, workspaceCheckpointDiff,
//   workspaceCheckpointRestorePreview, workspaceCheckpointRestoreApply
// Depends on: child_process, fs, os, path, ./git-handler

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");
const { gitStatus } = require("./git-handler");

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 30_000;
const CHECKPOINT_REFS_PREFIX = "refs/remodex/checkpoints";

async function workspaceCheckpointCapture(repoRoot, params) {
  const checkpoint = resolveCheckpointDescriptor(params);
  const commit = await captureGitCheckpoint(repoRoot, checkpoint.ref);
  return {
    repoRoot,
    checkpointRef: checkpoint.ref,
    checkpointKind: checkpoint.kind,
    commit,
    threadId: checkpoint.threadId,
    turnId: checkpoint.turnId || undefined,
    messageId: checkpoint.messageId || undefined,
  };
}

async function workspaceCheckpointCopy(repoRoot, params) {
  const sourceRef = resolveCheckpointRef(params, "source");
  const target = resolveCheckpointDescriptor(params, "target");
  const sourceCommit = await resolveCheckpointCommit(repoRoot, sourceRef);
  if (!sourceCommit) {
    return {
      copied: false,
      repoRoot,
      sourceCheckpointRef: sourceRef,
      checkpointRef: target.ref,
    };
  }

  await git(repoRoot, "update-ref", target.ref, sourceCommit);
  return {
    copied: true,
    repoRoot,
    sourceCheckpointRef: sourceRef,
    checkpointRef: target.ref,
    checkpointKind: target.kind,
    commit: sourceCommit,
    threadId: target.threadId,
    turnId: target.turnId || undefined,
    messageId: target.messageId || undefined,
  };
}

async function workspaceCheckpointDiff(repoRoot, params) {
  const fromRef = resolveCheckpointRef(params, "from");
  const toRef = resolveCheckpointRef(params, "to");
  const [fromCommit, toCommit] = await Promise.all([
    resolveCheckpointCommit(repoRoot, fromRef),
    resolveCheckpointCommit(repoRoot, toRef),
  ]);
  if (!fromCommit || !toCommit) {
    throw workspaceCheckpointError(
      "checkpoint_missing",
      "One of the requested workspace checkpoints is unavailable."
    );
  }

  const diff = await git(repoRoot, "diff", "--patch", "--minimal", "--no-color", fromCommit, toCommit);
  return {
    repoRoot,
    fromCheckpointRef: fromRef,
    toCheckpointRef: toRef,
    diff,
  };
}

async function workspaceCheckpointRestorePreview(repoRoot, params) {
  const checkpointRef = resolveCheckpointRef(params, "target");
  const commit = await resolveCheckpointCommit(repoRoot, checkpointRef);
  if (!commit) {
    throw workspaceCheckpointError(
      "checkpoint_missing",
      "The requested workspace checkpoint is unavailable."
    );
  }

  const [changedFiles, stagedFiles, untrackedFiles] = await Promise.all([
    changedFilesAgainstCommit(repoRoot, commit),
    stagedFilesInRepo(repoRoot),
    untrackedFilesInRepo(repoRoot),
  ]);

  return {
    canRestore: true,
    repoRoot,
    checkpointRef,
    commit,
    affectedFiles: uniqueSorted([...changedFiles, ...untrackedFiles]),
    stagedFiles,
    untrackedFiles,
  };
}

async function workspaceCheckpointRestoreApply(repoRoot, params) {
  if (params.confirmDestructiveRestore !== true) {
    throw workspaceCheckpointError(
      "restore_confirmation_required",
      "Checkpoint restore requires explicit destructive-restore confirmation."
    );
  }

  const preview = await workspaceCheckpointRestorePreview(repoRoot, params);
  const expectedTargetCommit = firstNonEmptyString([params.expectedTargetCommit]);
  if (expectedTargetCommit && preview.commit !== expectedTargetCommit) {
    throw workspaceCheckpointError(
      "checkpoint_changed",
      "The workspace checkpoint changed after preview. Review the restore again before applying it."
    );
  }

  const backup = backupDescriptorForRestore(params);
  const backupCommit = await captureGitCheckpoint(repoRoot, backup.ref);

  await git(repoRoot, "restore", "--source", preview.commit, "--worktree", "--staged", "--", ".");
  await git(repoRoot, "clean", "-fd", "--", ".");
  if (await hasHeadCommit(repoRoot)) {
    await git(repoRoot, "reset", "--quiet", "--", ".");
  }

  const status = await gitStatus(repoRoot).catch(() => null);
  return {
    success: true,
    repoRoot,
    checkpointRef: preview.checkpointRef,
    backupCheckpointRef: backup.ref,
    backupCommit,
    restoredFiles: preview.affectedFiles,
    status,
  };
}

function resolveCheckpointDescriptor(params, prefix = "") {
  const checkpointRef = firstNonEmptyString([
    params[`${prefix}CheckpointRef`],
    prefix ? null : params.checkpointRef,
  ]);
  if (checkpointRef) {
    return {
      ref: validateCheckpointRef(checkpointRef),
      kind: firstNonEmptyString([params[`${prefix}CheckpointKind`], params.checkpointKind]) || "custom",
      threadId: firstNonEmptyString([params.threadId]) || "",
      turnId: firstNonEmptyString([params.turnId]) || null,
      messageId: firstNonEmptyString([params.messageId]) || null,
    };
  }

  const threadId = requireIdentifier(params.threadId, "threadId");
  const kind = firstNonEmptyString([
    params[`${prefix}CheckpointKind`],
    params[`${prefix}Kind`],
    params.checkpointKind,
    params.kind,
  ]) || "turnEnd";
  const turnId = firstNonEmptyString([params[`${prefix}TurnId`], params.turnId]);
  const messageId = firstNonEmptyString([params[`${prefix}MessageId`], params.messageId]);
  const ref = checkpointRefFor({ threadId, kind, turnId, messageId });

  return {
    ref,
    kind,
    threadId,
    turnId: turnId || null,
    messageId: messageId || null,
  };
}

function resolveCheckpointRef(params, prefix) {
  const directRef = firstNonEmptyString([
    params[`${prefix}CheckpointRef`],
    params[`${prefix}Ref`],
    prefix === "target" ? params.checkpointRef : null,
  ]);
  if (directRef) {
    return validateCheckpointRef(directRef);
  }

  return resolveCheckpointDescriptor(params, prefix).ref;
}

function checkpointRefFor({ threadId, kind, turnId, messageId }) {
  const threadKey = encodeRefSegment(threadId);
  switch (kind) {
    case "messageStart":
      return `${CHECKPOINT_REFS_PREFIX}/${threadKey}/message-start/${encodeRefSegment(
        requireIdentifier(messageId, "messageId")
      )}`;
    case "turnStart":
      return `${CHECKPOINT_REFS_PREFIX}/${threadKey}/turn-start/${encodeRefSegment(
        requireIdentifier(turnId, "turnId")
      )}`;
    case "turnEnd":
    case "turn":
      return `${CHECKPOINT_REFS_PREFIX}/${threadKey}/turn/${encodeRefSegment(
        requireIdentifier(turnId, "turnId")
      )}`;
    case "restoreBackup":
      return `${CHECKPOINT_REFS_PREFIX}/${threadKey}/restore-backup/${Date.now()}-${Math.random()
        .toString(16)
        .slice(2)}`;
    default:
      throw workspaceCheckpointError(
        "invalid_checkpoint_kind",
        `Unsupported workspace checkpoint kind: ${kind}`
      );
  }
}

function backupDescriptorForRestore(params) {
  const threadId = requireIdentifier(params.threadId, "threadId");
  const ref = checkpointRefFor({ threadId, kind: "restoreBackup" });
  return {
    ref,
    kind: "restoreBackup",
    threadId,
  };
}

async function captureGitCheckpoint(repoRoot, checkpointRef) {
  const tempDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "remodex-checkpoint-"));
  const tempIndexPath = path.join(tempDir, `index-${process.pid}-${Date.now()}`);
  const env = {
    ...process.env,
    GIT_INDEX_FILE: tempIndexPath,
    GIT_AUTHOR_NAME: "Remodex",
    GIT_AUTHOR_EMAIL: "remodex@users.noreply.github.com",
    GIT_COMMITTER_NAME: "Remodex",
    GIT_COMMITTER_EMAIL: "remodex@users.noreply.github.com",
  };

  try {
    if (await hasHeadCommit(repoRoot)) {
      await git(repoRoot, "read-tree", "HEAD", { env });
    }
    await git(repoRoot, "add", "-A", "--", ".", { env });
    const treeOid = (await git(repoRoot, "write-tree", { env })).trim();
    if (!treeOid) {
      throw workspaceCheckpointError(
        "checkpoint_capture_failed",
        "Git did not produce a checkpoint tree."
      );
    }

    const message = `remodex checkpoint ref=${checkpointRef}`;
    const commitOid = (await git(repoRoot, "commit-tree", treeOid, "-m", message, { env })).trim();
    if (!commitOid) {
      throw workspaceCheckpointError(
        "checkpoint_capture_failed",
        "Git did not produce a checkpoint commit."
      );
    }

    await git(repoRoot, "update-ref", checkpointRef, commitOid);
    return commitOid;
  } finally {
    await fs.promises.rm(tempDir, { recursive: true, force: true }).catch(() => {});
  }
}

async function resolveCheckpointCommit(repoRoot, checkpointRef) {
  const result = await gitResult(
    repoRoot,
    ["rev-parse", "--verify", "--quiet", `${checkpointRef}^{commit}`],
    { allowNonZeroExit: true }
  );
  if (result.code !== 0) {
    return null;
  }
  const commit = result.stdout.trim();
  return commit || null;
}

async function hasHeadCommit(repoRoot) {
  const result = await gitResult(repoRoot, ["rev-parse", "--verify", "--quiet", "HEAD"], {
    allowNonZeroExit: true,
  });
  return result.code === 0 && result.stdout.trim().length > 0;
}

async function changedFilesAgainstCommit(repoRoot, commit) {
  const output = await git(repoRoot, "diff", "--name-only", commit, "--");
  return output.split("\n").map((line) => line.trim()).filter(Boolean);
}

async function stagedFilesInRepo(repoRoot) {
  const output = await git(repoRoot, "diff", "--name-only", "--cached");
  return output.split("\n").map((line) => line.trim()).filter(Boolean);
}

async function untrackedFilesInRepo(repoRoot) {
  const output = await git(repoRoot, "ls-files", "--others", "--exclude-standard");
  return output.split("\n").map((line) => line.trim()).filter(Boolean);
}

function validateCheckpointRef(checkpointRef) {
  const normalized = String(checkpointRef || "").trim();
  if (!normalized.startsWith(`${CHECKPOINT_REFS_PREFIX}/`)) {
    throw workspaceCheckpointError(
      "invalid_checkpoint_ref",
      "Workspace checkpoint refs must stay inside the Remodex checkpoint namespace."
    );
  }
  if (normalized.includes("..") || normalized.includes(" ")) {
    throw workspaceCheckpointError(
      "invalid_checkpoint_ref",
      "Workspace checkpoint ref contains invalid path segments."
    );
  }
  return normalized;
}

function requireIdentifier(value, name) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized) {
    throw workspaceCheckpointError(
      "missing_checkpoint_identifier",
      `Workspace checkpoint requires ${name}.`
    );
  }
  return normalized;
}

function encodeRefSegment(value) {
  return Buffer.from(requireIdentifier(value, "checkpoint segment"), "utf8")
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function uniqueSorted(values) {
  return [...new Set(values.filter(Boolean))].sort();
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

async function git(repoRoot, ...args) {
  let options = {};
  if (args.length && typeof args[args.length - 1] === "object" && !Array.isArray(args[args.length - 1])) {
    options = args.pop();
  }
  const result = await gitResult(repoRoot, args, options);
  return result.stdout;
}

async function gitResult(repoRoot, args, options = {}) {
  try {
    const { stdout, stderr } = await execFileAsync("git", args, {
      cwd: repoRoot,
      timeout: GIT_TIMEOUT_MS,
      env: options.env || process.env,
    });
    return { code: 0, stdout, stderr };
  } catch (err) {
    if (options.allowNonZeroExit) {
      return {
        code: typeof err.code === "number" ? err.code : 1,
        stdout: err.stdout || "",
        stderr: err.stderr || err.message || "",
      };
    }
    const message = (err.stderr || err.message || "git command failed").trim();
    throw workspaceCheckpointError("git_failed", message);
  }
}

function workspaceCheckpointError(errorCode, userMessage) {
  const err = new Error(userMessage);
  err.errorCode = errorCode;
  err.userMessage = userMessage;
  return err;
}

module.exports = {
  workspaceCheckpointCapture,
  workspaceCheckpointCopy,
  workspaceCheckpointDiff,
  workspaceCheckpointRestorePreview,
  workspaceCheckpointRestoreApply,
};
