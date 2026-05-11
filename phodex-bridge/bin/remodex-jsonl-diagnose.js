#!/usr/bin/env node
// FILE: remodex-jsonl-diagnose.js
// Purpose: Standalone diagnostic for Codex session JSONL history parsing.

const fs = require("fs");
const path = require("path");

const DEFAULT_RECENT_TURN_LIMIT = 5;
const DEFAULT_TEXT_PREVIEW_CHARS = 180;
const RELAY_SOFT_LIMIT_BYTES = 4 * 1024 * 1024;

function main(argv) {
  const options = parseArgs(argv);
  if (options.help || !options.filePath) {
    printUsage();
    process.exit(options.help ? 0 : 1);
  }

  const absolutePath = path.resolve(options.filePath);
  const result = diagnoseSessionJsonl(absolutePath, options);
  console.log(JSON.stringify(result, null, 2));

  if (result.errors.file) {
    process.exit(2);
  }
  if (result.parse.invalidJsonLines > 0 || result.history.turnCount === 0) {
    process.exit(3);
  }
}

function parseArgs(argv) {
  const options = {
    filePath: "",
    recentTurns: DEFAULT_RECENT_TURN_LIMIT,
    previewChars: DEFAULT_TEXT_PREVIEW_CHARS,
    includeText: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "-h" || arg === "--help") {
      options.help = true;
    } else if (arg === "--show-text") {
      options.includeText = true;
    } else if (arg === "--recent-turns") {
      options.recentTurns = readPositiveInteger(argv[index + 1], DEFAULT_RECENT_TURN_LIMIT);
      index += 1;
    } else if (arg === "--preview-chars") {
      options.previewChars = readPositiveInteger(argv[index + 1], DEFAULT_TEXT_PREVIEW_CHARS);
      index += 1;
    } else if (!options.filePath) {
      options.filePath = arg;
    }
  }

  return options;
}

function printUsage() {
  console.log([
    "Usage:",
    "  remodex-jsonl-diagnose /path/to/session.jsonl",
    "",
    "Options:",
    "  --recent-turns N    Number of recent parsed turns to summarize. Default: 5",
    "  --preview-chars N   Text preview length per item. Default: 180",
    "  --show-text         Include short text previews in the output",
  ].join("\n"));
}

