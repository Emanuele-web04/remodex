// FILE: workspace-handler.js
// Purpose: Executes workspace-scoped reverse patch previews/applies without touching unrelated repo changes.
// Layer: Bridge handler
// Exports: handleWorkspaceRequest
// Depends on: child_process, fs, os, path, ./git-handler

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");
const { gitStatus } = require("./git-handler");

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 30_000;
const MAX_IMAGE_READ_BYTES = 8 * 1024 * 1024;
const IMAGE_MIME_TYPES_BY_EXTENSION = new Map([
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".png", "image/png"],
  [".gif", "image/gif"],
  [".webp", "image/webp"],
  [".heic", "image/heic"],
  [".heif", "image/heif"],
]);
const repoMutationLocks = new Map();

function handleWorkspaceRequest(rawMessage, sendResponse) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method.startsWith("workspace/")) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleWorkspaceMethod(method, params)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "workspace_error";
      const message = err.userMessage || err.message || "Unknown workspace error";
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

async function handleWorkspaceMethod(method, params) {
  if (method === "workspace/readImage") {
    return workspaceReadImage(params);
  }

  const cwd = await resolveWorkspaceCwd(params);
  const repoRoot = await resolveRepoRoot(cwd);

  switch (method) {
    case "workspace/revertPatchPreview":
      return workspaceRevertPatchPreview(repoRoot, params);
    case "workspace/revertPatchApply":
      return withRepoMutationLock(repoRoot, () => workspaceRevertPatchApply(repoRoot, params));
    default:
      throw workspaceError("unknown_method", `Unknown workspace method: ${method}`);
  }
}

// Reads only recognized local image files, and only from the bound repo or Codex generated-images cache.
async function workspaceReadImage(params) {
  const requestedPath = firstNonEmptyString([params.path, params.filePath, params.localPath]);
  if (!requestedPath) {
    throw workspaceError("missing_image_path", "The request must include an image path.");
  }

  const cwd = firstNonEmptyString([params.cwd, params.currentWorkingDirectory])
    ? await resolveWorkspaceCwd(params)
    : null;
  const imagePath = path.isAbsolute(requestedPath)
    ? path.resolve(requestedPath)
    : path.resolve(cwd || process.cwd(), requestedPath);
  const extension = path.extname(imagePath).toLowerCase();
  const mimeType = IMAGE_MIME_TYPES_BY_EXTENSION.get(extension);
  if (!mimeType) {
    throw workspaceError("unsupported_image_type", "Only local image files can be previewed.");
  }

  const [realImagePath, realGeneratedImagesRoot] = await Promise.all([
    realpathOrNull(imagePath),
    realpathOrNull(path.join(os.homedir(), ".codex", "generated_images")),
  ]);
  if (!realImagePath) {
    throw workspaceError("image_not_found", "The image file no longer exists on this Mac.");
  }

  const repoRoot = cwd ? await resolveRepoRoot(cwd).catch(() => null) : null;
  const realRepoRoot = repoRoot ? await realpathOrNull(repoRoot) : null;
  const isAllowed =
    (realRepoRoot && isPathInside(realImagePath, realRepoRoot))
    || (realGeneratedImagesRoot && isPathInside(realImagePath, realGeneratedImagesRoot));
  if (!isAllowed) {
    throw workspaceError("image_path_not_allowed", "Only images in this workspace or Codex generated images can be previewed.");
  }

  const stat = await fs.promises.stat(realImagePath);
  if (!stat.isFile()) {
    throw workspaceError("image_not_found", "The image path is not a file.");
  }
  if (stat.size > MAX_IMAGE_READ_BYTES) {
    throw workspaceError(
      "image_too_large",
      "This image is too large to send to the phone. Open it on the Mac or move a smaller preview into the workspace."
    );
  }

  const includeData = params.includeData !== false && params.metadataOnly !== true;
  const result = {
    path: realImagePath,
    fileName: path.basename(realImagePath),
    mimeType,
    byteLength: stat.size,
    mtimeMs: stat.mtimeMs,
  };
  if (!includeData) {
    return result;
  }
  if (isUnchangedImageRead(params, stat)) {
    return {
      ...result,
      notModified: true,
    };
  }

  const data = await fs.promises.readFile(realImagePath);
  return {
    ...result,
    byteLength: data.length,
    dataBase64: data.toString("base64"),
  };
}

function isUnchangedImageRead(params, stat) {
  const cachedByteLength = Number(params.ifByteLength);
  const cachedMtimeMs = Number(params.ifMtimeMs);
  return Number.isFinite(cachedByteLength)
    && Number.isFinite(cachedMtimeMs)
    && cachedByteLength === stat.size
    && cachedMtimeMs === stat.mtimeMs;
}

