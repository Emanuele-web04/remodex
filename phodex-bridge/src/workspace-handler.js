// FILE: workspace-handler.js
// Purpose: Executes workspace-scoped previews, reads, and patch operations without touching unrelated repo changes.
// Layer: Bridge handler
// Exports: handleWorkspaceRequest
// Depends on: child_process, fs, os, path, ./codex-home, ./git-handler

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify, TextDecoder } = require("util");
const { resolveCodexGeneratedImagesRoot } = require("./codex-home");
const { gitStatus } = require("./git-handler");
const {
  workspaceCheckpointCapture,
  workspaceCheckpointCopy,
  workspaceCheckpointDiff,
  workspaceCheckpointRestoreApply,
  workspaceCheckpointRestorePreview,
} = require("./workspace-checkpoints");

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 30_000;
const MAX_IMAGE_READ_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_PREVIEW_READ_BYTES = 2 * 1024 * 1024;
const MAX_TEXT_FILE_READ_BYTES = 2 * 1024 * 1024;
const BINARY_SNIFF_BYTES = 8 * 1024;
const MAX_BASENAME_FALLBACK_MATCHES = 2;
const MIN_IMAGE_PREVIEW_PIXEL_DIMENSION = 128;
const MAX_IMAGE_PREVIEW_PIXEL_DIMENSION = 3_200;
const IMAGE_PREVIEW_RETRY_SCALE = 0.75;
const IMAGE_PREVIEW_TOOL_TIMEOUT_MS = 5_000;
const IMAGE_PREVIEW_TOTAL_TIMEOUT_MS = 15_000;
const IMAGE_MIME_TYPES_BY_EXTENSION = new Map([
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".png", "image/png"],
  [".gif", "image/gif"],
  [".webp", "image/webp"],
  [".heic", "image/heic"],
  [".heif", "image/heif"],
]);
/** Match git-handler.js: Node default maxBuffer is 1 MiB. */
const GIT_EXEC_MAX_BUFFER_BYTES = 50 * 1024 * 1024;
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
  if (method === "workspace/readFile") {
    return workspaceReadFile(params);
  }

  const cwd = await resolveWorkspaceCwd(params);
  const repoRoot = await resolveRepoRoot(cwd);

  switch (method) {
    case "workspace/checkpointCapture":
      return withRepoMutationLock(repoRoot, () => workspaceCheckpointCapture(repoRoot, params));
    case "workspace/checkpointCopy":
      return withRepoMutationLock(repoRoot, () => workspaceCheckpointCopy(repoRoot, params));
    case "workspace/checkpointDiff":
      return workspaceCheckpointDiff(repoRoot, params);
    case "workspace/checkpointRestorePreview":
      return workspaceCheckpointRestorePreview(repoRoot, params);
    case "workspace/checkpointRestoreApply":
      return withRepoMutationLock(repoRoot, () => workspaceCheckpointRestoreApply(repoRoot, params));
    case "workspace/revertPatchPreview":
      return workspaceRevertPatchPreview(repoRoot, params);
    case "workspace/revertPatchApply":
      return withRepoMutationLock(repoRoot, () => workspaceRevertPatchApply(repoRoot, params));
    case "workspace/revertPatchBatchPreview":
      return workspaceRevertPatchBatchPreview(repoRoot, params);
    case "workspace/revertPatchBatchApply":
      return withRepoMutationLock(repoRoot, () => workspaceRevertPatchBatchApply(repoRoot, params));
    default:
      throw workspaceError("unknown_method", `Unknown workspace method: ${method}`);
  }
}

