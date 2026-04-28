// FILE: project-handler.js
// Purpose: Serves safe Mac-local project folder discovery and creation requests from the iOS app.
// Layer: Bridge handler
// Exports: handleProjectRequest plus testable project filesystem helpers
// Depends on: fs, os, path

const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_DIRECTORY_LIMIT = 200;
const DEFAULT_HIDDEN_DIRECTORY_NAMES = new Set(["Library"]);

// ─── ENTRY POINT ─────────────────────────────────────────────

function handleProjectRequest(rawMessage, sendResponse) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method.startsWith("project/")) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleProjectMethod(method, params)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "project_error";
      const message = err.userMessage || err.message || "Unknown project folder error";
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

async function handleProjectMethod(method, params, options = {}) {
  switch (method) {
    case "project/quickLocations":
      return projectQuickLocations(options);
    case "project/listDirectory":
      return projectListDirectory(params, options);
    case "project/validatePath":
      return projectValidatePath(params, options);
    case "project/createDirectory":
      return projectCreateDirectory(params, options);
    default:
      throw projectError("unknown_method", `Unknown project method: ${method}`);
  }
}

// ─── Project Methods ─────────────────────────────────────────

async function projectQuickLocations(options = {}) {
  const homeDir = resolveHomeDir(options);
  const candidates = [
    { id: "home", label: "Home", path: homeDir },
    { id: "developer", label: "Developer", path: path.join(homeDir, "Developer") },
    { id: "documents", label: "Documents", path: path.join(homeDir, "Documents") },
    { id: "desktop", label: "Desktop", path: path.join(homeDir, "Desktop") },
  ];

  const locations = [];
  for (const candidate of candidates) {
    const validated = await validateDirectory(candidate.path, options).catch(() => null);
    if (!validated?.exists || !validated.isDirectory || !validated.isAllowed) {
      continue;
    }

    locations.push({
      id: candidate.id,
      label: candidate.label,
      path: validated.path,
    });
  }

  return { locations };
}

async function projectListDirectory(params, options = {}) {
  const requestedPath = readString(params.path) || resolveHomeDir(options);
  const directory = await requireUsableDirectory(requestedPath, options);
  const includeHidden = params.includeHidden === true;
  const limit = normalizeLimit(params.limit);
  const entries = await readDirectoryEntries(directory.path, {
    ...options,
    includeHidden,
    limit,
  });

  return {
    path: directory.path,
    parentPath: parentPathWithinAllowedRoots(directory.path, options),
    entries,
  };
}

async function projectValidatePath(params, options = {}) {
  const requestedPath = readString(params.path);
  if (!requestedPath) {
    throw projectError("missing_path", "A folder path is required.");
  }

  return validateDirectory(requestedPath, options);
}

async function projectCreateDirectory(params, options = {}) {
  const parentPath = readString(params.parentPath || params.parent || params.path);
  const rawName = readString(params.name || params.folderName || params.directoryName);
  if (!parentPath) {
    throw projectError("missing_parent_path", "A parent folder path is required.");
  }
  if (!rawName) {
    throw projectError("missing_directory_name", "A new folder name is required.");
  }

  const parent = await requireUsableDirectory(parentPath, options);
  const name = normalizeNewDirectoryName(rawName);
  const targetPath = path.join(parent.path, name);
  assertPathAllowed(targetPath, options);

  try {
    await fs.promises.mkdir(targetPath, { recursive: false });
  } catch (error) {
    if (error?.code === "EEXIST") {
      throw projectError("directory_exists", "A folder with that name already exists.");
    }
    throw projectError("create_failed", error?.message || "Unable to create that folder.");
  }

  const created = await requireUsableDirectory(targetPath, options);
  return {
    path: created.path,
    parentPath: parent.path,
    name: path.basename(created.path),
  };
}

// ─── Filesystem Helpers ──────────────────────────────────────

async function readDirectoryEntries(directoryPath, options = {}) {
  let dirents;
  try {
    dirents = await fs.promises.readdir(directoryPath, { withFileTypes: true });
  } catch (error) {
    throw projectError("read_failed", error?.message || "Unable to read that folder.");
  }

  const entries = [];
  for (const dirent of dirents) {
    if (!options.includeHidden && isHiddenDirectoryName(dirent.name)) {
      continue;
    }

    const childPath = path.join(directoryPath, dirent.name);
    const directory = await directoryEntryForPath(childPath, dirent, options);
    if (directory) {
      entries.push(directory);
    }
  }

  return entries
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }))
    .slice(0, options.limit || DEFAULT_DIRECTORY_LIMIT);
}

async function directoryEntryForPath(candidatePath, dirent, options = {}) {
  if (!dirent.isDirectory() && !dirent.isSymbolicLink()) {
    return null;
  }

  const validation = await validateDirectory(candidatePath, options).catch(() => null);
  if (!validation?.exists || !validation.isDirectory || !validation.isAllowed) {
    return null;
  }

  return {
    name: dirent.name,
    path: validation.path,
    isSymlink: dirent.isSymbolicLink(),
  };
}

