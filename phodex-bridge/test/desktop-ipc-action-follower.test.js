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
  hasActiveDesktopActivityForTurn,
  projectDesktopActivityNotifications,
  projectDesktopAssistantDeltaNotifications,
  projectDesktopTurnCompletedNotifications,
  projectDesktopUserMessageNotifications,
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

test("projects desktop user prelude notifications once for active assistant turns", () => {
  const mirroredKeys = new Set();
  const state = {
    turns: [{
      id: "turn-1",
      items: [{
        id: "user-1",
        type: "user_message",
        text: "Fix the ordering",
        createdAt: "2026-05-26T20:01:42.000Z",
      }, {
        id: "assistant-1",
        type: "assistant_message",
        text: "Working",
      }],
    }, {
      id: "turn-old",
      items: [{
        id: "user-old",
        type: "user_message",
        text: "Old prompt",
      }],
    }],
  };

  const first = projectDesktopUserMessageNotifications(
    "thread-1",
    state,
    mirroredKeys,
    new Set(["turn-1"])
  );
  const second = projectDesktopUserMessageNotifications(
    "thread-1",
    state,
    mirroredKeys,
    new Set(["turn-1"])
  );

  assert.deepEqual(first, [{
    method: "codex/event/user_message",
    params: {
      threadId: "thread-1",
      turnId: "turn-1",
      message: "Fix the ordering",
      id: "user-1",
      timestamp: "2026-05-26T20:01:42.000Z",
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
    },
  }]);
  assert.deepEqual(second, []);
});

test("projects desktop turn completion notifications from terminal state", () => {
  const state = {
    turns: [{
      id: "turn-1",
      status: "completed",
      items: [{
        id: "assistant-1",
        type: "assistant_message",
        text: "Done",
      }],
    }, {
      id: "turn-running",
      status: "running",
      items: [{
        id: "assistant-running",
        type: "assistant_message",
        text: "Still going",
      }],
    }, {
      id: "turn-terminal-active-tool",
      status: "completed",
      items: [{
        id: "tool-running",
        type: "tool_call",
        status: "running",
      }],
    }, {
      id: "turn-terminal-active-function-call",
      status: "completed",
      items: [{
        id: "call-active",
        type: "function_call",
        call_id: "call-active",
        name: "exec_command",
      }],
    }],
  };

  assert.deepEqual(
    projectDesktopTurnCompletedNotifications(
      "thread-1",
      state,
      new Set([
        "turn-1",
        "turn-running",
        "turn-terminal-active-tool",
        "turn-terminal-active-function-call",
      ])
    ),
    [{
      method: "turn/completed",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        id: "turn-1",
        status: "completed",
        remodexDesktopMirror: true,
        remodexDesktopIpcMirror: true,
      },
    }]
  );
});

test("detects active desktop activity before idle turn completion", () => {
  const state = {
    turns: [{
      id: "turn-running-tool",
      items: [{
        id: "tool-1",
        type: "tool_call",
        status: "running",
      }],
    }, {
      id: "turn-running-function-call",
      items: [{
        id: "call-active",
        type: "function_call",
        call_id: "call-active",
        name: "exec_command",
      }],
    }, {
      id: "turn-finished-function-call",
      items: [{
        id: "call-finished",
        type: "function_call",
        call_id: "call-finished",
        name: "exec_command",
      }, {
        type: "function_call_output",
        call_id: "call-finished",
        output: "done",
      }],
    }, {
      id: "turn-completed-tool",
      items: [{
        id: "tool-2",
        type: "command_execution",
        status: "completed",
      }],
    }],
  };

  assert.equal(hasActiveDesktopActivityForTurn(state, "turn-running-tool"), true);
  assert.equal(hasActiveDesktopActivityForTurn(state, "turn-running-function-call"), true);
  assert.equal(hasActiveDesktopActivityForTurn(state, "turn-finished-function-call"), false);
  assert.equal(hasActiveDesktopActivityForTurn(state, "turn-completed-tool"), false);
});