// Reads a UTF-8 text file from the active workspace for the phone-side read-only viewer.
async function workspaceReadFile(params) {
  const requestedPath = firstNonEmptyString([params.path, params.filePath, params.localPath]);
  if (!requestedPath) {
    throw workspaceError("missing_file_path", "The request must include a file path.");
  }

  const cwd = await resolveWorkspaceCwd(params);
  const realWorkspaceRoot = await resolveReadableWorkspaceRoot(cwd);
  const realFilePath = await resolveWorkspaceTextFilePath(cwd, requestedPath, realWorkspaceRoot);
  if (!realFilePath) {
    throw workspaceError("file_not_found", "The file no longer exists on this Mac.");
  }
  if (!realWorkspaceRoot || !isPathInside(realFilePath, realWorkspaceRoot)) {
    throw workspaceError("file_path_not_allowed", "Only files in the current workspace can be viewed.");
  }

  const stat = await fs.promises.stat(realFilePath);
  if (!stat.isFile()) {
    throw workspaceError("file_not_found", "The path is not a file.");
  }
  if (stat.size > MAX_TEXT_FILE_READ_BYTES) {
    throw workspaceError(
      "file_too_large",
      "This file is too large to send to the phone. Open it on the Mac or ask for a smaller section."
    );
  }

  const result = {
    path: realFilePath,
    fileName: path.basename(realFilePath),
    byteLength: stat.size,
    mtimeMs: stat.mtimeMs,
    encoding: "utf-8",
  };
  if (params.includeContent === false || params.metadataOnly === true) {
    return result;
  }
  if (isUnchangedTextFileRead(params, stat)) {
    return {
      ...result,
      notModified: true,
    };
  }

  const data = await fs.promises.readFile(realFilePath);
  const content = decodeUtf8TextFile(data);
  return {
    ...result,
    content,
    lineCount: countLines(content),
  };
}

// Reads recognized local image files from the bound repo, Codex image cache, or host temp screenshot folders.
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
  let mimeType = IMAGE_MIME_TYPES_BY_EXTENSION.get(extension);

  const [realImagePath, realGeneratedImagesRoot] = await Promise.all([
    realpathOrNull(imagePath),
    realpathOrNull(resolveCodexGeneratedImagesRoot()),
  ]);
  if (!realImagePath) {
    throw workspaceError("image_not_found", "The image file no longer exists on this Mac.");
  }

  const [realWorkspaceRoot, realTempRoots] = await Promise.all([
    cwd ? resolveImageWorkspaceRoot(cwd) : null,
    realTemporaryImageRoots(),
  ]);
  const isAllowed =
    (realWorkspaceRoot && isPathInside(realImagePath, realWorkspaceRoot))
    || (realGeneratedImagesRoot && isPathInside(realImagePath, realGeneratedImagesRoot))
    || realTempRoots.some((tempRoot) => isPathInside(realImagePath, tempRoot));
  if (!isAllowed) {
    throw workspaceError("image_path_not_allowed", "Only images in this workspace, Codex generated images, or temporary screenshot files can be previewed.");
  }

  const stat = await fs.promises.stat(realImagePath);
  if (!stat.isFile()) {
    throw workspaceError("image_not_found", "The image path is not a file.");
  }
  if (!mimeType) {
    mimeType = await sniffImageMimeType(realImagePath);
  }
  if (!mimeType) {
    throw workspaceError("unsupported_image_type", "Only local image files can be previewed.");
  }
  const includeData = params.includeData !== false && params.metadataOnly !== true;
  const maxPixelDimension = normalizedPreviewPixelDimension(params);
  if (stat.size > MAX_IMAGE_READ_BYTES && !maxPixelDimension) {
    throw workspaceError(
      "image_too_large",
      "This image is too large to send to the phone. Open it on the Mac or move a smaller preview into the workspace."
    );
  }

  const result = {
    path: realImagePath,
    fileName: path.basename(realImagePath),
    mimeType,
    byteLength: stat.size,
    mtimeMs: stat.mtimeMs,
    previewMaxPixelDimension: maxPixelDimension || undefined,
  };
  if (!includeData) {
    return result;
  }
  if (isUnchangedImageRead(params, stat, maxPixelDimension)) {
    return {
      ...result,
      notModified: true,
    };
  }

  const data = maxPixelDimension
    ? await readPreviewImageData(realImagePath, maxPixelDimension, stat.size)
    : await fs.promises.readFile(realImagePath);
  return {
    ...result,
    dataByteLength: data.length,
    dataBase64: data.toString("base64"),
  };
}

