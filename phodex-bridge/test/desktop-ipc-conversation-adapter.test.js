// FILE: desktop-ipc-conversation-adapter.test.js
// Purpose: Unit tests for the app-server to Desktop conversationState adapter and patch engine.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, ../src/desktop-ipc-conversation-adapter, ../src/desktop-ipc-state-patches

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  applyAppServerMessageToConversationState,
  buildConversationStateFromThread,
  synchronizeDesktopConversationCompatibility,
} = require("../src/desktop-ipc-conversation-adapter");
const {
  buildConversationStatePatches,
} = require("../src/desktop-ipc-state-patches");

test("conversation adapter publishes current Desktop canonical history with iterable phone settings", () => {
  const state = buildConversationStateFromThread({
    id: "thread-phone-desktop",
    cwd: "/Users/me/project",
    modelProvider: "openai",
    turns: [{
      id: "turn-phone-desktop",
      status: "inProgress",
      startedAt: 5,
      items: [{ id: "assistant", type: "agentMessage", text: "working" }],
    }],
  }, {
    previous: {
      turns: [{
        id: "turn-phone-desktop",
        turnId: "turn-phone-desktop",
        params: {
          threadId: "thread-phone-desktop",
          cwd: "/Users/me/project",
          input: [{ type: "image", url: "data:image/jpeg;base64,abc" }],
          approvalPolicy: "on-request",
          approvalsReviewer: "auto_review",
          sandboxPolicy: {
            type: "workspaceWrite",
            networkAccess: true,
          },
        },
        items: [],
      }],
    },
    now: () => 9_000,
  });

  synchronizeDesktopConversationCompatibility(state);

  assert.deepEqual(state.turns[0].params.attachments, []);
  assert.deepEqual(state.turns[0].params.sandboxPolicy, {
    type: "workspaceWrite",
    networkAccess: true,
    writableRoots: [],
    excludeSlashTmp: false,
    excludeTmpdirEnvVar: false,
  });
  assert.equal(state.turnHistory.kind, "canonical");
  assert.deepEqual(state.turnHistory.history.islands[0].entries, [{
    key: "turn:turn-phone-desktop",
    value: "turn:turn-phone-desktop",
  }]);
  assert.equal(
    state.turnHistory.history.entitiesByKey["turn:turn-phone-desktop"].turnId,
    "turn-phone-desktop"
  );
  assert.equal(state.turnHistory.history.isComplete, true);
  assert.deepEqual(state.currentPermissions.runtimeWorkspaceRoots, []);
  assert.deepEqual(state.currentPermissions.sandboxPolicy.writableRoots, []);
});

test("conversation adapter mirrors goal updates and clears as metadata", () => {
  const conversations = new Map();
  const apply = (message) => applyAppServerMessageToConversationState({
    conversations,
    message,
    shouldOwnThread: (threadId) => threadId === "thread-goal",
    now: () => 42,
  });
  apply({
    method: "thread/goal/updated",
    params: {
      threadId: "thread-goal",
      turnId: null,
      goal: {
        threadId: "thread-goal",
        objective: "Ship live goal sync",
        status: "usage_limited",
        tokensUsed: 1200,
        timeUsedSeconds: 90,
        createdAt: 1,
        updatedAt: 2,
      },
    },
  });
  assert.equal(conversations.get("thread-goal").threadGoal.status, "usageLimited");
  assert.equal(conversations.get("thread-goal").threadGoal.objective, "Ship live goal sync");

  apply({
    method: "thread/goal/updated",
    params: {
      threadId: "thread-goal",
      goal: {
        threadId: "thread-goal",
        objective: "Ship live goal sync",
        status: "complete",
        updatedAt: 3,
      },
    },
  });
  assert.equal(conversations.get("thread-goal").threadGoal, null);
  assert.equal(conversations.get("thread-goal").completedThreadGoal.status, "complete");

  apply({ method: "thread/goal/cleared", params: { threadId: "thread-goal" } });
  assert.equal(conversations.get("thread-goal").threadGoal, null);
  assert.equal(conversations.get("thread-goal").completedThreadGoal, null);
});

