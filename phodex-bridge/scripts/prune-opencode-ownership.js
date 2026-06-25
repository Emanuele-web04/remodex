#!/usr/bin/env node
// FILE: prune-opencode-ownership.js
// Purpose: Dry-run or apply cleanup of orphan OpenCode ownership/session rows in ~/.remodex.
// Layer: Maintenance script
// Exports: none (CLI)
// Depends on: ../src/thread-ownership-store, ../src/opencode-session-store

const os = require("os");
const path = require("path");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
const { createOpenCodeSessionStore } = require("../src/opencode-session-store");

const OPENCODE_PROVIDER_ID = "opencode";
const apply = process.argv.includes("--apply");

function remodexDir() {
  const override = process.env.REMODEX_HOME?.trim();
  return override || path.join(os.homedir(), ".remodex");
}

function main() {
  const base = remodexDir();
  const ownership = createThreadOwnershipStore({
    storagePath: path.join(base, "thread-ownership.json"),
  });
  const sessions = createOpenCodeSessionStore({
    storagePath: process.env.REMODEX_OPENCODE_SESSIONS_PATH?.trim() || path.join(base, "opencode-sessions.json"),
  });

  const owned = ownership.getAllOwnedBy(OPENCODE_PROVIDER_ID);
  let ownershipWithoutSession = 0;
  let sessionWithoutOwnership = 0;

  for (const { threadId } of owned) {
    if (!sessions.get(threadId)) {
      ownershipWithoutSession += 1;
      console.log(`[orphan-ownership] ${threadId} (no session)`);
      if (apply) {
        ownership.removeOwnership(threadId);
      }
    }
  }

  for (const [threadId] of sessions.entries()) {
    if (!ownership.ownsThread(threadId, OPENCODE_PROVIDER_ID)) {
      sessionWithoutOwnership += 1;
      console.log(`[orphan-session] ${threadId} (no ownership)`);
      if (apply) {
        sessions.remove(threadId);
      }
    }
  }

  console.log(
    JSON.stringify({
      mode: apply ? "apply" : "dry-run",
      ownership_without_session: ownershipWithoutSession,
      session_without_ownership: sessionWithoutOwnership,
    }),
  );

  if (!apply && (ownershipWithoutSession > 0 || sessionWithoutOwnership > 0)) {
    console.log("Re-run with --apply to persist removals.");
  }
}

main();