function normalizedPreviewPixelDimension(params) {
  const requested = Number(params.maxPixelDimension || params.previewMaxPixelDimension);
  if (!Number.isFinite(requested) || requested <= 0) {
    return null;
  }
  return Math.min(
    MAX_IMAGE_PREVIEW_PIXEL_DIMENSION,
    Math.max(MIN_IMAGE_PREVIEW_PIXEL_DIMENSION, Math.round(requested))
  );
}

async function sniffImageMimeType(filePath) {
  let header;
  try {
    const handle = await fs.promises.open(filePath, "r");
    try {
      header = Buffer.alloc(16);
      const read = await handle.read(header, 0, header.length, 0);
      header = header.subarray(0, read.bytesRead);
    } finally {
      await handle.close();
    }
  } catch {
    return null;
  }

  if (header.length >= 8 && header.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return "image/png";
  }
  if (header.length >= 3 && header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) {
    return "image/jpeg";
  }
  if (header.length >= 6 && (header.subarray(0, 6).toString("ascii") === "GIF87a" || header.subarray(0, 6).toString("ascii") === "GIF89a")) {
    return "image/gif";
  }
  if (header.length >= 12 && header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WEBP") {
    return "image/webp";
  }

  return null;
}

async function realTemporaryImageRoots() {
  const candidates = [
    os.tmpdir(),
    process.env.TMPDIR,
  ];

  if (process.platform === "darwin") {
    candidates.push("/tmp");
    candidates.push(path.join(os.homedir(), "Library", "Caches", "com.raycast-x.macos", "clipboard"));
  }

  const roots = await Promise.all(
    Array.from(new Set(candidates.filter(Boolean))).map((candidate) => realpathOrNull(candidate))
  );
  return Array.from(new Set(roots.filter(Boolean)));
}

// Read-only previews can scope non-git Codex scratch folders to cwd while rejecting broad roots.
async function resolveReadableWorkspaceRoot(cwd) {
  const realRepoRoot = await resolveRepoRoot(cwd).then(realpathOrNull).catch(() => null);
  if (realRepoRoot) {
    return realRepoRoot;
  }

  const realCwd = await realpathOrNull(cwd);
  if (!realCwd || isBroadWorkspaceRoot(realCwd)) {
    return null;
  }
  return realCwd;
}

async function resolveImageWorkspaceRoot(cwd) {
  return resolveReadableWorkspaceRoot(cwd);
}

// Handles assistant links that only include a filename by finding one unique workspace match.
async function resolveWorkspaceTextFilePath(cwd, requestedPath, realWorkspaceRoot) {
  const filePath = path.isAbsolute(requestedPath)
    ? path.resolve(requestedPath)
    : path.resolve(cwd, requestedPath);
  const realFilePath = await realpathOrNull(filePath);
  if (realFilePath || path.isAbsolute(requestedPath) || !realWorkspaceRoot) {
    return realFilePath;
  }

  if (!isBareFileName(requestedPath)) {
    return null;
  }

  return resolveUniqueWorkspaceBasenameMatch(realWorkspaceRoot, requestedPath);
}

async function resolveUniqueWorkspaceBasenameMatch(realWorkspaceRoot, requestedFileName) {
  const matches = await findWorkspaceBasenameMatches(realWorkspaceRoot, requestedFileName);
  if (matches.length === 0) {
    return null;
  }
  if (matches.length > 1) {
    throw workspaceError(
      "file_path_ambiguous",
      `Multiple files named "${requestedFileName}" exist in this workspace. Use a path with folders.`
    );
  }
  return matches[0];
}

async function findWorkspaceBasenameMatches(realWorkspaceRoot, requestedFileName) {
  const matches = [];
  const output = await git(realWorkspaceRoot, "ls-files", "-co", "--exclude-standard").catch(() => "");
  const relativePaths = output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  for (const relativePath of relativePaths) {
    if (path.basename(relativePath) !== requestedFileName) {
      continue;
    }
    const realCandidate = await realpathOrNull(path.resolve(realWorkspaceRoot, relativePath));
    if (realCandidate && isPathInside(realCandidate, realWorkspaceRoot)) {
      matches.push(realCandidate);
      if (matches.length >= MAX_BASENAME_FALLBACK_MATCHES) {
        break;
      }
    }
  }
  return matches;
}