test("conversation adapter strips injected context user items from hydrated turns", () => {
  const agentsText = "# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>";
  const envText = "<environment_context>\n  <cwd>/Users/me/proj</cwd>\n</environment_context>";
  const state = buildConversationStateFromThread({
    id: "thread-context-hydrate",
    name: "Context hydrate",
    cwd: "/Users/me/proj",
    turns: [{
      id: "turn-context-hydrate",
      status: "completed",
      items: [
        { id: "ctx-agents", type: "userMessage", content: [{ type: "input_text", text: agentsText }] },
        { id: "ctx-env", type: "userMessage", content: [{ type: "input_text", text: envText }] },
        { id: "real-prompt", type: "userMessage", content: [{ type: "input_text", text: "minchia compa" }] },
        { id: "reply", type: "agentMessage", text: "Dimmi tutto" },
      ],
    }],
  });

  const turn = state.turns[0];
  // The real prompt is adopted into params.input; context never becomes a bubble.
  assert.deepEqual(turn.params.input, [{ type: "text", text: "minchia compa" }]);
  assert.deepEqual(turn.items.map((item) => item.id), ["reply"]);
});

test("conversation adapter supplies receiverThreads required by Desktop collab rendering", () => {
  const state = buildConversationStateFromThread({
    id: "thread-collab-compatibility",
    cwd: "/Users/me/proj",
    turns: [{
      id: "turn-collab-compatibility",
      status: "completed",
      items: [{
        id: "collab-send-message",
        type: "collabAgentToolCall",
        tool: "send_message",
        status: "completed",
        receiverThreadIds: ["thread-child-a", "thread-child-b"],
        agentsStates: {},
      }],
    }],
  });

  assert.deepEqual(
    state.turns[0].items[0].receiverThreads,
    [{ threadId: "thread-child-a" }, { threadId: "thread-child-b" }]
  );
});

test("conversation adapter evicts pre-existing contextual items on merge", () => {
  const conversations = new Map();
  const owned = new Set(["thread-context-merge"]);
  const now = () => 9;
  const contextualItem = {
    id: "ctx-stale",
    type: "userMessage",
    content: [{
      type: "input_text",
      text: "# AGENTS.md instructions for /Users/me/proj\n<INSTRUCTIONS>rules</INSTRUCTIONS>",
    }],
  };

  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-context-merge",
        turn: { id: "turn-context-merge", items: [], status: "inProgress", startedAt: 1 },
      },
    },
  });
  // Simulate a contextual item that slipped into state before the filter existed.
  conversations.get("thread-context-merge").turns[0].items.push({ ...contextualItem });

  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/completed",
      params: {
        threadId: "thread-context-merge",
        turnId: "turn-context-merge",
        item: contextualItem,
      },
    },
  });

  assert.deepEqual(conversations.get("thread-context-merge").turns[0].items, []);
});

test("conversation adapter strips injected context carried inside turn.items", () => {
  const agentsText = "# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>";
  const envText = "<environment_context>\n  <cwd>/Users/me/proj</cwd>\n</environment_context>";
  const conversations = new Map();
  const owned = new Set(["thread-turn-items"]);
  const now = () => 3;

  // turn/completed carries the full turn.items on turn 1, injected context first.
  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/completed",
      params: {
        threadId: "thread-turn-items",
        turn: {
          id: "turn-turn-items",
          status: "completed",
          startedAt: 1,
          items: [
            { id: "ctx-agents", type: "userMessage", content: [{ type: "input_text", text: agentsText }] },
            { id: "ctx-env", type: "userMessage", content: [{ type: "input_text", text: envText }] },
            { id: "real-prompt", type: "userMessage", content: [{ type: "input_text", text: "minchia compa" }] },
            { id: "reply", type: "agentMessage", text: "Dimmi tutto" },
          ],
        },
      },
    },
  });

  const turn = conversations.get("thread-turn-items").turns[0];
  // Context is dropped; the real prompt is adopted into params.input (Desktop
  // renders the bubble from there), leaving only the assistant reply as an item.
  assert.deepEqual(turn.items.map((item) => item.id), ["reply"]);
  assert.deepEqual(turn.params.input, [{ type: "text", text: "minchia compa" }]);
  const serialized = JSON.stringify(turn);
  assert.equal(serialized.includes("AGENTS.md instructions"), false);
  assert.equal(serialized.includes("environment_context"), false);
});