test("projects desktop IPC bare function calls as live tool rows", () => {
  const mirroredKeys = new Set();
  const stateWithCall = {
    turns: [{
      id: "turn-tool",
      items: [{
        id: "call-1",
        type: "function_call",
        call_id: "call-1",
        name: "exec_command",
        arguments: JSON.stringify({ cmd: "git status", workdir: "/repo" }),
      }],
    }],
  };

  assert.deepEqual(projectDesktopActivityNotifications("thread-1", stateWithCall, mirroredKeys), [{
    method: "codex/event/exec_command_begin",
    params: {
      threadId: "thread-1",
      turnId: "turn-tool",
      call_id: "call-1",
      command: "git status",
      cwd: "/repo",
      status: "running",
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
    },
  }]);
  assert.deepEqual(projectDesktopActivityNotifications("thread-1", stateWithCall, mirroredKeys), []);

  const stateWithOutput = {
    turns: [{
      id: "turn-tool",
      items: [
        ...stateWithCall.turns[0].items,
        {
          type: "function_call_output",
          call_id: "call-1",
          output: "clean\\n",
        },
      ],
    }],
  };

  assert.deepEqual(projectDesktopActivityNotifications("thread-1", stateWithOutput, mirroredKeys), [{
    method: "codex/event/exec_command_output_delta",
    params: {
      threadId: "thread-1",
      turnId: "turn-tool",
      call_id: "call-1",
      command: "git status",
      cwd: "/repo",
      chunk: "clean\\n",
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
    },
  }, {
    method: "codex/event/exec_command_end",
    params: {
      threadId: "thread-1",
      turnId: "turn-tool",
      call_id: "call-1",
      command: "git status",
      cwd: "/repo",
      status: "completed",
      output: "clean\\n",
      remodexDesktopMirror: true,
      remodexDesktopIpcMirror: true,
    },
  }]);
});

test("projects completed-fast desktop custom tool calls as finished file changes", () => {
  const notifications = projectDesktopActivityNotifications("thread-1", {
    turns: [{
      id: "turn-patch",
      status: "running",
      items: [{
        id: "patch-1",
        type: "custom_tool_call",
        call_id: "patch-1",
        name: "apply_patch",
        status: "completed",
        input: [
          "*** Begin Patch",
          "*** Add File: note.txt",
          "+hello",
          "*** End Patch",
        ].join("\n"),
      }],
    }],
  }, new Set());

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].method, "codex/event/patch_apply_end");
  assert.equal(notifications[0].params.threadId, "thread-1");
  assert.equal(notifications[0].params.turnId, "turn-patch");
  assert.equal(notifications[0].params.call_id, "patch-1");
  assert.equal(notifications[0].params.status, "completed");
  assert.equal(notifications[0].params.success, true);
  assert.equal(notifications[0].params.changes[0].path, "note.txt");
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
    turnCompletionIdleMs: 10,
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
            items: [{
              id: "user-live-delta",
              type: "user_message",
              text: "Make the message show first",
            }, {
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
          path: ["turns", 0, "items", 1, "text"],
          value: "Hello world",
        }],
      },
    },
  });

  await waitFor(() => outbound.find((message) => message.method === "item/agentMessage/delta"));
  assert.equal(outbound[0].method, "codex/event/user_message");
  assert.deepEqual(outbound[0].params, {
    threadId: "thread-live-delta",
    turnId: "turn-live-delta",
    message: "Make the message show first",
    id: "user-live-delta",
    remodexDesktopMirror: true,
    remodexDesktopIpcMirror: true,
  });
  const deltaMessage = outbound.find((message) => message.method === "item/agentMessage/delta");
  assert.deepEqual(deltaMessage.params, {
    threadId: "thread-live-delta",
    turnId: "turn-live-delta",
    itemId: "assistant-live-delta",
    delta: " world",
  });
  await waitFor(() => outbound.find((message) => message.method === "turn/completed"));
  const completedMessage = outbound.find((message) => message.method === "turn/completed");
  assert.deepEqual(completedMessage.params, {
    threadId: "thread-live-delta",
    turnId: "turn-live-delta",
    id: "turn-live-delta",
    status: "completed",
    remodexDesktopMirror: true,
    remodexDesktopIpcMirror: true,
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
