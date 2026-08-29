// FILE: desktop-ipc-action-follower.test.js
// Purpose: Verifies Codex Desktop IPC pending actions are projected and routed without using rollout text.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/desktop-ipc-action-follower

const test = require("node:test");
const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const { EventEmitter } = require("node:events");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: wait } = require("node:timers/promises");

const {
  applyConversationStateChange,
  buildDesktopTurnsListResult,
  createDesktopIpcActionFollower,
  desktopFollowerPayloadForResponse,
  projectDesktopAssistantDeltaNotifications,
  projectPendingDesktopActions,
  resolveDefaultIpcSocketPath,
  seedConversationStateFromThreadRead,
} = require("../src/desktop-ipc-action-follower");
const {
  matchDesktopTurnIdentityContinuities,
} = require("../src/desktop-ipc-conversation-projector");

test("desktop identity repair pairs synthetic turns independently of parallel active turns", () => {
  const sharedTurn = {
    status: "inProgress",
    params: { input: [{ type: "text", text: "Repair A" }] },
    items: [{ id: "assistant-a-stable", type: "agentMessage", text: "Working" }],
  };
  const stableParallelTurn = {
    id: "turn-c",
    status: "inProgress",
    items: [{ id: "assistant-c", type: "agentMessage", text: "Parallel" }],
  };
  const matches = matchDesktopTurnIdentityContinuities(
    [
      { id: "ipc-turn-0", turn: sharedTurn },
      { id: "turn-c", turn: stableParallelTurn },
    ],
    [
      { id: "turn-real-a", turn: { ...sharedTurn, turnId: "turn-real-a" } },
      { id: "turn-c", turn: stableParallelTurn },
    ]
  );

  assert.deepEqual([...matches.previousTurnIds], ["ipc-turn-0"]);
  assert.deepEqual([...matches.nextTurnIds], ["turn-real-a"]);

  const stablePriority = matchDesktopTurnIdentityContinuities(
    [
      {
        id: "ipc-turn-0",
        turn: {
          startedAt: 123,
          params: { input: [{ type: "text", text: "same prompt" }] },
          items: [{ id: "assistant-fallback", type: "agentMessage", text: "Old" }],
        },
      },
      {
        id: "ipc-turn-1",
        turn: {
          startedAt: 999,
          params: { input: [{ type: "text", text: "other prompt" }] },
          items: [{ id: "assistant-stable", type: "agentMessage", text: "Stable" }],
        },
      },
    ],
    [{
      id: "turn-real-stable",
      turn: {
        startedAt: 123,
        params: { input: [{ type: "text", text: "same prompt" }] },
        items: [{ id: "assistant-stable", type: "agentMessage", text: "Stable" }],
      },
    }]
  );
  assert.deepEqual([...stablePriority.previousTurnIds], ["ipc-turn-1"]);
  assert.deepEqual([...stablePriority.nextTurnIds], ["turn-real-stable"]);
});

test("desktop turns/list returns newest-first pages without reversing reopen history", () => {
  const chronologicalTurns = [
    { id: "turn-1", items: [{ id: "message-1", type: "agentMessage", text: "one" }] },
    { id: "turn-2", items: [{ id: "message-2", type: "agentMessage", text: "two" }] },
    { id: "turn-3", items: [{ id: "message-3", type: "agentMessage", text: "three" }] },
  ];

  const firstPage = buildDesktopTurnsListResult(chronologicalTurns, {
    sortDirection: "desc",
    limit: 2,
  });
  assert.deepEqual(firstPage.data.map((turn) => turn.id), ["turn-3", "turn-2"]);
  assert.equal(Object.hasOwn(firstPage, "turns"), false);
  assert.equal(firstPage.hasMore, true);
  assert.ok(firstPage.nextCursor);

  const secondPage = buildDesktopTurnsListResult(chronologicalTurns, {
    sortDirection: "desc",
    limit: 2,
    cursor: firstPage.nextCursor,
  });
  assert.deepEqual(secondPage.data.map((turn) => turn.id), ["turn-1"]);
  assert.equal(secondPage.hasMore, false);
  assert.equal(secondPage.nextCursor, null);

  const streamingGrowth = structuredClone(chronologicalTurns);
  streamingGrowth[2].items[0].text = "three, still streaming";
  const pageAfterStreamingGrowth = buildDesktopTurnsListResult(streamingGrowth, {
    sortDirection: "desc",
    limit: 2,
    cursor: firstPage.nextCursor,
  });
  assert.deepEqual(pageAfterStreamingGrowth.data.map((turn) => turn.id), ["turn-1"]);

  const itemGrowth = structuredClone(chronologicalTurns);
  itemGrowth[2].items.push({ id: "tool-3", type: "toolCall", text: "running" });
  const pageAfterNonUserItemGrowth = buildDesktopTurnsListResult(itemGrowth, {
    sortDirection: "desc",
    limit: 2,
    cursor: firstPage.nextCursor,
  });
  assert.deepEqual(pageAfterNonUserItemGrowth.data.map((turn) => turn.id), ["turn-1"]);

  const changedSnapshot = buildDesktopTurnsListResult(
    chronologicalTurns.filter((turn) => turn.id !== "turn-2"),
    {
      sortDirection: "desc",
      limit: 2,
      cursor: firstPage.nextCursor,
    }
  );
  assert.equal(changedSnapshot, null);

  const prependedSnapshot = buildDesktopTurnsListResult(
    [{ id: "turn-x", items: [{ id: "message-x" }] }, ...chronologicalTurns],
    {
      sortDirection: "desc",
      limit: 2,
      cursor: firstPage.nextCursor,
    }
  );
  assert.equal(prependedSnapshot, null);
});

test("desktop turns/list private cursors never fall through to app-server", (t) => {
  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath: path.join(os.tmpdir(), `missing-remodex-${randomUUID()}.sock`),
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
  });
  t.after(() => follower.stopAll());

  const handled = follower.observeInbound(JSON.stringify({
    id: "private-cursor-read",
    method: "thread/turns/list",
    params: {
      threadId: "thread-with-expired-desktop-page",
      cursor: "remodex-desktop-turns:desc:id:missing-turn",
    },
  }));

  assert.equal(handled, true);
  assert.equal(outbound.length, 1);
  assert.equal(outbound[0].id, "private-cursor-read");
  assert.equal(outbound[0].error.code, -32602);
});

test("desktop-owned follow handshakes notify the navigation controller", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-action-follower-follow-"
  );
  const followerChanges = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    onFollowerStateChanged(threadId, following) {
      followerChanges.push({ threadId, following });
    },
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/list",
    params: {},
  }));
  await waitFor(() => state.socket);

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-following-changed",
    sourceClientId: "desktop-renderer",
    version: 1,
    params: {
      hostId: "local",
      conversationId: "thread-desktop-follow",
      following: true,
    },
  });
  await waitFor(() => followerChanges.length === 1);
  assert.deepEqual(followerChanges[0], {
    threadId: "thread-desktop-follow",
    following: true,
  });

  writeFrame(state.socket, {
    type: "broadcast",
    method: "client-status-changed",
    sourceClientId: "router",
    version: 1,
    params: {
      clientId: "desktop-renderer",
      status: "disconnected",
    },
  });
  await waitFor(() => followerChanges.length === 2);
  assert.deepEqual(followerChanges[1], {
    threadId: "thread-desktop-follow",
    following: false,
  });
});

test("phone thread reads subscribe the bridge to Desktop-owned state patches", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-action-follower-phone-follow-"
  );
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    id: "phone-read",
    method: "thread/read",
    params: { threadId: "thread-open-on-phone" },
  }));

  await waitFor(() => state.frames.some((frame) => (
    frame.method === "thread-stream-following-changed"
      && frame.params?.conversationId === "thread-open-on-phone"
      && frame.params?.following === true
  )));
  const follow = state.frames.find((frame) => (
    frame.method === "thread-stream-following-changed"
      && frame.params?.conversationId === "thread-open-on-phone"
  ));
  assert.equal(follow.sourceClientId, "remodex-test");
});

test("projects desktop pending user input as an app-server request shape", () => {
  const actions = projectPendingDesktopActions("thread-1", {
    requests: [{
      id: "req-user-input",
      method: "item/tool/requestUserInput",
      completed: false,
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "item-1",
        questions: [{
          id: "q1",
          header: "Mode",
          question: "Choose one",
          isOther: true,
          options: [{ label: "Yes", description: "Continue" }],
        }],
      },
    }],
  });

  assert.deepEqual(actions, [{
    id: "req-user-input",
    method: "item/tool/requestUserInput",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      remodexActionSource: "desktop-ipc-action-follower",
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
      questions: [{
        id: "q1",
        header: "Mode",
        question: "Choose one",
        isOther: true,
        options: [{ label: "Yes", description: "Continue" }],
      }],
    },
  }]);
});

test("preserves numeric app-server ids for desktop user-input replies", () => {
  const [action] = projectPendingDesktopActions("thread-numeric-input", {
    requests: [{
      // Codex Desktop currently uses numeric app-server ids for request_user_input.
      id: 36,
      method: "item/tool/requestUserInput",
      params: {
        turnId: "turn-numeric-input",
        questions: [{
          id: "pairing_scope",
          header: "Pairing",
          question: "Which pairing scope should be used?",
          options: [{ label: "Dev pairing now", description: "Connect now" }],
        }],
      },
    }],
  });

  assert.equal(action.id, 36);
  assert.deepEqual(
    desktopFollowerPayloadForResponse({
      requestId: "36",
      desktopRequestId: action.id,
      method: action.method,
      threadId: "thread-numeric-input",
    }, {
      id: 36,
      result: {
        answers: {
          pairing_scope: { answers: ["Dev pairing now"] },
        },
      },
    }),
    {
      method: "thread-follower-submit-user-input",
      params: {
        conversationId: "thread-numeric-input",
        requestId: 36,
        response: {
          answers: {
            pairing_scope: { answers: ["Dev pairing now"] },
          },
        },
      },
    }
  );
});

test("projects command, file, and permission approvals while ignoring completed requests", () => {
  const actions = projectPendingDesktopActions("thread-2", {
    requests: [
      {
        id: "req-command",
        method: "item/commandExecution/requestApproval",
        params: {
          turnId: "turn-2",
          itemId: "item-command",
          command: "git status",
          cwd: "/repo",
          reason: "Need to inspect changes",
        },
      },
      {
        id: "req-file",
        method: "item/fileChange/requestApproval",
        params: {
          threadId: "thread-2",
          turnId: "turn-2",
          itemId: "item-file",
          grantRoot: "/repo",
          reason: "Need to edit files",
        },
      },
      {
        id: "req-file-read",
        method: "item/fileRead/requestApproval",
        params: {
          threadId: "thread-2",
          turnId: "turn-2",
          itemId: "item-file-read",
          path: "/repo/secrets.txt",
          reason: "Need to inspect a file",
        },
      },
      {
        id: "req-done",
        method: "item/tool/requestUserInput",
        completed: true,
        params: {
          questions: [{ id: "q", question: "Done?" }],
        },
      },
      {
        id: "req-permissions",
        method: "item/permissions/requestApproval",
        params: {
          threadId: "thread-2",
          turnId: "turn-2",
          itemId: "item-permissions",
          reason: "Need plugin network access",
          permissions: {
            network: { enabled: true },
          },
        },
      },
    ],
  });

  assert.deepEqual(
    actions.map((action) => [action.id, action.method, action.params.threadId]),
    [
      ["req-command", "item/commandExecution/requestApproval", "thread-2"],
      ["req-file", "item/fileChange/requestApproval", "thread-2"],
      ["req-file-read", "item/fileRead/requestApproval", "thread-2"],
      ["req-permissions", "item/permissions/requestApproval", "thread-2"],
    ]
  );
  assert.equal(actions[0].params.command, "git status");
  assert.equal(actions[1].params.grantRoot, "/repo");
  assert.equal(actions[2].params.path, "/repo/secrets.txt");
  assert.equal(actions[3].params.reason, "Need plugin network access");
  assert.equal(actions[3].params.remodexActionSource, "desktop-ipc-action-follower");
});

test("builds desktop follower reply payloads from iOS responses", () => {
  assert.deepEqual(
    desktopFollowerPayloadForResponse({
      requestId: "req-command",
      method: "item/commandExecution/requestApproval",
      threadId: "thread-1",
    }, {
      id: "req-command",
      result: { decision: "acceptForSession" },
    }),
    {
      method: "thread-follower-command-approval-decision",
      params: {
        conversationId: "thread-1",
        requestId: "req-command",
        decision: "acceptForSession",
      },
    }
  );

  assert.deepEqual(
    desktopFollowerPayloadForResponse({
      requestId: "req-user-input",
      method: "item/tool/requestUserInput",
      threadId: "thread-1",
    }, {
      id: "req-user-input",
      result: {
        answers: {
          q1: { answers: ["Yes"] },
        },
      },
    }),
    {
      method: "thread-follower-submit-user-input",
      params: {
        conversationId: "thread-1",
        requestId: "req-user-input",
        response: {
          answers: {
            q1: { answers: ["Yes"] },
          },
        },
      },
    }
  );

  assert.deepEqual(
    desktopFollowerPayloadForResponse({
      requestId: "req-file-read",
      method: "item/fileRead/requestApproval",
      threadId: "thread-1",
    }, {
      id: "req-file-read",
      result: { decision: "accept" },
    }),
    {
      method: "thread-follower-file-approval-decision",
      params: {
        conversationId: "thread-1",
        requestId: "req-file-read",
        decision: "accept",
      },
    }
  );

  assert.deepEqual(
    desktopFollowerPayloadForResponse({
      requestId: "req-permissions",
      method: "item/permissions/requestApproval",
      threadId: "thread-1",
    }, {
      id: "req-permissions",
      result: {
        permissions: {
          network: { enabled: true },
        },
        scope: "turn",
      },
    }),
    {
      method: "thread-follower-file-approval-decision",
      params: {
        conversationId: "thread-1",
        requestId: "req-permissions",
        decision: "accept",
      },
    }
  );

  assert.deepEqual(
    desktopFollowerPayloadForResponse({
      requestId: "req-permissions",
      method: "item/permissions/requestApproval",
      threadId: "thread-1",
    }, {
      id: "req-permissions",
      result: {
        permissions: {},
        scope: "turn",
      },
    }),
    {
      method: "thread-follower-file-approval-decision",
      params: {
        conversationId: "thread-1",
        requestId: "req-permissions",
        decision: "decline",
      },
    }
  );
});

test("rejects malformed or failed desktop action responses instead of defaulting to accept", () => {
  assert.equal(
    desktopFollowerPayloadForResponse({
      requestId: "req-command",
      method: "item/commandExecution/requestApproval",
      threadId: "thread-1",
    }, {
      id: "req-command",
      error: { code: -32603, message: "User cancelled" },
    }),
    null
  );

  assert.equal(
    desktopFollowerPayloadForResponse({
      requestId: "req-command",
      method: "item/commandExecution/requestApproval",
      threadId: "thread-1",
    }, {
      id: "req-command",
      result: {},
    }),
    null
  );

  assert.equal(
    desktopFollowerPayloadForResponse({
      requestId: "req-user-input",
      method: "item/tool/requestUserInput",
      threadId: "thread-1",
    }, {
      id: "req-user-input",
      result: {},
    }),
    null
  );
});