test("conversation adapter extracts prompt from mixed context wrapper user items", () => {
  const wrappedPrompt = [
    "# AGENTS.md instructions for /Users/me/proj",
    "",
    "<INSTRUCTIONS>",
    "rules",
    "</INSTRUCTIONS>",
    "",
    "<environment_context>",
    "  <cwd>/Users/me/proj</cwd>",
    "</environment_context>",
    "",
    "## My request for Codex:",
    "fix the desktop sync bug",
  ].join("\n");
  const state = buildConversationStateFromThread({
    id: "thread-context-wrapper",
    name: "Context wrapper",
    cwd: "/Users/me/proj",
    turns: [{
      id: "turn-context-wrapper",
      status: "completed",
      items: [
        { id: "wrapped-prompt", type: "userMessage", content: [{ type: "input_text", text: wrappedPrompt }] },
        { id: "reply", type: "agentMessage", text: "Fixed" },
      ],
    }],
  });

  const turn = state.turns[0];
  assert.deepEqual(turn.params.input, [{ type: "text", text: "fix the desktop sync bug" }]);
  assert.deepEqual(turn.items.map((item) => item.id), ["reply"]);
  const serialized = JSON.stringify(turn);
  assert.equal(serialized.includes("AGENTS.md instructions"), false);
  assert.equal(serialized.includes("environment_context"), false);
  assert.equal(serialized.includes("## My request for Codex:"), false);
});

test("conversation adapter adopts live mixed context prompt item into params input", () => {
  const wrappedPrompt = [
    "# AGENTS.md instructions for /Users/me/proj",
    "",
    "<INSTRUCTIONS>",
    "rules",
    "</INSTRUCTIONS>",
    "",
    "## My request for Codex:",
    "continue from live event",
  ].join("\n");
  const conversations = new Map();
  const owned = new Set(["thread-live-wrapper"]);
  const now = () => 7;

  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-live-wrapper",
        turn: { id: "turn-live-wrapper", items: [], status: "inProgress", startedAt: 1 },
      },
    },
  });
  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/completed",
      params: {
        threadId: "thread-live-wrapper",
        turnId: "turn-live-wrapper",
        item: {
          id: "wrapped-live-prompt",
          type: "userMessage",
          content: [{ type: "input_text", text: wrappedPrompt }],
        },
      },
    },
  });

  const turn = conversations.get("thread-live-wrapper").turns[0];
  assert.deepEqual(turn.params.input, [{ type: "text", text: "continue from live event" }]);
  assert.deepEqual(turn.items, []);
  const serialized = JSON.stringify(turn);
  assert.equal(serialized.includes("AGENTS.md instructions"), false);
  assert.equal(serialized.includes("## My request for Codex:"), false);
});

test("conversation adapter drops injected context user items from live item events", () => {
  const conversations = new Map();
  const owned = new Set(["thread-context-live"]);
  const now = () => 5;

  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-context-live",
        turn: { id: "turn-context-live", items: [], status: "inProgress", startedAt: 1 },
      },
    },
  });
  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-context-live",
        turnId: "turn-context-live",
        item: {
          id: "ctx-live",
          type: "userMessage",
          content: [{
            type: "input_text",
            text: "# AGENTS.md instructions for /Users/me/proj\n<INSTRUCTIONS>rules</INSTRUCTIONS>",
          }],
        },
      },
    },
  });

  assert.deepEqual(conversations.get("thread-context-live").turns[0].items, []);
});