function diagnoseSessionJsonl(filePath, options = {}) {
  const includeText = Boolean(options.includeText);
  const previewChars = readPositiveInteger(options.previewChars, DEFAULT_TEXT_PREVIEW_CHARS);
  const recentTurnsLimit = readPositiveInteger(options.recentTurns, DEFAULT_RECENT_TURN_LIMIT);
  const summary = {
    file: {
      path: filePath,
      exists: false,
      bytes: 0,
    },
    parse: {
      totalLines: 0,
      blankLines: 0,
      validJsonLines: 0,
      invalidJsonLines: 0,
      invalidSamples: [],
    },
    session: {
      threadId: null,
      cwd: null,
      originator: null,
      source: null,
      sessionMetaCount: 0,
    },
    observed: {
      topLevelTypes: {},
      eventTypes: {},
      responseItemTypes: {},
      threadIds: [],
      turnIds: [],
    },
    history: {
      turnCount: 0,
      itemCount: 0,
      turnsWithNoItems: 0,
      recentTurns: [],
    },
    relaySimulation: {
      recentPageBytes: 0,
      recentPageWithin4MiB: false,
      compactSingleTurnBytes: 0,
      compactSingleTurnWithin4MiB: false,
      wouldReturnAtLeastOneTurn: false,
    },
    likelyIssue: "unknown",
    errors: {
      file: null,
    },
  };

  let stat;
  try {
    stat = fs.statSync(filePath);
  } catch (error) {
    summary.errors.file = error.message;
    return summary;
  }

  if (!stat.isFile()) {
    summary.errors.file = "Path is not a file.";
    return summary;
  }

  summary.file.exists = true;
  summary.file.bytes = stat.size;

  const turns = [];
  const turnsById = new Map();
  const threadIds = new Set();
  const turnIds = new Set();
  let activeTurnId = "";

  const raw = fs.readFileSync(filePath, "utf8");
  const lines = raw.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const lineNumber = index + 1;
    const line = lines[index];
    summary.parse.totalLines += 1;
    if (!line.trim()) {
      summary.parse.blankLines += 1;
      continue;
    }

    let entry;
    try {
      entry = JSON.parse(line);
      summary.parse.validJsonLines += 1;
    } catch (error) {
      summary.parse.invalidJsonLines += 1;
      if (summary.parse.invalidSamples.length < 5) {
        summary.parse.invalidSamples.push({
          line: lineNumber,
          error: error.message,
          preview: line.slice(0, 240),
        });
      }
      continue;
    }

    increment(summary.observed.topLevelTypes, readString(entry?.type) || "unknown");
    collectKnownThreadIds(entry, threadIds);

    if (entry?.type === "session_meta") {
      summary.session.sessionMetaCount += 1;
      const payload = objectValue(entry.payload);
      summary.session.threadId ||= readString(payload?.id) || readString(payload?.thread_id) || readString(payload?.threadId);
      summary.session.cwd ||= readString(payload?.cwd);
      summary.session.originator ||= readString(payload?.originator);
      summary.session.source ||= readString(payload?.source);
      if (summary.session.threadId) {
        threadIds.add(summary.session.threadId);
      }
      continue;
    }

    const embeddedTurns = findEmbeddedTurns(entry);
    for (const turn of embeddedTurns) {
      const turnId = readTurnId(turn) || `embedded-turn-line-${lineNumber}-${turns.length + 1}`;
      const record = ensureTurn(turns, turnsById, turnId, lineNumber, entry.timestamp);
      record.sourceKinds.add("embedded_turn");
      if (Array.isArray(turn.items)) {
        for (const item of turn.items) {
          addItem(record, item, lineNumber, includeText, previewChars);
        }
      }
      turnIds.add(turnId);
    }

    if (entry?.type === "event_msg") {
      const payload = objectValue(entry.payload);
      const eventType = readString(payload?.type) || "unknown";
      increment(summary.observed.eventTypes, eventType);

      if (eventType === "task_started") {
        activeTurnId = readString(payload?.turn_id) || readString(payload?.turnId) || activeTurnId || `turn-line-${lineNumber}`;
        const record = ensureTurn(turns, turnsById, activeTurnId, lineNumber, entry.timestamp);
        record.status ||= "running";
        record.sourceKinds.add("task_started");
        turnIds.add(activeTurnId);
      } else if (eventType === "task_complete") {
        const turnId = readString(payload?.turn_id) || readString(payload?.turnId) || activeTurnId || `turn-line-${lineNumber}`;
        const record = ensureTurn(turns, turnsById, turnId, lineNumber, entry.timestamp);
        record.status = "completed";
        record.sourceKinds.add("task_complete");
        turnIds.add(turnId);
      } else if (eventType === "user_message" || eventType === "agent_message" || eventType === "agent_reasoning") {
        const turnId = readString(payload?.turn_id) || readString(payload?.turnId) || activeTurnId || `turn-line-${lineNumber}`;
        const record = ensureTurn(turns, turnsById, turnId, lineNumber, entry.timestamp);
        record.sourceKinds.add(eventType);
        turnIds.add(turnId);
        addItem(record, itemFromEventPayload(eventType, payload, lineNumber), lineNumber, includeText, previewChars);
      }
    } else if (entry?.type === "response_item") {
      const payload = objectValue(entry.payload) || {};
      const itemType = normalizeType(readString(payload.type)) || "unknown";
      increment(summary.observed.responseItemTypes, itemType);
      const turnId = readString(payload.turn_id) || readString(payload.turnId) || activeTurnId || `response-items-line-${lineNumber}`;
      const record = ensureTurn(turns, turnsById, turnId, lineNumber, entry.timestamp);
      record.sourceKinds.add("response_item");
      turnIds.add(turnId);
      addItem(record, payload, lineNumber, includeText, previewChars);
    }
  }

  const sortedTurns = turns.sort((a, b) => a.firstLine - b.firstLine);
  summary.observed.threadIds = Array.from(threadIds).sort();
  summary.observed.turnIds = Array.from(turnIds).sort();
  summary.history.turnCount = sortedTurns.length;
  summary.history.itemCount = sortedTurns.reduce((total, turn) => total + turn.items.length, 0);
  summary.history.turnsWithNoItems = sortedTurns.filter((turn) => turn.items.length === 0).length;
  summary.history.recentTurns = sortedTurns.slice(-recentTurnsLimit).map((turn) => summarizeTurn(turn, includeText));

  const recentPage = {
    id: "diagnostic-thread-turns-list",
    result: {
      data: sortedTurns.slice(-recentTurnsLimit).reverse().map(toWireTurn),
      nextCursor: sortedTurns.length > recentTurnsLimit ? "diagnostic-has-older-turns" : null,
    },
  };
  const recentPageBytes = Buffer.byteLength(JSON.stringify(recentPage), "utf8");
  const compactSingleTurn = sortedTurns.length > 0 ? {
    id: "diagnostic-thread-turns-list",
    result: {
      data: [compactTurn(toWireTurn(sortedTurns[sortedTurns.length - 1]))],
      nextCursor: sortedTurns.length > 1 ? "diagnostic-has-older-turns" : null,
    },
  } : null;
  const compactSingleTurnBytes = compactSingleTurn
    ? Buffer.byteLength(JSON.stringify(compactSingleTurn), "utf8")
    : 0;

  summary.relaySimulation.recentPageBytes = recentPageBytes;
  summary.relaySimulation.recentPageWithin4MiB = recentPageBytes <= RELAY_SOFT_LIMIT_BYTES;
  summary.relaySimulation.compactSingleTurnBytes = compactSingleTurnBytes;
  summary.relaySimulation.compactSingleTurnWithin4MiB = compactSingleTurnBytes > 0
    && compactSingleTurnBytes <= RELAY_SOFT_LIMIT_BYTES;
  summary.relaySimulation.wouldReturnAtLeastOneTurn = summary.relaySimulation.recentPageWithin4MiB
    ? sortedTurns.length > 0
    : summary.relaySimulation.compactSingleTurnWithin4MiB;

  summary.likelyIssue = classifyIssue(summary);
  return summary;
}

