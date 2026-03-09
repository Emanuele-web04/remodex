// FILE: session-state.js
// Purpose: Persists the latest active Remodex thread so the user can reopen it on the Mac for handoff.
// Layer: CLI helper
// Exports: rememberActiveThread, openLastActiveThread, readLastActiveThread
// Depends on: fs, os, path, child_process

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const STATE_DIR = path.join(os.homedir(), ".remodex");
const STATE_FILE = path.join(STATE_DIR, "last-thread.json");
const DEFAULT_BUNDLE_ID = "com.openai.codex";

function rememberActiveThread(threadId, source) {
  if (!threadId || typeof threadId !== "string") {
    return false;
  }

  const payload = {
    threadId,
    source: source || "unknown",
    updatedAt: new Date().toISOString(),
  };

  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(payload, null, 2));
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

function readState() {
  if (!fs.existsSync(STATE_FILE)) {
    return null;
  }

  const raw = fs.readFileSync(STATE_FILE, "utf8");
  return JSON.parse(raw);
}

module.exports = {
  rememberActiveThread,
  openLastActiveThread,
  readLastActiveThread: readState,
};