test("conversation state patch builder falls back when patches are too large", () => {
  assert.deepEqual(
    buildConversationStatePatches(
      { turns: [] },
      { turns: [{ id: "turn-1" }], updatedAt: 1 },
      { maxPatchCount: 10, maxPatchBytes: 1024 }
    ),
    [
      { op: "add", path: ["turns", 0], value: { id: "turn-1" } },
      { op: "add", path: ["updatedAt"], value: 1 },
    ]
  );
  assert.equal(
    buildConversationStatePatches(
      { turns: [] },
      { turns: [{ id: "turn-1" }], updatedAt: 1 },
      { maxPatchCount: 1, maxPatchBytes: 1024 }
    ),
    null
  );
});

test("conversation adapter streams fileChange output deltas into fileChange items", () => {
  const conversations = new Map();
  const owned = new Set(["thread-file-change"]);
  const now = () => 42;

  let update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/fileChange/outputDelta",
      params: {
        threadId: "thread-file-change",
        turnId: "turn-file-change",
        itemId: "item-file-change",
        delta: "diff --git a/a.txt",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-file-change", changed: true });

  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/fileChange/outputDelta",
      params: {
        threadId: "thread-file-change",
        turnId: "turn-file-change",
        itemId: "item-file-change",
        delta: " b/a.txt",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-file-change", changed: true });

  const turn = conversations.get("thread-file-change").turns
    .find((candidate) => candidate.turnId === "turn-file-change");
  const item = turn.items.find((candidate) => candidate.id === "item-file-change");
  assert.equal(item.type, "fileChange");
  assert.equal(item.status, "inProgress");
  assert.equal(item.aggregatedOutput, "diff --git a/a.txt b/a.txt");
});

test("conversation adapter keeps turnless fileChange events on latest real turn", () => {
  const threadId = "thread-real-file-change";
  const conversations = new Map();
  const owned = new Set([threadId]);
  const conversation = buildConversationStateFromThread({
    id: threadId,
    turns: [{
      id: "turn-real-file-change",
      status: "inProgress",
      items: [{ id: "assistant-real", type: "agentMessage", text: "Working." }],
    }],
  });
  conversations.set(threadId, conversation);

  let update = applyAppServerMessageToConversationState({
    conversations,
    shouldOwnThread: (candidateThreadId) => owned.has(candidateThreadId),
    message: {
      method: "item/fileChange/outputDelta",
      params: {
        threadId,
        itemId: "streaming-file-change",
        delta: "diff --git a/Sources/Real.swift",
      },
    },
  });
  assert.deepEqual(update, { threadId, changed: true });

  update = applyAppServerMessageToConversationState({
    conversations,
    shouldOwnThread: (candidateThreadId) => owned.has(candidateThreadId),
    message: {
      method: "item/completed",
      params: {
        threadId,
        item: {
          id: "completed-file-change",
          type: "fileChange",
          status: "completed",
          changes: [{ path: "Sources/Real.swift", kind: "update", additions: 3, deletions: 1 }],
        },
      },
    },
  });
  assert.deepEqual(update, { threadId, changed: true });

  const turns = conversations.get(threadId).turns;
  assert.equal(turns.length, 1);
  assert.equal(turns[0].turnId, "turn-real-file-change");
  const streamingItem = turns[0].items.find((item) => item.id === "streaming-file-change");
  assert.equal(streamingItem.type, "fileChange");
  assert.equal(streamingItem.aggregatedOutput, "diff --git a/Sources/Real.swift");
  const completedItem = turns[0].items.find((item) => item.id === "completed-file-change");
  assert.equal(completedItem.type, "fileChange");
  assert.deepEqual(completedItem.changes, [
    { path: "Sources/Real.swift", kind: "update", additions: 3, deletions: 1 },
  ]);
});

test("conversation adapter keeps turnless fileChange events off optimistic pending turns", () => {
  const threadId = "thread-pending-file-change";
  const optimisticTurnId = `remodex-pending-turn:${threadId}:request-2`;
  const conversations = new Map();
  const fallbackTurnIdsByThreadId = new Map([[threadId, optimisticTurnId]]);
  const owned = new Set([threadId]);
  const conversation = buildConversationStateFromThread({
    id: threadId,
    turns: [{
      id: "turn-previous",
      status: "completed",
      items: [{ id: "assistant-previous", type: "agentMessage", text: "Done." }],
    }],
  });
  conversation.turns.push({
    id: optimisticTurnId,
    turnId: optimisticTurnId,
    params: {
      threadId,
      input: [{ type: "input_text", text: "follow up" }],
    },
    status: "inProgress",
    items: [],
    remodexOptimisticPendingTurn: true,
  });
  conversations.set(threadId, conversation);

  let update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    shouldOwnThread: (candidateThreadId) => owned.has(candidateThreadId),
    message: {
      method: "item/fileChange/outputDelta",
      params: {
        threadId,
        itemId: "late-file-change-delta",
        delta: "diff --git a/Sources/Previous.swift",
      },
    },
  });
  assert.deepEqual(update, { threadId, changed: true });

  update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    shouldOwnThread: (candidateThreadId) => owned.has(candidateThreadId),
    message: {
      method: "item/completed",
      params: {
        threadId,
        item: {
          id: "late-file-change",
          type: "fileChange",
          status: "completed",
          changes: [{ path: "Sources/Previous.swift", kind: "update", additions: 2, deletions: 1 }],
        },
      },
    },
  });

  assert.deepEqual(update, { threadId, changed: true });
  const turns = conversations.get(threadId).turns;
  assert.equal(turns[0].turnId, "turn-previous");
  assert.equal(turns[0].items.at(-1).id, "late-file-change");
  const deltaItem = turns[0].items.find((item) => item.id === "late-file-change-delta");
  assert.equal(deltaItem.type, "fileChange");
  assert.equal(deltaItem.aggregatedOutput, "diff --git a/Sources/Previous.swift");
  assert.deepEqual(turns[1].items, []);
});

