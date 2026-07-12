// FILE: desktop-ipc-conversation-projector.test.js
// Purpose: Unit tests for projecting Desktop conversationState into mobile app-server notifications.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, ../src/desktop-ipc-conversation-projector

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createDesktopConversationProjector,
  projectDesktopConversationStateToThread,
} = require("../src/desktop-ipc-conversation-projector");

test("desktop conversation projector bootstraps active Desktop turns for mobile", () => {
  const projector = createDesktopConversationProjector({ now: () => 1_710_000_000_000 });
  const output = projector.project("thread-projector", {
    title: "Desktop work",
    cwd: "/repo",
    turns: [{
      turnId: "turn-projector",
      status: "inProgress",
      params: {
        input: [{ type: "text", text: "build the thing" }],
      },
      items: [
        { id: "reason-projector", type: "reasoning", summary: ["Thinking"], content: ["Checking files"] },
        { id: "assistant-projector", type: "agentMessage", text: "Working" },
      ],
    }],
  });

  assert.equal(output.type, "events");
  assert.deepEqual(
    output.notifications.map((notification) => notification.method),
    [
      "thread/started",
      "turn/started",
      "item/started",
      "item/completed",
      "item/started",
      "item/completed",
      "item/started",
      "item/completed",
    ]
  );
  assert.equal(output.notifications[0].params.thread.title, "Desktop work");
  assert.equal(output.notifications[1].params.turnId, "turn-projector");
  assert.equal(output.notifications[1].params.remodexDesktopMirror, true);
  assert.equal(output.notifications[1].params.remodexDesktopIpcMirror, true);
});

test("desktop conversation projector exposes committed per-thread runtime settings", () => {
  const thread = projectDesktopConversationStateToThread("thread-runtime", {
    title: "Runtime settings",
    remodexRuntimeSettings: {
      model: "gpt-5.6",
      reasoningEffort: "xhigh",
      serviceTier: "fast",
      revision: 4,
      updatedAt: 1234,
      source: "phone",
    },
    turns: [],
  });

  assert.equal(thread.model, "gpt-5.6");
  assert.equal(thread.reasoningEffort, "xhigh");
  assert.equal(thread.serviceTier, "fast");
  assert.equal(thread.runtimeSettingsRevision, 4);
  assert.equal(thread.runtimeSettingsUpdatedAt, 1234);
  assert.equal(thread.runtimeSettingsSource, "phone");
});

test("desktop conversation projector pushes newer runtime settings to an already-open phone thread", () => {
  const projector = createDesktopConversationProjector();
  projector.project("thread-runtime-live", {
    title: "Runtime live",
    remodexRuntimeSettings: {
      model: "gpt-5.5",
      reasoningEffort: "medium",
      serviceTier: null,
      revision: 1,
    },
    turns: [],
  });
  const output = projector.project("thread-runtime-live", {
    title: "Runtime live",
    remodexRuntimeSettings: {
      model: "gpt-5.6",
      reasoningEffort: "high",
      serviceTier: "fast",
      revision: 2,
    },
    turns: [],
  });

  const runtimeUpdate = output.notifications.find((notification) => notification.method === "thread/started");
  assert.equal(runtimeUpdate.params.thread.model, "gpt-5.6");
  assert.equal(runtimeUpdate.params.thread.reasoningEffort, "high");
  assert.equal(runtimeUpdate.params.thread.serviceTier, "fast");
  assert.equal(runtimeUpdate.params.thread.runtimeSettingsRevision, 2);
});