// Validates the reverse patch against the current tree without writing repo files.
async function workspaceRevertPatchPreview(repoRoot, params) {
  const forwardPatch = resolveForwardPatch(params);
  const analysis = analyzeUnifiedPatch(forwardPatch);
  const stagedFiles = await findStagedTargetedFiles(repoRoot, analysis.affectedFiles);

  if (analysis.unsupportedReasons.length || stagedFiles.length) {
    return {
      canRevert: false,
      affectedFiles: analysis.affectedFiles,
      conflicts: [],
      unsupportedReasons: analysis.unsupportedReasons,
      stagedFiles,
    };
  }

  const applyCheck = await runGitApply(repoRoot, ["apply", "--reverse", "--check"], forwardPatch);
  const conflicts = applyCheck.ok
    ? []
    : parseApplyConflicts(applyCheck.stderr || applyCheck.stdout || "Patch does not apply.");

  return {
    canRevert: applyCheck.ok && conflicts.length === 0,
    affectedFiles: analysis.affectedFiles,
    conflicts,
    unsupportedReasons: [],
    stagedFiles,
  };
}

// Reverse-applies the patch only after the same safety checks pass in the locked mutation path.
async function workspaceRevertPatchApply(repoRoot, params) {
  const preview = await workspaceRevertPatchPreview(repoRoot, params);
  if (!preview.canRevert) {
    return {
      success: false,
      revertedFiles: [],
      conflicts: preview.conflicts,
      unsupportedReasons: preview.unsupportedReasons,
      stagedFiles: preview.stagedFiles,
    };
  }

  const forwardPatch = resolveForwardPatch(params);
  const applyResult = await runGitApply(repoRoot, ["apply", "--reverse"], forwardPatch);
  if (!applyResult.ok) {
    return {
      success: false,
      revertedFiles: [],
      conflicts: parseApplyConflicts(applyResult.stderr || applyResult.stdout || "Patch does not apply."),
      unsupportedReasons: [],
      stagedFiles: [],
      status: await gitStatus(repoRoot).catch(() => null),
    };
  }

  const status = await gitStatus(repoRoot).catch(() => null);
  return {
    success: true,
    revertedFiles: preview.affectedFiles,
    conflicts: [],
    unsupportedReasons: [],
    stagedFiles: [],
    status,
  };
}

function resolveForwardPatch(params) {
  const forwardPatch =
    typeof params.forwardPatch === "string" ? params.forwardPatch : "";

  if (!forwardPatch.trim()) {
    throw workspaceError("missing_patch", "The request must include a non-empty forwardPatch.");
  }

  return forwardPatch.endsWith("\n") ? forwardPatch : `${forwardPatch}\n`;
}

function analyzeUnifiedPatch(rawPatch) {
  const patch = rawPatch.trim();
  if (!patch) {
    return {
      affectedFiles: [],
      unsupportedReasons: ["No exact patch was captured."],
    };
  }

  const chunks = splitPatchIntoChunks(patch);
  if (!chunks.length) {
    return {
      affectedFiles: [],
      unsupportedReasons: ["No exact patch was captured."],
    };
  }

  const affectedFiles = [];
  const unsupportedReasons = new Set();

  for (const chunk of chunks) {
    const analysis = analyzePatchChunk(chunk);
    if (analysis.path) {
      affectedFiles.push(analysis.path);
    }
    for (const reason of analysis.unsupportedReasons) {
      unsupportedReasons.add(reason);
    }
  }

  if (!affectedFiles.length) {
    unsupportedReasons.add("No exact patch was captured.");
  }

  return {
    affectedFiles: [...new Set(affectedFiles)].sort(),
    unsupportedReasons: [...unsupportedReasons].sort(),
  };
}

function splitPatchIntoChunks(patch) {
  const lines = patch.split("\n");
  if (!lines.length) {
    return [];
  }

  const chunks = [];
  let current = [];

  for (const line of lines) {
    if (line.startsWith("diff --git ") && current.length) {
      chunks.push(current);
      current = [];
    }
    current.push(line);
  }

  if (current.length) {
    chunks.push(current);
  }

  return chunks;
}

function analyzePatchChunk(lines) {
  const path = extractPatchPath(lines);
  const isBinary = lines.some((line) => line.startsWith("Binary files ") || line === "GIT binary patch");
  const isRenameOrModeOnly = lines.some((line) =>
    line.startsWith("rename from ")
      || line.startsWith("rename to ")
      || line.startsWith("copy from ")
      || line.startsWith("copy to ")
      || line.startsWith("old mode ")
      || line.startsWith("new mode ")
      || line.startsWith("similarity index ")
      || line.startsWith("new file mode 120")
      || line.startsWith("deleted file mode 120")
  );

  let additions = 0;
  let deletions = 0;
  for (const line of lines) {
    if (line.startsWith("+") && !line.startsWith("+++")) {
      additions += 1;
    } else if (line.startsWith("-") && !line.startsWith("---")) {
      deletions += 1;
    }
  }

  const unsupportedReasons = [];
  if (isBinary) {
    unsupportedReasons.push("Binary changes are not auto-revertable in v1.");
  }
  if (isRenameOrModeOnly) {
    unsupportedReasons.push("Rename, mode-only, or symlink changes are not auto-revertable in v1.");
  }
  if (!path || (!additions && !deletions && !lines.includes("--- /dev/null") && !lines.includes("+++ /dev/null"))) {
    if (!isBinary && !isRenameOrModeOnly) {
      unsupportedReasons.push("No exact patch was captured.");
    }
  }

  return { path, unsupportedReasons };
}

