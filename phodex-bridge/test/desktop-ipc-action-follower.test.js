// FILE: desktop-ipc-action-follower.test.js
// Purpose: Verifies Codex Desktop IPC pending actions are projected and routed without using rollout text.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/desktop-ipc-action-follower

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: wait } = require("node:timers/promises");

const {
  applyConversationStateChange,
  createDesktopIpcActionFollower,
  desktopFollowerPayloadForResponse,
  projectPendingDesktopActions,
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

test("projects command and file approvals while ignoring completed or unsupported requests", () => {
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
        params: {},
      },
    ],
  });

  assert.deepEqual(
    actions.map((action) => [action.id, action.method, action.params.threadId]),
    [
      ["req-command", "item/commandExecution/requestApproval", "thread-2"],
      ["req-file", "item/fileChange/requestApproval", "thread-2"],
    ]
  );
  assert.equal(actions[0].params.command, "git status");
  assert.equal(actions[1].params.grantRoot, "/repo");
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

test("desktop IPC follower recovers a baseline before applying first patch-only action updates", async (t) => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-ipc-recovery-"));
  const socketPath = path.join(tempDir, "ipc.sock");
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
  await wait(60);

  assert.equal(outbound[0].id, "req-patch");
  assert.equal(outbound[0].method, "item/tool/requestUserInput");
});

test("desktop IPC follower answers client discovery requests as a passive client", async (t) => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-ipc-discovery-"));
  const socketPath = path.join(tempDir, "ipc.sock");
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
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-ipc-follower-"));
  const socketPath = path.join(tempDir, "ipc.sock");
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
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([header, body]));
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