test("desktop conversation projector reports identity continuity only for the same logical turn", () => {
  const sameTurnProjector = createDesktopConversationProjector();
  sameTurnProjector.project("thread-same-repair", {
    turns: [{
      status: "inProgress",
      params: { input: [{ type: "text", text: "Keep fixing mirroring" }] },
      items: [{ id: "stable-assistant", type: "agentMessage", text: "Working" }],
    }],
  });
  const sameTurnRepair = sameTurnProjector.project("thread-same-repair", {
    turns: [{
      turnId: "turn-real-a",
      status: "inProgress",
      params: { input: [{ type: "text", text: "Keep fixing mirroring" }] },
      items: [{ id: "stable-assistant", type: "agentMessage", text: "Working" }],
    }],
  });
  assert.equal(sameTurnRepair.type, "fullReplace");
  assert.deepEqual(sameTurnRepair.turnIdentityContinuityTurnIds, ["turn-real-a"]);

  const nextTurnProjector = createDesktopConversationProjector();
  nextTurnProjector.project("thread-different-repair", {
    turns: [{
      status: "inProgress",
      params: { input: [{ type: "text", text: "Turn A prompt" }] },
      items: [{ id: "assistant-a", type: "agentMessage", text: "A output" }],
    }],
  });
  const differentTurn = nextTurnProjector.project("thread-different-repair", {
    turns: [{
      turnId: "turn-real-b",
      status: "inProgress",
      params: { input: [{ type: "text", text: "Turn B prompt" }] },
      items: [{ id: "assistant-b", type: "agentMessage", text: "B output" }],
    }],
  });
  assert.equal(differentTurn.type, "fullReplace");
  assert.deepEqual(differentTurn.turnIdentityContinuityTurnIds, []);

  const repeatedPromptProjector = createDesktopConversationProjector();
  repeatedPromptProjector.project("thread-repeated-prompt", {
    turns: [{
      status: "inProgress",
      params: { input: [{ type: "text", text: "continue" }] },
      items: [{ id: "assistant-repeat-a", type: "agentMessage", text: "A output" }],
    }],
  });
  const repeatedPromptNewTurn = repeatedPromptProjector.project("thread-repeated-prompt", {
    turns: [{
      turnId: "turn-repeat-b",
      status: "inProgress",
      params: { input: [{ type: "text", text: "continue" }] },
      items: [{ id: "assistant-repeat-b", type: "agentMessage", text: "B output" }],
    }],
  });
  assert.deepEqual(repeatedPromptNewTurn.turnIdentityContinuityTurnIds, []);

  const parallelProjector = createDesktopConversationProjector();
  parallelProjector.project("thread-one-to-one-continuity", {
    turns: [{
      status: "inProgress",
      startedAt: 123,
      params: { input: [{ type: "text", text: "same signature" }] },
      items: [],
    }],
  });
  const parallelReplacement = parallelProjector.project("thread-one-to-one-continuity", {
    turns: [
      {
        turnId: "turn-real-first",
        status: "inProgress",
        startedAt: 123,
        params: { input: [{ type: "text", text: "same signature" }] },
        items: [],
      },
      {
        turnId: "turn-real-second",
        status: "inProgress",
        startedAt: 123,
        params: { input: [{ type: "text", text: "same signature" }] },
        items: [],
      },
    ],
  });
  assert.equal(parallelReplacement.type, "fullReplace");
  assert.deepEqual(
    parallelReplacement.turnIdentityContinuityTurnIds,
    ["turn-real-first"],
    "one synthetic alias cannot suppress two canonical run starts"
  );

  const partialRepairProjector = createDesktopConversationProjector();
  partialRepairProjector.project("thread-partial-repair", {
    turns: [
      {
        status: "inProgress",
        items: [{ id: "assistant-partial-a", type: "agentMessage", text: "A" }],
      },
      {
        status: "inProgress",
        items: [{ id: "assistant-partial-c", type: "agentMessage", text: "C" }],
      },
    ],
  });
  const partialRepair = partialRepairProjector.project("thread-partial-repair", {
    turns: [
      {
        turnId: "turn-real-partial-a",
        status: "inProgress",
        items: [{ id: "assistant-partial-a", type: "agentMessage", text: "A" }],
      },
      {
        status: "inProgress",
        items: [{ id: "assistant-partial-c", type: "agentMessage", text: "C" }],
      },
    ],
  });
  assert.equal(partialRepair.type, "fullReplace");
  assert.deepEqual(
    partialRepair.notifications
      .filter((notification) => notification.method === "turn/started")
      .map((notification) => notification.params.turnId),
    ["turn-real-partial-a", "ipc-turn-1"]
  );
  assert.deepEqual(
    new Set(partialRepair.turnIdentityContinuityTurnIds),
    new Set(["turn-real-partial-a", "ipc-turn-1"])
  );
});

