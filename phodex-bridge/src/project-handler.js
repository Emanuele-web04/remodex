// FILE: project-handler.js
// Purpose: Serves safe Mac-local project folder discovery and creation requests from the iOS app.
// Layer: Bridge handler
// Exports: handleProjectRequest plus testable project filesystem helpers
// Depends on: fs, os, path, ./codex-home

const fs = require("fs");
const os = require("os");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");

const DEFAULT_DIRECTORY_LIMIT = 200;
const DEFAULT_DIRECTORY_SEARCH_LIMIT = 80;
const DEFAULT_DIRECTORY_SEARCH_MAX_DEPTH = 8;
const DEFAULT_DIRECTORY_SEARCH_MAX_VISITED = 5000;
const DEFAULT_HIDDEN_DIRECTORY_NAMES = new Set(["Library"]);

// Rootless chat slug rules mirror Codex Desktop's `~/Documents/Codex/<DATE>/<slug>`
// convention so iOS-created Quick Chats land in the same bucket Desktop classifies
// as projectless.
const ROOTLESS_CHAT_SLUG_MAX_TOKENS = 6;
const ROOTLESS_CHAT_SLUG_MAX_LENGTH = 60;
const ROOTLESS_CHAT_SLUG_FALLBACK = "new-chat";
const ROOTLESS_CHAT_DEDUP_LIMIT = 50;

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
    case "project/projectlessRoots":
      return projectProjectlessRoots(options);
    case "project/listDirectory":
      return projectListDirectory(params, options);
    case "project/searchDirectories":
      return projectSearchDirectories(params, options);
    case "project/validatePath":
      return projectValidatePath(params, options);
    case "project/createDirectory":
      return projectCreateDirectory(params, options);
    case "project/createRootlessChatRoot":
      return projectCreateRootlessChatRoot(params, options);
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