test("applies desktop IPC snapshots and Immer-style request patches", () => {
  const snapshot = applyConversationStateChange(null, {
    type: "snapshot",
    conversationState: {
      requests: [{
        id: "req-1",
        method: "item/tool/requestUserInput",
        params: {
          questions: [{ id: "q1", question: "Continue?" }],
        },
      }],
    },
  });

  const patched = applyConversationStateChange(snapshot, {
    type: "patches",
    patches: [{
      op: "replace",
      path: ["requests", 0, "completed"],
      value: true,
    }],
  });

  assert.equal(snapshot.requests[0].completed, undefined);
  assert.equal(patched.requests[0].completed, true);
  assert.deepEqual(projectPendingDesktopActions("thread-1", patched), []);
});

test("seeds conversation state from thread/read responses for IPC recovery", () => {
  assert.deepEqual(
    seedConversationStateFromThreadRead({
      thread: {
        turns: [{ id: "turn-1", items: [] }],
      },
    }),
    {
      turns: [{ id: "turn-1", items: [] }],
      requests: [],
    }
  );

  assert.deepEqual(
    seedConversationStateFromThreadRead({
      conversationState: {
        requests: [{ id: "req-1" }],
      },
    }),
    {
      requests: [{ id: "req-1" }],
    }
  );
});

test("projects only appended assistant text as live app-server deltas", () => {
  const previousState = {
    turns: [{
      id: "turn-1",
      items: [{
        id: "assistant-1",
        type: "assistant_message",
        text: "Hello",
      }],
    }],
  };
  const nextState = {
    turns: [{
      id: "turn-1",
      items: [{
        id: "assistant-1",
        type: "assistant_message",
        text: "Hello world",
      }],
    }],
  };

  assert.deepEqual(
    projectDesktopAssistantDeltaNotifications("thread-1", previousState, nextState),
    [{
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "assistant-1",
        delta: " world",
      },
    }]
  );
});

test("projects canonical desktop agentMessage items as live app-server deltas", () => {
  const previousState = {
    turns: [{
      id: "turn-agent-message",
      items: [{
        id: "agent-message-1",
        type: "agentMessage",
        text: "Hello",
      }],
    }],
  };
  const nextState = {
    turns: [{
      id: "turn-agent-message",
      items: [{
        id: "agent-message-1",
        type: "agentMessage",
        text: "Hello world",
      }],
    }],
  };

  assert.deepEqual(
    projectDesktopAssistantDeltaNotifications("thread-agent-message", previousState, nextState),
    [{
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-agent-message",
        turnId: "turn-agent-message",
        itemId: "agent-message-1",
        delta: " world",
      },
    }]
  );
});

test("does not replay unchanged or rewritten assistant text as live deltas", () => {
  const previousState = {
    turns: [{
      id: "turn-1",
      items: [
        {
          id: "assistant-same",
          type: "assistant_message",
          text: "same",
        },
        {
          id: "assistant-rewrite",
          type: "assistant_message",
          text: "draft",
        },
      ],
    }],
  };
  const nextState = {
    turns: [{
      id: "turn-1",
      items: [
        {
          id: "assistant-same",
          type: "assistant_message",
          text: "same",
        },
        {
          id: "assistant-rewrite",
          type: "assistant_message",
          text: "final",
        },
      ],
    }],
  };

  assert.deepEqual(
    projectDesktopAssistantDeltaNotifications("thread-1", previousState, nextState),
    []
  );
});

test("desktop IPC follower backs off baseline recovery instead of hot-looping", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-recovery-backoff-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  let readAttempts = 0;
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    async readConversationState() {
      readAttempts += 1;
      throw new Error("thread not loaded");
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-backoff" },
  }));
  await waitFor(() => serverSocket);

  const patchBroadcast = (value) => ({
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-backoff",
      change: {
        type: "patches",
        patches: [{ op: "replace", path: ["turns", 0, "items", 0, "text"], value }],
      },
    },
  });

  // A burst of patch-only broadcasts must trigger at most one immediate read
  // attempt; retries wait for the backoff window instead of running per patch.
  for (let index = 0; index < 5; index += 1) {
    writeFrame(serverSocket, patchBroadcast(`delta ${index}`));
  }
  await wait(100);
  assert.equal(readAttempts, 1);

  // Failed recovery must not leak speculative timeline rows to the phone.
  assert.deepEqual(
    outbound.filter((message) => typeof message.method === "string"
      && (message.method.startsWith("item/") || message.method.startsWith("turn/"))),
    []
  );
});

test("desktop IPC follower announces thread replacement when synthetic turn ids become real", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-full-replace-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-full-replace" },
  }));
  await waitFor(() => serverSocket);

  // First snapshot carries a turn without any id, so the projector synthesizes one.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-full-replace",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            status: "inProgress",
            items: [{ id: "assistant-replace", type: "agentMessage", text: "partial" }],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => message.method === "turn/started"));

  // The next snapshot has the canonical turn id: the phone must be told to rebuild.
  const canonicalReplacementStartIndex = outbound.length;
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-full-replace",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            turnId: "turn-real-id",
            status: "inProgress",
            items: [{ id: "assistant-replace", type: "agentMessage", text: "partial" }],
          }],
          requests: [],
        },
      },
    },
  });

  await waitFor(() => outbound.some((message) => message.method === "thread/replaced"));
  const replaced = outbound.find((message) => message.method === "thread/replaced");
  assert.equal(replaced.params.threadId, "thread-full-replace");
  assert.equal(replaced.params.remodexDesktopMirror, true);
  assert.equal(replaced.params.remodexDesktopIpcMirror, true);
  // No embedded thread: the phone rebuilds from canonical history, and heavy
  // threads must not ship as one oversized relay frame.
  assert.equal(replaced.params.thread, undefined);

  // The replacement bootstrap follows the announcement with the real turn id.
  const replacedIndex = outbound.indexOf(replaced);
  const followUpTurnStarted = outbound.slice(replacedIndex + 1)
    .find((message) => message.method === "turn/started");
  assert.equal(followUpTurnStarted.params.turnId, "turn-real-id");
  assert.equal(followUpTurnStarted.params.remodexTurnIdentityContinuity, true);
  assert.equal(
    outbound.slice(canonicalReplacementStartIndex).some((message) => (
      message.method === "turn/completed" && message.params?.turnId === "ipc-turn-0"
    )),
    false,
    "canonical id repair must not terminate the synthetic alias"
  );

  // Shape alone is not continuity: if synthetic A ended while IPC was stale
  // and the next snapshot contains a different real B, B must advance iOS's
  // monotonic run generation.
  const distinctThreadId = "thread-full-replace-distinct-turn";
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: distinctThreadId },
  }));
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: distinctThreadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            status: "inProgress",
            params: { input: [{ type: "text", text: "Synthetic A prompt" }] },
            items: [{ id: "assistant-a", type: "agentMessage", text: "A output" }],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === distinctThreadId
      && message.params?.turnId === "ipc-turn-0"
  )));
  const distinctReplacementStartIndex = outbound.length;
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: distinctThreadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            turnId: "turn-real-b",
            status: "inProgress",
            params: { input: [{ type: "text", text: "Synthetic A prompt" }] },
            items: [{ id: "assistant-b", type: "agentMessage", text: "B output" }],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => outbound.slice(distinctReplacementStartIndex).some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === distinctThreadId
      && message.params?.turnId === "turn-real-b"
  )));
  const distinctTurnStarted = outbound.slice(distinctReplacementStartIndex).find((message) => (
    message.method === "turn/started"
      && message.params?.threadId === distinctThreadId
      && message.params?.turnId === "turn-real-b"
  ));
  assert.notEqual(distinctTurnStarted.params.remodexTurnIdentityContinuity, true);
});

test("uses the Codex Desktop named pipe as the default Windows IPC path", (t) => {
  useProcessPlatform(t, "win32");
  assert.equal(resolveDefaultIpcSocketPath(), "\\\\.\\pipe\\codex-ipc");
});

test("desktop IPC follower tries the legacy candidate after the current socket fails", async (t) => {
  const { tempDir, socketPath: legacySocketPath } = createIpcTestSocket("remodex-ipc-legacy-fallback-");
  const currentSocketPath = path.join(tempDir, "missing-current.sock");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "legacy-follower" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(legacySocketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath: () => [currentSocketPath, legacySocketPath],
    sendApplicationResponse() {},
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-legacy-fallback" },
  }));

  await waitFor(() => serverSocket);
  assert.ok(serverSocket);
});

test("desktop IPC follower projects first add patch-only action updates without a baseline read", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-recovery-");
  let baselineReads = 0;
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    async readConversationState() {
      baselineReads += 1;
      await wait(30);
      return { requests: [] };
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-patch" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-patch",
      change: {
        type: "patches",
        patches: [{
          op: "add",
          path: ["requests", 0],
          value: {
            id: "req-patch",
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-patch",
              turnId: "turn-patch",
              itemId: "item-patch",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          },
        }],
      },
    },
  });
  await wait(25);

  assert.equal(baselineReads, 0);
  assert.equal(outbound[0].id, "req-patch");
  assert.equal(outbound[0].method, "item/tool/requestUserInput");
});

test("desktop IPC follower projects a request patch after restart before the phone rereads the thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-restart-action-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-restarted" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  // A sidebar refresh connects the restarted bridge, but intentionally does
  // not mark this already-open phone thread active via thread/read or resume.
  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-following-changed",
    sourceClientId: "desktop",
    version: 1,
    params: {
      conversationId: "thread-open-before-restart",
      following: true,
    },
  });
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-open-before-restart",
      change: {
        type: "patches",
        patches: [{
          op: "add",
          path: ["requests", 0],
          value: {
            id: 50,
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-open-before-restart",
              turnId: "turn-after-restart",
              questions: [{
                id: "restart_question",
                header: "Restart",
                question: "Does the question survive a bridge restart?",
                options: [{ label: "Yes", description: "It does." }],
              }],
            },
          },
        }],
      },
    },
  });

  await waitFor(() => outbound.some((message) => message.id === 50));
  const prompt = outbound.find((message) => message.id === 50);
  assert.equal(prompt.method, "item/tool/requestUserInput");
  assert.equal(prompt.params.questions[0].id, "restart_question");
});

test("desktop IPC follower uses baseline recovery for patch-only updates that need existing state", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-replace-recovery-");
  let baselineReads = 0;
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    async readConversationState() {
      baselineReads += 1;
      return {
        requests: [{
          id: "req-recovered",
          method: "item/tool/requestUserInput",
          completed: true,
          params: {
            threadId: "thread-replace",
            turnId: "turn-replace",
            itemId: "item-replace",
            questions: [{ id: "q1", question: "Continue?" }],
          },
        }],
      };
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-replace" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-replace",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["requests", 0, "completed"],
          value: false,
        }],
      },
    },
  });
  await wait(40);

  assert.equal(baselineReads, 1);
  assert.equal(outbound[0].id, "req-recovered");
  assert.equal(outbound[0].method, "item/tool/requestUserInput");
});

test("desktop IPC follower does not issue baseline reads just because a chat opens", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-lazy-recovery-");
  let baselineReads = 0;
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    async readConversationState() {
      baselineReads += 1;
      return { requests: [] };
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-open" },
  }));
  await waitFor(() => serverSocket);
  await wait(40);

  assert.equal(baselineReads, 0);
});

test("desktop IPC follower waits for a usable snapshot when a first patch needs missing state", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-wait-snapshot-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-wait-snapshot" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-wait-snapshot",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["requests", 0, "completed"],
          value: false,
        }],
      },
    },
  });
  await wait(25);
  assert.equal(outbound.length, 0);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-wait-snapshot",
      change: {
        type: "snapshot",
        conversationState: {
          requests: [{
            id: "req-after-snapshot",
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-wait-snapshot",
              turnId: "turn-after-snapshot",
              itemId: "item-after-snapshot",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          }],
        },
      },
    },
  });
  await wait(25);

  assert.equal(outbound[0].id, "req-after-snapshot");
  assert.equal(outbound[0].method, "item/tool/requestUserInput");
});

test("desktop IPC follower does not block add patch-only actions on a failing baseline reader", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-recovery-fallback-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (message) => warnings.push(String(message));
  t.after(() => {
    console.warn = originalWarn;
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    async readConversationState() {
      throw new Error("Codex request timed out: thread/read");
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-patch-fallback" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-patch-fallback",
      change: {
        type: "patches",
        patches: [{
          op: "add",
          path: ["requests", 0],
          value: {
            id: "req-fallback",
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-patch-fallback",
              turnId: "turn-fallback",
              itemId: "item-fallback",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          },
        }],
      },
    },
  });
  await wait(40);

  assert.equal(outbound[0].id, "req-fallback");
  assert.equal(outbound[0].method, "item/tool/requestUserInput");
  assert.equal(warnings.length, 0);
});

test("desktop IPC follower answers client discovery requests as a passive client", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-discovery-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-discovery" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "client-discovery-request",
    requestId: "discovery-1",
    request: {
      requestId: "inner-1",
      sourceClientId: "desktop",
      version: 1,
      method: "thread-follower-start-turn",
      params: {},
    },
  });
  await wait(25);

  const discoveryResponse = serverFrames.find((frame) => frame.type === "client-discovery-response");
  assert.deepEqual(discoveryResponse, {
    type: "client-discovery-response",
    requestId: "discovery-1",
    response: {
      canHandle: false,
    },
  });
});

test("desktop IPC follower forwards pending actions and routes iOS replies back to the Mac", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-submit-user-input") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { ok: true },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-live" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-live",
      change: {
        type: "snapshot",
        conversationState: {
          requests: [{
            id: "req-live",
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-live",
              turnId: "turn-live",
              itemId: "item-live",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          }],
        },
      },
    },
  });
  await wait(25);

  assert.equal(outbound[0].id, "req-live");
  assert.equal(outbound[0].method, "item/tool/requestUserInput");

  follower.observeInbound(JSON.stringify({
    id: "req-live",
    result: {
      answers: {
        q1: { answers: ["Yes"] },
      },
    },
  }));
  await wait(25);

  const replyFrame = serverFrames.find((frame) => frame.method === "thread-follower-submit-user-input");
  assert.deepEqual(replyFrame.params, {
    conversationId: "thread-live",
    requestId: "req-live",
    response: {
      answers: {
        q1: { answers: ["Yes"] },
      },
    },
  });
});

