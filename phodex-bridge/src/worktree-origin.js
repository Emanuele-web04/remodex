// FILE: worktree-origin.js
// Purpose: Resolves the checkout that owns a Codex-managed worktree so thread rows can be
//          grouped under their source project instead of a separate look-alike project.
// Layer: CLI helper
// Exports: createWorktreeOriginEnricher
// Depends on: fs, os, path, ./thread-row-enrichment

const fs = require("fs");
const os = require("os");
const path = require("path");
const { forEachThreadRowInResponse } = require("./thread-row-enrichment");

// One entry per managed-worktree cwd seen on this machine, and managed worktree paths are
// single-use, so the map is bounded by real worktrees rather than by list refreshes.
const DEFAULT_MAX_ENTRIES = 1024;

const THREAD_ROW_CWD_KEYS = ["cwd", "workingDirectory", "working_directory", "current_working_directory"];

// Managed worktrees live at CODEX_HOME/worktrees/<token>/<repo>, so their basename matches the
// source repo while their path does not: the phone would otherwise show one project row per
// worktree next to the repo the worktree was cut from. Git already records the owner in the
// worktree's `.git` file (`gitdir: <checkout>/.git/worktrees/<name>`), so a single small read
// per worktree recovers the source checkout without shelling out to git.
function createWorktreeOriginEnricher({
  fsModule = fs,
  codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex"),
  maxEntries = DEFAULT_MAX_ENTRIES,
} = {}) {
  const worktreesRoots = managedWorktreesRoots(codexHome, fsModule);
  const cache = new Map();

  function originPathForCwd(cwd) {
    if (cache.has(cwd)) {
      const cached = cache.get(cwd);
      // Refresh insertion order so the Map behaves as an LRU.
      cache.delete(cwd);
      cache.set(cwd, cached);
      return cached;
    }

    const originPath = resolveOriginPath(cwd);
    cache.set(cwd, originPath);
    while (cache.size > Math.max(1, maxEntries)) {
      cache.delete(cache.keys().next().value);
    }
    return originPath;
  }

  // A removed worktree resolves to "" and stays cached: its path is never reused, so the
  // thread keeps the standalone project row it has today instead of re-reading every refresh.
  function resolveOriginPath(cwd) {
    const scope = resolveManagedWorktreeScope(cwd, worktreesRoots);
    if (!scope) {
      return "";
    }

    const checkoutRoot = readOwningCheckoutRoot(scope.worktreeRoot, fsModule);
    if (!checkoutRoot) {
      return "";
    }
    if (!scope.relativePath) {
      return checkoutRoot;
    }

    // Package-scoped chats point at a subdirectory, so mirror it into the checkout when it
    // exists there; otherwise the repo root is still the right project to group under.
    const scopedPath = path.join(checkoutRoot, scope.relativePath);
    return isExistingDirectory(scopedPath, fsModule) ? scopedPath : checkoutRoot;
  }

  function attachToThread(thread) {
    if (!thread || typeof thread !== "object" || normalizeString(thread.worktreeOriginPath)) {
      return thread;
    }

    const cwd = threadRowCwd(thread);
    if (!cwd) {
      return thread;
    }

    const originPath = originPathForCwd(cwd);
    if (originPath) {
      thread.worktreeOriginPath = originPath;
    }
    return thread;
  }

  function enrichResponse(method, envelope) {
    return forEachThreadRowInResponse(method, envelope, attachToThread);
  }

  return {
    attachToThread,
    enrichResponse,
    // Exposed for focused tests so cache growth stays provable.
    cacheSize: () => cache.size,
  };
}

// CODEX_HOME can sit behind a symlink while thread rows carry resolved paths (or the reverse),
// so both spellings of the worktrees root are accepted.
function managedWorktreesRoots(codexHome, fsModule) {
  const joinedRoot = path.join(normalizeString(codexHome) || path.join(os.homedir(), ".codex"), "worktrees");
  const roots = [joinedRoot];
  const realRoot = realPathOrNull(joinedRoot, fsModule);
  if (realRoot && realRoot !== joinedRoot) {
    roots.push(realRoot);
  }
  return roots;
}

function resolveManagedWorktreeScope(cwd, worktreesRoots) {
  for (const root of worktreesRoots) {
    const relativePath = path.relative(root, cwd);
    if (!relativePath || relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
      continue;
    }

    const segments = relativePath.split(path.sep).filter(Boolean);
    // <token>/<repo> is the worktree itself; anything deeper is a chat scoped inside it.
    if (segments.length < 2) {
      continue;
    }

    return {
      worktreeRoot: path.join(root, segments[0], segments[1]),
      relativePath: segments.slice(2).join(path.sep),
    };
  }

  return null;
}

function readOwningCheckoutRoot(worktreeRoot, fsModule) {
  let gitFileContents = "";
  try {
    gitFileContents = fsModule.readFileSync(path.join(worktreeRoot, ".git"), "utf8");
  } catch {
    // A removed worktree, or a plain repo copied under the worktrees root, has no `.git` file.
    return "";
  }

  const gitDirMatch = /^\s*gitdir:\s*(.+?)\s*$/m.exec(gitFileContents);
  if (!gitDirMatch) {
    return "";
  }

  const gitDir = path.resolve(worktreeRoot, gitDirMatch[1]);
  const gitDirSegments = gitDir.split(path.sep);
  // Only <checkout>/.git/worktrees/<name> identifies a linked worktree of a real checkout.
  if (gitDirSegments.length < 4
    || gitDirSegments[gitDirSegments.length - 2] !== "worktrees"
    || gitDirSegments[gitDirSegments.length - 3] !== ".git") {
    return "";
  }

  return path.dirname(path.dirname(path.dirname(gitDir)));
}

function threadRowCwd(thread) {
  for (const key of THREAD_ROW_CWD_KEYS) {
    const candidate = normalizeString(thread[key]);
    if (candidate) {
      return candidate;
    }
  }
  return "";
}

function isExistingDirectory(candidatePath, fsModule) {
  try {
    return fsModule.statSync(candidatePath).isDirectory();
  } catch {
    return false;
  }
}

function realPathOrNull(candidatePath, fsModule) {
  try {
    return fsModule.realpathSync(candidatePath);
  } catch {
    return null;
  }
}

function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

module.exports = {
  createWorktreeOriginEnricher,
};