function classifyIssue(summary) {
  if (summary.errors.file) {
    return "file_not_readable";
  }
  if (summary.parse.invalidJsonLines > 0 && summary.parse.validJsonLines === 0) {
    return "jsonl_not_parseable";
  }
  if (summary.history.turnCount === 0 && summary.parse.validJsonLines > 0) {
    return "jsonl_parseable_but_no_recognized_turns";
  }
  if (!summary.relaySimulation.wouldReturnAtLeastOneTurn) {
    return "recognized_turns_but_payload_still_too_large";
  }
  return "jsonl_parseable_and_turns_extractable";
}

function ensureTurn(turns, turnsById, turnId, lineNumber, timestamp) {
  const normalizedTurnId = readString(turnId) || `turn-line-${lineNumber}`;
  let turn = turnsById.get(normalizedTurnId);
  if (!turn) {
    turn = {
      id: normalizedTurnId,
      firstLine: lineNumber,
      lastLine: lineNumber,
      createdAt: readString(timestamp) || null,
      status: "",
      sourceKinds: new Set(),
      items: [],
    };
    turnsById.set(normalizedTurnId, turn);
    turns.push(turn);
  }
  turn.lastLine = lineNumber;
  return turn;
}

function addItem(turn, item, lineNumber, includeText, previewChars) {
  if (!item || typeof item !== "object") {
    return;
  }
  const text = firstText(item);
  turn.items.push({
    id: readString(item.id) || readString(item.item_id) || readString(item.itemId) || `item-line-${lineNumber}-${turn.items.length + 1}`,
    type: readString(item.type) || "unknown",
    role: readString(item.role) || null,
    line: lineNumber,
    textBytes: text ? Buffer.byteLength(text, "utf8") : 0,
    textPreview: includeText && text ? truncateText(text, previewChars) : undefined,
    rawBytes: Buffer.byteLength(JSON.stringify(item), "utf8"),
  });
}