function isBareFileName(candidatePath) {
  return candidatePath === path.basename(candidatePath)
    && candidatePath !== "."
    && candidatePath !== "..";
}

function isBroadWorkspaceRoot(candidatePath) {
  const normalized = path.resolve(candidatePath);
  return normalized === path.parse(normalized).root
    || normalized === path.resolve(os.homedir());
}

function decodeUtf8TextFile(data) {
  const sample = data.subarray(0, Math.min(data.length, BINARY_SNIFF_BYTES));
  if (sample.includes(0)) {
    throw workspaceError("binary_file", "This file looks binary, so it cannot be shown as text.");
  }

  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(data);
  } catch {
    throw workspaceError("unsupported_text_encoding", "Only UTF-8 text files can be viewed.");
  }
}

function countLines(content) {
  if (!content) {
    return 0;
  }
  const newlineCount = (content.match(/\n/g) || []).length;
  return content.endsWith("\n") ? newlineCount : newlineCount + 1;
}

async function readPreviewImageData(imagePath, maxPixelDimension, originalByteLength) {
  if (!usesNativeImagePreview()) {
    if (originalByteLength <= MAX_IMAGE_PREVIEW_READ_BYTES) {
      return fs.promises.readFile(imagePath);
    }

    throw workspaceError(
      "image_preview_unsupported_platform",
      "This computer cannot resize image previews yet. Try a smaller image or open it on the computer."
    );
  }

  let sawConversionFailure = false;
  const previewDeadline = Date.now() + IMAGE_PREVIEW_TOTAL_TIMEOUT_MS;
  for (const candidateDimension of previewPixelDimensionCandidates(maxPixelDimension)) {
    const remainingTimeoutMs = previewDeadline - Date.now();
    if (remainingTimeoutMs <= 0) {
      throw workspaceError(
        "image_preview_timed_out",
        "This image preview took too long to resize. Try a smaller image or open it on the computer."
      );
    }

    try {
      const previewData = await downsampleImageNative(
        imagePath,
        candidateDimension,
        Math.min(IMAGE_PREVIEW_TOOL_TIMEOUT_MS, remainingTimeoutMs)
      );
      if (previewData && previewData.length > 0 && previewData.length <= MAX_IMAGE_PREVIEW_READ_BYTES) {
        return previewData;
      }
    } catch (err) {
      if (isImagePreviewTimeoutError(err)) {
        throw workspaceError(
          "image_preview_timed_out",
          "This image preview took too long to resize. Try a smaller image or open it on the computer."
        );
      }
      sawConversionFailure = true;
    }
  }

  if (sawConversionFailure) {
    throw workspaceError(
      "image_preview_failed",
      "This image could not be converted into a lightweight phone preview."
    );
  }

  throw workspaceError(
    "image_preview_too_large",
    "This image preview is still too large to send to the phone."
  );
}

function previewPixelDimensionCandidates(maxPixelDimension) {
  const dimensions = [];
  let next = maxPixelDimension;
  while (next >= MIN_IMAGE_PREVIEW_PIXEL_DIMENSION) {
    dimensions.push(next);
    if (next === MIN_IMAGE_PREVIEW_PIXEL_DIMENSION) {
      break;
    }
    next = Math.max(
      MIN_IMAGE_PREVIEW_PIXEL_DIMENSION,
      Math.floor(next * IMAGE_PREVIEW_RETRY_SCALE)
    );
  }

  // Hard-to-compress previews can stay oversized after one resize; these checkpoints keep retry behavior predictable.
  for (const checkpoint of [1024, 768, 512, 384, 256, MIN_IMAGE_PREVIEW_PIXEL_DIMENSION]) {
    if (checkpoint <= maxPixelDimension) {
      dimensions.push(checkpoint);
    }
  }

  return Array.from(new Set(dimensions)).sort((a, b) => b - a);
}

function usesNativeImagePreview() {
  const normalizedPlatform = String(process.platform || "").trim().toLowerCase();
  return normalizedPlatform === "darwin"
    || normalizedPlatform === "macos"
    || normalizedPlatform === "mac"
    || normalizedPlatform === "win32"
    || normalizedPlatform === "windows";
}

