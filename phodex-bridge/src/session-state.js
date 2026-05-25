// FILE: session-state.js
// Purpose: Persists the latest active Remodex thread so the user can reopen it on the Mac for handoff.
// Layer: CLI helper
// Exports: rememberActiveThread, openLastActiveThread, readLastActiveThread
// Depends on: fs, os, path, child_process

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const DEFAULT_STATE_DIR_NAME = ".remodex";
const LAST_THREAD_FILE = "last-thread.json";
const DEFAULT_BUNDLE_ID = "com.openai.codex";

function resolveRemodexStateDir({ env = process.env, osImpl = os } = {}) {
  const override = typeof env.REMODEX_DEVICE_STATE_DIR === "string" && env.REMODEX_DEVICE_STATE_DIR.trim();
  return override || path.join(osImpl.homedir(), DEFAULT_STATE_DIR_NAME);
}

function resolveLastThreadPath(options = {}) {
  return path.join(resolveRemodexStateDir(options), LAST_THREAD_FILE);
}

function rememberActiveThread(threadId, source, options = {}) {
  if (!threadId || typeof threadId !== "string") {
    return false;
  }

  const payload = {
    threadId,
    source: source || "unknown",
    updatedAt: new Date().toISOString(),
  };

  const stateFile = resolveLastThreadPath(options);
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify(payload, null, 2));
  return true;
}

function openLastActiveThread({ bundleId = DEFAULT_BUNDLE_ID } = {}) {
  const state = readState();
  const threadId = state?.threadId;
  if (!threadId) {
    throw new Error("No remembered Remodex thread found yet.");
  }

  const targetUrl = `codex://threads/${threadId}`;
  execFileSync("open", ["-b", bundleId, targetUrl], { stdio: "ignore" });
  return state;
}

function readState(options = {}) {
  const stateFile = resolveLastThreadPath(options);
  if (!fs.existsSync(stateFile)) {
    return null;
  }

  try {
    const raw = fs.readFileSync(stateFile, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

module.exports = {
  rememberActiveThread,
  openLastActiveThread,
  readLastActiveThread: readState,
  resolveLastThreadPath,
  resolveRemodexStateDir,
};
