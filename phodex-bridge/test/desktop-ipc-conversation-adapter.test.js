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
} = require("../src/desktop-ipc-conversation-adapter");
const {
  buildConversationStatePatches,
} = require("../src/desktop-ipc-state-patches");

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