async function downsampleImageNative(imagePath, maxPixelDimension, timeoutMs = IMAGE_PREVIEW_TOOL_TIMEOUT_MS) {
  return usesWindowsImagePreview()
    ? downsampleImageWithPowerShell(imagePath, maxPixelDimension, timeoutMs)
    : downsampleImageWithSips(imagePath, maxPixelDimension, timeoutMs);
}

function usesWindowsImagePreview() {
  const normalizedPlatform = String(process.platform || "").trim().toLowerCase();
  return normalizedPlatform === "win32" || normalizedPlatform === "windows";
}

async function downsampleImageWithSips(imagePath, maxPixelDimension, timeoutMs = IMAGE_PREVIEW_TOOL_TIMEOUT_MS) {
  const tempDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "remodex-image-preview-"));
  const outputPath = path.join(tempDir, `preview${path.extname(imagePath) || ".png"}`);
  const command = resolveHostCommand("sips");
  try {
    await execFileAsync(command.file, [
      ...command.args,
      "-Z",
      String(maxPixelDimension),
      imagePath,
      "--out",
      outputPath,
    ], {
      timeout: Math.max(1, Math.floor(timeoutMs)),
      maxBuffer: 1024 * 1024,
    });
    return await fs.promises.readFile(outputPath);
  } finally {
    await fs.promises.rm(tempDir, { recursive: true, force: true }).catch(() => {});
  }
}

function resolveHostCommand(commandName) {
  if (path.delimiter !== ";") {
    return { file: commandName, args: [] };
  }

  const pathEntries = String(process.env.PATH || "")
    .split(path.delimiter)
    .filter(Boolean);
  for (const entry of pathEntries) {
    const jsShim = path.join(entry, `${commandName}.js`);
    if (fs.existsSync(jsShim)) {
      return { file: process.execPath, args: [jsShim] };
    }
  }
  return { file: commandName, args: [] };
}

async function downsampleImageWithPowerShell(imagePath, maxPixelDimension, timeoutMs = IMAGE_PREVIEW_TOOL_TIMEOUT_MS) {
  const tempDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "remodex-image-preview-"));
  const outputPath = path.join(tempDir, `preview${path.extname(imagePath) || ".png"}`);
  const scriptPath = path.join(tempDir, "resize-preview.ps1");
  const script = `
param(
  [Parameter(Mandatory=$true)][string]$InputPath,
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [Parameter(Mandatory=$true)][int]$MaxDimension
)
Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($InputPath)
try {
  $longest = [Math]::Max($image.Width, $image.Height)
  if ($longest -le 0) { throw "Invalid image dimensions." }
  $scale = [Math]::Min(1.0, [double]$MaxDimension / [double]$longest)
  $targetWidth = [Math]::Max(1, [int][Math]::Round($image.Width * $scale))
  $targetHeight = [Math]::Max(1, [int][Math]::Round($image.Height * $scale))
  $bitmap = New-Object System.Drawing.Bitmap $targetWidth, $targetHeight
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.DrawImage($image, 0, 0, $targetWidth, $targetHeight)
    } finally {
      $graphics.Dispose()
    }
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    if ($bitmap) { $bitmap.Dispose() }
  }
} finally {
  $image.Dispose()
}
`;
  try {
    await fs.promises.writeFile(scriptPath, script, "utf8");
    await execFileAsync("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath,
      imagePath,
      outputPath,
      String(maxPixelDimension),
    ], {
      timeout: Math.max(1, Math.floor(timeoutMs)),
      maxBuffer: 1024 * 1024,
      windowsHide: true,
    });
    return await fs.promises.readFile(outputPath);
  } finally {
    await fs.promises.rm(tempDir, { recursive: true, force: true }).catch(() => {});
  }
}

function isImagePreviewTimeoutError(err) {
  return err?.code === "ETIMEDOUT"
    || (err?.killed === true && err?.signal === "SIGTERM")
    || /timed out|timeout/i.test(String(err?.message || ""));
}

