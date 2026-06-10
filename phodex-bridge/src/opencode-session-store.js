// FILE: opencode-session-store.js
// Purpose: Persists durable thread → session mappings so a session created in OpenCode
//          can be resumed across bridge restarts. Also indexes externally discovered
//          sessions (class e) until adopt-on-resume in threadRead.
// Layer: Persistence helper
// Exports: createOpenCodeSessionStore
// Depends on: os, path, json-file-store, normalize

const os = require("os");
const path = require("path");
const { readString } = require("./normalize");
const { createJsonFileStore } = require("./json-file-store");

function readDiscoveredIndex(store, fs) {
  try {
    const filePath = store.resolvePath();
    const raw = fs.readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const value = parsed.discovered;
      return typeof value === "object" && !Array.isArray(value) ? value : {};
    }
  } catch {
    // File doesn't exist yet or is corrupted; start fresh.
  }
  return {};
}

function createOpenCodeSessionStore({
  storagePath = "",
  homeDir = os.homedir(),
  fsImpl,
  nowMs = Date.now,
} = {}) {
  const sessionsStore = createJsonFileStore({
    filePath: storagePath,
    defaultFileName: "opencode-sessions.json",
    homeDir,
    key: "sessions",
    fsImpl,
  });

  let sessions = sessionsStore.read();
  const fs = fsImpl || require("fs");
  let discovered = readDiscoveredIndex(sessionsStore, fs);

  function persist() {
    const filePath = sessionsStore.resolvePath();
    const directory = path.dirname(filePath);
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    try {
      fs.chmodSync(directory, 0o700);
    } catch {
      // Best-effort on platforms that restrict chmod.
    }
    const state = { sessions, discovered };
    const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tempPath, `${JSON.stringify(state, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    fs.renameSync(tempPath, filePath);
    try {
      fs.chmodSync(filePath, 0o600);
    } catch {
      // Best-effort on platforms that restrict chmod.
    }
  }

  function set(threadId, sessionId, metadata = {}) {
    const normalizedThreadId = readString(threadId);
    const normalizedSessionId = readString(sessionId);
    if (!normalizedThreadId || !normalizedSessionId) {
      return false;
    }

    const previous = sessions[normalizedThreadId] || {};
    const meta = metadata && typeof metadata === "object" ? metadata : {};
    sessions[normalizedThreadId] = {
      sessionId: normalizedSessionId,
      cwd: readString(meta.cwd) || readString(previous.cwd) || "",
      model: readString(meta.model) || readString(previous.model) || "",
      agent: readString(meta.agent) || readString(previous.agent) || "",
      title: readString(meta.title) || readString(previous.title) || "",
      archived: meta.archived === true || (meta.archived === undefined && previous.archived === true),
      discovered: meta.discovered === true || previous.discovered === true,
      updatedAt: new Date(nowMs()).toISOString(),
    };
    persist();
    return true;
  }

  function get(threadId) {
    const normalizedThreadId = readString(threadId);
    return sessions[normalizedThreadId]?.sessionId || null;
  }

  function getEntry(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !sessions[normalizedThreadId]) {
      return null;
    }
    return { ...sessions[normalizedThreadId] };
  }

  function getBySessionId(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return null;
    }
    for (const [threadId, entry] of Object.entries(sessions)) {
      if (readString(entry?.sessionId) === normalizedSessionId) {
        return { threadId, ...entry };
      }
    }
    return null;
  }

  function setDiscovered(sessionId, metadata = {}) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId) {
      return false;
    }
    const meta = metadata && typeof metadata === "object" ? metadata : {};
    const previous = discovered[normalizedSessionId] || {};
    discovered[normalizedSessionId] = {
      threadId:
        readString(meta.threadId) ||
        readString(previous.threadId) ||
        `opencode-session-${normalizedSessionId}`,
      sessionId: normalizedSessionId,
      cwd: readString(meta.cwd) || readString(previous.cwd) || "",
      model: readString(meta.model) || readString(previous.model) || "",
      agent: readString(meta.agent) || readString(previous.agent) || "",
      title: readString(meta.title) || readString(previous.title) || "",
      adopted: previous.adopted === true,
      updatedAt: new Date(nowMs()).toISOString(),
    };
    persist();
    return true;
  }

  function getDiscovered(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId || !discovered[normalizedSessionId]) {
      return null;
    }
    return { ...discovered[normalizedSessionId] };
  }

  function markAdopted(sessionId) {
    const normalizedSessionId = readString(sessionId);
    if (!normalizedSessionId || !discovered[normalizedSessionId]) {
      return false;
    }
    discovered[normalizedSessionId].adopted = true;
    discovered[normalizedSessionId].updatedAt = new Date(nowMs()).toISOString();
    persist();
    return true;
  }

  function remove(threadId) {
    const normalizedThreadId = readString(threadId);
    if (!normalizedThreadId || !sessions[normalizedThreadId]) {
      return false;
    }

    delete sessions[normalizedThreadId];
    persist();
    return true;
  }

  function entries() {
    return Object.entries(sessions).map(([threadId, entry]) => [threadId, entry]);
  }

  return {
    get,
    getEntry,
    getBySessionId,
    set,
    setDiscovered,
    getDiscovered,
    markAdopted,
    remove,
    entries,
  };
}

module.exports = { createOpenCodeSessionStore };