function itemFromEventPayload(eventType, payload, lineNumber) {
  const role = eventType === "user_message" ? "user" : "assistant";
  return {
    id: readString(payload.id) || `${eventType}-line-${lineNumber}`,
    type: eventType,
    role,
    text: readString(payload.message) || readString(payload.text) || readString(payload.summary) || "",
  };
}

function summarizeTurn(turn, includeText) {
  return {
    id: turn.id,
    firstLine: turn.firstLine,
    lastLine: turn.lastLine,
    status: turn.status || null,
    sourceKinds: Array.from(turn.sourceKinds).sort(),
    itemCount: turn.items.length,
    rawItemBytes: turn.items.reduce((total, item) => total + item.rawBytes, 0),
    textBytes: turn.items.reduce((total, item) => total + item.textBytes, 0),
    items: turn.items.slice(-5).map((item) => ({
      id: item.id,
      type: item.type,
      role: item.role,
      line: item.line,
      textBytes: item.textBytes,
      rawBytes: item.rawBytes,
      ...(includeText && item.textPreview !== undefined ? { textPreview: item.textPreview } : {}),
    })),
  };
}

function toWireTurn(turn) {
  return {
    id: turn.id,
    createdAt: turn.createdAt,
    status: turn.status || undefined,
    items: turn.items.map((item) => ({
      id: item.id,
      type: item.type,
      role: item.role || undefined,
      text: item.textPreview || undefined,
      remodexDiagnosticRawBytes: item.rawBytes,
      remodexDiagnosticTextBytes: item.textBytes,
    })),
  };
}

function compactTurn(turn) {
  return {
    id: turn.id,
    createdAt: turn.createdAt,
    status: turn.status,
    remodexDiagnosticCompacted: true,
    items: (Array.isArray(turn.items) ? turn.items : []).slice(-1).map((item) => ({
      id: item.id,
      type: item.type || "relay_truncated_item",
      role: item.role,
      relayPayloadTruncated: true,
      text: item.text ? truncateText(item.text, 1000) : undefined,
    })),
  };
}

function findEmbeddedTurns(entry) {
  const candidates = [
    entry?.turns,
    entry?.thread?.turns,
    entry?.payload?.turns,
    entry?.payload?.thread?.turns,
    entry?.result?.turns,
    entry?.result?.thread?.turns,
    entry?.result?.data,
    entry?.result?.items,
    entry?.result?.payload?.turns,
    entry?.result?.payload?.data,
    entry?.result?.payload?.items,
  ];
  return candidates.find((value) => Array.isArray(value)) || [];
}

function collectKnownThreadIds(value, output, depth = 0) {
  if (!value || depth > 4) {
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value.slice(0, 50)) {
      collectKnownThreadIds(item, output, depth + 1);
    }
    return;
  }
  if (typeof value !== "object") {
    return;
  }

  for (const key of ["thread_id", "threadId", "conversation_id", "conversationId"]) {
    const id = readString(value[key]);
    if (id) {
      output.add(id);
    }
  }
  for (const key of ["payload", "result", "thread"]) {
    collectKnownThreadIds(value[key], output, depth + 1);
  }
}

function readTurnId(turn) {
  return readString(turn?.id) || readString(turn?.turnId) || readString(turn?.turn_id);
}

function firstText(value, depth = 0) {
  if (!value || depth > 5) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const text = firstText(item, depth + 1);
      if (text) {
        return text;
      }
    }
    return "";
  }
  if (typeof value !== "object") {
    return "";
  }
  for (const key of ["text", "message", "summary", "output", "outputText", "output_text", "content"]) {
    const text = firstText(value[key], depth + 1);
    if (text) {
      return text;
    }
  }
  return "";
}

function objectValue(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function readPositiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function increment(record, key) {
  record[key] = (record[key] || 0) + 1;
}

function normalizeType(value) {
  return readString(value).toLowerCase().replace(/[\s_-]+/g, "");
}

function truncateText(value, maxChars) {
  const text = readString(value);
  if (!text || text.length <= maxChars) {
    return text;
  }
  return `...\n${text.slice(-maxChars)}`;
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  diagnoseSessionJsonl,
};