test("desktop IPC follower keeps projected actions pending across IPC disconnects", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-disconnect-action-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-action-disconnect" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-action-disconnect",
      change: {
        type: "snapshot",
        conversationState: {
          requests: [{
            id: "req-action-disconnect",
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-action-disconnect",
              turnId: "turn-action-disconnect",
              itemId: "item-action-disconnect",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          }],
        },
      },
    },
  });
  await waitFor(() => outbound.find((message) => message.id === "req-action-disconnect"));

  const previousSocket = serverSocket;
  serverSocket = null;
  previousSocket.destroy();

  // A transient disconnect proves nothing about the prompt's outcome, so the
  // phone-side approval must stay open instead of being falsely resolved.
  await wait(150);
  assert.equal(
    outbound.some((message) => message.method === "serverRequest/resolved"
      && message.params?.requestId === "req-action-disconnect"),
    false
  );

  // Reconnect and deliver a snapshot where the prompt is gone: only now does the
  // follower resolve it, tagged as a Desktop mirror event.
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-action-disconnect" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-action-disconnect",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await waitFor(
    () => outbound.find((message) => message.method === "serverRequest/resolved"
      && message.params?.requestId === "req-action-disconnect"),
    1_000
  );
  const resolved = outbound.find((message) => message.method === "serverRequest/resolved"
    && message.params?.requestId === "req-action-disconnect");
  assert.deepEqual(resolved, {
    method: "serverRequest/resolved",
    params: {
      threadId: "thread-action-disconnect",
      requestId: "req-action-disconnect",
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
      remodexActionSource: "desktop-ipc-action-follower",
    },
  });
});

test("desktop IPC follower routes phone turns to Desktop-owned threads", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-turn-start-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method?.startsWith("thread-follower-")) {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: frame.method === "thread-follower-start-turn"
            ? { result: { turn: { id: "turn-from-phone" } } }
            : { turn: { id: "turn-from-phone" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const runtimeCommits = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    runtimeSettingsStore: {
      get() {
        return null;
      },
      commit(threadId, params, metadata) {
        runtimeCommits.push({ threadId, params, metadata });
        return null;
      },
      attachToConversation() {},
    },
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-desktop-owned" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-desktop-owned",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
        },
      },
    },
  });
  await wait(25);

  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-1",
    method: "turn/start",
    params: {
      threadId: "thread-desktop-owned",
      input: [{ type: "input_text", text: "continue from phone" }],
      cwd: "/repo",
      model: "gpt-test",
      effort: "low",
      serviceTier: "fast",
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-update-thread-settings"));
  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"));
  const settingsFrame = serverFrames.find((frame) => frame.method === "thread-follower-update-thread-settings");
  const turnStartFrame = serverFrames.find((frame) => frame.method === "thread-follower-start-turn");
  assert.deepEqual(settingsFrame.params, {
    conversationId: "thread-desktop-owned",
    threadSettings: {
      model: "gpt-test",
      effort: "low",
      serviceTier: "fast",
    },
  });
  assert.ok(
    serverFrames.indexOf(settingsFrame) < serverFrames.indexOf(turnStartFrame),
    "Desktop runtime settings must settle before start-turn"
  );
  assert.equal(turnStartFrame.version, 2);
  assert.deepEqual(turnStartFrame.params, {
    conversationId: "thread-desktop-owned",
    turnStart: {
      request: {
        threadId: "thread-desktop-owned",
        input: [{ type: "input_text", text: "continue from phone" }],
        cwd: "/repo",
        model: "gpt-test",
        effort: "low",
        serviceTier: "fast",
        clientUserMessageId: "phone-turn-start-1",
      },
      context: {
        inheritThreadSettings: true,
      },
    },
  });

  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-1"));
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-1"), {
    id: "phone-turn-start-1",
    result: { turn: { id: "turn-from-phone" } },
  });
  assert.deepEqual(runtimeCommits, [{
    threadId: "thread-desktop-owned",
    params: {
      threadId: "thread-desktop-owned",
      input: [{ type: "input_text", text: "continue from phone" }],
      cwd: "/repo",
      model: "gpt-test",
      effort: "low",
      serviceTier: "fast",
    },
    metadata: {
      source: "phone",
      turnId: "turn-from-phone",
    },
  }]);

  const routedRequests = [
    {
      id: "phone-steer-1",
      method: "turn/steer",
      params: {
        threadId: "thread-desktop-owned",
        input: [{ type: "input_text", text: "steer from phone" }],
        expectedTurnId: "turn-from-phone",
      },
      expectedMethod: "thread-follower-steer-turn",
      expectedParams: {
        conversationId: "thread-desktop-owned",
        input: [{ type: "input_text", text: "steer from phone" }],
        expectedTurnId: "turn-from-phone",
      },
    },
    {
      id: "phone-interrupt-1",
      method: "turn/interrupt",
      params: {
        threadId: "thread-desktop-owned",
        turnId: "turn-from-phone",
      },
      expectedMethod: "thread-follower-interrupt-turn",
      expectedParams: {
        conversationId: "thread-desktop-owned",
        mode: "user-stop",
        expectedTurnId: "turn-from-phone",
      },
    },
    {
      id: "phone-compact-1",
      method: "thread/compact/start",
      params: {
        threadId: "thread-desktop-owned",
      },
      expectedMethod: "thread-follower-compact-thread",
      expectedParams: {
        conversationId: "thread-desktop-owned",
      },
    },
  ];

  for (const request of routedRequests) {
    const handledRoute = follower.observeInbound(JSON.stringify({
      id: request.id,
      method: request.method,
      params: request.params,
    }));
    assert.equal(handledRoute, true);
    await waitFor(() => serverFrames.find((frame) => frame.method === request.expectedMethod));
    const routedFrame = serverFrames.find((frame) => frame.method === request.expectedMethod);
    // Versions mirror Codex Desktop's bundled method map (interrupt is v4).
    assert.equal(
      routedFrame.version,
      request.expectedMethod === "thread-follower-interrupt-turn" ? 4 : 1
    );
    assert.deepEqual(routedFrame.params, request.expectedParams);
    await waitFor(() => outbound.find((message) => message.id === request.id));
    assert.deepEqual(outbound.find((message) => message.id === request.id), {
      id: request.id,
      result: { turn: { id: "turn-from-phone" } },
    });
  }

  const serverFrameCountBeforeUnsupportedMutations = serverFrames.length;
  const unsupportedMutations = [
    {
      id: "phone-guardian-retry-1",
      method: "thread/approveGuardianDeniedAction",
      params: { event: { id: "review-1", status: "denied" } },
      message: "Approve this retry in Codex Desktop.",
    },
    {
      id: "phone-review-start-1",
      method: "review/start",
      params: { target: { type: "uncommittedChanges" } },
      message: "Start this review in Codex Desktop.",
    },
    {
      id: "phone-settings-update-1",
      method: "thread/settings/update",
      params: { approvalsReviewer: "auto_review" },
      message: "Change these thread settings in Codex Desktop.",
    },
  ];
  for (const mutation of unsupportedMutations) {
    const handled = follower.observeInbound(JSON.stringify({
      id: mutation.id,
      method: mutation.method,
      params: {
        threadId: "thread-desktop-owned",
        ...mutation.params,
      },
    }));
    assert.equal(handled, true);
    assert.deepEqual(outbound.find((message) => message.id === mutation.id), {
      id: mutation.id,
      error: {
        code: -32004,
        message: mutation.message,
      },
    });
  }
  assert.equal(serverFrames.length, serverFrameCountBeforeUnsupportedMutations);
});

test("desktop IPC follower falls back locally when no Desktop client can handle the request", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-local-fallback-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        // Router-style no-handler error: the request never reached any client,
        // so retrying it locally is safe.
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "error",
          method: frame.method,
          handledByClientId: "",
          error: "No Codex IPC client can handle thread-follower-start-turn.",
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-route-fallback" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-route-fallback",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-route-fallback",
    method: "turn/start",
    params: {
      threadId: "thread-route-fallback",
      input: [{ type: "input_text", text: "continue locally after failure" }],
    },
  }));
  assert.equal(handled, true);
  await waitFor(() => localForwards.length === 1);
  assert.equal(localForwards[0].id, "phone-turn-start-route-fallback");
  assert.equal(localForwards[0].method, "turn/start");
  assert.equal(outbound.some((message) => message.id === "phone-turn-start-route-fallback"), false);

  const handledAgain = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-route-fallback-2",
    method: "turn/start",
    params: {
      threadId: "thread-route-fallback",
      input: [{ type: "input_text", text: "stay local" }],
    },
  }));
  assert.equal(handledAgain, false);
  assert.equal(
    serverFrames.filter((frame) => frame.method === "thread-follower-start-turn").length,
    1
  );
});

test("desktop IPC follower falls back locally when Desktop settings sync times out before turn delivery", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-settings-timeout-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
      // Model an inactive/stale Desktop owner: the router accepts the settings
      // request, but no renderer answers it before the bridge timeout.
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 100,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-settings-timeout" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-settings-timeout",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-settings-timeout",
    method: "turn/start",
    params: {
      threadId: "thread-settings-timeout",
      input: [{ type: "input_text", text: "continue despite stale Desktop owner" }],
      model: "gpt-test",
      effort: "low",
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => localForwards.length === 1, 1_000);
  assert.equal(localForwards[0].id, "phone-turn-start-settings-timeout");
  assert.equal(localForwards[0].method, "turn/start");
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false,
    "the Desktop turn must not be sent after settings sync times out"
  );
  assert.equal(
    outbound.some((message) => message.id === "phone-turn-start-settings-timeout"),
    false,
    "the local app-server owns the eventual response"
  );
});

test("desktop IPC follower does not rerun ambiguous Desktop failures locally", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-ambiguous-error-");
  const localForwards = [];
  let serverSocket = null;
  let respondWithTimeout = false;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn" && !respondWithTimeout) {
        // Explicit Desktop-side error: the request reached the owner, so the
        // bridge must not rerun the same turn on the local app-server.
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "error",
          method: frame.method,
          handledByClientId: "desktop",
          error: "Desktop rejected the turn",
        });
      }
      // When respondWithTimeout is set, never answer so the request times out.
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 150,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-ambiguous-error" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-ambiguous-error",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-desktop-error",
    method: "turn/start",
    params: {
      threadId: "thread-ambiguous-error",
      input: [{ type: "input_text", text: "explicit desktop error" }],
    },
  }));
  assert.equal(handled, true);
  await waitFor(() => outbound.some((message) => message.id === "phone-turn-start-desktop-error"));
  const errorResponse = outbound.find((message) => message.id === "phone-turn-start-desktop-error");
  assert.equal(errorResponse.error.code, -32000);
  assert.deepEqual(localForwards, []);

  respondWithTimeout = true;
  const handledTimeout = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-desktop-timeout",
    method: "turn/start",
    params: {
      threadId: "thread-ambiguous-error",
      input: [{ type: "input_text", text: "desktop timeout" }],
    },
  }));
  assert.equal(handledTimeout, true);
  await waitFor(() => outbound.some((message) => message.id === "phone-turn-start-desktop-timeout"), 1_000);
  const timeoutResponse = outbound.find((message) => message.id === "phone-turn-start-desktop-timeout");
  assert.equal(timeoutResponse.error.code, -32000);
  assert.deepEqual(localForwards, []);
});

test("desktop IPC follower mirrors live assistant text growth from desktop state", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-assistant-delta-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-live-delta" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-live-delta",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-live-delta",
            status: "inProgress",
            items: [{
              id: "assistant-live-delta",
              type: "assistant_message",
              text: "Hello",
            }],
          }],
        },
      },
    },
  });
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-live-delta",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "items", 0, "text"],
          value: "Hello world",
        }],
      },
    },
  });

  await waitFor(() => outbound.find((message) => message.method === "item/agentMessage/delta"));
  const deltaMessage = outbound.find((message) => message.method === "item/agentMessage/delta");
  assert.equal(deltaMessage.params.threadId, "thread-live-delta");
  assert.equal(deltaMessage.params.turnId, "turn-live-delta");
  assert.equal(deltaMessage.params.itemId, "assistant-live-delta");
  assert.equal(deltaMessage.params.delta, " world");
  assert.equal(deltaMessage.params.remodexDesktopMirror, true);
  assert.equal(deltaMessage.params.remodexDesktopIpcMirror, true);
});

test("desktop IPC follower discovers running sidebar threads before the phone opens them", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-running-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  // The sidebar asks for the list, but it never reads either individual chat.
  follower.observeInbound(JSON.stringify({
    id: "sidebar-list",
    method: "thread/list",
    params: {},
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-idle-unopened",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{ id: "turn-idle", status: "completed", items: [] }],
          requests: [],
        },
      },
    },
  });
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-running-unopened",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-running-unopened",
            status: "inProgress",
            items: [{
              id: "assistant-running-unopened",
              type: "assistant_message",
              text: "Working",
            }],
          }],
          requests: [],
        },
      },
    },
  });
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-normalized-running-unopened",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-normalized-running",
            status: "inProgress",
            items: [],
          }],
          requests: [],
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-normalized-idle": {
                  turnId: "turn-normalized-idle",
                  status: "completed",
                  items: [],
                },
                "turn:turn-normalized-parallel-older": {
                  turnId: "turn-normalized-parallel-older",
                  status: "inProgress",
                  items: [],
                },
                "turn:turn-normalized-running": {
                  turnId: "turn-normalized-running",
                  status: "inProgress",
                  items: [],
                },
              },
              islands: [{
                id: "tail:1",
                entries: [
                  { key: "turn:turn-normalized-idle", value: "turn:turn-normalized-idle" },
                  {
                    key: "turn:turn-normalized-parallel-older",
                    value: "turn:turn-normalized-parallel-older",
                  },
                  { key: "turn:turn-normalized-running", value: "turn:turn-normalized-running" },
                ],
              }],
              generation: 1,
              isComplete: true,
            },
          },
        },
      },
    },
  });

  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === "thread-running-unopened"
  )));
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === "thread-normalized-running-unopened"
      && message.params?.turnId === "turn-normalized-running"
  )));
  assert.equal(
    outbound.some((message) => message.params?.threadId === "thread-idle-unopened"),
    false,
    "idle unopened snapshots should stay local to the bridge"
  );
  assert.equal(
    outbound.some((message) => message.method === "item/completed"),
    false,
    "background discovery must not replay historical transcript items"
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-normalized-idle-stale",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "idle", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-ancient-null-duration": {
                  turnId: "turn-ancient-null-duration",
                  turnStartedAtMs: 1,
                  durationMs: null,
                  status: "inProgress",
                  items: [],
                },
                "turn:turn-latest-completed": {
                  turnId: "turn-latest-completed",
                  status: "completed",
                  items: [],
                },
              },
              islands: [{
                id: "tail:1",
                entries: [
                  {
                    key: "turn:turn-ancient-null-duration",
                    value: "turn:turn-ancient-null-duration",
                  },
                  { key: "turn:turn-latest-completed", value: "turn:turn-latest-completed" },
                ],
              }],
              generation: 1,
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await wait(50);
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/started"
        && message.params?.threadId === "thread-normalized-idle-stale"
    )),
    false,
    "idle background discovery must not resurrect a stale null-duration turn"
  );
  assert.equal(follower.hasLiveThreadState("thread-normalized-idle-stale"), true);
  const idleOpenHandled = follower.observeInbound(JSON.stringify({
    id: "open-normalized-idle-stale",
    method: "thread/turns/list",
    params: { threadId: "thread-normalized-idle-stale", limit: 1 },
  }));
  assert.equal(idleOpenHandled, false);
  assert.equal(
    outbound.some((message) => message.id === "open-normalized-idle-stale"),
    false
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-normalized-running-unopened",
      change: {
        type: "patches",
        patches: [
          {
            op: "replace",
            path: ["turns", 0, "status"],
            value: "completed",
          },
          {
            op: "replace",
            path: [
              "turnHistory",
              "history",
              "entitiesByKey",
              "turn:turn-normalized-parallel-older",
              "status",
            ],
            value: "completed",
          },
          {
            op: "replace",
            path: [
              "turnHistory",
              "history",
              "entitiesByKey",
              "turn:turn-normalized-running",
              "status",
            ],
            value: "completed",
          },
        ],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-normalized-running-unopened"
      && message.params?.turnId === "turn-normalized-running"
  )));

  // The idle snapshot is retained inside the bridge, so a later Mac-started
  // run is still discovered without any per-thread read from the phone.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-idle-unopened",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "status"],
          value: "inProgress",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === "thread-idle-unopened"
  )));
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-idle-unopened",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "status"],
          value: "completed",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-idle-unopened"
  )));

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-running-unopened",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "items", 0, "text"],
          value: "Working still",
        }],
      },
    },
  });

  await wait(25);
  assert.equal(
    outbound.some((message) => (
      message.method === "item/agentMessage/delta"
        && message.params?.threadId === "thread-running-unopened"
    )),
    false,
    "an unopened running chat should remain lifecycle-only"
  );

  const readHandled = follower.observeInbound(JSON.stringify({
    id: "open-running-thread",
    method: "thread/read",
    params: { threadId: "thread-running-unopened" },
  }));
  assert.equal(readHandled, true);
  assert.equal(
    outbound.find((message) => message.id === "open-running-thread")
      ?.result?.thread?.turns?.[0]?.items?.[0]?.text,
    "Working still"
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-running-unopened",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "items", 0, "text"],
          value: "Working still after open",
        }],
      },
    },
  });

  await waitFor(() => outbound.some((message) => (
    message.method === "item/agentMessage/delta"
      && message.params?.threadId === "thread-running-unopened"
      && message.params?.delta === " after open"
  )));
});