test("conversation adapter tracks requests and resolved notifications", () => {
  const conversations = new Map();
  const owned = new Set(["thread-adapter"]);
  const now = () => 42;
  let update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      id: "request-1",
      method: "item/tool/requestUserInput",
      params: {
        threadId: "thread-adapter",
        turnId: "turn-adapter",
        itemId: "item-adapter",
        questions: [{ id: "q1", question: "Continue?" }],
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-adapter", changed: true });
  assert.equal(conversations.get("thread-adapter").requests.length, 1);

  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "serverRequest/resolved",
      params: {
        threadId: "thread-adapter",
        requestId: "request-1",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-adapter", changed: true });
  assert.equal(conversations.get("thread-adapter").requests.length, 0);
});

test("conversation adapter ignores thread started notifications for unowned threads", () => {
  const conversations = new Map();
  const owned = new Set();
  const update = applyAppServerMessageToConversationState({
    conversations,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "thread/started",
      params: {
        thread: {
          id: "thread-unowned-started",
          sessionId: "session-unowned-started",
          preview: "Desktop owned",
          turns: [],
        },
      },
    },
  });

  assert.equal(update, null);
  assert.equal(conversations.has("thread-unowned-started"), false);
});

test("conversation adapter keeps the prompt in params and drops the echoed userMessage item", () => {
  const conversations = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-canonical-user",
    [{
      params: {
        threadId: "thread-canonical-user",
        input: [{ type: "input_text", text: "build the canonical path" }],
        cwd: "/tmp/canonical-user",
      },
    }],
  ]]);
  const owned = new Set(["thread-canonical-user"]);
  const now = () => 42;

  let update = applyAppServerMessageToConversationState({
    conversations,
    pendingTurnStartParamsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-canonical-user",
        turn: {
          id: "turn-canonical-user",
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });
  // Desktop renders the user bubble from params.input; no item is injected.
  assert.deepEqual(
    conversations.get("thread-canonical-user").turns[0].params.input,
    [{ type: "input_text", text: "build the canonical path" }]
  );
  assert.deepEqual(conversations.get("thread-canonical-user").turns[0].items, []);

  // A reasoning item streams in before the echoed user message arrives.
  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-canonical-user",
        turnId: "turn-canonical-user",
        item: {
          id: "reasoning-1",
          type: "reasoning",
          summary: [],
          content: [],
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });

  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-canonical-user",
        turnId: "turn-canonical-user",
        item: {
          id: "canonical-user-message",
          type: "userMessage",
          content: [{ type: "text", text: "build the canonical path" }],
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });
  // The app-server echo of the initial prompt is dropped: Desktop would label
  // a userMessage item that fails its params.input dedupe as a steer.
  assert.deepEqual(
    conversations.get("thread-canonical-user").turns[0].items.map((item) => item.id),
    ["reasoning-1"]
  );

  // A genuinely new user message mid-turn is a steer and must be kept.
  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-canonical-user",
        turnId: "turn-canonical-user",
        item: {
          id: "steer-user-message",
          type: "userMessage",
          content: [{ type: "text", text: "also update the docs" }],
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });
  assert.deepEqual(
    conversations.get("thread-canonical-user").turns[0].items.map((item) => item.id),
    ["reasoning-1", "steer-user-message"]
  );
});

