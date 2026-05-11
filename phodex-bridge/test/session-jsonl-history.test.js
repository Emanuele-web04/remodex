// FILE: session-jsonl-history.test.js
// Purpose: Verifies local Codex JSONL history fallback pages for empty app-server turn lists.

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  readThreadTurnsListPageFromSessionJsonl,
} = require("../src/session-jsonl-history");

test("readThreadTurnsListPageFromSessionJsonl builds a recent turns page from rollout JSONL", () => {
  const filePath = "/tmp/session.jsonl";
  const content = [
    JSON.stringify({
      timestamp: "2026-05-05T23:31:11.000Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl",
        cwd: "/repo",
        originator: "Codex Desktop",
        source: "vscode",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:12.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-jsonl",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:13.000Z",
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: "turn-jsonl",
        message: "please fix this",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:14.000Z",
      type: "response_item",
      payload: {
        id: "assistant-final",
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "fixed" }],
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:15.000Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: "turn-jsonl",
      },
    }),
    "",
  ].join("\n");
  const fsModule = {
    readFileSync: (readPath) => {
      assert.equal(readPath, filePath);
      return content;
    },
  };

  const page = readThreadTurnsListPageFromSessionJsonl(filePath, {
    threadId: "thread-jsonl",
    limit: 5,
    fsModule,
  });

  assert.equal(page.remodexJsonlFallback, true);
  assert.equal(page.nextCursor, null);
  assert.equal(page.data.length, 1);
  assert.equal(page.data[0].id, "turn-jsonl");
  assert.equal(page.data[0].status, "completed");
  assert.deepEqual(
    page.data[0].items.map((item) => [item.type, item.role, item.text || item.content?.[0]?.text]),
    [
      ["user_message", "user", "please fix this"],
      ["message", "assistant", "fixed"],
    ]
  );
});

test("readThreadTurnsListPageFromSessionJsonl caps fallback pages to five turns", () => {
  const filePath = "/tmp/thread-cap.jsonl";
  const lines = [
    {
      timestamp: "2026-05-05T23:31:11.000Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-cap",
      },
    },
    ...Array.from({ length: 8 }, (_, index) => ({
      timestamp: `2026-05-05T23:31:${12 + index}.000Z`,
      type: "response_item",
      payload: {
        id: `assistant-${index + 1}`,
        type: "message",
        role: "assistant",
        turn_id: `turn-${index + 1}`,
        content: [{ type: "output_text", text: `reply ${index + 1}` }],
      },
    })),
  ];

  const page = readThreadTurnsListPageFromSessionJsonl(filePath, {
    threadId: "thread-jsonl-cap",
    limit: 20,
    fsModule: {
      readFileSync: (readPath) => {
        assert.equal(readPath, filePath);
        return lines.map((line) => JSON.stringify(line)).join("\n");
      },
    },
  });

  assert.equal(page.data.length, 5);
  assert.deepEqual(
    page.data.map((turn) => turn.id),
    ["turn-8", "turn-7", "turn-6", "turn-5", "turn-4"]
  );
  assert.equal(page.nextCursor, "remodex-jsonl-fallback-older-unavailable");
});

test("readThreadTurnsListPageFromSessionJsonl honors a stricter caller max limit", () => {
  const filePath = "/tmp/thread-strict-cap.jsonl";
  const lines = [
    {
      timestamp: "2026-05-05T23:31:11.000Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-strict-cap",
      },
    },
    ...Array.from({ length: 3 }, (_, index) => ({
      timestamp: `2026-05-05T23:31:${12 + index}.000Z`,
      type: "response_item",
      payload: {
        id: `assistant-${index + 1}`,
        type: "message",
        role: "assistant",
        turn_id: `turn-${index + 1}`,
        content: [{ type: "output_text", text: `reply ${index + 1}` }],
      },
    })),
  ];

  const page = readThreadTurnsListPageFromSessionJsonl(filePath, {
    threadId: "thread-jsonl-strict-cap",
    limit: 20,
    maxLimit: 1,
    fsModule: {
      readFileSync: () => lines.map((line) => JSON.stringify(line)).join("\n"),
    },
  });

  assert.equal(page.data.length, 1);
  assert.equal(page.data[0].id, "turn-3");
  assert.equal(page.nextCursor, "remodex-jsonl-fallback-older-unavailable");
});

test("readThreadTurnsListPageFromSessionJsonl skips cursor requests", () => {
  const page = readThreadTurnsListPageFromSessionJsonl("/tmp/session.jsonl", {
    threadId: "thread-jsonl",
    limit: 5,
    cursor: "older",
    fsModule: {
      readFileSync: () => {
        throw new Error("should not read file for cursor pages");
      },
    },
  });

  assert.equal(page, null);
});