async function requireUsableDirectory(candidatePath, options = {}) {
  const validation = await validateDirectory(candidatePath, options);
  if (!validation.isAllowed) {
    throw projectError("path_not_allowed", "That folder is outside the allowed local project locations.");
  }
  if (!validation.exists) {
    throw projectError("missing_directory", "That folder does not exist on this Mac.");
  }
  if (!validation.isDirectory) {
    throw projectError("not_directory", "That path is not a folder.");
  }

  return validation;
}

async function validateDirectory(candidatePath, options = {}) {
  const normalizedPath = normalizeCandidatePath(candidatePath, options);
  const isAllowed = isPathAllowed(normalizedPath, options);
  if (!isAllowed) {
    return {
      path: normalizedPath,
      exists: false,
      isDirectory: false,
      isAllowed: false,
    };
  }

  try {
    const realPath = await fs.promises.realpath(normalizedPath);
    const stats = await fs.promises.stat(realPath);
    return {
      path: realPath,
      exists: true,
      isDirectory: stats.isDirectory(),
      isAllowed: isPathAllowed(realPath, options),
    };
  } catch {
    return {
      path: normalizedPath,
      exists: false,
      isDirectory: false,
      isAllowed,
    };
  }
}

function parentPathWithinAllowedRoots(candidatePath, options = {}) {
  const parentPath = path.dirname(candidatePath);
  if (!parentPath || parentPath === candidatePath) {
    return null;
  }

  return isPathAllowed(parentPath, options) ? parentPath : null;
}

function assertPathAllowed(candidatePath, options = {}) {
  if (!isPathAllowed(candidatePath, options)) {
    throw projectError("path_not_allowed", "That folder is outside the allowed local project locations.");
  }
}

function isPathAllowed(candidatePath, options = {}) {
  const normalizedPath = path.resolve(candidatePath);
  return allowedProjectRoots(options).some((rootPath) => samePathOrDescendant(normalizedPath, rootPath));
}

function allowedProjectRoots(options = {}) {
  const roots = Array.isArray(options.allowedRoots) && options.allowedRoots.length
    ? options.allowedRoots
    : [resolveHomeDir(options)];

  return [...new Set(roots.flatMap((rootPath) => {
    const resolvedRoot = path.resolve(rootPath);
    return [resolvedRoot, realpathSyncIfAvailable(resolvedRoot)].filter(Boolean);
  }))];
}

function samePathOrDescendant(candidatePath, rootPath) {
  const relative = path.relative(rootPath, candidatePath);
  return relative === "" || (!!relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function normalizeCandidatePath(candidatePath, options = {}) {
  const rawPath = readString(candidatePath);
  if (!rawPath) {
    throw projectError("missing_path", "A folder path is required.");
  }

  if (rawPath === "~" || rawPath.startsWith("~/")) {
    return path.resolve(resolveHomeDir(options), rawPath.slice(2));
  }

  if (!path.isAbsolute(rawPath)) {
    throw projectError("invalid_path", "Use an absolute folder path.");
  }

  return path.resolve(rawPath);
}

function isHiddenDirectoryName(name) {
  return name.startsWith(".") || DEFAULT_HIDDEN_DIRECTORY_NAMES.has(name);
}

function normalizeNewDirectoryName(rawName) {
  const name = rawName.trim();
  if (!name || name === "." || name === "..") {
    throw projectError("invalid_directory_name", "Use a valid folder name.");
  }
  if (name.includes("/") || name.includes("\\") || name.includes("\0")) {
    throw projectError("invalid_directory_name", "Folder names cannot contain path separators.");
  }
  if (name.length > 120) {
    throw projectError("invalid_directory_name", "Use a shorter folder name.");
  }

  return name;
}

function normalizeLimit(rawLimit) {
  const numericLimit = Number(rawLimit);
  if (!Number.isFinite(numericLimit) || numericLimit <= 0) {
    return DEFAULT_DIRECTORY_LIMIT;
  }

  return Math.min(Math.floor(numericLimit), DEFAULT_DIRECTORY_LIMIT);
}

function resolveHomeDir(options = {}) {
  return options.homeDir || os.homedir();
}

function realpathSyncIfAvailable(candidatePath) {
  try {
    return fs.realpathSync(candidatePath);
  } catch {
    return null;
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function projectError(errorCode, userMessage) {
  const err = new Error(userMessage);
  err.errorCode = errorCode;
  err.userMessage = userMessage;
  return err;
}

module.exports = {
  handleProjectRequest,
  handleProjectMethod,
  projectQuickLocations,
  projectListDirectory,
  projectValidatePath,
  projectCreateDirectory,
  validateDirectory,
};
