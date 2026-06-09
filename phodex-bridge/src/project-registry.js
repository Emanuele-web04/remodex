// FILE: project-registry.js
// Purpose: Persists provider-neutral local project folders discovered by Codex, OpenCode, or manual picks.
// Layer: Bridge service
// Exports: createProjectRegistry plus pure path helpers used by tests
// Depends on: fs, os, path, ./codex-home

const fs = require("fs");
const os = require("os");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");
const { isPathAllowed } = require("./project-path-policy");
const { readString } = require("./normalize");

const REGISTRY_SCHEMA_VERSION = 1;
const REGISTRY_DIRECTORY_NAME = "remodex";
const REGISTRY_FILE_NAME = "known-projects.json";

let defaultProjectRegistry = null;

// Entry point

function createProjectRegistry(options = {}) {
  const storagePath = resolveRegistryStoragePath(options);
  return {
    storagePath,
    listProjects(params = {}) {
      return listKnownProjects(storagePath, params, options);
    },
    rememberProjectPath(candidatePath, metadata = {}) {
      return rememberKnownProjectPath(storagePath, candidatePath, metadata, options);
    },
    rememberProjectsFromThreads(threads, metadata = {}) {
      return rememberKnownProjectsFromThreads(storagePath, threads, metadata, options);
    },
  };
}

function getDefaultProjectRegistry() {
  if (!defaultProjectRegistry) {
    defaultProjectRegistry = createProjectRegistry();
  }
  return defaultProjectRegistry;
}

// Registry operations

function listKnownProjects(storagePath, params = {}, options = {}) {
  const state = readRegistryState(storagePath);
  const includeUnavailable =
    params.includeUnavailable === true || params.include_unavailable === true;
  const seenKeys = new Set();

  return state.projects
    .map((entry) => normalizeStoredEntry(entry, options))
    .filter(Boolean)
    .filter((entry) => {
      const key = projectIdentityKey(entry.path);
      if (!key || seenKeys.has(key)) {
        return false;
      }
      seenKeys.add(key);

      if (isGeneratedProjectlessPath(entry.path, options)) {
        return false;
      }
      if (includeUnavailable) {
        return true;
      }
      return directoryExists(entry.path);
    })
    .toSorted(compareKnownProjects)
    .map(publicKnownProject);
}

function rememberKnownProjectPath(storagePath, candidatePath, metadata = {}, options = {}) {
  return (
    rememberKnownProjectEntries(
      storagePath,
      [
        {
          path: candidatePath,
          metadata,
        },
      ],
      options,
    )[0] || null
  );
}

function rememberKnownProjectsFromThreads(storagePath, threads, metadata = {}, options = {}) {
  if (!Array.isArray(threads) || threads.length === 0) {
    return [];
  }

  const candidates = [];
  for (const thread of threads) {
    const cwd = readThreadProjectPath(thread);
    if (!cwd) {
      continue;
    }

    candidates.push({
      path: cwd,
      metadata: {
        ...metadata,
        provider: readString(
          metadata.provider || thread.modelProvider || thread.model_provider || thread.provider,
        ),
        lastSeenAt: readThreadLastSeenAt(thread) || metadata.lastSeenAt,
      },
    });
  }
  return rememberKnownProjectEntries(storagePath, candidates, options);
}

// Batches thread-list updates into one registry read/write so provider sync
// stays cheap even when a page contains many threads from the same project.
function rememberKnownProjectEntries(storagePath, candidates, options = {}) {
  if (!Array.isArray(candidates) || candidates.length === 0) {
    return [];
  }

  const now = currentTimestamp(options);
  const state = readRegistryState(storagePath);
  const indexByKey = new Map();
  state.projects.forEach((entry, index) => {
    const key = projectIdentityKey(entry?.path);
    if (key && !indexByKey.has(key)) {
      indexByKey.set(key, index);
    }
  });
  const remembered = [];
  let didChange = false;

  for (const candidate of candidates) {
    const metadata = candidate?.metadata || {};
    const normalizedPath = normalizeProjectPath(candidate?.path, options);
    if (
      !normalizedPath ||
      isGeneratedProjectlessPath(normalizedPath, options) ||
      !isPathAllowed(normalizedPath, options)
    ) {
      continue;
    }

    const key = projectIdentityKey(normalizedPath);
    const existingIndex = indexByKey.has(key) ? indexByKey.get(key) : -1;
    const previous = existingIndex >= 0 ? state.projects[existingIndex] : null;
    const nextEntry = mergeProjectEntry(previous, {
      path: normalizedPath,
      label: readString(metadata.label) || projectLabelForPath(normalizedPath),
      source: readString(metadata.source) || "unknown",
      provider: readString(metadata.provider || metadata.providerHint || metadata.provider_hint),
      firstSeenAt: previous?.firstSeenAt || now,
      lastSeenAt: readString(metadata.lastSeenAt || metadata.last_seen_at) || now,
    });

    if (existingIndex >= 0) {
      state.projects[existingIndex] = nextEntry;
    } else {
      indexByKey.set(key, state.projects.length);
      state.projects.push(nextEntry);
    }
    didChange = true;
    remembered.push(publicKnownProject(nextEntry));
  }

  if (didChange) {
    writeRegistryState(storagePath, state);
  }
  return remembered;
}