function isUnchangedImageRead(params, stat, maxPixelDimension) {
  const cachedByteLength = Number(params.ifByteLength);
  const cachedMtimeMs = Number(params.ifMtimeMs);
  const cachedPreviewMaxPixelDimension = Number(params.ifPreviewMaxPixelDimension || params.ifMaxPixelDimension);
  const previewDimensionMatches = maxPixelDimension
    ? Number.isFinite(cachedPreviewMaxPixelDimension) && cachedPreviewMaxPixelDimension === maxPixelDimension
    : !Number.isFinite(cachedPreviewMaxPixelDimension);
  return Number.isFinite(cachedByteLength)
    && Number.isFinite(cachedMtimeMs)
    && previewDimensionMatches
    && cachedByteLength === stat.size
    && cachedMtimeMs === stat.mtimeMs;
}

function isUnchangedTextFileRead(params, stat) {
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

  const applyCheck = await checkReversePatch(repoRoot, forwardPatch);
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
  const forwardPatch = resolveForwardPatch(params);
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

  const checkedPatch = await checkReversePatch(repoRoot, forwardPatch);
  const applyResult = checkedPatch.ok
    ? await runGitApply(repoRoot, checkedPatch.applyArgs, forwardPatch)
    : checkedPatch;
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

  await resetTargetedFilesIndex(repoRoot, preview.affectedFiles);
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

// Validates a newest-first patch batch as one reverse operation so dependent patches see the right state.
async function workspaceRevertPatchBatchPreview(repoRoot, params) {
  const patches = resolveForwardPatchBatch(params);
  const analyses = patches.map((patch) => analyzeUnifiedPatch(patch.forwardPatch));
  const affectedFiles = uniqueSorted(analyses.flatMap((analysis) => analysis.affectedFiles));
  const unsupportedReasons = uniqueSorted(analyses.flatMap((analysis) => analysis.unsupportedReasons));
  const stagedFiles = await findStagedTargetedFiles(repoRoot, affectedFiles);

  if (unsupportedReasons.length || stagedFiles.length) {
    return {
      canRevert: false,
      affectedFiles,
      conflicts: [],
      unsupportedReasons,
      stagedFiles,
      patchResults: patches.map((patch, index) => ({
        id: patch.id,
        canRevert: analyses[index].unsupportedReasons.length === 0,
        unsupportedReasons: analyses[index].unsupportedReasons,
      })),
    };
  }

  const sequenceCheck = await previewReversePatchSequence(repoRoot, patches, affectedFiles);
  const conflicts = sequenceCheck.ok
    ? []
    : parseApplyConflicts(sequenceCheck.stderr || sequenceCheck.stdout || "Patch batch does not apply.");

  return {
    canRevert: sequenceCheck.ok && conflicts.length === 0,
    affectedFiles,
    conflicts,
    unsupportedReasons: [],
    stagedFiles,
    patchResults: patches.map((patch) => ({
      id: patch.id,
      canRevert: sequenceCheck.ok && conflicts.length === 0,
    })),
  };
}

// Applies all batch patches under one repo lock and only marks success after the full reverse patch lands.
async function workspaceRevertPatchBatchApply(repoRoot, params) {
  const patches = resolveForwardPatchBatch(params);
  const preview = await workspaceRevertPatchBatchPreview(repoRoot, params);
  if (!preview.canRevert) {
    return {
      success: false,
      revertedFiles: [],
      conflicts: preview.conflicts,
      unsupportedReasons: preview.unsupportedReasons,
      stagedFiles: preview.stagedFiles,
      patchResults: preview.patchResults || [],
    };
  }

  const applyResult = await applyReversePatchSequence(repoRoot, patches, preview.affectedFiles);
  if (!applyResult.ok) {
    return {
      success: false,
      revertedFiles: [],
      conflicts: parseApplyConflicts(applyResult.stderr || applyResult.stdout || "Patch batch does not apply."),
      unsupportedReasons: [],
      stagedFiles: [],
      patchResults: patches.map((patch) => ({
        id: patch.id,
        applied: applyResult.appliedPatchIds.includes(patch.id),
      })),
      status: await gitStatus(repoRoot).catch(() => null),
    };
  }

  await resetTargetedFilesIndex(repoRoot, preview.affectedFiles);
  const status = await gitStatus(repoRoot).catch(() => null);
  return {
    success: true,
    revertedFiles: preview.affectedFiles,
    conflicts: [],
    unsupportedReasons: [],
    stagedFiles: [],
    patchResults: patches.map((patch) => ({ id: patch.id, applied: true })),
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

function resolveForwardPatchBatch(params) {
  const rawPatches = Array.isArray(params.patches) ? params.patches : [];
  const patches = rawPatches.map((rawPatch, index) => {
    if (typeof rawPatch === "string") {
      return {
        id: String(index),
        forwardPatch: rawPatch.endsWith("\n") ? rawPatch : `${rawPatch}\n`,
      };
    }

    const forwardPatch = rawPatch && typeof rawPatch.forwardPatch === "string"
      ? rawPatch.forwardPatch
      : "";
    return {
      id: rawPatch && typeof rawPatch.id === "string" ? rawPatch.id : String(index),
      forwardPatch: forwardPatch.endsWith("\n") ? forwardPatch : `${forwardPatch}\n`,
    };
  }).filter((patch) => patch.forwardPatch.trim());

  if (!patches.length) {
    throw workspaceError("missing_patch", "The request must include at least one non-empty patch.");
  }

  return patches;
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

async function previewReversePatchSequence(repoRoot, patches, affectedFiles) {
  const sandboxRoot = await createPatchSandbox(repoRoot, affectedFiles);

  try {
    for (const patch of patches) {
      const check = await checkReversePatch(sandboxRoot, patch.forwardPatch);
      if (!check.ok) {
        return { ...check, failedPatchId: patch.id };
      }

      const applied = await runGitApply(sandboxRoot, check.applyArgs, patch.forwardPatch);
      if (!applied.ok) {
        return { ...applied, failedPatchId: patch.id };
      }
      await syncPatchSandboxIndex(sandboxRoot);
    }

    return { ok: true, stdout: "", stderr: "" };
  } finally {
    await fs.promises.rm(sandboxRoot, { recursive: true, force: true }).catch(() => {});
  }
}

async function applyReversePatchSequence(repoRoot, patches, affectedFiles) {
  const appliedPatchIds = [];
  const backup = await createPatchBackup(repoRoot, affectedFiles);

  try {
    for (const patch of patches) {
      const checkedPatch = await checkReversePatch(repoRoot, patch.forwardPatch);
      if (!checkedPatch.ok) {
        await restorePatchBackup(repoRoot, backup);
        return { ...checkedPatch, appliedPatchIds, failedPatchId: patch.id };
      }

      const appliedPatch = await runGitApply(repoRoot, checkedPatch.applyArgs, patch.forwardPatch);
      if (!appliedPatch.ok) {
        await restorePatchBackup(repoRoot, backup);
        return { ...appliedPatch, appliedPatchIds, failedPatchId: patch.id };
      }

      appliedPatchIds.push(patch.id);
    }

    return { ok: true, stdout: "", stderr: "", appliedPatchIds };
  } finally {
    await fs.promises.rm(backup.root, { recursive: true, force: true }).catch(() => {});
  }
}

async function createPatchSandbox(repoRoot, affectedFiles) {
  const sandboxRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), "remodex-revert-preview-"));

  for (const affectedFile of affectedFiles) {
    const sourcePath = path.resolve(repoRoot, affectedFile);
    if (!isPathInside(sourcePath, repoRoot)) {
      continue;
    }

    const destinationPath = path.resolve(sandboxRoot, affectedFile);
    if (!isPathInside(destinationPath, sandboxRoot) || !fs.existsSync(sourcePath)) {
      continue;
    }

    await fs.promises.mkdir(path.dirname(destinationPath), { recursive: true });
    await fs.promises.copyFile(sourcePath, destinationPath);
  }

  await initializePatchSandboxGitRepo(sandboxRoot);
  return sandboxRoot;
}

async function initializePatchSandboxGitRepo(sandboxRoot) {
  await git(sandboxRoot, "init", "-q");
  await git(sandboxRoot, "config", "user.email", "remodex@example.local");
  await git(sandboxRoot, "config", "user.name", "Remodex");
  await syncPatchSandboxIndex(sandboxRoot);
  await git(sandboxRoot, "commit", "-qm", "snapshot", "--allow-empty");
}

async function syncPatchSandboxIndex(sandboxRoot) {
  await git(sandboxRoot, "add", "-A");
}

async function createPatchBackup(repoRoot, affectedFiles) {
  const backupRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), "remodex-revert-backup-"));
  const entries = [];

  for (const affectedFile of affectedFiles) {
    const sourcePath = path.resolve(repoRoot, affectedFile);
    if (!isPathInside(sourcePath, repoRoot)) {
      continue;
    }

    const backupPath = path.resolve(backupRoot, affectedFile);
    if (!isPathInside(backupPath, backupRoot)) {
      continue;
    }

    const exists = fs.existsSync(sourcePath);
    entries.push({ relativePath: affectedFile, exists });
    if (!exists) {
      continue;
    }

    await fs.promises.mkdir(path.dirname(backupPath), { recursive: true });
    await fs.promises.copyFile(sourcePath, backupPath);
  }

  return { root: backupRoot, entries };
}