test("conversation adapter dedupes the echoed prompt after fallback turn id promotion", () => {
  const conversations = new Map();
  const fallbackTurnIdsByThreadId = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-promoted-user",
    [{
      params: {
        threadId: "thread-promoted-user",
        input: [{ type: "input_text", text: "prompt before promotion" }],
      },
    }],
  ]]);
  const owned = new Set(["thread-promoted-user"]);
  const now = () => 7;

  // turn/started arrives without a usable turn id, so the turn is created
  // under a fallback id with the prompt held in params.input only.
  applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    pendingTurnStartParamsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-promoted-user",
        turn: {
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });
  const fallbackTurn = conversations.get("thread-promoted-user").turns[0];
  assert.deepEqual(fallbackTurn.params.input, [{ type: "input_text", text: "prompt before promotion" }]);
  assert.deepEqual(fallbackTurn.items, []);

  // A later event promotes the fallback turn to its real id, then the app-server
  // echoes the prompt as a userMessage item; it must still dedupe against
  // params.input instead of surviving as a "Steered conversation" row.
  applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-promoted-user",
        turnId: "turn-promoted-real",
        item: {
          id: "canonical-promoted-user-message",
          type: "userMessage",
          content: [{ type: "text", text: "prompt before promotion" }],
        },
      },
    },
  });

  const turn = conversations.get("thread-promoted-user").turns[0];
  assert.equal(turn.turnId, "turn-promoted-real");
  assert.deepEqual(turn.items.filter((item) => item.type === "userMessage"), []);
  assert.deepEqual(turn.params.input, [{ type: "input_text", text: "prompt before promotion" }]);
});

test("conversation adapter marks worked-for boundaries from deltas and completions", () => {
  const conversations = new Map();
  const owned = new Set(["thread-worked-for"]);
  let timestamp = 1000;
  const now = () => {
    timestamp += 10;
    return timestamp;
  };

  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-worked-for",
        turn: { id: "turn-worked-for", items: [], status: "inProgress", error: null, startedAt: 1 },
      },
    },
  });
  assert.equal(conversations.get("thread-worked-for").turns[0].firstTurnWorkItemStartedAtMs, null);

  // A joined-mid-turn delta (no item/started seen) must still mark work start.
  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/commandExecution/outputDelta",
      params: {
        threadId: "thread-worked-for",
        turnId: "turn-worked-for",
        itemId: "command-1",
        delta: "output line\n",
      },
    },
  });
  const workedTurn = conversations.get("thread-worked-for").turns[0];
  assert.ok(workedTurn.firstTurnWorkItemStartedAtMs > 0);

  // An agentMessage that only surfaces at item/completed still marks the
  // final-assistant boundary Desktop uses as workedCompletedAtMs.
  applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/completed",
      params: {
        threadId: "thread-worked-for",
        turnId: "turn-worked-for",
        item: { id: "assistant-final", type: "agentMessage", text: "all done" },
      },
    },
  });
  assert.ok(workedTurn.finalAssistantStartedAtMs > workedTurn.firstTurnWorkItemStartedAtMs);
});

