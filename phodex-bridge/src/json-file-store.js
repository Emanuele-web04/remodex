// FILE: json-file-store.js
// Purpose: Shared atomic JSON file persistence for domain stores.
//          Extracted from thread-ownership-store and opencode-session-store.
// Layer: Persistence helper
// Exports: createJsonFileStore
// Depends on: fs, os, path, normalize

const fs = require("fs");
const os = require("os");
const path = require("path");
const { readString } = require("./normalize");

const DEFAULT_WRITE_DEBOUNCE_MS = 0;
const CORRUPT_BACKUP_SUFFIX = ".corrupt";

function createJsonFileStore({
  filePath = "",
  defaultFileName,
  homeDir = os.homedir(),
  key,
  fsImpl = fs,
  writeDebounceMs = DEFAULT_WRITE_DEBOUNCE_MS,
} = {}) {
  const resolvedHome = path.resolve(homeDir);
  const resolvedPath =
    readString(filePath) || path.join(resolvedHome, ".remodex", defaultFileName);
  const debounceMs = Number.isFinite(writeDebounceMs) && writeDebounceMs >= 0
    ? writeDebounceMs
    : DEFAULT_WRITE_DEBOUNCE_MS;

  let pendingValue = null;
  let flushTimer = null;

  function resolvePath() {
    return resolvedPath;
  }

  function extractBucket(parsed) {
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const value = parsed[key];
      return typeof value === "object" && !Array.isArray(value) ? value : {};
    }
    return {};
  }

  function read() {
    let raw = "";
    try {
      raw = fsImpl.readFileSync(resolvedPath, "utf8");
    } catch {
      return {};
    }

    try {
      return extractBucket(JSON.parse(raw));
    } catch {
      backupCorruptFile(raw);
      const salvaged = salvageStorePayload(raw, key);
      if (Object.keys(salvaged).length > 0) {
        writeNow(salvaged);
      }
      return salvaged;
    }
  }

  function write(value) {
    const normalized =
      typeof value === "object" && !Array.isArray(value) ? value : {};
    pendingValue = normalized;

    if (debounceMs === 0) {
      writeNow(normalized);
      return;
    }

    if (flushTimer) {
      clearTimeout(flushTimer);
    }
    flushTimer = setTimeout(() => {
      flushTimer = null;
      if (pendingValue) {
        writeNow(pendingValue);
        pendingValue = null;
      }
    }, debounceMs);
  }

  function flush() {
    if (flushTimer) {
      clearTimeout(flushTimer);
      flushTimer = null;
    }
    if (pendingValue) {
      writeNow(pendingValue);
      pendingValue = null;
    }
  }

  function writeNow(value) {
    const normalized =
      typeof value === "object" && !Array.isArray(value) ? value : {};
    const state = { [key]: normalized };
    const directory = path.dirname(resolvedPath);
    fsImpl.mkdirSync(directory, { recursive: true, mode: 0o700 });
    try {
      fsImpl.chmodSync(directory, 0o700);
    } catch {
      // Best-effort on platforms that restrict chmod.
    }
    const tempPath = `${resolvedPath}.${process.pid}.${Date.now()}.tmp`;
    fsImpl.writeFileSync(
      tempPath,
      `${JSON.stringify(state, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    fsImpl.renameSync(tempPath, resolvedPath);
    try {
      fsImpl.chmodSync(resolvedPath, 0o600);
    } catch {
      // Best-effort on platforms that restrict chmod.
    }
  }

  function backupCorruptFile(raw) {
    const backupPath = `${resolvedPath}${CORRUPT_BACKUP_SUFFIX}.${Date.now()}.bak`;
    try {
      fsImpl.writeFileSync(backupPath, raw, { encoding: "utf8", mode: 0o600 });
    } catch {
      // Best-effort backup only.
    }
  }

  return { resolvePath, read, write, flush };
}

function salvageStorePayload(raw, key) {
  const salvagedRoot = trySalvageJsonObject(raw);
  if (!salvagedRoot) {
    return {};
  }
  return extractBucketForKey(salvagedRoot, key);
}

function trySalvageJsonObject(raw) {
  const trimmed = typeof raw === "string" ? raw.trim() : "";
  if (!trimmed) {
    return null;
  }

  for (let end = trimmed.length; end > 0; end -= 1) {
    const prefix = trimmed.slice(0, end).replace(/,\s*$/, "");
    for (const suffix of ["", "}", "}}", "}}}", "}}}}", "}}}}}"]) {
      try {
        const parsed = JSON.parse(`${prefix}${suffix}`);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          return parsed;
        }
      } catch {
        // Keep trimming until we find parseable JSON.
      }
    }
  }
  return null;
}

function extractBucketForKey(parsed, key) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {};
  }
  const value = parsed[key];
  return typeof value === "object" && !Array.isArray(value) ? value : {};
}

module.exports = {
  CORRUPT_BACKUP_SUFFIX,
  DEFAULT_WRITE_DEBOUNCE_MS,
  createJsonFileStore,
  salvageStorePayload,
};