test("desktop IPC follower settles an announced background turn after reconnect", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-reconnect-");
  let serverSocket = null;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-reconnect",
    "inProgress",
    { turnId: "turn-background-reconnect" }
  ));
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === "thread-background-reconnect"
  )));

  const disconnectedSocket = serverSocket;
  disconnectedSocket.destroy();
  await wait(25);
  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket && serverSocket !== disconnectedSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-reconnect",
    "completed",
    { turnId: "turn-background-reconnect" }
  ));

  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-reconnect"
  )));
  await wait(275);
  const completions = outbound.filter((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-reconnect"
  ));
  assert.equal(completions.length, 1);
  assert.equal(completions[0].params.status, "completed");
});

test("desktop IPC follower re-announces a still-running background turn on sidebar refresh", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-reannounce-");
  let serverSocket = null;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  let currentTime = 1_700_000_000_000;
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
    now: () => currentTime,
  });
  t.after(() => follower.stopAll());

  const threadStarts = () => outbound.filter((message) => (
    message.method === "turn/started"
      && message.params?.threadId === "thread-background-reannounce"
  ));
  const refreshSidebar = () => follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));

  refreshSidebar();
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-reannounce",
    "inProgress",
    { turnId: "turn-background-reannounce" }
  ));
  await waitFor(() => threadStarts().length === 1);

  // A phone that connected after the run began learns about it here.
  refreshSidebar();
  await waitFor(() => threadStarts().length === 2);
  const reannounced = threadStarts()[1];
  assert.equal(reannounced.params.turnId, "turn-background-reannounce");
  assert.equal(reannounced.params.remodexTurnIdentityContinuity, true);
  assert.equal(reannounced.params.remodexBackgroundDiscovery, true);

  refreshSidebar();
  await wait(25);
  assert.equal(threadStarts().length, 2, "refreshes inside the throttle window must not duplicate");

  currentTime += 31_000;
  refreshSidebar();
  await waitFor(() => threadStarts().length === 3);

  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-reannounce",
    "completed",
    { turnId: "turn-background-reannounce" }
  ));
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-reannounce"
  )));

  currentTime += 31_000;
  refreshSidebar();
  await wait(25);
  assert.equal(threadStarts().length, 3, "a settled turn must not be re-announced");
});

test("desktop IPC follower keeps announced background turns running through an IPC disconnect", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-disconnect-");
  let serverSocket = null;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-disconnect",
    "inProgress",
    { turnId: "turn-background-disconnect" }
  ));
  await waitFor(() => outbound.some((message) => message.method === "turn/started"));
  const disconnectedSocket = serverSocket;
  disconnectedSocket.destroy();

  await wait(75);
  assert.equal(outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-disconnect"
  )), false, "transport loss alone must not synthesize an interrupted turn");

  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket && serverSocket !== disconnectedSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-disconnect",
    "completed",
    { turnId: "turn-background-disconnect" }
  ));
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-disconnect"
  )));
  const completions = outbound.filter((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-disconnect"
  ));
  assert.equal(completions.length, 1);
  assert.equal(completions[0].params.status, "completed");
});

test("desktop IPC follower settles a running background thread before archive", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-archive-");
  let serverSocket = null;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-archive",
    "inProgress",
    { turnId: "turn-background-archive" }
  ));
  await waitFor(() => outbound.some((message) => message.method === "turn/started"));
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-archived",
    sourceClientId: "desktop",
    version: 2,
    params: { conversationId: "thread-background-archive" },
  });
  await waitFor(() => outbound.some((message) => message.method === "thread/archived"));

  const completionIndex = outbound.findIndex((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-archive"
  ));
  const archiveIndex = outbound.findIndex((message) => message.method === "thread/archived");
  assert.ok(completionIndex >= 0 && completionIndex < archiveIndex);
  assert.equal(outbound[completionIndex].params.status, "interrupted");
});

test("desktop IPC follower does not evict an announced background turn", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-lru-");
  let serverSocket = null;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-lru-protected",
    "inProgress",
    { turnId: "turn-background-lru-protected" }
  ));
  await waitFor(() => outbound.some((message) => message.method === "turn/started"));

  for (let index = 0; index < 512; index += 1) {
    writeFrame(serverSocket, backgroundConversationSnapshot(
      `thread-background-lru-idle-${index}`,
      "completed",
      { turnId: `turn-background-lru-idle-${index}` }
    ));
  }
  await wait(75);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-background-lru-protected",
      change: {
        type: "patches",
        patches: [{ op: "replace", path: ["turns", 0, "status"], value: "completed" }],
      },
    },
  });

  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-background-lru-protected"
  )));
});

test("desktop IPC background recovery stays lifecycle-only until open", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-background-recovery-");
  let serverSocket = null;
  const baseline = {
    turns: [{
      status: "inProgress",
      items: [{ id: "assistant-background-recovery", type: "assistant_message", text: "A" }],
    }],
    requests: [],
  };
  let readAttempts = 0;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    async readConversationState() {
      readAttempts += 1;
      return structuredClone(baseline);
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, backgroundConversationSnapshot(
    "thread-background-recovery",
    "inProgress",
    { items: [] }
  ));
  await waitFor(() => outbound.some((message) => message.method === "turn/started"));
  const started = outbound.find((message) => message.method === "turn/started");
  assert.equal(started.params.turnId, "ipc-turn-0");

  const disconnectedSocket = serverSocket;
  disconnectedSocket.destroy();
  await wait(25);
  follower.observeInbound(JSON.stringify({ method: "thread/list", params: {} }));
  await waitFor(() => serverSocket && serverSocket !== disconnectedSocket);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "thread-background-recovery",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "items", 0, "text"],
          value: "AB",
        }],
      },
    },
  });
  await waitFor(() => readAttempts === 1);
  await wait(25);
  assert.equal(
    outbound.some((message) => message.method === "item/agentMessage/delta"),
    false
  );

  const handled = follower.observeInbound(JSON.stringify({
    id: "open-background-recovery",
    method: "thread/read",
    params: { threadId: "thread-background-recovery" },
  }));
  assert.equal(handled, true);
  const read = outbound.find((message) => message.id === "open-background-recovery");
  assert.equal(read.result.thread.turns[0].id, "ipc-turn-0");
  assert.equal(read.result.thread.turns[0].items[0].text, "AB");

  const handledResume = follower.observeInbound(JSON.stringify({
    id: "resume-background-recovery",
    method: "thread/resume",
    params: { threadId: "thread-background-recovery" },
  }));
  assert.equal(handledResume, true);
  const resume = outbound.find((message) => message.id === "resume-background-recovery");
  assert.equal(resume.result.remodexDesktopIpcMirror, true);
});

test("desktop IPC follower normalizes phone turn starts before Desktop follower requests", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-follower-normalize-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { ok: true },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    normalizeTurnStartParams(params) {
      return { ...params, summary: "none" };
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-normalize" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-normalize",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-normalize",
    method: "turn/start",
    params: {
      threadId: "thread-normalize",
      input: [{ type: "input_text", text: "continue" }],
      summary: "auto",
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"));
  const turnStartFrame = serverFrames.find((frame) => frame.method === "thread-follower-start-turn");
  assert.deepEqual(turnStartFrame.params.turnStart.request, {
    threadId: "thread-normalize",
    input: [{ type: "input_text", text: "continue" }],
    summary: "none",
    clientUserMessageId: "phone-turn-start-normalize",
  });
  assert.deepEqual(turnStartFrame.params.turnStart.context, {
    inheritThreadSettings: true,
  });
});

test("desktop IPC follower releases desktop state when the live owner claims a thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-owner-release-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-released" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-released",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-released",
      remodexOwnerSource: "desktop-ipc-live-owner",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-released",
    method: "turn/start",
    params: {
      threadId: "thread-released",
      input: [{ type: "input_text", text: "continue locally" }],
    },
  }));
  assert.equal(handled, false);
  await wait(25);
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false
  );
});

test("desktop IPC follower keeps held turns queued across a transient IPC disconnect", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-hold-disconnect-");
  const serverFrames = [];
  const localForwards = [];
  const outbound = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-after-reconnect" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 600,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-hold-disconnect" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-hold-disconnect",
    method: "turn/start",
    params: {
      threadId: "thread-hold-disconnect",
      input: [{ type: "input_text", text: "survive the drop" }],
    },
  }));
  assert.equal(handled, true);

  // Drop the IPC connection while the turn is still held: it must stay queued
  // instead of running locally on unproven ownership.
  await waitFor(() => serverSocket);
  const firstSocket = serverSocket;
  serverSocket = null;
  firstSocket.destroy();
  await wait(50);
  assert.deepEqual(localForwards, []);

  // At the hold deadline the request routes through the bus over a reconnect.
  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"), 2_000);
  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-hold-disconnect"), 1_000);
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-hold-disconnect"), {
    id: "phone-turn-start-hold-disconnect",
    result: { turn: { id: "turn-after-reconnect" } },
  });
  assert.deepEqual(localForwards, []);
});

test("desktop IPC follower keeps live owner routing guard across IPC disconnects", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-owner-disconnect-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-owner-disconnect" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-owner-disconnect",
      remodexOwnerSource: "desktop-ipc-live-owner",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);
  serverSocket.destroy();
  await wait(25);

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-owner-disconnect" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-owner-disconnect",
    method: "turn/start",
    params: {
      threadId: "thread-owner-disconnect",
      input: [{ type: "input_text", text: "stay local after disconnect" }],
    },
  }));
  assert.equal(handled, false);
  assert.deepEqual(localForwards, []);
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false
  );
});

test("desktop IPC follower accepts peer ownership snapshots before a phone resume", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-peer-snapshot-before-resume-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.type === "client-discovery-request") {
        writeFrame(socket, {
          type: "client-discovery-response",
          requestId: frame.requestId,
          response: { canHandle: true },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-peer-snapshot" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex() {},
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 2_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-other-active" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-peer-before-resume",
      remodexOwnerSource: "desktop-ipc-live-owner",
      change: { type: "snapshot", conversationState: { turns: [], requests: [] } },
    },
  });
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-owner",
    version: 6,
    params: {
      conversationId: "thread-peer-before-resume",
      change: { type: "snapshot", conversationState: { turns: [], requests: [] } },
    },
  });
  await wait(25);

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-peer-before-resume" },
  }));
  assert.equal(follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-peer-before-resume",
    method: "turn/start",
    params: {
      threadId: "thread-peer-before-resume",
      input: [{ type: "input_text", text: "desktop owns now" }],
    },
  })), true);

  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"), 1_000);
  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-peer-before-resume"), 1_000);
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-peer-before-resume"), {
    id: "phone-turn-start-peer-before-resume",
    result: { turn: { id: "turn-peer-snapshot" } },
  });
});

test("desktop IPC follower ignores peer patches while the live owner owns a thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-ignore-peer-patch-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-ignore-peer-patch" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-ignore-peer-patch",
      remodexOwnerSource: "desktop-ipc-live-owner",
      change: { type: "snapshot", conversationState: { turns: [], requests: [] } },
    },
  });
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-patch",
    version: 6,
    params: {
      conversationId: "thread-ignore-peer-patch",
      change: {
        type: "patches",
        patches: [{
          op: "add",
          path: ["requests", 0],
          value: {
            id: "req-peer-patch",
            method: "item/fileChange/requestApproval",
            params: {
              threadId: "thread-ignore-peer-patch",
              turnId: "turn-peer-patch",
              itemId: "item-peer-patch",
            },
          },
        }],
      },
    },
  });
  await wait(25);

  assert.equal(follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-ignore-peer-patch",
    method: "turn/start",
    params: {
      threadId: "thread-ignore-peer-patch",
      input: [{ type: "input_text", text: "stay with live owner" }],
    },
  })), false);
  await wait(25);
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false
  );
});

test("desktop IPC follower ignores Desktop echoes for locally owned threads", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-local-owner-echo-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    requestTimeoutMs: 500,
    // Simulates the bridge's live owner claiming the thread before any
    // live-owner broadcast has been observed on this socket.
    isLocallyOwnedThread: (threadId) => threadId === "thread-local-echo",
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-local-echo" },
  }));
  await waitFor(() => serverSocket);

  // An untagged Desktop snapshot of the locally-streamed thread must not become
  // follower state that would shadow the app-server for reads.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-echo",
    version: 6,
    params: {
      conversationId: "thread-local-echo",
      change: { type: "snapshot", conversationState: { turns: [], requests: [] } },
    },
  });
  await wait(25);

  assert.equal(follower.hasLiveThreadState("thread-local-echo"), false);
});