test("desktop conversation projector emits plan reasoning and command deltas", () => {
  const projector = createDesktopConversationProjector();
  projector.project("thread-deltas", {
    turns: [{
      turnId: "turn-deltas",
      status: "inProgress",
      items: [
        { id: "plan-deltas", type: "plan", text: "Step 1" },
        { id: "reason-deltas", type: "reasoning", summary: ["Think"], content: ["Read"] },
        {
          id: "command-deltas",
          type: "commandExecution",
          status: "inProgress",
          command: "npm test",
          cwd: "/repo",
          aggregatedOutput: "line 1\n",
        },
      ],
    }],
  });

  const output = projector.project("thread-deltas", {
    turns: [{
      turnId: "turn-deltas",
      status: "inProgress",
      items: [
        { id: "plan-deltas", type: "plan", text: "Step 1\nStep 2" },
        { id: "reason-deltas", type: "reasoning", summary: ["Thinking"], content: ["Reading"] },
        {
          id: "command-deltas",
          type: "commandExecution",
          status: "inProgress",
          command: "npm test",
          cwd: "/repo",
          aggregatedOutput: "line 1\nline 2\n",
        },
      ],
    }],
  });

  assert.deepEqual(
    output.notifications.map((notification) => [notification.method, notification.params.delta]),
    [
      ["item/plan/delta", "\nStep 2"],
      ["item/reasoning/summaryTextDelta", "ing"],
      ["item/reasoning/textDelta", "ing"],
      ["item/commandExecution/outputDelta", "line 2\n"],
    ]
  );
});

test("desktop conversation projector marks Litter todo-list items as progress plans", () => {
  const rawPlan = {
    id: "dae353b0-litter-plan",
    type: "todo-list",
    status: "completed",
    explanation: "All review fixes are complete.",
    plan: [
      { step: "Fix history", status: "completed" },
      { step: "Verify mirroring", status: "completed" },
    ],
  };
  const state = {
    turns: [{
      turnId: "turn-litter-plan",
      status: "inProgress",
      items: [rawPlan],
    }],
  };

  const thread = projectDesktopConversationStateToThread("thread-litter-plan", state);
  assert.equal(thread.turns[0].items[0].remodexProgressPlan, true);

  const output = createDesktopConversationProjector().project("thread-litter-plan", state);
  const lifecycleItems = output.notifications
    .filter((notification) => notification.method === "item/started"
      || notification.method === "item/completed")
    .map((notification) => notification.params.item);
  assert.equal(lifecycleItems.length, 2);
  assert.equal(lifecycleItems.every((item) => item.remodexProgressPlan === true), true);
});

test("desktop conversation projector normalizes Desktop tool aliases for mobile lifecycle", () => {
  const projector = createDesktopConversationProjector();
  const output = projector.project("thread-tool-aliases", {
    turns: [{
      turnId: "turn-tool-aliases",
      status: "inProgress",
      items: [
        {
          id: "mcp-tool-alias",
          type: "mcpToolCall",
          status: "completed",
          server: "search",
          tool: "query",
          result: { content: [{ type: "text", text: "found it" }] },
        },
        {
          id: "dynamic-tool-alias",
          type: "dynamicToolCall",
          status: "running",
          namespace: "workspace",
          tool: "Read",
          contentItems: [{ type: "text", text: "file contents" }],
        },
        {
          id: "web-search-alias",
          type: "webSearch",
          status: "completed",
          query: "docs",
          output: "opened docs",
        },
      ],
    }],
  });

  const startedItems = output.notifications
    .filter((notification) => notification.method === "item/started")
    .map((notification) => notification.params.item);
  assert.deepEqual(
    startedItems.map((item) => item.type),
    ["toolCall", "toolCall", "toolCall"]
  );
  assert.deepEqual(
    startedItems.map((item) => item.remodexDesktopIpcItemType),
    ["mcpToolCall", "dynamicToolCall", "webSearch"]
  );

  // Only finished tools close at bootstrap; the running one keeps streaming.
  const completedItems = output.notifications
    .filter((notification) => notification.method === "item/completed")
    .map((notification) => notification.params.item);
  assert.deepEqual(
    completedItems.map((item) => item.id),
    ["mcp-tool-alias", "web-search-alias"]
  );
});