async function projectProjectlessRoots(options = {}) {
  const homeDir = resolveHomeDir(options);
  const codexHome = path.resolve(readString(options.codexHome) || resolveCodexHome());
  const documentedThreadsRoot = path.join(codexHome, "threads");
  const desktopDocumentsRoot = path.join(homeDir, "Documents", "Codex");
  const roots = uniqueExistingOrCandidatePaths([
    documentedThreadsRoot,
    desktopDocumentsRoot,
  ]);

  return {
    codexHome,
    roots,
    documentedThreadsRoot,
    desktopDocumentsRoot,
  };
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

async function projectSearchDirectories(params, options = {}) {
  const requestedPath = readString(params.path) || resolveHomeDir(options);
  const query = readString(params.query);
  const directory = await requireUsableDirectory(requestedPath, options);
  if (!query) {
    return {
      path: directory.path,
      entries: [],
    };
  }

  const includeHidden = params.includeHidden === true;
  const entries = await searchDirectoryEntries(directory.path, query, {
    ...options,
    includeHidden,
    limit: normalizeSearchLimit(params.limit),
    maxDepth: normalizeSearchDepth(params.maxDepth),
    maxVisited: normalizeSearchVisitedLimit(params.maxVisited),
  });

  return {
    path: directory.path,
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

// Mirrors the Codex Desktop "Chats" convention by materializing a dated rootless
// chat folder under `~/Documents/Codex/<DATE>/<slug>` (or its Windows equivalent
// `%USERPROFILE%\Documents\Codex\<DATE>\<slug>`) before the iOS client issues
// `thread/start`. Without an explicit cwd the app-server falls back to its own
// process working directory (often the user's home), which would otherwise show
// up in the sidebar as a project named after the user account.
async function projectCreateRootlessChatRoot(params = {}, options = {}) {
  const homeDir = resolveHomeDir(options);
  const desktopDocumentsRoot = path.join(homeDir, "Documents", "Codex");
  const dateFolder = readString(params.dateFolder) || formatRootlessChatDate(new Date());
  if (!isISODateFolderName(dateFolder)) {
    throw projectError("invalid_date_folder", "The chat date folder must be in YYYY-MM-DD format.");
  }

  const slugBase = rootlessChatSlugFromPromptHint(params.promptHint);
  const dateRootPath = path.join(desktopDocumentsRoot, dateFolder);

  try {
    await fs.promises.mkdir(dateRootPath, { recursive: true });
  } catch (error) {
    throw projectError("create_failed", error?.message || "Unable to prepare the Codex chats folder.");
  }

  const targetPath = await reserveUniqueRootlessChatPath(dateRootPath, slugBase);
  try {
    await fs.promises.mkdir(targetPath, { recursive: false });
  } catch (error) {
    if (error?.code !== "EEXIST") {
      throw projectError("create_failed", error?.message || "Unable to create the rootless chat folder.");
    }
  }

  const resolvedPath = await safeRealpath(targetPath);
  return {
    path: resolvedPath,
    parentPath: dateRootPath,
    name: path.basename(resolvedPath),
    slug: slugBase,
    dateFolder,
    root: desktopDocumentsRoot,
  };
}

// Codex Desktop generates kebab-case slugs from the first words of the prompt
// (e.g. "mi-dici-la-pwd-corrente" from "mi dici la pwd corrente?"). We mirror
// the same shape so that side-by-side users with the desktop app see a
// consistent chat folder naming scheme.
function rootlessChatSlugFromPromptHint(rawPromptHint) {
  const hint = typeof rawPromptHint === "string" ? rawPromptHint.normalize("NFKD") : "";
  const sanitized = hint
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, " ")
    .trim();
  if (!sanitized) {
    return ROOTLESS_CHAT_SLUG_FALLBACK;
  }

  const tokens = sanitized
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, ROOTLESS_CHAT_SLUG_MAX_TOKENS);
  if (!tokens.length) {
    return ROOTLESS_CHAT_SLUG_FALLBACK;
  }

  let slug = tokens.join("-");
  if (slug.length > ROOTLESS_CHAT_SLUG_MAX_LENGTH) {
    slug = slug.slice(0, ROOTLESS_CHAT_SLUG_MAX_LENGTH).replace(/-+$/g, "");
  }
  return slug || ROOTLESS_CHAT_SLUG_FALLBACK;
}

// Appends "-2", "-3", … so two rapid-fire chats with the same first words
// keep distinct folders instead of fighting over the same path.
async function reserveUniqueRootlessChatPath(parentDirectory, slugBase) {
  for (let attempt = 0; attempt < ROOTLESS_CHAT_DEDUP_LIMIT; attempt += 1) {
    const candidateSlug = attempt === 0 ? slugBase : `${slugBase}-${attempt + 1}`;
    const candidatePath = path.join(parentDirectory, candidateSlug);
    try {
      await fs.promises.access(candidatePath, fs.constants.F_OK);
    } catch {
      return candidatePath;
    }
  }

  return path.join(parentDirectory, `${slugBase}-${Date.now()}`);
}

function formatRootlessChatDate(date) {
  const year = date.getFullYear().toString().padStart(4, "0");
  const month = (date.getMonth() + 1).toString().padStart(2, "0");
  const day = date.getDate().toString().padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function isISODateFolderName(value) {
  if (typeof value !== "string" || value.length !== 10) {
    return false;
  }
  return /^\d{4}-\d{2}-\d{2}$/u.test(value);
}

async function safeRealpath(candidatePath) {
  try {
    return await fs.promises.realpath(candidatePath);
  } catch {
    return path.resolve(candidatePath);
  }
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

async function searchDirectoryEntries(rootPath, query, options = {}) {
  const tokens = searchTokens(query);
  if (!tokens.length) {
    return [];
  }

  const limit = options.limit || DEFAULT_DIRECTORY_SEARCH_LIMIT;
  const maxDepth = options.maxDepth ?? DEFAULT_DIRECTORY_SEARCH_MAX_DEPTH;
  const maxVisited = options.maxVisited || DEFAULT_DIRECTORY_SEARCH_MAX_VISITED;
  const queue = [{ directoryPath: rootPath, depth: 0 }];
  const visitedDirectories = new Set([realpathSyncIfAvailable(rootPath) || rootPath]);
  const matches = [];
  let visitedCount = 0;

  while (queue.length && matches.length < limit && visitedCount < maxVisited) {
    const { directoryPath, depth } = queue.shift();
    visitedCount += 1;

    let dirents;
    try {
      dirents = await fs.promises.readdir(directoryPath, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const dirent of sortedDirents(dirents)) {
      if (!options.includeHidden && isHiddenDirectoryName(dirent.name)) {
        continue;
      }

      const childPath = path.join(directoryPath, dirent.name);
      const directory = await directoryEntryForPath(childPath, dirent, options);
      if (!directory) {
        continue;
      }

      if (directoryMatchesSearch(directory, tokens)) {
        matches.push(directory);
        if (matches.length >= limit) {
          break;
        }
      }

      if (!dirent.isSymbolicLink() && depth < maxDepth) {
        const realPath = directory.path;
        if (!visitedDirectories.has(realPath)) {
          visitedDirectories.add(realPath);
          queue.push({ directoryPath: realPath, depth: depth + 1 });
        }
      }
    }
  }

  return matches;
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
  const envRoots = (process.env.REMODEX_ALLOWED_ROOTS || "")
    .split(":")
    .map((entry) => entry.trim())
    .filter(Boolean);

  const roots = Array.isArray(options.allowedRoots) && options.allowedRoots.length
    ? options.allowedRoots
    : envRoots.length
      ? envRoots
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

function normalizeSearchLimit(rawLimit) {
  const numericLimit = Number(rawLimit);
  if (!Number.isFinite(numericLimit) || numericLimit <= 0) {
    return DEFAULT_DIRECTORY_SEARCH_LIMIT;
  }

  return Math.min(Math.floor(numericLimit), DEFAULT_DIRECTORY_SEARCH_LIMIT);
}

function normalizeSearchDepth(rawDepth) {
  const numericDepth = Number(rawDepth);
  if (!Number.isFinite(numericDepth) || numericDepth < 0) {
    return DEFAULT_DIRECTORY_SEARCH_MAX_DEPTH;
  }

  return Math.min(Math.floor(numericDepth), DEFAULT_DIRECTORY_SEARCH_MAX_DEPTH);
}

function normalizeSearchVisitedLimit(rawLimit) {
  const numericLimit = Number(rawLimit);
  if (!Number.isFinite(numericLimit) || numericLimit <= 0) {
    return DEFAULT_DIRECTORY_SEARCH_MAX_VISITED;
  }

  return Math.min(Math.floor(numericLimit), DEFAULT_DIRECTORY_SEARCH_MAX_VISITED);
}

function sortedDirents(dirents) {
  return [...dirents].sort((left, right) => (
    left.name.localeCompare(right.name, undefined, { sensitivity: "base" })
  ));
}

function searchTokens(query) {
  return query
    .toLowerCase()
    .split(/\s+/)
    .map((token) => token.trim())
    .filter(Boolean);
}

function directoryMatchesSearch(directory, tokens) {
  const haystack = directory.name.toLowerCase();
  return tokens.every((token) => haystack.includes(token));
}

function resolveHomeDir(options = {}) {
  return options.homeDir || os.homedir();
}

function uniqueExistingOrCandidatePaths(paths) {
  const seen = new Set();
  const result = [];

  for (const candidatePath of paths) {
    const normalizedPath = path.resolve(candidatePath);
    const realPath = realpathSyncIfAvailable(normalizedPath) || normalizedPath;
    if (seen.has(realPath)) {
      continue;
    }
    seen.add(realPath);
    result.push(realPath);
  }

  return result;
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
  projectProjectlessRoots,
  projectListDirectory,
  projectSearchDirectories,
  projectValidatePath,
  projectCreateDirectory,
  projectCreateRootlessChatRoot,
  validateDirectory,
  rootlessChatSlugFromPromptHint,
};