test("desktop IPC follower holds quick phone turns until the desktop snapshot arrives", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-hold-turn-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-held" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 400,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-held" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-held",
    method: "turn/start",
    params: {
      threadId: "thread-held",
      input: [{ type: "input_text", text: "continue quickly" }],
    },
  }));
  assert.equal(handled, true);
  assert.deepEqual(localForwards, []);

  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 6,
    params: {
      conversationId: "thread-held",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });

  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"));
  const turnStartFrame = serverFrames.find((frame) => frame.method === "thread-follower-start-turn");
  assert.equal(turnStartFrame.params.conversationId, "thread-held");
  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-held"));
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-held"), {
    id: "phone-turn-start-held",
    result: { turn: { id: "turn-held" } },
  });
  assert.deepEqual(localForwards, []);
});

test("desktop IPC follower routes held phone turns once discovery confirms desktop ownership", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-probe-owned-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.type === "client-discovery-request") {
        // Codex Desktop only invokes handlers when the nested request version
        // matches the method version, so a missing version must read as false.
        writeFrame(socket, {
          type: "client-discovery-response",
          requestId: frame.requestId,
          response: { canHandle: frame.request?.version === 2 },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { result: { turn: { id: "turn-probe-owned" } } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 2_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-probe-owned" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-probe",
    method: "turn/start",
    params: {
      threadId: "thread-probe-owned",
      input: [{ type: "input_text", text: "route via probe" }],
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"), 1_000);
  const turnStartFrame = serverFrames.find((frame) => frame.method === "thread-follower-start-turn");
  assert.equal(turnStartFrame.params.conversationId, "thread-probe-owned");
  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-probe"));
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-probe"), {
    id: "phone-turn-start-probe",
    result: { turn: { id: "turn-probe-owned" } },
  });
  assert.deepEqual(localForwards, []);
});

test("desktop IPC follower coalesces duplicate held turn starts for a thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-held-turn-coalesce-");
  const serverFrames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.type === "client-discovery-request") {
        writeFrame(socket, {
          type: "client-discovery-response",
          requestId: frame.requestId,
          response: { canHandle: true },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-coalesced" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex() {
      assert.fail("duplicate held turn/start should not fall back locally");
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 2_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-held-coalesce" },
  }));
  assert.equal(follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-coalesce-old",
    method: "turn/start",
    params: {
      threadId: "thread-held-coalesce",
      input: [{ type: "input_text", text: "old duplicate" }],
    },
  })), true);
  assert.equal(follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-coalesce-new",
    method: "turn/start",
    params: {
      threadId: "thread-held-coalesce",
      input: [{ type: "input_text", text: "new duplicate" }],
    },
  })), true);

  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-coalesce-old"), 1_000);
  assert.equal(outbound.find((message) => message.id === "phone-turn-start-coalesce-old").error?.code, -32000);
  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-coalesce-new"), 1_000);
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-coalesce-new"), {
    id: "phone-turn-start-coalesce-new",
    result: { turn: { id: "turn-coalesced" } },
  });
  const routedStarts = serverFrames.filter((frame) => frame.method === "thread-follower-start-turn");
  assert.equal(routedStarts.length, 1);
  assert.equal(routedStarts[0].params.turnStart.request.input[0].text, "new duplicate");
});

test("desktop IPC follower retries held ownership probes after IPC connects", async (t) => {
  const outbound = [];
  const localForwards = [];
  const writtenFrames = [];
  let fakeSocket = null;

  const netModule = {
    createConnection() {
      fakeSocket = new EventEmitter();
      fakeSocket.destroyed = true;
      fakeSocket.write = (buffer, callback = () => {}) => {
        const frame = parseFrameBuffer(buffer);
        writtenFrames.push(frame);
        callback();
        if (frame.method === "initialize") {
          setImmediate(() => emitFrame(fakeSocket, {
            type: "response",
            requestId: frame.requestId,
            resultType: "success",
            method: "initialize",
            handledByClientId: "router",
            result: { clientId: "remodex-test" },
          }));
        } else if (frame.type === "client-discovery-request") {
          setImmediate(() => emitFrame(fakeSocket, {
            type: "client-discovery-response",
            requestId: frame.requestId,
            response: { canHandle: true },
          }));
        } else if (frame.method === "thread-follower-start-turn") {
          setImmediate(() => emitFrame(fakeSocket, {
            type: "response",
            requestId: frame.requestId,
            resultType: "success",
            method: frame.method,
            handledByClientId: "desktop",
            result: { turn: { id: "turn-connect-probe" } },
          }));
        }
      };
      fakeSocket.destroy = () => {
        fakeSocket.destroyed = true;
        fakeSocket.emit("close");
      };
      setTimeout(() => {
        fakeSocket.destroyed = false;
        fakeSocket.emit("connect");
      }, 25);
      return fakeSocket;
    },
  };

  const follower = createDesktopIpcActionFollower({
    socketPath: "/tmp/remodex-fake-ipc",
    netModule,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 1_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-connect-probe" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-connect-probe",
    method: "turn/start",
    params: {
      threadId: "thread-connect-probe",
      input: [{ type: "input_text", text: "route after connect" }],
    },
  }));
  assert.equal(handled, true);
  assert.equal(writtenFrames.some((frame) => frame.type === "client-discovery-request"), false);

  await waitFor(() => writtenFrames.some((frame) => frame.type === "client-discovery-request"), 1_000);
  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-connect-probe"), 1_000);
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-connect-probe"), {
    id: "phone-turn-start-connect-probe",
    result: { turn: { id: "turn-connect-probe" } },
  });
  assert.deepEqual(localForwards, []);
});

test("desktop IPC follower ignores stale positive discovery after a held turn already expired", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-probe-expired-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;
  let discoveryRequestFrame = null;

  // Ignores discovery probes, and reports no handler for routed requests so the
  // expired hold falls back to the local app-server.
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.type === "client-discovery-request") {
        discoveryRequestFrame = frame;
      } else if (frame.type === "request" && frame.method?.startsWith("thread-follower-")) {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "error",
          error: "no-client-found",
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 100,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-probe-expired" },
  }));
  const firstHandled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-expired-probe",
    method: "turn/start",
    params: {
      threadId: "thread-probe-expired",
      input: [{ type: "input_text", text: "expires before discovery answers" }],
    },
  }));
  assert.equal(firstHandled, true);

  // The hold expires and the request falls back to the local app-server.
  await waitFor(() => localForwards.some((message) => message.id === "phone-turn-start-expired-probe"), 1_000);
  assert.ok(discoveryRequestFrame);

  // A very late positive discovery answer must not flip the thread to Desktop.
  writeFrame(serverSocket, {
    type: "client-discovery-response",
    requestId: discoveryRequestFrame.requestId,
    response: { canHandle: true },
  });
  await wait(25);

  const secondHandled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-after-expired-probe",
    method: "turn/start",
    params: {
      threadId: "thread-probe-expired",
      input: [{ type: "input_text", text: "must not route to desktop" }],
    },
  }));
  assert.equal(secondHandled, false);
});

test("desktop IPC follower ignores stale positive discovery after live owner claims a thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-probe-stale-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-should-not-route" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 5_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-probe-stale" },
  }));
  const firstHandled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-stale-probe",
    method: "turn/start",
    params: {
      threadId: "thread-probe-stale",
      input: [{ type: "input_text", text: "hold before owner claim" }],
    },
  }));
  assert.equal(firstHandled, true);

  await waitFor(() => (
    serverFrames.find((frame) => frame.type === "client-discovery-request")
  ), 1_000);
  const discoveryRequest = serverFrames.find((frame) => frame.type === "client-discovery-request");
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-probe-stale",
      remodexOwnerSource: "desktop-ipc-live-owner",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });

  await waitFor(() => localForwards.some((message) => message.id === "phone-turn-start-stale-probe"), 1_000);
  writeFrame(serverSocket, {
    type: "client-discovery-response",
    requestId: discoveryRequest.requestId,
    response: { canHandle: true },
  });
  await wait(25);

  const secondHandled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-after-stale-probe",
    method: "turn/start",
    params: {
      threadId: "thread-probe-stale",
      input: [{ type: "input_text", text: "must stay local" }],
    },
  }));
  assert.equal(secondHandled, false);
  await wait(25);
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false
  );
});

test("desktop IPC follower cancels held turns when the live owner removes a thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-probe-removed-");
  const serverFrames = [];
  const localForwards = [];
  const outbound = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-should-not-start-after-removal" } },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 5_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-probe-removed" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-removed",
    method: "turn/start",
    params: {
      threadId: "thread-probe-removed",
      input: [{ type: "input_text", text: "must not start after removal" }],
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => (
    serverFrames.find((frame) => frame.type === "client-discovery-request")
  ), 1_000);
  const discoveryRequest = serverFrames.find((frame) => frame.type === "client-discovery-request");
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-probe-removed",
      remodexOwnerSource: "desktop-ipc-live-owner",
      remodexOwnerReleased: true,
      change: {
        type: "snapshot",
        conversationState: { remodexRemoved: true, turns: [], requests: [] },
      },
    },
  });

  await waitFor(() => outbound.some((message) => message.id === "phone-turn-start-removed"), 1_000);
  writeFrame(serverSocket, {
    type: "client-discovery-response",
    requestId: discoveryRequest.requestId,
    response: { canHandle: true },
  });
  await wait(25);

  const errorResponse = outbound.find((message) => message.id === "phone-turn-start-removed");
  assert.equal(errorResponse.error.code, -32000);
  assert.deepEqual(localForwards, []);
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false
  );
});

test("desktop IPC follower keeps held phone turns queued when discovery denies ownership", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-probe-denied-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.type === "client-discovery-request") {
        writeFrame(socket, {
          type: "client-discovery-response",
          requestId: frame.requestId,
          response: { canHandle: false },
        });
      } else if (frame.type === "request" && frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "error",
          error: "no-client-found",
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 120,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-probe-denied" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-denied",
    method: "turn/start",
    params: {
      threadId: "thread-probe-denied",
      input: [{ type: "input_text", text: "local thread" }],
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => serverFrames.some((frame) => frame.type === "client-discovery-request"), 1_000);
  await wait(30);
  assert.deepEqual(localForwards, []);
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    false
  );

  // The timer-routed request can still fall back locally after a real no-client-found.
  await waitFor(() => localForwards.length > 0, 1_000);
  assert.equal(localForwards[0].id, "phone-turn-start-denied");
  assert.equal(
    serverFrames.some((frame) => frame.method === "thread-follower-start-turn"),
    true
  );
});

test("desktop IPC follower forwards held phone turns to local codex when no snapshot arrives", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-hold-timeout-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  // Models Codex Desktop's real router: client-origin discovery probes are
  // ignored, but routed requests get a no-client-found error when nobody owns
  // the thread.
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.type === "request" && frame.method?.startsWith("thread-follower-")) {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "error",
          error: "no-client-found",
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 100,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-hold-timeout" },
  }));
  const handled = follower.observeInbound(JSON.stringify({
    id: "phone-turn-start-timeout",
    method: "turn/start",
    params: {
      threadId: "thread-hold-timeout",
      input: [{ type: "input_text", text: "no desktop here" }],
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => localForwards.length > 0, 1_000);
  assert.equal(localForwards[0].id, "phone-turn-start-timeout");
  assert.equal(localForwards[0].method, "turn/start");
});

test("desktop IPC follower ignores Remodex-owned live owner broadcasts", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-owner-echo-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-owner-broadcast" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "remodex-owner",
    version: 6,
    params: {
      conversationId: "thread-owner-broadcast",
      remodexOwnerSource: "desktop-ipc-live-owner",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-owner-broadcast",
            items: [{
              id: "assistant-owner-broadcast",
              type: "agentMessage",
              text: "This is already phone-bound through app-server.",
            }],
          }],
          requests: [{
            id: "req-owner-broadcast",
            method: "item/fileChange/requestApproval",
            params: {
              threadId: "thread-owner-broadcast",
              turnId: "turn-owner-broadcast",
              itemId: "file-owner-broadcast",
            },
          }],
        },
      },
    },
  });

  await wait(50);
  assert.deepEqual(outbound, []);
});

test("desktop IPC follower keeps connected active ownership authoritative through quiet work", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-stale-active-read-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  let fakeNow = 1_000_000;
  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    now: () => fakeNow,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-stale-active" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 6,
    params: {
      conversationId: "thread-stale-active",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-stale-active",
            status: "inProgress",
            items: [],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => follower.hasLiveThreadState("thread-stale-active"));
  const desktopSnapshotAt = fakeNow;

  // While Desktop keeps the stream fresh, cached reads answer immediately.
  const freshServed = follower.observeInbound(JSON.stringify({
    id: "read-fresh",
    method: "thread/read",
    params: { threadId: "thread-stale-active" },
  }));
  assert.equal(freshServed, true);
  assert.equal(outbound.some((message) => message.id === "read-fresh"), true);

  // Long-running tools, subagents, approvals, and reasoning can be quiet for
  // longer than the cache window while the Desktop IPC stream stays healthy.
  fakeNow += 21_000;
  assert.equal(follower.hasLiveThreadState("thread-stale-active"), true);
  assert.equal(
    follower.hasFreshLiveThreadState("thread-stale-active", {
      fallbackActivityAt: desktopSnapshotAt - 1,
    }),
    true,
    "an older fallback must not displace a genuinely quiet Desktop turn"
  );
  const staleServed = follower.observeInbound(JSON.stringify({
    id: "read-stale",
    method: "thread/read",
    params: { threadId: "thread-stale-active" },
  }));
  assert.equal(staleServed, true);
  assert.equal(
    outbound.find((message) => message.id === "read-stale")?.result?.thread?.turns?.[0]?.status,
    "inProgress"
  );

  // A connected IPC client is not permanent proof that this one thread is
  // still live. Newer rollout activity lets the fallback recover it.
  assert.equal(follower.hasFreshLiveThreadState("thread-stale-active", {
    fallbackActivityAt: fakeNow + 1,
  }), false);

  // The next Desktop snapshot continues the same source epoch and produces the
  // real completion instead of a replacement/bootstrap discontinuity.
  const freshEpochStartIndex = outbound.length;
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 6,
    params: {
      conversationId: "thread-stale-active",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-stale-active",
            status: "completed",
            items: [{
              id: "assistant-fresh-epoch",
              type: "agentMessage",
              text: "Fresh Desktop epoch.",
            }],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => outbound.slice(freshEpochStartIndex).some((message) => (
    message.method === "turn/completed"
  )));
  const freshEpochMessages = outbound.slice(freshEpochStartIndex);
  assert.equal(
    freshEpochMessages.some((message) => message.method === "thread/replaced"),
    false
  );
  const completion = freshEpochMessages.find((message) => message.method === "turn/completed");
  assert.equal(completion.params.turnId, "turn-stale-active");
  assert.equal(completion.params.status, "completed");
  assert.equal(follower.hasLiveThreadState("thread-stale-active"), true);

  // Idle cached threads have no phantom-running risk: they stay servable even
  // after the active-state freshness window elapses again.
  fakeNow += 60_000;
  const idleServed = follower.observeInbound(JSON.stringify({
    id: "read-idle",
    method: "thread/read",
    params: { threadId: "thread-stale-active" },
  }));
  assert.equal(idleServed, true);
  const idleResponse = outbound.find((message) => message.id === "read-idle");
  assert.equal(idleResponse.result.thread.turns[0].status, "completed");
  assert.equal(idleResponse.result.thread.turns[0].items[0].id, "assistant-fresh-epoch");
});