function extractPatchPath(lines) {
  for (const line of lines) {
    if (line.startsWith("+++ ")) {
      const normalized = normalizeDiffPath(line.slice(4).trim());
      if (normalized && normalized !== "/dev/null") {
        return normalized;
      }
    }
  }

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      const components = line.trim().split(/\s+/);
      if (components.length >= 4) {
        return normalizeDiffPath(components[3]);
      }
    }
  }

  return "";
}

function normalizeDiffPath(rawPath) {
  if (!rawPath) {
    return "";
  }

  if (rawPath.startsWith("a/") || rawPath.startsWith("b/")) {
    return rawPath.slice(2);
  }

  return rawPath;
}

async function findStagedTargetedFiles(cwd, affectedFiles) {
  if (!affectedFiles.length) {
    return [];
  }

  try {
    const output = await git(cwd, "diff", "--name-only", "--cached", "--", ...affectedFiles);
    return output
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .sort();
  } catch {
    return [];
  }
}

async function runGitApply(cwd, args, patchText) {
  const tempPatchPath = await writeTempPatchFile(patchText);

  try {
    const { stdout, stderr } = await execFileAsync("git", [...args, tempPatchPath], {
      cwd,
      timeout: GIT_TIMEOUT_MS,
    });
    return { ok: true, stdout, stderr };
  } catch (err) {
    return {
      ok: false,
      stdout: err.stdout || "",
      stderr: err.stderr || err.message || "",
    };
  } finally {
    try {
      fs.unlinkSync(tempPatchPath);
    } catch {
      // Ignore temp cleanup failures.
    }
  }
}

async function writeTempPatchFile(patchText) {
  const tempPatchPath = path.join(
    os.tmpdir(),
    `remodex-revert-${Date.now()}-${Math.random().toString(16).slice(2)}.patch`
  );
  await fs.promises.writeFile(tempPatchPath, patchText, "utf8");
  return tempPatchPath;
}

function parseApplyConflicts(stderr) {
  const lines = String(stderr || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  const conflictsByPath = new Map();
  for (const line of lines) {
    let path = "unknown";
    const patchFailedMatch = line.match(/^error:\s+patch failed:\s+(.+?):\d+$/i);
    const doesNotApplyMatch = line.match(/^error:\s+(.+?):\s+patch does not apply$/i);

    if (patchFailedMatch) {
      path = patchFailedMatch[1];
    } else if (doesNotApplyMatch) {
      path = doesNotApplyMatch[1];
    }

    if (!conflictsByPath.has(path)) {
      conflictsByPath.set(path, { path, message: line });
    }
  }

  if (!conflictsByPath.size && lines.length) {
    return [{ path: "unknown", message: lines.join(" ") }];
  }

  return [...conflictsByPath.values()];
}

async function withRepoMutationLock(cwd, callback) {
  const previous = repoMutationLocks.get(cwd) || Promise.resolve();
  let releaseCurrent = null;
  const current = new Promise((resolve) => {
    releaseCurrent = resolve;
  });
  const chained = previous.then(() => current);
  repoMutationLocks.set(cwd, chained);

  await previous;
  try {
    return await callback();
  } finally {
    releaseCurrent();
    if (repoMutationLocks.get(cwd) === chained) {
      repoMutationLocks.delete(cwd);
    }
  }
}

async function resolveWorkspaceCwd(params) {
  const requestedCwd = firstNonEmptyString([params.cwd, params.currentWorkingDirectory]);

  if (!requestedCwd) {
    throw workspaceError(
      "missing_working_directory",
      "Workspace actions require a bound local working directory."
    );
  }

  if (!isExistingDirectory(requestedCwd)) {
    throw workspaceError(
      "missing_working_directory",
      "The requested local working directory does not exist on this Mac."
    );
  }

  return requestedCwd;
}

// Resolves the canonical repo root so revert safety checks stay stable from nested chat folders.
async function resolveRepoRoot(cwd) {
  try {
    const output = await git(cwd, "rev-parse", "--show-toplevel");
    const repoRoot = output.trim();
    if (repoRoot) {
      return repoRoot;
    }
  } catch {
    // Fall through to the user-facing error below.
  }

  throw workspaceError(
    "missing_working_directory",
    "The selected local folder is not inside a Git repository."
  );
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

async function realpathOrNull(candidatePath) {
  try {
    return await fs.promises.realpath(candidatePath);
  } catch {
    return null;
  }
}

function isPathInside(candidatePath, rootPath) {
  const relative = path.relative(rootPath, candidatePath);
  return relative === "" || (relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function workspaceError(errorCode, userMessage) {
  const err = new Error(userMessage);
  err.errorCode = errorCode;
  err.userMessage = userMessage;
  return err;
}

function git(cwd, ...args) {
  return execFileAsync("git", args, { cwd, timeout: GIT_TIMEOUT_MS })
    .then(({ stdout }) => stdout)
    .catch((err) => {
      const msg = (err.stderr || err.message || "").trim();
      throw new Error(msg || "git command failed");
    });
}

module.exports = { handleWorkspaceMethod, handleWorkspaceRequest };
