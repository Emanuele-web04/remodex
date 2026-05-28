// FILE: session-jsonl-history.test.js
// Purpose: Verifies local Codex JSONL history fallback pages for empty app-server turn lists.

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  parseSessionJsonlMetadata,
  parseSessionJsonlTurns,
  readThreadTurnsListPageFromSessionJsonl,
} = require("../src/session-jsonl-history");

test("parseSessionJsonlMetadata reads desktop thread cwd", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-05T23:31:11.000Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-meta",
        cwd: "/Users/test/Project",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:12.000Z",
      type: "response_item",
      payload: {
        id: "assistant-final",
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "done" }],
      },
    }),
  ].join("\n");

  assert.deepEqual(parseSessionJsonlMetadata(content), {
    threadId: "thread-jsonl-meta",
    cwd: "/Users/test/Project",
  });
});

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

test("parseSessionJsonlTurns attaches pre-task user messages to following task", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-05T23:31:11.000Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-prelude",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:12.000Z",
      type: "event_msg",
      payload: {
        type: "user_message",
        message: "from mac",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-05T23:31:13.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-jsonl-prelude",
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-jsonl-prelude" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].id, "turn-jsonl-prelude");
  assert.equal(turns[0].items[0].type, "user_message");
  assert.equal(turns[0].items[0].text, "from mac");
});

test("parseSessionJsonlTurns deduplicates mirrored mobile user messages", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-24T19:30:07.522Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-mobile",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T19:30:10.900Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-jsonl-mobile",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T19:30:10.911Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "review these changes" }],
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T19:30:10.915Z",
      type: "event_msg",
      payload: {
        type: "user_message",
        message: "review these changes",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T19:30:12.000Z",
      type: "response_item",
      payload: {
        id: "assistant-final",
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "done" }],
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-jsonl-mobile" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].id, "turn-jsonl-mobile");
  const userItems = turns[0].items.filter((item) => item.role === "user");
  assert.equal(userItems.length, 1);
  assert.equal(userItems[0].type, "user_message");
  assert.equal(userItems[0].text, "review these changes");
  assert.equal(userItems[0].createdAt, "2026-05-24T19:30:10.915Z");
  assert.equal(userItems[0].timestamp, "2026-05-24T19:30:10.915Z");
});

test("parseSessionJsonlTurns deduplicates raw skill text against structured skill input", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-24T21:52:47.000Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-skill",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T21:52:51.100Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-jsonl-skill",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T21:52:51.133Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [
          { type: "input_text", text: "one last time" },
          { type: "skill", id: "check-code", name: "check-code" },
        ],
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T21:52:51.133Z",
      type: "event_msg",
      payload: {
        type: "user_message",
        message: "$check-code one last time",
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-jsonl-skill" });
  const userItems = turns[0].items.filter((item) => item.role === "user");

  assert.equal(userItems.length, 1);
  assert.equal(userItems[0].type, "message");
  assert.equal(userItems[0].content[0].text, "one last time");
  assert.deepEqual(userItems[0].content[1], { type: "skill", id: "check-code", name: "check-code" });
  assert.equal(userItems[0].createdAt, "2026-05-24T21:52:51.133Z");
});

