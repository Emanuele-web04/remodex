// FILE: rollout-watch.js
// Purpose: Watches the rollout file for the active Remodex thread so handoff can be verified from the real persisted Codex data.
// Layer: CLI helper
// Exports: watchThreadRollout
// Depends on: fs, os, path, ./session-state

const fs = require("fs");
const os = require("os");
const path = require("path");
const { readLastActiveThread } = require("./session-state");

function watchThreadRollout(threadId = "") {
  const resolvedThreadId = resolveThreadId(threadId);
  const sessionsRoot = resolveSessionsRoot();
  const rolloutPath = findRolloutFileForThread(sessionsRoot, resolvedThreadId);

  if (!rolloutPath) {
    throw new Error(`No rollout file found for thread ${resolvedThreadId}.`);
  }

  let offset = fs.statSync(rolloutPath).size;
  let partialLine = "";

  console.log(`[remodex] Watching thread ${resolvedThreadId}`);
  console.log(`[remodex] Rollout file: ${rolloutPath}`);
  console.log("[remodex] Waiting for new persisted events... (Ctrl+C to stop)");

  const onChange = (current, previous) => {
    if (current.size <= previous.size) {
      return;
    }

    const stream = fs.createReadStream(rolloutPath, {
      start: offset,
      end: current.size - 1,
      encoding: "utf8",
    });

    let chunkBuffer = "";
    stream.on("data", (chunk) => {
      chunkBuffer += chunk;
    });

    stream.on("end", () => {
      offset = current.size;
      const combined = partialLine + chunkBuffer;
      const lines = combined.split("\n");
      partialLine = lines.pop() || "";

      for (const line of lines) {
        const formatted = formatRolloutLine(line);
        if (formatted) {
          console.log(formatted);
        }
      }
    });
  };

  fs.watchFile(rolloutPath, { interval: 700 }, onChange);

  const cleanup = () => {
    fs.unwatchFile(rolloutPath, onChange);
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);
}

function resolveThreadId(threadId) {
  if (threadId && typeof threadId === "string") {
    return threadId;
  }

  const last = readLastActiveThread();
  if (last?.threadId) {
    return last.threadId;
  }

  throw new Error("No thread id provided and no remembered Remodex thread found.");
}

function resolveSessionsRoot() {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  return path.join(codexHome, "sessions");
}

function findRolloutFileForThread(root, threadId) {
  const stack = [root];

  while (stack.length > 0) {
    const current = stack.pop();
    const entries = fs.readdirSync(current, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }

      if (!entry.isFile()) {
        continue;
      }

      if (entry.name.includes(threadId) && entry.name.startsWith("rollout-") && entry.name.endsWith(".jsonl")) {
        return fullPath;
      }
    }
  }

  return null;
}

function formatRolloutLine(rawLine) {
  const trimmed = rawLine.trim();
  if (!trimmed) {
    return null;
  }

  let parsed = null;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }

  const timestamp = formatTimestamp(parsed.timestamp);
  const payload = parsed.payload || {};

  if (parsed.type === "event_msg") {
    const eventType = payload.type;
    if (eventType === "user_message") {
      return `${timestamp} Phone: ${previewText(payload.message)}`;
    }
    if (eventType === "agent_message") {
      return `${timestamp} Codex: ${previewText(payload.message)}`;
    }
    if (eventType === "task_started") {
      return `${timestamp} Task started`;
    }
    if (eventType === "task_complete") {
      return `${timestamp} Task complete`;
    }
  }

  return null;
}

function formatTimestamp(value) {
  if (!value || typeof value !== "string") {
    return "[time?]";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "[time?]";
  }

  return `[${date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}]`;
}

function previewText(value) {
  if (typeof value !== "string") {
    return "";
  }

  const normalized = value.replace(/\s+/g, " ").trim();
  if (normalized.length <= 120) {
    return normalized;
  }

  return `${normalized.slice(0, 117)}...`;
}

module.exports = { watchThreadRollout };