async function restorePatchBackup(repoRoot, backup) {
  for (const entry of backup.entries) {
    const targetPath = path.resolve(repoRoot, entry.relativePath);
    if (!isPathInside(targetPath, repoRoot)) {
      continue;
    }

    if (!entry.exists) {
      await fs.promises.rm(targetPath, { force: true, recursive: true }).catch(() => {});
      continue;
    }

    const backupPath = path.resolve(backup.root, entry.relativePath);
    if (!isPathInside(backupPath, backup.root)) {
      continue;
    }

    await fs.promises.mkdir(path.dirname(targetPath), { recursive: true });
    await fs.promises.copyFile(backupPath, targetPath);
  }

  await resetTargetedFilesIndex(repoRoot, backup.entries.map((entry) => entry.relativePath));
}

async function resetTargetedFilesIndex(cwd, affectedFiles) {
  if (!affectedFiles.length) {
    return;
  }

  await git(cwd, "reset", "-q", "--", ...affectedFiles);
}

async function checkReversePatch(cwd, patchText) {
  if (isFileLifecyclePatch(patchText)) {
    const plainCheck = await runGitApply(cwd, ["apply", "--reverse", "--check"], patchText);
    return { ...plainCheck, applyArgs: ["apply", "--reverse"] };
  }

  const codexCheckArgs = ["apply", "--reverse", "--check", "--3way"];
  const plainCheckArgs = ["apply", "--reverse", "--check"];
  const codexCheck = await runGitApply(cwd, codexCheckArgs, patchText);

  if (codexCheck.ok) {
    return { ...codexCheck, applyArgs: ["apply", "--reverse", "--3way"] };
  }

  // git apply --3way requires index/worktree agreement; assistant edits are usually unstaged.
  if (!isIndexMismatch(codexCheck)) {
    return { ...codexCheck, applyArgs: ["apply", "--reverse", "--3way"] };
  }

  const plainCheck = await runGitApply(cwd, plainCheckArgs, patchText);
  return { ...plainCheck, applyArgs: ["apply", "--reverse"] };
}

function isFileLifecyclePatch(patchText) {
  return String(patchText || "")
    .split("\n")
    .some((line) => line === "--- /dev/null" || line === "+++ /dev/null");
}

function isIndexMismatch(result) {
  const output = `${result.stderr || ""}\n${result.stdout || ""}`;
  return output.includes("does not match index");
}

function uniqueSorted(values) {
  return [...new Set(values.filter(Boolean))].sort();
}

async function runGitApply(cwd, args, patchText) {
  const tempPatchPath = await writeTempPatchFile(patchText);

  try {
    const { stdout, stderr } = await execFileAsync("git", [...args, tempPatchPath], {
      cwd,
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: GIT_EXEC_MAX_BUFFER_BYTES,
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
  return execFileAsync("git", args, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: GIT_EXEC_MAX_BUFFER_BYTES,
  })
    .then(({ stdout }) => stdout)
    .catch((err) => {
      const msg = (err.stderr || err.message || "").trim();
      throw new Error(msg || "git command failed");
    });
}

module.exports = { handleWorkspaceMethod, handleWorkspaceRequest };