test("desktop IPC follower releases stale active ownership when the connected bus stops responding", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-stalled-active-read-");
  let serverSocket = null;
  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  let fakeNow = 2_000_000;
  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    now: () => fakeNow,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-stalled-active" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 6,
    params: {
      conversationId: "thread-stalled-active",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-stalled-active",
            status: "inProgress",
            items: [],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => follower.hasLiveThreadState("thread-stalled-active"));

  // The socket remains open, but no frame arrives for longer than the bus lease.
  fakeNow += 5 * 60_000 + 1;
  assert.equal(follower.hasLiveThreadState("thread-stalled-active"), false);
  const served = follower.observeInbound(JSON.stringify({
    id: "read-stalled",
    method: "thread/read",
    params: { threadId: "thread-stalled-active" },
  }));
  assert.equal(served, false);
  assert.equal(outbound.some((message) => message.id === "read-stalled"), false);
});

test("desktop IPC follower yields normalized history reads while keeping its bounded live tail", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-normalized-history-yield-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-normalized-history" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "snapshot",
        conversationState: {
          title: "A real task with normalized history",
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "idle", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-ancient-stale": {
                  turnId: "turn-ancient-stale",
                  turnStartedAtMs: 1,
                  durationMs: null,
                  status: "inProgress",
                  items: [],
                },
                "turn:turn-normalized": {
                  turnId: "turn-normalized",
                  status: "completed",
                  items: [{
                    id: "assistant-normalized",
                    type: "agentMessage",
                    text: "Stored outside the legacy turns array.",
                  }],
                },
              },
              islands: [{
                id: "tail:1",
                entries: [
                  { key: "turn:turn-ancient-stale", value: "turn:turn-ancient-stale" },
                  { key: "turn:turn-normalized", value: "turn:turn-normalized" },
                ],
              }],
              generation: 1,
              isComplete: true,
            },
          },
        },
      },
    },
  });

  await waitFor(() => outbound.some((message) => message.method === "thread/replaced"));
  assert.equal(
    follower.hasLiveThreadState("thread-normalized-history"),
    true,
    "a usable bounded Desktop tail should keep the expensive rollout mirror suppressed"
  );
  assert.equal(
    outbound.some((message) => message.method === "turn/started"),
    false,
    "explicit idle runtime must not resurrect an ancient normalized inProgress turn"
  );
  outbound.length = 0;

  for (const method of ["thread/read", "thread/resume", "thread/turns/list"]) {
    const handled = follower.observeInbound(JSON.stringify({
      id: `normalized-${method}`,
      method,
      params: { threadId: "thread-normalized-history", limit: 1 },
    }));
    assert.equal(handled, false, `${method} should fall through to canonical recovery`);
  }
  assert.deepEqual(outbound, []);

  // Current Litter snapshots keep even the active turn only in the normalized
  // store. Project the bounded tail live while ignoring an ancient stale
  // inProgress entity and keeping all history reads canonical.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "snapshot",
        conversationState: {
          title: "A real task with normalized live history",
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-stale-running": {
                  turnId: "turn-stale-running",
                  turnStartedAtMs: 1,
                  durationMs: 1,
                  status: "inProgress",
                  items: [],
                },
                "turn:turn-normalized": {
                  turnId: "turn-normalized",
                  status: "completed",
                  items: [],
                },
                "turn:turn-running": {
                  turnId: "turn-running",
                  status: "inProgress",
                  items: [{
                    id: "assistant-running",
                    type: "agentMessage",
                    text: "A",
                  }],
                },
              },
              islands: [{
                id: "tail:1",
                entries: [
                  { key: "turn:turn-stale-running", value: "turn:turn-stale-running" },
                  { key: "turn:turn-normalized", value: "turn:turn-normalized" },
                  { key: "turn:turn-running", value: "turn:turn-running" },
                ],
              }],
              generation: 2,
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await wait(50);
  assert.equal(follower.hasLiveThreadState("thread-normalized-history"), true);
  assert.equal(
    outbound.some((message) => message.method === "thread/replaced"),
    false,
    "the live tail must not restart canonical history after its first repair"
  );
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/started"
        && message.params?.threadId === "thread-normalized-history"
        && message.params?.turn?.id === "turn-running"
    )),
    true,
    "the current Desktop turn should stay live while history remains canonical"
  );
  outbound.length = 0;

  // Litter rehydrates the same full normalized snapshot with different item
  // IDs shortly after connect. That is a baseline replacement, not hundreds
  // of new live items.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "snapshot",
        conversationState: {
          title: "A real task with rehydrated normalized IDs",
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-stale-running": {
                  turnId: "turn-stale-running",
                  turnStartedAtMs: 1,
                  durationMs: null,
                  status: "inProgress",
                  items: [],
                },
                "turn:turn-normalized": {
                  turnId: "turn-normalized",
                  status: "completed",
                  items: [],
                },
                "turn:turn-running": {
                  turnId: "turn-running",
                  status: "inProgress",
                  items: [{
                    id: "item-rehydrated-running",
                    type: "agentMessage",
                    text: "A",
                  }],
                },
              },
              islands: [{
                id: "tail:1",
                entries: [
                  { key: "turn:turn-stale-running", value: "turn:turn-stale-running" },
                  { key: "turn:turn-normalized", value: "turn:turn-normalized" },
                  { key: "turn:turn-running", value: "turn:turn-running" },
                ],
              }],
              generation: 3,
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await wait(50);
  assert.deepEqual(
    outbound.filter((message) => message.method?.startsWith("item/")),
    [],
    "a re-keyed full snapshot must not replay historical item lifecycles"
  );
  assert.equal(
    outbound.some((message) => message.method === "turn/started"),
    false,
    "the same active turn must not restart on baseline rehydration"
  );
  outbound.length = 0;

  const stateProbeHandled = follower.observeInbound(JSON.stringify({
    id: "normalized-live-state",
    method: "thread/turns/list",
    params: {
      threadId: "thread-normalized-history",
      limit: 8,
      sortDirection: "desc",
    },
  }));
  assert.equal(stateProbeHandled, true);
  const stateProbe = outbound.find((message) => message.id === "normalized-live-state");
  assert.equal(stateProbe?.result?.remodexDesktopLiveState, true);
  assert.deepEqual(stateProbe?.result?.data?.[0], {
    id: "turn-running",
    status: "inProgress",
  });
  assert.equal(
    stateProbe?.result?.data?.some((turn) => turn.id === "turn-stale-running"),
    false
  );
  outbound.length = 0;

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: [
            "turnHistory",
            "history",
            "entitiesByKey",
            "turn:turn-running",
            "items",
            0,
            "text",
          ],
          value: "AB",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "item/agentMessage/delta"
      && message.params?.threadId === "thread-normalized-history"
      && message.params?.turnId === "turn-running"
      && message.params?.delta === "B"
  )));
  assert.equal(
    outbound.some((message) => message.method === "thread/replaced"),
    false
  );
  outbound.length = 0;

  // A temporary legacy-complete snapshot must not reclaim history reads or
  // restart the source epoch. Canonical history authority stays sticky while
  // the same bounded current turn continues over Desktop IPC.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [
            {
              id: "turn-stale-running",
              turnStartedAtMs: 1,
              durationMs: 1,
              status: "inProgress",
              items: [],
            },
            { id: "turn-normalized", status: "completed", items: [] },
            {
              id: "turn-running",
              status: "inProgress",
              items: [{ id: "assistant-running", type: "agentMessage", text: "AB" }],
            },
          ],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
        },
      },
    },
  });
  await wait(50);
  assert.equal(follower.hasLiveThreadState("thread-normalized-history"), true);
  assert.equal(
    outbound.some((message) => message.method === "thread/replaced"),
    false
  );
  outbound.length = 0;

  assert.equal(follower.observeInbound(JSON.stringify({
    id: "partial-turns",
    method: "thread/turns/list",
    params: { threadId: "thread-normalized-history", limit: 1 },
  })), false);
  assert.deepEqual(outbound, []);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["threadRuntimeStatus", "type"],
          value: "idle",
        }],
      },
    },
  });
  await wait(25);
  assert.equal(outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-normalized-history"
      && message.params?.turnId === "turn-running"
  )), false, "runtime idle alone must not complete an explicitly active turn");
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/started"
        && message.params?.turnId === "turn-stale-running"
    )),
    false
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-normalized-history",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 2, "status"],
          value: "completed",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.threadId === "thread-normalized-history"
      && message.params?.turnId === "turn-running"
  )));
  outbound.length = 0;

  assert.equal(follower.observeInbound(JSON.stringify({
    id: "normalized-idle-state",
    method: "thread/turns/list",
    params: {
      threadId: "thread-normalized-history",
      limit: 8,
      sortDirection: "desc",
    },
  })), true);
  const idleStateProbe = outbound.find((message) => message.id === "normalized-idle-state");
  assert.equal(idleStateProbe?.result?.data?.[0]?.status, "completed");
  outbound.length = 0;

  // A genuinely blank Desktop snapshot has no normalized turn entities, so it
  // remains authoritative and can still answer with an empty first page.
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-genuinely-blank" },
  }));
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: "thread-genuinely-blank",
      change: {
        type: "snapshot",
        conversationState: {
          title: "Blank task",
          turns: [],
          requests: [],
          turnHistory: {
            kind: "canonical",
            history: { entitiesByKey: {}, generation: 1, isComplete: true },
          },
        },
      },
    },
  });
  await wait(50);
  outbound.length = 0;
  const blankHandled = follower.observeInbound(JSON.stringify({
    id: "blank-turns",
    method: "thread/turns/list",
    params: { threadId: "thread-genuinely-blank", limit: 1 },
  }));
  assert.equal(blankHandled, true);
  assert.deepEqual(
    outbound.find((message) => message.id === "blank-turns")?.result?.data,
    []
  );
});

test("desktop IPC follower coalesces stale normalized snapshot bursts before publishing lifecycle", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-snapshot-coalesce-");
  const outbound = [];
  let serverSocket = null;
  const nowValue = Date.now();
  const locallyOwnedThreadIDs = new Set();

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    now: () => nowValue,
    snapshotDebounceMs: 75,
    isLocallyOwnedThread: (threadID) => locallyOwnedThreadIDs.has(threadID),
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-snapshot-coalesce" },
  }));
  await waitFor(() => serverSocket);

  const sendSnapshot = ({
    threadId = "thread-snapshot-coalesce",
    oldStatus,
    includeNewTurn,
  }) => {
    const entitiesByKey = {
      "turn:turn-old": {
        turnId: "turn-old",
        turnStartedAtMs: nowValue,
        durationMs: 0,
        status: oldStatus,
        items: [],
      },
    };
    const entries = [{ key: "turn:turn-old", value: "turn:turn-old" }];
    if (includeNewTurn) {
      entitiesByKey["turn:turn-new"] = {
        turnId: "turn-new",
        turnStartedAtMs: nowValue,
        durationMs: 0,
        status: "inProgress",
        items: [],
      };
      entries.push({ key: "turn:turn-new", value: "turn:turn-new" });
    }
    writeFrame(serverSocket, {
      type: "broadcast",
      method: "thread-stream-state-changed",
      sourceClientId: "desktop-live",
      version: 11,
      params: {
        conversationId: threadId,
        change: {
          type: "snapshot",
          conversationState: {
            turns: [],
            requests: [],
            threadRuntimeStatus: { type: "active", activeFlags: [] },
            turnHistory: {
              kind: "canonical",
              history: {
                entitiesByKey,
                islands: [{ id: "tail:coalesce", entries }],
                isComplete: true,
              },
            },
          },
        },
      },
    });
  };

  sendSnapshot({ oldStatus: "inProgress", includeNewTurn: false });
  await wait(25);
  // The debounced snapshot is already authoritative for source arbitration:
  // rollout must stay suppressed while the follower coalesces the burst.
  assert.equal(follower.hasLiveThreadState("thread-snapshot-coalesce"), true);
  assert.equal(follower.hasFreshLiveThreadState("thread-snapshot-coalesce"), true);
  assert.equal(follower.observeInbound(JSON.stringify({
    id: "provisional-explicit-state",
    method: "thread/turns/list",
    params: {
      threadId: "thread-snapshot-coalesce",
      limit: 8,
      sortDirection: "desc",
      remodexTurnStateOnly: true,
    },
  })), false);
  assert.equal(outbound.some((message) => message.id === "provisional-explicit-state"), false);

  sendSnapshot({ oldStatus: "completed", includeNewTurn: true });
  await wait(50);
  assert.equal(outbound.some((message) => message.method?.startsWith("turn/")), false);

  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started" && message.params?.turnId === "turn-new"
  )));
  assert.notEqual(
    outbound.find((message) => (
      message.method === "turn/started" && message.params?.turnId === "turn-new"
    ))?.params?.remodexTurnIdentityContinuity,
    true,
    "a distinct replacement turn must advance the phone run generation"
  );
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/started" && message.params?.turnId === "turn-old"
    )),
    false
  );
  assert.equal(
    outbound.filter((message) => message.method === "thread/replaced").length,
    1
  );
  outbound.length = 0;

  assert.equal(follower.observeInbound(JSON.stringify({
    id: "settled-explicit-state",
    method: "thread/turns/list",
    params: {
      threadId: "thread-snapshot-coalesce",
      limit: 8,
      sortDirection: "desc",
      remodexTurnStateOnly: true,
    },
  })), true);
  assert.deepEqual(
    outbound.find((message) => message.id === "settled-explicit-state")?.result?.data?.[0],
    { id: "turn-new", status: "inProgress" }
  );
  outbound.length = 0;

  const locallyOwnedThreadID = "thread-owned-during-snapshot-debounce";
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: locallyOwnedThreadID },
  }));
  sendSnapshot({
    threadId: locallyOwnedThreadID,
    oldStatus: "inProgress",
    includeNewTurn: false,
  });
  await wait(25);
  locallyOwnedThreadIDs.add(locallyOwnedThreadID);
  await wait(75);

  assert.deepEqual(outbound, []);
  assert.equal(follower.hasLiveThreadState(locallyOwnedThreadID), false);
});