// Entry normalization

function mergeProjectEntry(previous, next) {
  const previousSources = Array.isArray(previous?.sources) ? previous.sources : [];
  const previousProviderHints = Array.isArray(previous?.providerHints)
    ? previous.providerHints
    : [];
  const sources = appendUniqueString(previousSources, next.source);
  const providerHints = appendUniqueString(previousProviderHints, next.provider);

  return {
    path: next.path,
    label: next.label || previous?.label || projectLabelForPath(next.path),
    source: next.source || previous?.source || "unknown",
    sources,
    providerHints,
    firstSeenAt: previous?.firstSeenAt || next.firstSeenAt,
    lastSeenAt: mostRecentTimestamp(previous?.lastSeenAt, next.lastSeenAt),
  };
}

function normalizeStoredEntry(entry, options = {}) {
  if (!entry || typeof entry !== "object") {
    return null;
  }

  const normalizedPath = normalizeProjectPath(entry.path, options);
  if (!normalizedPath || !isPathAllowed(normalizedPath, options)) {
    return null;
  }

  return {
    path: normalizedPath,
    label: readString(entry.label) || projectLabelForPath(normalizedPath),
    source: readString(entry.source) || firstString(entry.sources) || "unknown",
    sources: uniqueStrings(entry.sources),
    providerHints: uniqueStrings(entry.providerHints || entry.provider_hints),
    firstSeenAt: readString(entry.firstSeenAt || entry.first_seen_at) || "",
    lastSeenAt: readString(entry.lastSeenAt || entry.last_seen_at) || "",
  };
}

function publicKnownProject(entry) {
  return {
    id: entry.path,
    path: entry.path,
    label: entry.label || projectLabelForPath(entry.path),
    source: entry.source || "unknown",
    sources: uniqueStrings(entry.sources),
    providerHints: uniqueStrings(entry.providerHints),
    firstSeenAt: entry.firstSeenAt || "",
    lastSeenAt: entry.lastSeenAt || "",
  };
}

// Storage

function resolveRegistryStoragePath(options = {}) {
  if (readString(options.storagePath)) {
    return path.resolve(options.storagePath);
  }

  const codexHome = path.resolve(readString(options.codexHome) || resolveCodexHome());
  return path.join(codexHome, REGISTRY_DIRECTORY_NAME, REGISTRY_FILE_NAME);
}

function readRegistryState(storagePath) {
  try {
    const raw = fs.readFileSync(storagePath, "utf8");
    const parsed = JSON.parse(raw);
    return normalizeRegistryState(parsed);
  } catch {
    return emptyRegistryState();
  }
}

