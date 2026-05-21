// FILE: claude-thread-store.js
// Purpose: Persists Remodex-owned Claude Code thread metadata and replayable turn summaries.
// Layer: Runtime provider state
// Exports: createClaudeThreadStore
// Depends on: fs, path, crypto, ./daemon-state

const fs = require("fs");
const path = require("path");
const { randomUUID } = require("crypto");
const { resolveRemodexStateDir } = require("./daemon-state");
const { CLAUDE_PROVIDER_ID, normalizeClaudeModel } = require("./claude-models");

const STORE_FILE_NAME = "claude-threads.json";
const STORE_VERSION = 1;

function createClaudeThreadStore({
  stateDir = resolveRemodexStateDir(),
  fsImpl = fs,
  now = () => new Date(),
  randomUUIDImpl = randomUUID,
  persistDelayMs = 75,
} = {}) {
  const storeFile = path.join(stateDir, STORE_FILE_NAME);
  let stateCache = null;
  let pendingWriteTimer = null;

  function loadStateFromDisk() {
    if (!fsImpl.existsSync(storeFile)) {
      return createEmptyState();
    }

    try {
      const parsed = JSON.parse(fsImpl.readFileSync(storeFile, "utf8"));
      return normalizeState(parsed);
    } catch {
      return createEmptyState();
    }
  }

  function readState() {
    if (!stateCache) {
      stateCache = loadStateFromDisk();
    }
    return stateCache;
  }

  function writeState(state) {
    const normalizedState = normalizeState(state);
    stateCache = normalizedState;
    fsImpl.mkdirSync(path.dirname(storeFile), { recursive: true, mode: 0o700 });
    try {
      fsImpl.chmodSync(path.dirname(storeFile), 0o700);
    } catch {
      // Best-effort only on filesystems that do not support POSIX modes.
    }
    fsImpl.writeFileSync(storeFile, JSON.stringify(normalizedState, null, 2), { mode: 0o600 });
    try {
      fsImpl.chmodSync(storeFile, 0o600);
    } catch {
      // Best-effort only on filesystems that do not support POSIX modes.
    }
  }

  function scheduleWrite(state) {
    if (pendingWriteTimer) {
      return;
    }
    pendingWriteTimer = setTimeout(() => {
      pendingWriteTimer = null;
      writeState(state);
    }, persistDelayMs);
    pendingWriteTimer.unref?.();
  }

  function flush() {
    if (!pendingWriteTimer) {
      return;
    }
    clearTimeout(pendingWriteTimer);
    pendingWriteTimer = null;
    writeState(readState());
  }

  function mutate(mutator, { persist = "immediate" } = {}) {
    const state = readState();
    const result = mutator(state);
    if (persist === "debounced") {
      scheduleWrite(state);
    } else {
      flush();
      writeState(state);
    }
    return result;
  }

  function createThread({ cwd, model, title } = {}) {
    return mutate((state) => {
      const timestamp = nowIso(now);
      const thread = {
        id: randomUUIDImpl(),
        title: normalizeString(title) || "Claude",
        name: null,
        preview: "",
        createdAt: timestamp,
        updatedAt: timestamp,
        cwd: normalizeString(cwd) || null,
        model: normalizeClaudeModel(model),
        modelProvider: CLAUDE_PROVIDER_ID,
        source: CLAUDE_PROVIDER_ID,
        archived: false,
        sessionId: null,
        turns: [],
        metadata: {
          modelProvider: CLAUDE_PROVIDER_ID,
          source: CLAUDE_PROVIDER_ID,
        },
      };
      state.threads[thread.id] = thread;
      return publicThread(thread);
    });
  }

  function ownsThread(threadId) {
    const normalizedThreadId = normalizeString(threadId);
    return Boolean(normalizedThreadId && readState().threads[normalizedThreadId]);
  }

  function getThread(threadId) {
    const normalizedThreadId = normalizeString(threadId);
    if (!normalizedThreadId) {
      return null;
    }
    const thread = readState().threads[normalizedThreadId];
    return thread ? normalizeThread(thread) : null;
  }

  function getPublicThread(threadId) {
    const thread = getThread(threadId);
    return thread ? publicThread(thread) : null;
  }

  function listThreads({ limit, cursor, includeArchived } = {}) {
    const offset = parseCursor(cursor);
    const maxItems = normalizeLimit(limit, 70);
    const threads = Object.values(readState().threads)
      .map(normalizeThread)
      .filter((thread) => includeArchived || thread.archived !== true)
      .sort((lhs, rhs) => rhs.updatedAt.localeCompare(lhs.updatedAt));
    const page = threads.slice(offset, offset + maxItems).map(publicThread);
    const nextOffset = offset + page.length;
    return {
      data: page,
      nextCursor: nextOffset < threads.length ? String(nextOffset) : null,
    };
  }

  function readThread(threadId) {
    const thread = getThread(threadId);
    if (!thread) {
      throw threadNotFoundError(threadId);
    }
    return {
      thread: publicThread(thread, { includeTurns: true }),
    };
  }

  function listTurns(threadId, { limit, cursor, sortDirection } = {}) {
    const thread = getThread(threadId);
    if (!thread) {
      throw threadNotFoundError(threadId);
    }

    const offset = parseCursor(cursor);
    const maxItems = normalizeLimit(limit, 5);
    const descending = normalizeString(sortDirection).toLowerCase() !== "asc";
    const orderedTurns = descending ? [...thread.turns].reverse() : [...thread.turns];
    const page = orderedTurns.slice(offset, offset + maxItems).map(publicTurn);
    const nextOffset = offset + page.length;
    return {
      data: page,
      nextCursor: nextOffset < orderedTurns.length ? String(nextOffset) : null,
    };
  }

  function ensureTurn({ threadId, turnId, inputText, model }) {
    return mutate((state) => {
      const thread = state.threads[normalizeString(threadId)];
      if (!thread) {
        throw threadNotFoundError(threadId);
      }

      if (normalizeString(model)) {
        thread.model = normalizeClaudeModel(model);
      }

      const timestamp = nowIso(now);
      let turn = thread.turns.find((candidate) => candidate.id === turnId);
      if (!turn) {
        turn = {
          id: turnId,
          status: "running",
          createdAt: timestamp,
          updatedAt: timestamp,
          items: [],
        };
        thread.turns.push(turn);
      }

      const normalizedInput = normalizeString(inputText);
      if (normalizedInput && !turn.items.some((item) => item.type === "userMessage")) {
        turn.items.push({
          id: `user-${turnId}`,
          type: "userMessage",
          text: normalizedInput,
          createdAt: timestamp,
        });
        thread.preview = normalizedInput.slice(0, 280);
      }

      thread.updatedAt = timestamp;
      turn.updatedAt = timestamp;
      return publicTurn(turn);
    }, { persist: "debounced" });
  }

  function appendItemDelta({ threadId, turnId, itemId, type, delta, item = {} }) {
    const deltaText = typeof delta === "string" ? delta : "";
    if (!deltaText.trim()) {
      return null;
    }

    return mutate((state) => {
      const thread = state.threads[normalizeString(threadId)];
      if (!thread) {
        throw threadNotFoundError(threadId);
      }
      const turn = thread.turns.find((candidate) => candidate.id === turnId);
      if (!turn) {
        throw turnNotFoundError(turnId);
      }

      const timestamp = nowIso(now);
      const normalizedItemId = normalizeString(itemId) || `${type}-${turnId}`;
      let existing = turn.items.find((candidate) => candidate.id === normalizedItemId);
      if (!existing) {
        existing = {
          id: normalizedItemId,
          type,
          text: "",
          createdAt: timestamp,
          ...normalizeItemMetadata(item),
        };
        turn.items.push(existing);
      }

      existing.type = type || existing.type;
      existing.text = `${existing.text || ""}${deltaText}`;
      existing.updatedAt = timestamp;
      turn.updatedAt = timestamp;
      thread.updatedAt = timestamp;
      if (type === "agentMessage" && deltaText.trim()) {
        thread.preview = `${thread.preview || ""}${deltaText}`.trim().slice(0, 280);
      }

      return publicTurn(turn);
    });
  }

  function completeTurn({ threadId, turnId, status = "completed", errorMessage = "" }) {
    return mutate((state) => {
      const thread = state.threads[normalizeString(threadId)];
      if (!thread) {
        throw threadNotFoundError(threadId);
      }
      const turn = thread.turns.find((candidate) => candidate.id === turnId);
      if (!turn) {
        throw turnNotFoundError(turnId);
      }

      const timestamp = nowIso(now);
      turn.status = status;
      turn.updatedAt = timestamp;
      if (errorMessage) {
        turn.error = { message: errorMessage };
      } else {
        delete turn.error;
      }
      thread.updatedAt = timestamp;
      return publicTurn(turn);
    });
  }

  function rememberSessionId(threadId, sessionId) {
    const normalizedSessionId = normalizeString(sessionId);
    if (!normalizedSessionId) {
      return null;
    }
    return mutate((state) => {
      const thread = state.threads[normalizeString(threadId)];
      if (!thread) {
        return null;
      }
      thread.sessionId = normalizedSessionId;
      return normalizedSessionId;
    });
  }

  function renameThread(threadId, name) {
    const normalizedName = normalizeString(name);
    return mutate((state) => {
      const thread = state.threads[normalizeString(threadId)];
      if (!thread) {
        throw threadNotFoundError(threadId);
      }
      thread.name = normalizedName || null;
      thread.title = normalizedName || thread.title || "Claude";
      thread.updatedAt = nowIso(now);
      return publicThread(thread);
    });
  }

  function setArchived(threadId, archived) {
    return mutate((state) => {
      const thread = state.threads[normalizeString(threadId)];
      if (!thread) {
        throw threadNotFoundError(threadId);
      }
      thread.archived = archived === true;
      thread.updatedAt = nowIso(now);
      return publicThread(thread);
    });
  }

  return {
    appendItemDelta,
    completeTurn,
    createThread,
    ensureTurn,
    getPublicThread,
    getThread,
    listThreads,
    listTurns,
    ownsThread,
    readThread,
    rememberSessionId,
    renameThread,
    setArchived,
    storeFile,
    flush,
  };
}