test("desktop conversation projector emits generic tool output deltas from Desktop aliases", () => {
  const projector = createDesktopConversationProjector();
  projector.project("thread-tool-delta", {
    turns: [{
      turnId: "turn-tool-delta",
      status: "inProgress",
      items: [{
        id: "dynamic-tool-delta",
        type: "dynamicToolCall",
        status: "running",
        tool: "Read",
        contentItems: [{ type: "text", text: "line 1\n" }],
      }],
    }],
  });

  const output = projector.project("thread-tool-delta", {
    turns: [{
      turnId: "turn-tool-delta",
      status: "inProgress",
      items: [{
        id: "dynamic-tool-delta",
        type: "dynamicToolCall",
        status: "running",
        tool: "Read",
        contentItems: [{ type: "text", text: "line 1\nline 2\n" }],
      }],
    }],
  });

  assert.deepEqual(
    output.notifications.map((notification) => [notification.method, notification.params.delta]),
    [["item/toolCall/outputDelta", "line 2\n"]]
  );
  assert.equal(output.notifications[0].params.item.type, "toolCall");
  assert.equal(output.notifications[0].params.item.remodexDesktopIpcItemType, "dynamicToolCall");
});

test("desktop conversation projector mirrors thread metadata changes", () => {
  const projector = createDesktopConversationProjector();
  projector.project("thread-meta", {
    title: "Old title",
    turns: [{ turnId: "turn-meta", status: "completed", items: [] }],
  });

  const output = projector.project("thread-meta", {
    title: "New title",
    threadRuntimeStatus: { type: "active", activeFlags: [] },
    turns: [{ turnId: "turn-meta", status: "completed", items: [] }],
  });

  assert.deepEqual(
    output.notifications.map((notification) => notification.method),
    ["thread/name/updated", "thread/status/changed"]
  );
  assert.equal(output.notifications[0].params.title, "New title");
  assert.deepEqual(output.notifications[1].params.status, { type: "active", activeFlags: [] });
});

test("desktop conversation projector hides injected context from user bubbles", () => {
  const projector = createDesktopConversationProjector();
  const output = projector.project("thread-context", {
    turns: [{
      turnId: "turn-context",
      status: "inProgress",
      params: {
        input: [
          {
            type: "text",
            text: "# AGENTS.md instructions for /Users/me/proj\n<INSTRUCTIONS>## Skills\n- stuff\n</INSTRUCTIONS>",
          },
          {
            type: "text",
            text: "IDE context preamble\n\n## My request for Codex:\nfix the bug",
          },
        ],
      },
      items: [],
    }],
  });

  const userStarts = output.notifications.filter((notification) => (
    notification.method === "item/started"
    && notification.params.item.type === "userMessage"
  ));
  assert.equal(userStarts.length, 1);
  assert.deepEqual(userStarts[0].params.item.content, [
    { type: "text", text: "fix the bug" },
  ]);
});

test("desktop conversation projector skips userMessage items that only carry context", () => {
  const projector = createDesktopConversationProjector();
  const output = projector.project("thread-context-item", {
    turns: [{
      turnId: "turn-context-item",
      status: "inProgress",
      items: [
        {
          id: "context-only",
          type: "userMessage",
          content: [{
            type: "text",
            text: "# AGENTS.md instructions for /Users/me/proj\n<INSTRUCTIONS>rules</INSTRUCTIONS>",
          }],
        },
        { id: "assistant-1", type: "agentMessage", text: "on it" },
      ],
    }],
  });

  const startedItemIds = output.notifications
    .filter((notification) => notification.method === "item/started")
    .map((notification) => notification.params.itemId);
  assert.deepEqual(startedItemIds, ["assistant-1"]);
});