function writeRegistryState(storagePath, state) {
  const normalizedState = normalizeRegistryState(state);
  const directory = path.dirname(storagePath);
  fs.mkdirSync(directory, { recursive: true });
  const tempPath = `${storagePath}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tempPath, `${JSON.stringify(normalizedState, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  fs.renameSync(tempPath, storagePath);
  try {
    fs.chmodSync(storagePath, 0o600);
  } catch {
    // Best-effort on platforms that restrict chmod.
  }
}

function normalizeRegistryState(state) {
  return {
    version: REGISTRY_SCHEMA_VERSION,
    projects: Array.isArray(state?.projects) ? state.projects.filter(Boolean) : [],
  };
}

function emptyRegistryState() {
  return {
    version: REGISTRY_SCHEMA_VERSION,
    projects: [],
  };
}

// Path helpers

function normalizeProjectPath(candidatePath, options = {}) {
  const rawPath = readString(candidatePath);
  if (!rawPath || !isLikelyFilesystemPath(rawPath)) {
    return null;
  }

  const expandedPath = expandHomePath(rawPath, options);
  if (!path.isAbsolute(expandedPath)) {
    return null;
  }

  const resolvedPath = path.resolve(expandedPath);
  return realpathSyncIfAvailable(resolvedPath) || resolvedPath;
}

function isGeneratedProjectlessPath(candidatePath, options = {}) {
  const normalizedPath = normalizeProjectPath(candidatePath, options);
  if (!normalizedPath) {
    return false;
  }

  const homeDir = path.resolve(readString(options.homeDir) || os.homedir());
  const codexHome = path.resolve(readString(options.codexHome) || resolveCodexHome());
  const knownRootlessRoots = [
    path.join(codexHome, "threads"),
    path.join(homeDir, "Documents", "Codex"),
  ];

  return (
    knownRootlessRoots.some((rootPath) => samePathOrDescendant(normalizedPath, rootPath)) ||
    hasGeneratedProjectlessComponents(normalizedPath)
  );
}

function hasGeneratedProjectlessComponents(candidatePath) {
  const components = projectPathComponents(candidatePath);
  for (let index = 0; index < components.length; index += 1) {
    if (
      components[index] === ".codex" &&
      components[index + 1] === "threads" &&
      readString(components[index + 2])
    ) {
      return true;
    }

    if (
      components[index] === "Documents" &&
      components[index + 1] === "Codex" &&
      isISODateFolderName(components[index + 2]) &&
      readString(components[index + 3])
    ) {
      return true;
    }
  }
  return false;
}

function samePathOrDescendant(candidatePath, rootPath) {
  const normalizedCandidate = path.resolve(candidatePath);
  const normalizedRoot = realpathSyncIfAvailable(path.resolve(rootPath)) || path.resolve(rootPath);
  const relative = path.relative(normalizedRoot, normalizedCandidate);
  return (
    relative === "" || (!!relative && !relative.startsWith("..") && !path.isAbsolute(relative))
  );
}

function projectIdentityKey(candidatePath) {
  const normalizedPath = readString(candidatePath);
  if (!normalizedPath) {
    return "";
  }
  return process.platform === "win32" || process.platform === "darwin"
    ? normalizedPath.toLowerCase()
    : normalizedPath;
}

function projectLabelForPath(candidatePath) {
  const baseName = path.basename(candidatePath);
  return baseName || candidatePath;
}

function readThreadProjectPath(thread) {
  if (
    thread?.metadata?.projectCwdSource === "fallback" ||
    thread?.metadata?.projectRegistrySkipCwd === true
  ) {
    return "";
  }
  return readString(
    thread?.cwd ||
      thread?.current_working_directory ||
      thread?.workingDirectory ||
      thread?.directory,
  );
}

function readThreadLastSeenAt(thread) {
  return readString(
    thread?.updatedAt || thread?.updated_at || thread?.createdAt || thread?.created_at,
  );
}

function expandHomePath(candidatePath, options = {}) {
  const homeDir = readString(options.homeDir) || os.homedir();
  if (candidatePath === "~") {
    return homeDir;
  }
  if (candidatePath.startsWith("~/")) {
    return path.join(homeDir, candidatePath.slice(2));
  }
  return candidatePath;
}

function isLikelyFilesystemPath(value) {
  return (
    value === "~" ||
    value === "/" ||
    value.startsWith("/") ||
    value.startsWith("~/") ||
    /^[A-Za-z]:[\\/]/u.test(value) ||
    value.startsWith("\\\\")
  );
}

function directoryExists(candidatePath) {
  try {
    return fs.statSync(candidatePath).isDirectory();
  } catch {
    return false;
  }
}

function realpathSyncIfAvailable(candidatePath) {
  try {
    return fs.realpathSync.native(candidatePath);
  } catch {
    try {
      return fs.realpathSync(candidatePath);
    } catch {
      return null;
    }
  }
}

// Value helpers

function compareKnownProjects(left, right) {
  const leftTime = Date.parse(left.lastSeenAt || left.firstSeenAt || 0) || 0;
  const rightTime = Date.parse(right.lastSeenAt || right.firstSeenAt || 0) || 0;
  if (leftTime !== rightTime) {
    return rightTime - leftTime;
  }

  const labelOrder = left.label.localeCompare(right.label, undefined, { sensitivity: "base" });
  if (labelOrder !== 0) {
    return labelOrder;
  }
  return left.path.localeCompare(right.path, undefined, { sensitivity: "base" });
}

function mostRecentTimestamp(left, right) {
  const leftTime = Date.parse(left || 0) || 0;
  const rightTime = Date.parse(right || 0) || 0;
  if (!leftTime) {
    return right || left || "";
  }
  if (!rightTime) {
    return left || right || "";
  }
  return rightTime >= leftTime ? right : left;
}

function currentTimestamp(options = {}) {
  if (typeof options.now === "function") {
    return new Date(options.now()).toISOString();
  }
  return new Date().toISOString();
}

function appendUniqueString(values, value) {
  return uniqueStrings([...values, value]);
}

function uniqueStrings(values) {
  if (!Array.isArray(values)) {
    return [];
  }

  const seen = new Set();
  const result = [];
  for (const value of values) {
    const normalized = readString(value);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    result.push(normalized);
  }
  return result;
}

function firstString(values) {
  return uniqueStrings(values)[0] || "";
}

function projectPathComponents(candidatePath) {
  return candidatePath.replace(/\\/g, "/").split("/").filter(Boolean);
}

function isISODateFolderName(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/u.test(value);
}

module.exports = {
  createProjectRegistry,
  getDefaultProjectRegistry,
  isGeneratedProjectlessPath,
  normalizeProjectPath,
  projectLabelForPath,
};