test("desktop IPC follower completes either parallel active turn across normalized snapshots", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-parallel-normalized-");
  const outbound = [];
  let serverSocket = null;
  const nowValue = Date.now();

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    now: () => nowValue,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  const primaryThreadId = "thread-parallel-normalized";
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: primaryThreadId },
  }));
  await waitFor(() => serverSocket);

  const sendSnapshot = (
    firstStatus,
    secondStatus,
    runtimeType = "active",
    threadId = primaryThreadId
  ) => {
    const firstTurn = {
      turnId: "turn-parallel-a",
      turnStartedAtMs: nowValue,
      durationMs: 0,
      status: firstStatus,
      items: [],
    };
    const secondTurn = {
      turnId: "turn-parallel-b",
      turnStartedAtMs: nowValue,
      durationMs: 0,
      status: secondStatus,
      items: [],
    };
    writeFrame(serverSocket, {
      type: "broadcast",
      method: "thread-stream-state-changed",
      sourceClientId: "desktop-live",
      version: 11,
      params: {
        conversationId: threadId,
        change: {
          type: "snapshot",
          conversationState: {
            turns: [],
            requests: [],
            threadRuntimeStatus: { type: runtimeType, activeFlags: [] },
            turnHistory: {
              kind: "canonical",
              history: {
                entitiesByKey: {
                  "turn:turn-parallel-a": firstTurn,
                  "turn:turn-parallel-b": secondTurn,
                },
                islands: [{
                  id: "tail:parallel",
                  entries: [
                    { key: "turn:turn-parallel-a", value: "turn:turn-parallel-a" },
                    { key: "turn:turn-parallel-b", value: "turn:turn-parallel-b" },
                  ],
                }],
                isComplete: true,
              },
            },
          },
        },
      },
    });
  };

  sendSnapshot("inProgress", "inProgress");
  await waitFor(() => outbound.filter((message) => message.method === "turn/started").length === 2);
  assert.deepEqual(
    outbound
      .filter((message) => message.method === "turn/started")
      .map((message) => message.params?.turnId),
    ["turn-parallel-a", "turn-parallel-b"]
  );
  outbound.length = 0;

  sendSnapshot("completed", "inProgress");
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.turnId === "turn-parallel-a"
  )));
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/completed"
        && message.params?.turnId === "turn-parallel-b"
    )),
    false
  );
  assert.equal(outbound.some((message) => message.method?.startsWith("item/")), false);
  outbound.length = 0;

  sendSnapshot("completed", "completed", "idle");
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed"
      && message.params?.turnId === "turn-parallel-b"
  )));
  assert.equal(outbound.some((message) => message.method === "turn/started"), false);

  const inverseThreadId = "thread-parallel-normalized-inverse";
  outbound.length = 0;
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: inverseThreadId },
  }));
  sendSnapshot("inProgress", "inProgress", "active", inverseThreadId);
  await waitFor(() => outbound.filter((message) => (
    message.method === "turn/started"
      && message.params?.threadId === inverseThreadId
  )).length === 2);
  outbound.length = 0;

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: inverseThreadId,
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: [
            "turnHistory",
            "history",
            "entitiesByKey",
            "turn:turn-parallel-b",
            "status",
          ],
          value: "completed",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === inverseThreadId
      && message.params?.turnId === "turn-parallel-a"
  )));
  const inverseMessages = outbound.filter((message) => (
    message.params?.threadId === inverseThreadId
  ));
  const secondCompletionIndex = inverseMessages.findIndex((message) => (
    message.method === "turn/completed" && message.params?.turnId === "turn-parallel-b"
  ));
  const firstRestoreIndex = inverseMessages.findIndex((message) => (
    message.method === "turn/started" && message.params?.turnId === "turn-parallel-a"
  ));
  assert.ok(secondCompletionIndex >= 0);
  assert.ok(firstRestoreIndex > secondCompletionIndex);
  assert.equal(inverseMessages[firstRestoreIndex].params.remodexTurnIdentityContinuity, true);
  assert.equal(
    inverseMessages.some((message) => (
      message.method === "turn/completed" && message.params?.turnId === "turn-parallel-a"
    )),
    false
  );
});

test("desktop IPC follower bootstraps normalized active content produced during reconnect", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-ipc-normalized-reconnect-repair-"
  );
  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  const threadId = "thread-normalized-reconnect-repair";
  const sendSnapshot = (text) => writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-reconnect": {
                  turnId: "turn-reconnect",
                  turnStartedAtMs: Date.now(),
                  durationMs: 0,
                  status: "inProgress",
                  items: [{ id: "assistant-reconnect", type: "agentMessage", text }],
                },
              },
              islands: [{
                id: "tail:reconnect",
                entries: [{ key: "turn:turn-reconnect", value: "turn:turn-reconnect" }],
              }],
              isComplete: true,
            },
          },
        },
      },
    },
  });

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId },
  }));
  await waitFor(() => state.socket);
  sendSnapshot("A");
  await waitFor(() => outbound.some((message) => message.method === "thread/replaced"));
  outbound.length = 0;

  state.socket.destroy();
  await waitFor(() => state.socket == null);
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId },
  }));
  await waitFor(() => state.connectionCount === 2 && state.socket);
  sendSnapshot("Output produced while IPC was disconnected");

  await waitFor(() => outbound.some((message) => (
    message.method === "item/started"
      && message.params?.itemId === "assistant-reconnect"
  )));
  const bootstrappedItem = outbound.find((message) => (
    message.method === "item/started"
      && message.params?.itemId === "assistant-reconnect"
  ));
  assert.equal(
    outbound.some((message) => message.method === "item/agentMessage/delta"),
    false,
    "reconnect content is bootstrapped as an item, not misrepresented as a streamed suffix"
  );
  assert.equal(
    bootstrappedItem.params.item.text,
    "Output produced while IPC was disconnected"
  );
});

test("desktop IPC follower bootstraps a normalized active turn when the phone opens it", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-ipc-background-canonical-repair-"
  );
  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  const threadId = "thread-background-canonical-repair";
  follower.observeInbound(JSON.stringify({ id: "sidebar", method: "thread/list", params: {} }));
  await waitFor(() => state.socket);
  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-background-history": {
                  turnId: "turn-background-history",
                  status: "completed",
                  items: [{
                    id: "assistant-background-history",
                    type: "agentMessage",
                    text: "Older completed output",
                  }],
                },
                "turn:turn-background-parallel": {
                  turnId: "turn-background-parallel",
                  turnStartedAtMs: Date.now(),
                  durationMs: 0,
                  status: "inProgress",
                  items: [{
                    id: "assistant-background-parallel",
                    type: "agentMessage",
                    text: "Parallel active block",
                  }],
                },
                "turn:turn-background-repair": {
                  turnId: "turn-background-repair",
                  turnStartedAtMs: Date.now(),
                  durationMs: 0,
                  status: "inProgress",
                  params: { input: [{ type: "text", text: "Continue the active task" }] },
                  items: [
                    {
                      id: "assistant-background-first",
                      type: "agentMessage",
                      text: "First active block",
                    },
                    {
                      id: "assistant-background-second",
                      type: "agentMessage",
                      text: "Second active block",
                    },
                  ],
                },
              },
              islands: [{
                id: "tail:background-repair",
                entries: [
                  {
                    key: "turn:turn-background-history",
                    value: "turn:turn-background-history",
                  },
                  {
                    key: "turn:turn-background-parallel",
                    value: "turn:turn-background-parallel",
                  },
                  {
                    key: "turn:turn-background-repair",
                    value: "turn:turn-background-repair",
                  },
                ],
              }],
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started" && message.params?.threadId === threadId
  )));
  assert.equal(
    outbound.filter((message) => (
      message.method === "turn/started" && message.params?.threadId === threadId
    )).length,
    1,
    "background discovery should announce the active turn once"
  );
  outbound.length = 0;

  const handled = follower.observeInbound(JSON.stringify({
    id: "metadata-only-resume",
    method: "thread/resume",
    params: { threadId, excludeTurns: true },
  }));
  assert.equal(handled, false);
  await waitFor(() => outbound.some((message) => (
    message.method === "item/started"
      && message.params?.itemId === "assistant-background-second"
  )));
  assert.equal(outbound[0].method, "thread/replaced");
  assert.deepEqual(
    outbound
      .filter((message) => message.method === "turn/started")
      .map((message) => message.params.turnId),
    ["turn-background-parallel"],
    "opening should add the other parallel run without repeating the sidebar-announced run"
  );
  assert.deepEqual(
    outbound
      .filter((message) => message.method === "item/started")
      .map((message) => message.params.itemId),
    [
      "assistant-background-parallel",
      "turn-background-repair:input",
      "assistant-background-first",
      "assistant-background-second",
    ],
    "the phone should receive the complete bounded active-turn baseline before another patch"
  );
  assert.deepEqual(
    outbound
      .filter((message) => message.method === "item/completed")
      .map((message) => message.params.itemId),
    [
      "assistant-background-parallel",
      "turn-background-repair:input",
      "assistant-background-first",
      "assistant-background-second",
    ],
    "each completed baseline item should arrive with its normal terminal notification"
  );
  assert.equal(
    outbound.some((message) => message.params?.itemId === "assistant-background-history"),
    false,
    "opening an active chat must not replay completed historical turns"
  );
  outbound.length = 0;

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: [
            "turnHistory",
            "history",
            "entitiesByKey",
            "turn:turn-background-repair",
            "items",
            1,
            "text",
          ],
          value: "Second active block continued",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => message.method === "item/agentMessage/delta"));
  assert.deepEqual(
    outbound.map((message) => ({
      method: message.method,
      itemId: message.params?.itemId,
      delta: message.params?.delta,
    })),
    [{
      method: "item/agentMessage/delta",
      itemId: "assistant-background-second",
      delta: " continued",
    }],
    "the next normalized patch should diff against the delivered baseline without replaying it"
  );
});

test("desktop IPC follower preserves promoted synthetic-turn identity from prompt and start", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-ipc-promoted-identity-"
  );
  const outbound = [];
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  const threadId = "thread-background-identity-continuity";
  const startedAt = Date.now();
  const prompt = [{ type: "text", text: "Continue the same promoted run" }];
  follower.observeInbound(JSON.stringify({ id: "sidebar", method: "thread/list", params: {} }));
  await waitFor(() => state.socket);
  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            status: "inProgress",
            turnStartedAtMs: startedAt,
            durationMs: 0,
            params: { input: prompt },
            items: [{
              id: "assistant-synthetic-alias",
              type: "agentMessage",
              text: "Synthetic alias output",
            }],
          }],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                "turn:turn-promoted-canonical": {
                  turnId: "turn-promoted-canonical",
                  status: "inProgress",
                  turnStartedAtMs: startedAt,
                  durationMs: 0,
                  params: { input: prompt },
                  items: [{
                    id: "assistant-canonical-alias",
                    type: "agentMessage",
                    text: "Canonical alias output",
                  }],
                },
              },
              islands: [{
                id: "tail:identity-continuity",
                entries: [{
                  key: "turn:turn-promoted-canonical",
                  value: "turn:turn-promoted-canonical",
                }],
              }],
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.threadId === threadId
      && String(message.params?.turnId || "").startsWith("ipc-turn-")
  )));
  outbound.length = 0;

  const handled = follower.observeInbound(JSON.stringify({
    id: "metadata-only-identity-resume",
    method: "thread/resume",
    params: { threadId, excludeTurns: true },
  }));
  assert.equal(handled, false);
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started"
      && message.params?.turnId === "turn-promoted-canonical"
  )));
  const canonicalStart = outbound.find((message) => (
    message.method === "turn/started"
      && message.params?.turnId === "turn-promoted-canonical"
  ));
  assert.equal(canonicalStart.params.remodexTurnIdentityContinuity, true);
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/started"
        && String(message.params?.turnId || "").startsWith("ipc-turn-")
    )),
    false,
    "the already-announced synthetic alias must not start twice during promotion"
  );
});

test("desktop IPC follower reuses its normalized history index for live content patches", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-ipc-normalized-index-reuse-"
  );
  const outbound = [];
  let indexRebuilds = 0;
  const nowValue = Date.now();
  const follower = createDesktopIpcActionFollower({
    socketPath,
    now: () => nowValue,
    onNormalizedHistoryIndexRebuilt() {
      indexRebuilds += 1;
    },
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  const threadId = "thread-normalized-index-reuse";
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId },
  }));
  await waitFor(() => state.socket);

  const entitiesByKey = {};
  const entries = [];
  const historicalTurnCount = 1_000;
  for (let index = 0; index < historicalTurnCount; index += 1) {
    const turnId = `turn-history-${index}`;
    entitiesByKey[`turn:${turnId}`] = { turnId, status: "completed", items: [] };
    entries.push({ key: `turn:${turnId}`, value: `turn:${turnId}` });
  }
  entitiesByKey["turn:turn-index-live"] = {
    turnId: "turn-index-live",
    turnStartedAtMs: nowValue,
    durationMs: 0,
    status: "inProgress",
    items: [{ id: "assistant-index-live", type: "agentMessage", text: "A" }],
  };
  entries.push({ key: "turn:turn-index-live", value: "turn:turn-index-live" });
  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: { entitiesByKey, islands: [{ id: "tail:index", entries }], isComplete: true },
          },
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => message.method === "thread/replaced"));
  assert.equal(indexRebuilds, 1);
  outbound.length = 0;

  let text = "A";
  const contentPatchCount = 20;
  for (let index = 0; index < contentPatchCount; index += 1) {
    text += "x";
    writeFrame(state.socket, {
      type: "broadcast",
      method: "thread-stream-state-changed",
      sourceClientId: "desktop-live",
      version: 11,
      params: {
        conversationId: threadId,
        change: {
          type: "patches",
          patches: [{
            op: "replace",
            path: [
              "turnHistory",
              "history",
              "entitiesByKey",
              "turn:turn-index-live",
              "items",
              0,
              "text",
            ],
            value: text,
          }],
        },
      },
    });
  }
  await waitFor(() => outbound.filter((message) => (
    message.method === "item/agentMessage/delta"
  )).length === contentPatchCount);
  assert.equal(indexRebuilds, 1, "content patches must not rescan normalized history");
  outbound.length = 0;

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "patches",
        patches: [
          { op: "replace", path: ["threadRuntimeStatus", "type"], value: "idle" },
        ],
      },
    },
  });
  await wait(25);
  assert.equal(
    outbound.some((message) => (
      message.method === "turn/completed" && message.params?.turnId === "turn-index-live"
    )),
    false,
    "a runtime-idle-only patch must not complete an explicitly in-progress turn"
  );

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: [
            "turnHistory",
            "history",
            "entitiesByKey",
            "turn:turn-index-live",
            "status",
          ],
          value: "completed",
        }],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/completed" && message.params?.turnId === "turn-index-live"
  )));
  assert.equal(indexRebuilds, 1, "status patches must update the active set without a full rebuild");
  outbound.length = 0;

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "patches",
        patches: [
          {
            op: "add",
            path: [
              "turnHistory",
              "history",
              "entitiesByKey",
              "turn:turn-index-next",
            ],
            value: {
              turnId: "turn-index-next",
              turnStartedAtMs: nowValue,
              durationMs: 0,
              status: "inProgress",
              items: [],
            },
          },
          {
            op: "add",
            path: ["turnHistory", "history", "islands", 0, "entries", entries.length],
            value: { key: "turn:turn-index-next", value: "turn:turn-index-next" },
          },
          { op: "replace", path: ["threadRuntimeStatus", "type"], value: "active" },
        ],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "turn/started" && message.params?.turnId === "turn-index-next"
  )));
  assert.equal(indexRebuilds, 2, "a structural turn-order patch should rebuild exactly once");
});