test("desktop conversation projector hides native goal continuation context", () => {
  const projector = createDesktopConversationProjector();
  const output = projector.project("thread-goal-context", {
    turns: [{
      turnId: "turn-goal-context",
      status: "inProgress",
      params: {
        input: [{
          type: "text",
          text: "<codex_internal_context source=\"goal\">\nContinue working toward the active thread goal.\n</codex_internal_context>",
        }],
      },
      items: [{ id: "assistant-goal", type: "agentMessage", text: "Continuing" }],
    }],
  });
  assert.equal(JSON.stringify(output.notifications).includes("codex_internal_context"), false);
  assert.deepEqual(
    output.notifications.filter((entry) => entry.method === "item/started").map((entry) => entry.params.itemId),
    ["assistant-goal"]
  );
});

test("desktop conversation projector mirrors token usage updates", () => {
  const projector = createDesktopConversationProjector();
  projector.project("thread-usage", {
    turns: [{ turnId: "turn-usage", status: "completed", items: [] }],
  });

  const output = projector.project("thread-usage", {
    latestTokenUsageInfo: {
      totalTokens: 1200,
      contextWindow: 200000,
    },
    turns: [{ turnId: "turn-usage", status: "completed", items: [] }],
  });

  assert.deepEqual(
    output.notifications.map((notification) => notification.method),
    ["thread/tokenUsage/updated"]
  );
  assert.deepEqual(output.notifications[0].params.usage, {
    totalTokens: 1200,
    contextWindow: 200000,
  });
  assert.equal(output.notifications[0].params.threadId, "thread-usage");
  assert.equal(output.notifications[0].params.remodexDesktopMirror, true);
});

test("desktop conversation projector keeps running items open until they finish", () => {
  const projector = createDesktopConversationProjector();
  const bootstrap = projector.project("thread-running-item", {
    turns: [{
      turnId: "turn-running-item",
      status: "inProgress",
      items: [{
        id: "command-running",
        type: "commandExecution",
        status: "inProgress",
        command: "npm test",
        aggregatedOutput: "",
      }],
    }],
  });
  assert.deepEqual(
    bootstrap.notifications.map((notification) => notification.method),
    ["thread/started", "turn/started", "item/started"]
  );

  const completed = projector.project("thread-running-item", {
    turns: [{
      turnId: "turn-running-item",
      status: "inProgress",
      items: [{
        id: "command-running",
        type: "commandExecution",
        status: "completed",
        command: "npm test",
        aggregatedOutput: "ok\n",
      }],
    }],
  });
  assert.deepEqual(
    completed.notifications.map((notification) => notification.method),
    ["item/completed"]
  );
  assert.equal(completed.notifications[0].params.item.status, "completed");
});

test("desktop conversation projector reseeds evicted threads without replaying history", () => {
  const projector = createDesktopConversationProjector({ maxCacheSize: 1 });
  const snapshot = (threadId) => ({
    turns: [{
      turnId: `turn-${threadId}`,
      status: "inProgress",
      items: [{ id: `assistant-${threadId}`, type: "agentMessage", text: "hello" }],
    }],
  });

  projector.project("thread-evict-a", snapshot("thread-evict-a"));
  // Filling the cache with a second thread evicts the first.
  projector.project("thread-evict-b", snapshot("thread-evict-b"));

  const reseeded = projector.project("thread-evict-a", snapshot("thread-evict-a"));
  assert.equal(reseeded.type, "baseline");
  assert.deepEqual(reseeded.notifications, []);

  // After the silent reseed, new activity flows again as ordinary diffs.
  const followUp = projector.project("thread-evict-a", {
    turns: [{
      turnId: "turn-thread-evict-a",
      status: "inProgress",
      items: [{ id: "assistant-thread-evict-a", type: "agentMessage", text: "hello world" }],
    }],
  });
  assert.deepEqual(
    followUp.notifications.map((notification) => notification.method),
    ["item/agentMessage/delta"]
  );
  assert.equal(followUp.notifications[0].params.delta, " world");
});