test("parseSessionJsonlTurns preserves explicit timestamp aliases over entry timestamp", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-24T21:52:51.900Z",
      type: "session_meta",
      payload: {
        id: "thread-jsonl-timestamps",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T21:52:52.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-jsonl-timestamps",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-24T21:52:53.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        created_at: "2026-05-24T21:52:51.133Z",
        content: [{ type: "input_text", text: "timed prompt" }],
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-jsonl-timestamps" });
  const userItems = turns[0].items.filter((item) => item.role === "user");

  assert.equal(userItems.length, 1);
  assert.equal(userItems[0].createdAt, "2026-05-24T21:52:51.133Z");
  assert.equal(userItems[0].timestamp, "2026-05-24T21:52:51.133Z");
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

test("parseSessionJsonlTurns restores desktop custom apply_patch as fileChange", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: Sources/App.swift",
    "@@",
    "-let title = \"Old\"",
    "+let title = \"New\"",
    "*** End Patch",
    "",
  ].join("\n");
  const content = [
    JSON.stringify({
      timestamp: "2026-05-15T07:53:52.418Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-patch",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:53.000Z",
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        status: "completed",
        name: "apply_patch",
        call_id: "call-patch",
        input: patch,
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-patch" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].items.length, 1);
  assert.equal(turns[0].items[0].type, "fileChange");
  assert.equal(turns[0].items[0].id, "call-patch");
  assert.deepEqual(turns[0].items[0].changes.map((change) => ({
    path: change.path,
    kind: change.kind,
    additions: change.additions,
    deletions: change.deletions,
  })), [{
    path: "Sources/App.swift",
    kind: "update",
    additions: 1,
    deletions: 1,
  }]);
});

test("parseSessionJsonlTurns restores update_plan calls as progress plan items", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-15T07:53:52.418Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-plan",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:53.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        name: "update_plan",
        call_id: "call-plan",
        arguments: JSON.stringify({
          explanation: "Break the work into safe slices.",
          plan: [
            { step: "Inspect plan rendering", status: "completed" },
            { step: "Keep it visible", status: "in_progress" },
          ],
        }),
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-plan" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].items.length, 1);
  assert.equal(turns[0].items[0].type, "plan");
  assert.equal(turns[0].items[0].id, "call-plan");
  assert.equal(turns[0].items[0].explanation, "Break the work into safe slices.");
  assert.deepEqual(turns[0].items[0].plan, [
    { step: "Inspect plan rendering", status: "completed" },
    { step: "Keep it visible", status: "in_progress" },
  ]);
});

test("parseSessionJsonlTurns enriches exec_command function calls for readable history", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-22T14:51:03.000Z",
      type: "session_meta",
      payload: {
        id: "thread-command",
        cwd: "/Users/test/Project",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-22T14:51:04.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-command",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-22T14:51:05.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        name: "exec_command",
        call_id: "call-command",
        arguments: JSON.stringify({
          cmd: "git status --short --branch",
          workdir: "/Users/test/Project",
          yield_time_ms: 1000,
        }),
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-command" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].items.length, 1);
  assert.equal(turns[0].items[0].type, "commandExecution");
  assert.equal(turns[0].items[0].id, "call-command");
  assert.equal(turns[0].items[0].command, "git status --short --branch");
  assert.equal(turns[0].items[0].cwd, "/Users/test/Project");
  assert.equal(turns[0].items[0].status, "completed");
});

test("parseSessionJsonlTurns adds readable messages for generic tool calls", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-22T14:51:03.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-tools",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-22T14:51:04.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        name: "write_stdin",
        call_id: "call-stdin",
        arguments: JSON.stringify({
          session_id: 42,
          chars: "y\n",
        }),
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-22T14:51:05.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        name: "view_image",
        call_id: "call-image",
        arguments: JSON.stringify({
          path: "/Users/test/Project/tmp/screenshots/detail.png",
        }),
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-tools" });

  assert.equal(turns.length, 1);
  assert.deepEqual(turns[0].items.map((item) => ({
    id: item.id,
    type: item.type,
    message: item.message,
    toolName: item.tool_name,
  })), [
    {
      id: "call-stdin",
      type: "tool_call",
      message: "Write to terminal",
      toolName: "write_stdin",
    },
    {
      id: "call-image",
      type: "tool_call",
      message: "Open image …/screenshots/detail.png",
      toolName: "view_image",
    },
  ]);
});

test("parseSessionJsonlTurns restores view_image tool output as imageView without inline data", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-22T14:52:03.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-view-image",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-22T14:52:04.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        name: "view_image",
        call_id: "call-view-image",
        arguments: JSON.stringify({
          path: "/Users/test/Library/Application Support/CleanShot/media/screenshot.png",
        }),
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-22T14:52:05.000Z",
      type: "response_item",
      payload: {
        type: "function_call_output",
        call_id: "call-view-image",
        output: [
          {
            type: "input_image",
            image_url: "data:image/png;base64,AAAA",
          },
        ],
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-view-image" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].items.length, 2);
  assert.deepEqual(turns[0].items.map((item) => item.type), ["tool_call", "imageView"]);
  assert.equal(turns[0].items[1].id, "call-view-image-image-view");
  assert.equal(
    turns[0].items[1].path,
    "/Users/test/Library/Application Support/CleanShot/media/screenshot.png"
  );
  assert.equal(Object.hasOwn(turns[0].items[1], "output"), false);
  assert.equal(turns[0].items[1].remodexJsonlToolOutputImage, true);
});

test("parseSessionJsonlTurns restores completed desktop Plan items without duplicating proposed_plan messages", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-20T14:37:30.000Z",
      type: "session_meta",
      payload: {
        id: "thread-completed-plan",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-20T14:37:31.000Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-completed-plan",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-20T14:37:40.000Z",
      type: "event_msg",
      payload: {
        type: "item_completed",
        turn_id: "turn-completed-plan",
        item: {
          type: "Plan",
          id: "turn-completed-plan-plan",
          text: "# Improve Dashboard\n\n- Tighten validation",
        },
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-20T14:37:40.010Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: [{
          type: "output_text",
          text: "<proposed_plan>\n# Improve Dashboard\n\n- Tighten validation\n</proposed_plan>",
        }],
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-20T14:37:41.000Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: "turn-completed-plan",
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-completed-plan" });

  assert.equal(turns.length, 1);
  assert.equal(turns[0].status, "completed");
  assert.equal(turns[0].items.length, 1);
  assert.equal(turns[0].items[0].type, "plan");
  assert.equal(turns[0].items[0].id, "turn-completed-plan-plan");
  assert.equal(turns[0].items[0].text, "# Improve Dashboard\n\n- Tighten validation");
});

test("parseSessionJsonlTurns hides subagent orchestration transcript internals", () => {
  const content = [
    JSON.stringify({
      timestamp: "2026-05-15T07:53:52.418Z",
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: "turn-subagents",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:53.000Z",
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: "turn-subagents",
        message: "Compare these codebases",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:54.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        name: "spawn_agent",
        call_id: "call-spawn",
        arguments: "{}",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:55.000Z",
      type: "response_item",
      payload: {
        type: "function_call_output",
        call_id: "call-spawn",
        output: "agent id",
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:56.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{
          type: "input_text",
          text: "<subagent_notification>\n{\"status\":{\"completed\":\"done\"}}",
        }],
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:57.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "Final synthesis" }],
      },
    }),
    JSON.stringify({
      timestamp: "2026-05-15T07:53:58.000Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: "turn-subagents",
      },
    }),
  ].join("\n");

  const turns = parseSessionJsonlTurns(content, { threadId: "thread-subagents" });

  assert.equal(turns.length, 1);
  assert.deepEqual(
    turns[0].items.map((item) => [item.type, item.role, item.name, item.text || item.content?.[0]?.text]),
    [
      ["user_message", "user", undefined, "Compare these codebases"],
      ["message", "assistant", undefined, "Final synthesis"],
    ]
  );
});