function createEmptyState() {
  return {
    version: STORE_VERSION,
    threads: {},
  };
}

function normalizeState(value) {
  const source = value && typeof value === "object" ? value : {};
  const threads = source.threads && typeof source.threads === "object" && !Array.isArray(source.threads)
    ? source.threads
    : {};
  return {
    version: STORE_VERSION,
    threads: Object.fromEntries(
      Object.entries(threads)
        .map(([id, thread]) => [id, normalizeThread({ id, ...thread })])
        .filter(([, thread]) => Boolean(thread.id))
    ),
  };
}

function normalizeThread(thread) {
  const timestamp = normalizeString(thread.updatedAt)
    || normalizeString(thread.createdAt)
    || new Date(0).toISOString();
  const id = normalizeString(thread.id);
  return {
    id,
    title: normalizeString(thread.title) || "Claude",
    name: normalizeString(thread.name) || null,
    preview: normalizeString(thread.preview),
    createdAt: normalizeString(thread.createdAt) || timestamp,
    updatedAt: timestamp,
    cwd: normalizeString(thread.cwd) || null,
    model: normalizeClaudeModel(thread.model),
    modelProvider: CLAUDE_PROVIDER_ID,
    source: CLAUDE_PROVIDER_ID,
    archived: thread.archived === true,
    sessionId: normalizeString(thread.sessionId) || null,
    turns: Array.isArray(thread.turns) ? thread.turns.map(normalizeTurn).filter(Boolean) : [],
    metadata: {
      ...(thread.metadata && typeof thread.metadata === "object" ? thread.metadata : {}),
      modelProvider: CLAUDE_PROVIDER_ID,
      source: CLAUDE_PROVIDER_ID,
    },
  };
}