test("desktop IPC follower incrementally mirrors normalized guardian review updates", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-ipc-normalized-guardian-review-"
  );
  const outbound = [];
  let indexRebuilds = 0;
  const threadId = "thread-normalized-guardian-review";
  const turnKey = "turn:turn-normalized-review";
  const follower = createDesktopIpcActionFollower({
    socketPath,
    onNormalizedHistoryIndexRebuilt() {
      indexRebuilds += 1;
    },
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId },
  }));
  await waitFor(() => state.socket);
  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "idle", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                [turnKey]: {
                  turnId: "turn-normalized-review",
                  status: "completed",
                  items: [
                    {
                      id: "automatic-approval-review:review-normalized",
                      type: "automaticApprovalReview",
                      reviewId: "review-normalized",
                      targetItemId: "command-normalized",
                      startedAtMs: 100,
                      completedAtMs: null,
                      review: { status: "inProgress", riskLevel: null },
                      action: {
                        type: "command",
                        source: "shell",
                        command: "pwd",
                        cwd: "/tmp",
                      },
                    },
                    { id: "assistant-normalized", type: "agentMessage", text: "A" },
                  ],
                },
              },
              islands: [{
                id: "tail:normalized-review",
                entries: [{ key: turnKey, value: turnKey }],
              }],
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "item/autoApprovalReview/started"
  )));
  assert.equal(indexRebuilds, 1);
  outbound.length = 0;

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "patches",
        patches: [
          {
            op: "replace",
            path: [
              "turnHistory", "history", "entitiesByKey", turnKey,
              "items", 0, "review", "status",
            ],
            value: "denied",
          },
          {
            op: "replace",
            path: [
              "turnHistory", "history", "entitiesByKey", turnKey,
              "items", 0, "completedAtMs",
            ],
            value: 200,
          },
        ],
      },
    },
  });
  await waitFor(() => outbound.some((message) => (
    message.method === "item/autoApprovalReview/completed"
  )));
  assert.equal(indexRebuilds, 1, "review field updates must not rebuild normalized history");
  outbound.length = 0;

  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: [
            "turnHistory", "history", "entitiesByKey", turnKey,
            "items", 1, "text",
          ],
          value: "AB",
        }],
      },
    },
  });
  await wait(50);
  assert.equal(
    outbound.some((message) => message.method?.startsWith("item/autoApprovalReview/")),
    false,
    "unrelated content patches must not rescan or replay review overlays"
  );
  assert.equal(indexRebuilds, 1);
});

test("desktop IPC follower delivers normalized guardian reviews when an idle background thread is opened", async (t) => {
  const { socketPath, state } = await startInitializedIpcTestServer(
    t,
    "remodex-ipc-bg-open-review-"
  );
  const outbound = [];
  const threadId = "thread-background-open-review";
  const olderTurnKey = "turn:turn-background-review-older";
  const turnKey = "turn:turn-background-review";
  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    requestTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  // Sidebar refresh connects the Desktop bus without opening any thread, so
  // the snapshot below lands while the thread is still background-only.
  follower.observeInbound(JSON.stringify({
    method: "thread/list",
    params: {},
  }));
  await waitFor(() => state.socket);
  writeFrame(state.socket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-live",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [],
          requests: [],
          threadRuntimeStatus: { type: "idle", activeFlags: [] },
          turnHistory: {
            kind: "canonical",
            history: {
              entitiesByKey: {
                [olderTurnKey]: {
                  turnId: "turn-background-review-older",
                  status: "completed",
                  items: [
                    {
                      id: "automatic-approval-review:review-background-old-approved",
                      type: "automaticApprovalReview",
                      reviewId: "review-background-old-approved",
                      targetItemId: "command-background-old",
                      startedAtMs: 50,
                      completedAtMs: 75,
                      review: { status: "approved", riskLevel: "low" },
                      action: {
                        type: "command",
                        source: "shell",
                        command: "pwd",
                        cwd: "/tmp",
                      },
                    },
                    { id: "assistant-background-old", type: "agentMessage", text: "Old" },
                  ],
                },
                [turnKey]: {
                  turnId: "turn-background-review",
                  status: "completed",
                  items: [
                    {
                      id: "automatic-approval-review:review-background-open",
                      type: "automaticApprovalReview",
                      reviewId: "review-background-open",
                      targetItemId: "command-background",
                      startedAtMs: 100,
                      completedAtMs: 200,
                      review: { status: "denied", riskLevel: "high" },
                      event: { decision_source: "agent" },
                      action: {
                        type: "command",
                        source: "shell",
                        command: "rm -rf build",
                        cwd: "/tmp",
                      },
                    },
                    { id: "assistant-background", type: "agentMessage", text: "A" },
                  ],
                },
              },
              islands: [{
                id: "tail:background-review",
                entries: [
                  { key: olderTurnKey, value: olderTurnKey },
                  { key: turnKey, value: turnKey },
                ],
              }],
              isComplete: true,
            },
          },
        },
      },
    },
  });
  await wait(100);
  assert.equal(
    outbound.some((message) => message.method?.startsWith("item/autoApprovalReview/")),
    false,
    "background-only threads must not stream review rows before the phone opens them"
  );

  follower.observeInbound(JSON.stringify({
    method: "thread/read",
    params: { threadId },
  }));
  await waitFor(() => outbound.some((message) => (
    message.method === "item/autoApprovalReview/completed"
  )));
  const reviewNotification = outbound.find((message) => (
    message.method === "item/autoApprovalReview/completed"
  ));
  assert.equal(reviewNotification.params.threadId, threadId);
  assert.equal(reviewNotification.params.reviewId, "review-background-open");
  assert.equal(reviewNotification.params.review.status, "denied");
  assert.equal(
    outbound.some((message) => (
      message.params?.reviewId === "review-background-old-approved"
    )),
    false,
    "approved reviews outside the bounded projected tail must not be appended as detached rows"
  );
  assert.equal(
    reviewNotification.params.decisionSource,
    "agent",
    "overlay decisionSource must fall back to event.decision_source"
  );
  assert.equal(reviewNotification.params.remodexGuardianRetrySupported, false);
  assert.equal(
    outbound.some((message) => message.method === "thread/replaced"),
    true,
    "opening a canonical-history background thread announces a replacement"
  );
});

test("desktop IPC follower keeps phone interest in a thread across a Desktop disconnect", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-active-thread-disconnect-");
  const serverFrames = [];
  const localForwards = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex(rawMessage) {
      localForwards.push(JSON.parse(rawMessage));
    },
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 500,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-interest-disconnect" },
  }));
  await waitFor(() => serverSocket);

  // Before any disconnect, phone interest plus a live ownership probe window
  // means a quick turn/start is held rather than treated as unroutable.
  const heldBeforeDisconnect = follower.observeInbound(JSON.stringify({
    id: "phone-turn-before-disconnect",
    method: "turn/start",
    params: {
      threadId: "thread-interest-disconnect",
      input: [{ type: "input_text", text: "before disconnect" }],
    },
  }));
  assert.equal(heldBeforeDisconnect, true);

  serverSocket.destroy();
  await wait(25);

  // Phone interest is phone-scoped, not connection-scoped: a transient Desktop
  // disconnect must NOT drop it, or reconnect snapshots for a thread the phone
  // is still viewing would be ignored until the phone issues a fresh read. The
  // same ownership-probe window (still unexpired) must keep holding the turn.
  const handledAfterDisconnect = follower.observeInbound(JSON.stringify({
    id: "phone-turn-after-disconnect",
    method: "turn/start",
    params: {
      threadId: "thread-interest-disconnect",
      input: [{ type: "input_text", text: "after disconnect" }],
    },
  }));
  assert.equal(handledAfterDisconnect, true);
});

test("desktop IPC follower caps activeThreadIds so a marathon connection cannot grow it forever", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-active-thread-cap-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex() {},
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 10_000,
  });
  t.after(() => follower.stopAll());

  const oldestThreadId = "thread-cap-0";
  // MAX_ACTIVE_THREAD_IDS is 512: one more distinct thread than the cap must
  // evict the oldest LRU entry.
  const totalThreads = 513;
  for (let i = 0; i < totalThreads; i += 1) {
    follower.observeInbound(JSON.stringify({
      method: "thread/resume",
      params: { threadId: `thread-cap-${i}` },
    }));
  }
  await waitFor(() => serverSocket);

  const heldOldest = follower.observeInbound(JSON.stringify({
    id: "phone-turn-cap-oldest",
    method: "turn/start",
    params: {
      threadId: oldestThreadId,
      input: [{ type: "input_text", text: "oldest thread" }],
    },
  }));
  assert.equal(heldOldest, false, "the oldest thread id should have been evicted once the cap was exceeded");

  const newestThreadId = `thread-cap-${totalThreads - 1}`;
  const heldNewest = follower.observeInbound(JSON.stringify({
    id: "phone-turn-cap-newest",
    method: "turn/start",
    params: {
      threadId: newestThreadId,
      input: [{ type: "input_text", text: "newest thread" }],
    },
  }));
  assert.equal(heldNewest, true, "the most recently observed thread id should still be treated as active");
});

test("desktop IPC follower protects pending prompts from active-thread LRU eviction", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-active-thread-pending-cap-");
  const serverFrames = [];
  const outbound = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      serverFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      } else if (frame.method === "thread-follower-submit-user-input") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { ok: true },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    forwardToLocalCodex() {},
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 10_000,
  });
  t.after(() => follower.stopAll());

  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-pending-cap" },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-pending-cap",
      change: {
        type: "snapshot",
        conversationState: {
          requests: [{
            id: "req-pending-cap",
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-pending-cap",
              turnId: "turn-pending-cap",
              itemId: "item-pending-cap",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          }],
        },
      },
    },
  });
  await waitFor(() => outbound.find((message) => message.id === "req-pending-cap"));

  for (let i = 0; i < 512; i += 1) {
    follower.observeInbound(JSON.stringify({
      method: "thread/resume",
      params: { threadId: `thread-pending-cap-fill-${i}` },
    }));
  }

  await wait(25);
  assert.equal(
    outbound.some((message) => message.method === "serverRequest/resolved"
      && message.params?.requestId === "req-pending-cap"),
    false,
    "LRU eviction must not dismiss a still-pending Desktop prompt"
  );

  follower.observeInbound(JSON.stringify({
    id: "req-pending-cap",
    result: {
      answers: {
        q1: { answers: ["Yes"] },
      },
    },
  }));
  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-submit-user-input"));
  const replyFrame = serverFrames.find((frame) => frame.method === "thread-follower-submit-user-input");
  assert.equal(replyFrame.params.requestId, "req-pending-cap");
});

test("desktop IPC follower refreshes active-thread recency so re-read threads survive eviction", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-ipc-active-thread-lru-");
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const follower = createDesktopIpcActionFollower({
    socketPath,
    sendApplicationResponse() {},
    forwardToLocalCodex() {},
    requestTimeoutMs: 500,
    ownershipProbeTimeoutMs: 10_000,
  });
  t.after(() => follower.stopAll());

  // Fill the set exactly to MAX_ACTIVE_THREAD_IDS (512) with no eviction yet.
  for (let i = 0; i < 512; i += 1) {
    follower.observeInbound(JSON.stringify({
      method: "thread/resume",
      params: { threadId: `thread-lru-${i}` },
    }));
  }
  // Re-reading the oldest thread must refresh its recency (delete-before-add),
  // so the next overflow evicts thread-lru-1 instead of thread-lru-0.
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-lru-0" },
  }));
  follower.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-lru-512" },
  }));
  await waitFor(() => serverSocket);

  const heldRefreshed = follower.observeInbound(JSON.stringify({
    id: "phone-turn-lru-refreshed",
    method: "turn/start",
    params: {
      threadId: "thread-lru-0",
      input: [{ type: "input_text", text: "refreshed thread" }],
    },
  }));
  assert.equal(heldRefreshed, true, "a re-read thread must have its recency refreshed and survive eviction");

  const heldEvicted = follower.observeInbound(JSON.stringify({
    id: "phone-turn-lru-evicted",
    method: "turn/start",
    params: {
      threadId: "thread-lru-1",
      input: [{ type: "input_text", text: "evicted thread" }],
    },
  }));
  assert.equal(heldEvicted, false, "the least-recently-read thread must be the one evicted");
});

function backgroundConversationSnapshot(threadId, status, {
  turnId = null,
  items = [],
} = {}) {
  const turn = { status, items };
  if (turnId) {
    turn.id = turnId;
  }
  return {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: threadId,
      change: {
        type: "snapshot",
        conversationState: {
          turns: [turn],
          requests: [],
        },
      },
    },
  };
}

function attachFrameReader(socket, onFrame) {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const frameLength = buffer.readUInt32LE(0);
      if (buffer.length < 4 + frameLength) {
        return;
      }

      const payload = buffer.slice(4, 4 + frameLength).toString("utf8");
      buffer = buffer.slice(4 + frameLength);
      onFrame(JSON.parse(payload));
    }
  });
}

function writeFrame(socket, payload) {
  socket.write(encodeFrame(payload));
}

function emitFrame(socket, payload) {
  socket.emit("data", encodeFrame(payload));
}

function encodeFrame(payload) {
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function parseFrameBuffer(buffer) {
  const frameLength = buffer.readUInt32LE(0);
  return JSON.parse(buffer.slice(4, 4 + frameLength).toString("utf8"));
}

async function waitFor(predicate, timeoutMs = 500) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error("Timed out waiting for condition");
    }
    await wait(5);
  }
}

function createIpcTestSocket(prefix) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\${path.basename(tempDir)}-ipc`
    : path.join(tempDir, "ipc.sock");
  return { tempDir, socketPath };
}

async function startInitializedIpcTestServer(t, prefix) {
  const { tempDir, socketPath } = createIpcTestSocket(prefix);
  const state = { socket: null, connectionCount: 0, frames: [] };
  const server = net.createServer((socket) => {
    state.socket = socket;
    state.connectionCount += 1;
    socket.on("close", () => {
      if (state.socket === socket) {
        state.socket = null;
      }
    });
    attachFrameReader(socket, (frame) => {
      state.frames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "remodex-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    server.close();
    state.socket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });
  return { socketPath, state };
}

function useProcessPlatform(t, platform) {
  const descriptor = Object.getOwnPropertyDescriptor(process, "platform");
  Object.defineProperty(process, "platform", {
    ...descriptor,
    value: platform,
  });
  t.after(() => {
    Object.defineProperty(process, "platform", descriptor);
  });
}
