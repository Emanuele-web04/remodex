// FILE: project-path-policy.js
// Purpose: Shared home-root allowlist policy for project folder paths used by browse and registry writes.
// Layer: Bridge policy
// Exports: isPathAllowed, assertProjectPathAllowed, validateDirectory, normalizeCandidatePath, resolveHomeDir
// Depends on: fs, os, path, ./normalize

const fs = require("fs");
const os = require("os");
const path = require("path");
const { readString } = require("./normalize");

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

function isPathAllowed(candidatePath, options = {}) {
  const normalizedPath = path.resolve(candidatePath);
  return allowedProjectRoots(options).some((rootPath) => samePathOrDescendant(normalizedPath, rootPath));
}

function projectPathError(errorCode, userMessage) {
  const err = new Error(userMessage);
  err.errorCode = errorCode;
  err.userMessage = userMessage;
  return err;
}

function assertProjectPathAllowed(candidatePath, options = {}) {
  if (!isPathAllowed(candidatePath, options)) {
    throw projectPathError(
      "path_not_allowed",
      "That folder is outside the allowed local project locations.",
    );
  }
}

function normalizeCandidatePath(candidatePath, options = {}) {
  const rawPath = readString(candidatePath);
  if (!rawPath) {
    throw projectPathError("missing_path", "A folder path is required.");
  }

  if (rawPath === "~" || rawPath.startsWith("~/")) {
    return path.resolve(resolveHomeDir(options), rawPath.slice(2));
  }

  if (!path.isAbsolute(rawPath)) {
    throw projectPathError("invalid_path", "Use an absolute folder path.");
  }

  return path.resolve(rawPath);
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

module.exports = {
  allowedProjectRoots,
  assertProjectPathAllowed,
  isPathAllowed,
  normalizeCandidatePath,
  realpathSyncIfAvailable,
  resolveHomeDir,
  samePathOrDescendant,
  validateDirectory,
};