function normalizeTurn(turn) {
  const id = normalizeString(turn?.id);
  if (!id) {
    return null;
  }
  const timestamp = normalizeString(turn.updatedAt)
    || normalizeString(turn.createdAt)
    || new Date(0).toISOString();
  const normalized = {
    id,
    status: normalizeString(turn.status) || "completed",
    createdAt: normalizeString(turn.createdAt) || timestamp,
    updatedAt: timestamp,
    items: Array.isArray(turn.items) ? turn.items.map(normalizeItem).filter(Boolean) : [],
  };
  if (turn.error && typeof turn.error === "object") {
    normalized.error = {
      message: normalizeString(turn.error.message) || "Turn failed",
    };
  }
  return normalized;
}

function normalizeItem(item) {
  const id = normalizeString(item?.id);
  const type = normalizeString(item?.type);
  if (!id || !type) {
    return null;
  }
  return {
    id,
    type,
    text: normalizeString(item.text),
    createdAt: normalizeString(item.createdAt) || new Date(0).toISOString(),
    updatedAt: normalizeString(item.updatedAt) || undefined,
    ...normalizeItemMetadata(item),
  };
}

function normalizeItemMetadata(item) {
  const metadata = {};
  for (const key of ["command", "path", "toolName", "name", "phase"]) {
    const value = normalizeString(item?.[key]);
    if (value) {
      metadata[key] = value;
    }
  }
  return metadata;
}

function publicThread(thread, { includeTurns = false } = {}) {
  const normalized = normalizeThread(thread);
  const result = {
    id: normalized.id,
    title: normalized.title,
    name: normalized.name,
    preview: normalized.preview,
    createdAt: normalized.createdAt,
    updatedAt: normalized.updatedAt,
    cwd: normalized.cwd,
    model: normalized.model,
    modelProvider: CLAUDE_PROVIDER_ID,
    source: CLAUDE_PROVIDER_ID,
    metadata: normalized.metadata,
  };
  if (includeTurns) {
    result.turns = normalized.turns.map(publicTurn);
  }
  return result;
}

function publicTurn(turn) {
  const normalized = normalizeTurn(turn);
  const result = {
    id: normalized.id,
    status: normalized.status,
    createdAt: normalized.createdAt,
    updatedAt: normalized.updatedAt,
    items: normalized.items.map((item) => Object.fromEntries(
      Object.entries(item).filter(([, value]) => value !== undefined && value !== null)
    )),
  };
  if (normalized.error) {
    result.error = normalized.error;
  }
  return result;
}

function parseCursor(cursor) {
  const numeric = Number(cursor);
  return Number.isInteger(numeric) && numeric > 0 ? numeric : 0;
}

function normalizeLimit(limit, fallback) {
  const numeric = Number(limit);
  if (!Number.isInteger(numeric) || numeric <= 0) {
    return fallback;
  }
  return Math.min(numeric, 100);
}

function nowIso(now) {
  const value = now();
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function normalizeString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function threadNotFoundError(threadId) {
  const error = new Error(`Claude thread not found: ${threadId || "(missing)"}`);
  error.errorCode = "thread_not_found";
  return error;
}

function turnNotFoundError(turnId) {
  const error = new Error(`Claude turn not found: ${turnId || "(missing)"}`);
  error.errorCode = "turn_not_found";
  return error;
}

module.exports = {
  createClaudeThreadStore,
};