test("desktop conversation projector bootstraps fresh after explicit removal", () => {
  const projector = createDesktopConversationProjector({ maxCacheSize: 1 });
  const snapshot = {
    turns: [{
      turnId: "turn-remove",
      status: "inProgress",
      items: [{ id: "assistant-remove", type: "agentMessage", text: "hello" }],
    }],
  };

  projector.project("thread-remove", snapshot);
  projector.remove("thread-remove");

  const rebootstrapped = projector.project("thread-remove", snapshot);
  assert.equal(rebootstrapped.type, "events");
  assert.deepEqual(
    rebootstrapped.notifications.map((notification) => notification.method),
    ["thread/started", "turn/started", "item/started", "item/completed"]
  );
});

test("projects Desktop conversation state into thread/read backfill shape", () => {
  const thread = projectDesktopConversationStateToThread("thread-read-backfill", {
    title: "Backfill",
    cwd: "/repo",
    turns: [{
      turnId: "turn-read-backfill",
      status: "completed",
      params: {
        input: [{ type: "text", text: "hello" }],
      },
      items: [
        { id: "assistant-read-backfill", type: "agentMessage", text: "world" },
        {
          id: "mcp-read-backfill",
          type: "mcpToolCall",
          status: "completed",
          tool: "query",
          result: { content: [{ type: "text", text: "found it" }] },
        },
        {
          id: "dynamic-read-backfill",
          type: "dynamicToolCall",
          status: "completed",
          tool: "Read",
          contentItems: [{ type: "text", text: "file contents" }],
        },
      ],
    }],
  });

  assert.equal(thread.id, "thread-read-backfill");
  assert.equal(thread.name, "Backfill");
  assert.equal(thread.turns[0].id, "turn-read-backfill");
  assert.deepEqual(
    thread.turns[0].items.map((item) => item.type),
    ["userMessage", "agentMessage", "toolCall", "toolCall"]
  );
  assert.deepEqual(
    thread.turns[0].items.slice(2).map((item) => item.remodexDesktopIpcItemType),
    ["mcpToolCall", "dynamicToolCall"]
  );
});

test("desktop conversation projector live-syncs goal metadata without transcript rows", () => {
  const projector = createDesktopConversationProjector();
  const baseGoal = {
    threadId: "thread-goal",
    objective: "Ship live goal sync",
    status: "active",
    tokenBudget: null,
    tokensUsed: 10,
    timeUsedSeconds: 2,
    createdAt: 1,
    updatedAt: 2,
  };
  const bootstrap = projector.project("thread-goal", { threadGoal: baseGoal, turns: [] });
  assert.deepEqual(bootstrap.notifications.map((entry) => entry.method), ["thread/goal/updated"]);
  assert.deepEqual(bootstrap.notifications[0].params.goal, baseGoal);
  assert.equal(bootstrap.notifications[0].params.turnId, null);

  const progress = projector.project("thread-goal", {
    threadGoal: { ...baseGoal, tokensUsed: 20, updatedAt: 3 },
    turns: [],
  });
  assert.deepEqual(progress.notifications.map((entry) => entry.method), ["thread/goal/updated"]);
  assert.equal(progress.notifications[0].params.goal.tokensUsed, 20);

  const completed = projector.project("thread-goal", {
    threadGoal: null,
    completedThreadGoal: { ...baseGoal, status: "complete", updatedAt: 4 },
    turns: [],
  });
  assert.deepEqual(completed.notifications.map((entry) => entry.method), ["thread/goal/updated"]);
  assert.equal(completed.notifications[0].params.goal.status, "complete");

  const cleared = projector.project("thread-goal", {
    threadGoal: null,
    completedThreadGoal: null,
    turns: [],
  });
  assert.deepEqual(cleared.notifications.map((entry) => entry.method), ["thread/goal/cleared"]);
  assert.equal(cleared.notifications[0].params.threadId, "thread-goal");
});
