// FILE: desktop-ipc-action-follower.test.js
// Purpose: Verifies Codex Desktop IPC pending actions are projected and routed without using rollout text.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/desktop-ipc-action-follower

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: wait } = require("node:timers/promises");

const {
  applyConversationStateChange,
  createDesktopIpcActionFollower,
  desktopFollowerPayloadForResponse,
  projectDesktopAssistantDeltaNotifications,
  projectPendingDesktopActions,
  resolveDefaultIpcSocketPath,
  seedConversationStateFromThreadRead,
} = require("../src/desktop-ipc-action-follower");

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
});

test("uses the Codex Desktop named pipe as the default Windows IPC path", (t) => {
  useProcessPlatform(t, "win32");
  assert.equal(resolveDefaultIpcSocketPath(), "\\\\.\\pipe\\codex-ipc");
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
    },
  }));
  assert.equal(handled, true);

  await waitFor(() => serverFrames.find((frame) => frame.method === "thread-follower-start-turn"));
  const turnStartFrame = serverFrames.find((frame) => frame.method === "thread-follower-start-turn");
  assert.equal(turnStartFrame.version, 1);
  assert.deepEqual(turnStartFrame.params, {
    conversationId: "thread-desktop-owned",
    senderRequestId: "phone-turn-start-1",
    turnStartParams: {
      threadId: "thread-desktop-owned",
      input: [{ type: "input_text", text: "continue from phone" }],
      cwd: "/repo",
      model: "gpt-test",
    },
  });

  await waitFor(() => outbound.find((message) => message.id === "phone-turn-start-1"));
  assert.deepEqual(outbound.find((message) => message.id === "phone-turn-start-1"), {
    id: "phone-turn-start-1",
    result: { turn: { id: "turn-from-phone" } },
  });

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
        turnId: "turn-from-phone",
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
    // Versions mirror Codex Desktop's bundled method map (interrupt is v2).
    assert.equal(
      routedFrame.version,
      request.expectedMethod === "thread-follower-interrupt-turn" ? 2 : 1
    );
    assert.deepEqual(routedFrame.params, request.expectedParams);
    await waitFor(() => outbound.find((message) => message.id === request.id));
    assert.deepEqual(outbound.find((message) => message.id === request.id), {
      id: request.id,
      result: { turn: { id: "turn-from-phone" } },
    });
  }
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
  assert.deepEqual(turnStartFrame.params.turnStartParams, {
    threadId: "thread-normalize",
    input: [{ type: "input_text", text: "continue" }],
    summary: "none",
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
          response: { canHandle: frame.request?.version === 1 },
        });
      } else if (frame.method === "thread-follower-start-turn") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { turn: { id: "turn-probe-owned" } },
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
  assert.equal(routedStarts[0].params.turnStartParams.input[0].text, "new duplicate");
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

test("desktop IPC follower stops serving stale active-turn caches to phone reads", async (t) => {
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

  // While Desktop keeps the stream fresh, cached reads answer immediately.
  assert.equal(follower.hasFreshLiveThreadState("thread-stale-active"), true);
  const freshServed = follower.observeInbound(JSON.stringify({
    id: "read-fresh",
    method: "thread/read",
    params: { threadId: "thread-stale-active" },
  }));
  assert.equal(freshServed, true);
  assert.equal(outbound.some((message) => message.id === "read-fresh"), true);

  // Desktop went silent while the cache still claims an active turn: the cache
  // is stale evidence, so the read must fall through to the local app-server
  // instead of pinning a phantom running indicator on the phone. The same
  // staleness must unmute the rollout fallback mirror (hasFreshLiveThreadState
  // false while hasLiveThreadState stays true) so the reopened thread recovers.
  fakeNow += 21_000;
  assert.equal(follower.hasLiveThreadState("thread-stale-active"), true);
  assert.equal(follower.hasFreshLiveThreadState("thread-stale-active"), false);
  const staleServed = follower.observeInbound(JSON.stringify({
    id: "read-stale",
    method: "thread/read",
    params: { threadId: "thread-stale-active" },
  }));
  assert.equal(staleServed, false);
  assert.equal(outbound.some((message) => message.id === "read-stale"), false);

  // Idle cached threads have no phantom-running risk: they stay servable.
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
            items: [],
          }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => outbound.some((message) => message.method === "turn/completed"));
  fakeNow += 60_000;
  const idleServed = follower.observeInbound(JSON.stringify({
    id: "read-idle",
    method: "thread/read",
    params: { threadId: "thread-stale-active" },
  }));
  assert.equal(idleServed, true);
  assert.equal(outbound.some((message) => message.id === "read-idle"), true);
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