test("conversation adapter propagates phone turn model and effort to composer fields", () => {
  const conversations = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-model-meta",
    [{
      params: {
        threadId: "thread-model-meta",
        input: [{ type: "input_text", text: "use my model" }],
        model: "gpt-5.5",
        effort: "medium",
        serviceTier: "fast",
      },
    }],
  ]]);
  const owned = new Set(["thread-model-meta"]);
  const now = () => 21;

  applyAppServerMessageToConversationState({
    conversations,
    pendingTurnStartParamsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-model-meta",
        turn: {
          id: "turn-model-meta",
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });

  const conversation = conversations.get("thread-model-meta");
  assert.equal(conversation.latestModel, "gpt-5.5");
  assert.equal(conversation.latestReasoningEffort, "medium");
  assert.equal(conversation.latestServiceTier, "fast");
  assert.equal(conversation.latestCollaborationMode.settings.model, "gpt-5.5");
  assert.equal(conversation.latestCollaborationMode.settings.reasoning_effort, "medium");
});

test("conversation adapter consumes pending turn starts FIFO for rapid consecutive turns", () => {
  const conversations = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-fifo",
    [
      { params: { threadId: "thread-fifo", input: [{ type: "input_text", text: "first prompt" }] } },
      { params: { threadId: "thread-fifo", input: [{ type: "input_text", text: "second prompt" }] } },
    ],
  ]]);
  const owned = new Set(["thread-fifo"]);
  const now = () => 11;

  for (const turnId of ["turn-fifo-1", "turn-fifo-2"]) {
    applyAppServerMessageToConversationState({
      conversations,
      pendingTurnStartParamsByThreadId,
      now,
      shouldOwnThread: (threadId) => owned.has(threadId),
      message: {
        method: "turn/started",
        params: {
          threadId: "thread-fifo",
          turn: {
            id: turnId,
            items: [],
            status: "inProgress",
            error: null,
            startedAt: 1,
          },
        },
      },
    });
  }

  const turns = conversations.get("thread-fifo").turns;
  assert.deepEqual(
    turns.map((turn) => turn.params.input[0].text),
    ["first prompt", "second prompt"]
  );
  assert.equal(pendingTurnStartParamsByThreadId.has("thread-fifo"), false);
});

test("conversation adapter keeps a stable fallback turn until a real turn id arrives", () => {
  const conversations = new Map();
  const fallbackTurnIdsByThreadId = new Map();
  const owned = new Set(["thread-turnless"]);
  let timestamp = 100;
  const now = () => {
    timestamp += 1;
    return timestamp;
  };

  let update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-turnless",
        turn: {
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-turnless", changed: true });
  const syntheticTurnId = conversations.get("thread-turnless").turns[0].turnId;
  assert.match(syntheticTurnId, /^remodex-live-turn:thread-turnless:/);

  update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-turnless",
        itemId: "assistant-turnless",
        delta: "Hello",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-turnless", changed: true });
  assert.equal(conversations.get("thread-turnless").turns.length, 1);
  assert.equal(conversations.get("thread-turnless").turns[0].items[0].text, "Hello");

  update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-turnless",
        turnId: "turn-real",
        itemId: "assistant-turnless",
        delta: " world",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-turnless", changed: true });
  const turns = conversations.get("thread-turnless").turns;
  assert.equal(turns.length, 1);
  assert.equal(turns[0].turnId, "turn-real");
  assert.equal(turns[0].items[0].text, "Hello world");
});
