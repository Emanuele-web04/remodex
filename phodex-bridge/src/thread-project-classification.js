// FILE: thread-project-classification.js
// Purpose: Aligns legacy mobile sidebar classification with app-server project ownership.
// Layer: CLI helper
// Exports: normalizeThreadProjectClassification
// Depends on: fs, os, path

const fs = require("fs");
const os = require("os");
const path = require("path");

const CWD_KEYS = ["cwd", "current_working_directory", "working_directory", "projectPath", "project_path"];

// Older iOS builds infer Projects versus Chats from cwd and do not decode
// app-server's canonical projectId. Old rootless chats inherited the bridge
// process home as cwd, so Desktop places them in Recents while the phone invents a
// project from that path. Rewrite that legacy fallback to the same generated chat-root
// shape used by current Remodex builds. A real path (rather than null) replaces stale
// iOS sidebar cache and remains a valid cwd when the chat is resumed.
function normalizeThreadProjectClassification(thread, {
  fsModule = fs,
  homeDir = os.homedir(),
  latestCwd = "",
} = {}) {
  if (!thread || typeof thread !== "object" || !Object.hasOwn(thread, "projectId")) {
    return thread;
  }
  const normalizedLatestCwd = normalizePath(latestCwd);
  if (normalizedLatestCwd && !samePath(thread.cwd, normalizedLatestCwd)) {
    thread.cwd = normalizedLatestCwd;
    return thread;
  }
  if (normalizeString(thread.projectId) || !samePath(thread.cwd, homeDir)) {
    return thread;
  }

  const projectlessPath = legacyProjectlessPath(thread, homeDir);
  try {
    fsModule.mkdirSync(projectlessPath, { recursive: true });
  } catch {
    return thread;
  }

  for (const key of CWD_KEYS) {
    if (Object.hasOwn(thread, key)) {
      thread[key] = projectlessPath;
    }
  }
  if (thread.metadata && typeof thread.metadata === "object") {
    for (const key of CWD_KEYS) {
      if (Object.hasOwn(thread.metadata, key)) {
        thread.metadata[key] = projectlessPath;
      }
    }
  }
  return thread;
}

function legacyProjectlessPath(thread, homeDir) {
  const timestamp = Number(thread?.createdAt ?? thread?.created_at) * 1000;
  const date = Number.isFinite(timestamp) && timestamp > 0 ? new Date(timestamp) : new Date();
  const day = date.toISOString().slice(0, 10);
  const threadId = normalizeString(thread?.id) || normalizeString(thread?.threadId) || "chat";
  return path.join(homeDir, "Documents", "Codex", day, `legacy-${threadId.slice(0, 8)}`);
}

function samePath(left, right) {
  const normalizedLeft = normalizePath(left);
  const normalizedRight = normalizePath(right);
  return Boolean(normalizedLeft && normalizedRight && normalizedLeft === normalizedRight);
}

function normalizePath(value) {
  const normalized = normalizeString(value);
  return normalized ? path.resolve(normalized) : "";
}

function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

module.exports = {
  normalizeThreadProjectClassification,
};
