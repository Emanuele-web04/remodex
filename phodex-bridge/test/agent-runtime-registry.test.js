// FILE: agent-runtime-registry.test.js
// Purpose: Verifies agent runtime registry routing, initialize payloads, and thread projection.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/agent-runtime-registry, ../src/thread-agent-state

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createAgentRuntimeRegistry } = require("../src/agent-runtime-registry");
const { createThreadAgentStateStore } = require("../src/thread-agent-state");

test("agent runtime registry returns codex ready and cursor not_installed", async () => {
  await withTempStateDir(async ({ registry }) => {
    const runtimes = await registry.listAgentRuntimes();
    assert.equal(runtimes[0].id, "codex");
    assert.equal(runtimes[0].status, "ready");
    assert.equal(runtimes[0].modelCatalog.defaultModelId, "gpt-5.5");
    assert.equal(runtimes[2].id, "cursor");
    assert.equal(runtimes[2].status, "not_installed");
    assert.equal(runtimes[2].modelCatalog.status, "unavailable");
  });
});

test("agent runtime registry reports opencode not_installed when binary is missing", async () => {
  await withTempStateDir(async ({ registry }) => {
    const openCode = await registry.resolveOpenCodeStatus({
      forceRefresh: true,
    });
    assert.equal(openCode.id, "opencode");
    assert.equal(openCode.status, "not_installed");
    assert.equal(openCode.modelCatalog.defaultModelId, "opencode-go/deepseek-v4-flash");
    assert.ok(openCode.modelCatalog.models.some((model) => model.providerID === "opencode-go"));
  }, {
    execFileImpl: async () => {
      const error = new Error("ENOENT");
      error.code = "ENOENT";
      throw error;
    },
  });
});

test("agent runtime registry survives opencode probe failures without throwing", async () => {
  await withTempStateDir(async ({ registry }) => {
    const openCode = await registry.resolveOpenCodeStatus({
      forceRefresh: true,
    });
    assert.equal(openCode.id, "opencode");
    assert.equal(openCode.status, "error");
  }, {
    execFileImpl: async () => {
      throw new Error("probe failed");
    },
  });
});

test("warm initialize payload includes bridge-managed runtime list", async () => {
  await withTempStateDir(async ({ registry }) => {
    await registry.refreshInitializeCache();
    const payload = registry.buildWarmInitializeResult();
    assert.equal(payload.bridgeManaged, true);
    assert.equal(payload.defaultAgentRuntime, "codex");
    assert.equal(Array.isArray(payload.agentRuntimes), true);
    assert.equal(payload.agentRuntimes.length, 3);
  }, {
    execFileImpl: missingCommandExecFile,
  });
});

test("agent/runtime/list responds with runtime inventory", async () => {
  await withTempStateDir(async ({ registry }) => {
    await registry.refreshInitializeCache();
    const responses = [];
    const handled = await registry.handleInboundRequest(JSON.stringify({
      id: "runtime-list-1",
      method: "agent/runtime/list",
      params: {},
    }), (rawMessage) => {
      responses.push(JSON.parse(rawMessage));
    });

    assert.equal(handled, true);
    assert.equal(responses.length, 1);
    assert.equal(responses[0].result.defaultAgentRuntime, "codex");
    assert.equal(responses[0].result.agentRuntimes.length, 3);
  }, {
    execFileImpl: missingCommandExecFile,
  });
});

test("thread/list projection injects bridge runtime fields and backfills legacy codex threads", async () => {
  await withTempStateDir(async ({ registry }) => {
    const enriched = registry.enrichOutboundResponse(JSON.stringify({
      id: "thread-list-1",
      result: {
        data: [{ id: "thread-legacy", title: "Legacy thread" }],
      },
    }), { method: "thread/list" });

    const parsed = JSON.parse(enriched);
    assert.equal(parsed.result.data[0].agentRuntime, "codex");
    assert.equal(parsed.result.data[0].agentSessionId, "thread-legacy");
    assert.equal(parsed.result.data[0].opencodeBuildAgentName, "build");
    assert.equal(parsed.result.data[0].opencodePlanAgentName, "plan");
  });
});

test("thread/start locks runtime after successful codex response", async () => {
  await withTempStateDir(async ({ registry, stateDir }) => {
    const allowed = registry.validateThreadStartRequest(JSON.stringify({
      id: "thread-start-1",
      method: "thread/start",
      params: {
        threadId: "thread-1",
        agentRuntime: "codex",
      },
    }));
    assert.equal(allowed.allowed, true);

    registry.observeOutboundMessage(JSON.stringify({
      id: "thread-start-1",
      result: {
        thread: { id: "thread-1" },
      },
    }));

    const record = registry.threadAgentState.get("thread-1");
    assert.equal(record.runtimeLocked, true);
    assert.equal(record.agentRuntime, "codex");
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(stateDir, "thread-agent-state.json"), "utf8")).threads["thread-1"].runtimeLocked,
      true
    );
  });
});

test("runtime dispatch forwards codex thread/start through the adapter", async () => {
  const forwarded = [];
  await withTempStateDir(async ({ registry }) => {
    const rawRequest = JSON.stringify({
      id: "thread-start-dispatch-1",
      method: "thread/start",
      params: {
        threadId: "thread-dispatch",
        agentRuntime: "codex",
        cwd: "/tmp/remodex",
      },
    });

    const handled = await registry.handleRuntimeRequest(rawRequest, {
      sendResponse: () => {
        throw new Error("codex runtime dispatch should not send an error response");
      },
      sendToRuntime(runtimeId, rawMessage) {
        forwarded.push({ runtimeId, rawMessage });
      },
    });

    assert.equal(handled, true);
    assert.equal(forwarded.length, 1);
    assert.equal(forwarded[0].runtimeId, "codex");
    assert.deepEqual(JSON.parse(forwarded[0].rawMessage), JSON.parse(rawRequest));

    const record = registry.threadAgentState.get("thread-dispatch");
    assert.equal(record.agentRuntime, "codex");
    assert.equal(record.cwd, "/tmp/remodex");
  });
});

test("runtime dispatch forwards existing codex turn requests by thread state", async () => {
  const forwarded = [];
  await withTempStateDir(async ({ registry }) => {
    registry.threadAgentState.upsert("thread-existing", {
      agentRuntime: "codex",
      agentSessionId: "thread-existing",
      runtimeLocked: true,
    });

    const rawRequest = JSON.stringify({
      id: "turn-start-dispatch-1",
      method: "turn/start",
      params: {
        threadId: "thread-existing",
        input: "hello",
      },
    });

    const handled = await registry.handleRuntimeRequest(rawRequest, {
      sendResponse: () => {
        throw new Error("codex turn dispatch should not send an error response");
      },
      sendToRuntime(runtimeId, rawMessage) {
        forwarded.push({ runtimeId, rawMessage });
      },
    });

    assert.equal(handled, true);
    assert.equal(forwarded.length, 1);
    assert.equal(forwarded[0].runtimeId, "codex");
    assert.equal(JSON.parse(forwarded[0].rawMessage).method, "turn/start");
  });
});

test("runtime dispatch rejects unavailable non-codex thread/start without forwarding", async () => {
  const forwarded = [];
  const responses = [];
  await withTempStateDir(async ({ registry }) => {
    const handled = await registry.handleRuntimeRequest(JSON.stringify({
      id: "thread-start-opencode-1",
      method: "thread/start",
      params: {
        threadId: "thread-opencode",
        agentRuntime: "opencode",
      },
    }), {
      sendResponse(rawMessage) {
        responses.push(JSON.parse(rawMessage));
      },
      sendToRuntime(runtimeId, rawMessage) {
        forwarded.push({ runtimeId, rawMessage });
      },
    });

    assert.equal(handled, true);
    assert.equal(forwarded.length, 0);
    assert.equal(responses.length, 1);
    assert.equal(responses[0].error.data.errorCode, "agent_runtime_unavailable");
  });
});

test("runtime dispatch can route to an injected non-codex adapter", async () => {
  const forwarded = [];
  const fakeOpenCodeAdapter = {
    id: "opencode",
    async handleRuntimeRequest({ rawMessage, sendToRuntime }) {
      sendToRuntime(rawMessage);
    },
  };

  await withTempStateDir(async ({ registry }) => {
    const rawRequest = JSON.stringify({
      id: "thread-start-opencode-available-1",
      method: "thread/start",
      params: {
        threadId: "thread-opencode-available",
        agentRuntime: "opencode",
      },
    });

    const handled = await registry.handleRuntimeRequest(rawRequest, {
      sendResponse() {
        throw new Error("available runtime should not produce an error response");
      },
      sendToRuntime(runtimeId, rawMessage) {
        forwarded.push({ runtimeId, rawMessage });
      },
    });

    assert.equal(handled, true);
    assert.equal(forwarded.length, 1);
    assert.equal(forwarded[0].runtimeId, "opencode");
    assert.equal(registry.threadAgentState.get("thread-opencode-available").agentRuntime, "opencode");
  }, {
    runtimeAdapters: [fakeOpenCodeAdapter],
  });
});

test("runtime dispatch rejects existing unavailable runtime threads without falling back to codex", async () => {
  const forwarded = [];
  const responses = [];
  await withTempStateDir(async ({ registry }) => {
    registry.threadAgentState.upsert("thread-opencode", {
      agentRuntime: "opencode",
      agentSessionId: "opencode-session-1",
      runtimeLocked: true,
    });

    const handled = await registry.handleRuntimeRequest(JSON.stringify({
      id: "turn-start-opencode-1",
      method: "turn/start",
      params: {
        threadId: "thread-opencode",
        input: "hello",
      },
    }), {
      sendResponse(rawMessage) {
        responses.push(JSON.parse(rawMessage));
      },
      sendToRuntime(runtimeId, rawMessage) {
        forwarded.push({ runtimeId, rawMessage });
      },
    });

    assert.equal(handled, true);
    assert.equal(forwarded.length, 0);
    assert.equal(responses.length, 1);
    assert.equal(responses[0].error.data.errorCode, "agent_runtime_unavailable");
  });
});

test("runtime dispatch isolates adapter failures as json-rpc errors", async () => {
  const responses = [];
  const failingAdapter = {
    id: "codex",
    shouldHandleRuntime(agentRuntime) {
      return agentRuntime === "codex";
    },
    async getRuntimeListEntry() {
      return { id: "codex", status: "ready" };
    },
    async handleRuntimeRequest() {
      throw new Error("adapter exploded");
    },
  };

  await withTempStateDir(async ({ registry }) => {
    const handled = await registry.handleRuntimeRequest(JSON.stringify({
      id: "thread-list-failed-1",
      method: "thread/list",
      params: {},
    }), {
      sendResponse(rawMessage) {
        responses.push(JSON.parse(rawMessage));
      },
      sendToRuntime() {
        throw new Error("sendToRuntime should not be called after adapter failure");
      },
    });

    assert.equal(handled, true);
    assert.equal(responses.length, 1);
    assert.equal(responses[0].error.data.errorCode, "agent_runtime_dispatch_failed");
  }, {
    codexAdapter: failingAdapter,
  });
});

test("runtime dispatch ignores non-runtime bridge methods", async () => {
  await withTempStateDir(async ({ registry }) => {
    const handled = await registry.handleRuntimeRequest(JSON.stringify({
      id: "workspace-read-1",
      method: "workspace/read",
      params: {},
    }), {
      sendResponse() {
        throw new Error("non-runtime methods should not be answered by runtime registry");
      },
      sendToRuntime() {
        throw new Error("non-runtime methods should not be forwarded by runtime registry");
      },
    });

    assert.equal(handled, false);
  });
});

test("runtime response routing sends pending responses to non-codex adapters", async () => {
  const responses = [];
  const fakeOpenCodeAdapter = {
    id: "opencode",
    async handleRuntimeResponse({ parsed, sendResponse }) {
      if (parsed.id !== "per_123") {
        return false;
      }
      sendResponse(JSON.stringify({
        method: "serverRequest/resolved",
        params: { requestId: "per_123" },
      }));
      return true;
    },
  };

  await withTempStateDir(async ({ registry }) => {
    const handled = await registry.handleRuntimeResponse(JSON.stringify({
      id: "per_123",
      result: {
        permissions: { edit: true },
      },
    }), {
      sendResponse(rawMessage) {
        responses.push(JSON.parse(rawMessage));
      },
    });

    assert.equal(handled, true);
    assert.equal(responses[0].method, "serverRequest/resolved");
    assert.equal(responses[0].params.requestId, "per_123");
  }, {
    runtimeAdapters: [fakeOpenCodeAdapter],
  });
});

test("runtime response routing ignores normal requests and unknown responses", async () => {
  await withTempStateDir(async ({ registry }) => {
    assert.equal(await registry.handleRuntimeResponse(JSON.stringify({
      id: "turn-start-1",
      method: "turn/start",
      params: {},
    })), false);

    assert.equal(await registry.handleRuntimeResponse(JSON.stringify({
      id: "unknown-response",
      result: {},
    })), false);
  });
});

test("thread/fork responses inherit runtime metadata into bridge state", async () => {
  await withTempStateDir(async ({ registry }) => {
    registry.threadAgentState.upsert("thread-source", {
      agentRuntime: "opencode",
      agentSessionId: "ses-source",
      runtimeLocked: true,
    });

    registry.trackForwardedRequest(JSON.stringify({
      id: "fork-1",
      method: "thread/fork",
      params: { sourceThreadId: "thread-source" },
    }));

    registry.observeOutboundMessage(JSON.stringify({
      id: "fork-1",
      result: {
        thread: {
          id: "thread-forked",
          agentSessionId: "thread-forked",
        },
      },
    }));

    const forked = registry.threadAgentState.get("thread-forked");
    assert.equal(forked?.agentRuntime, "opencode");
    assert.equal(forked?.runtimeLocked, true);
  });
});

test("thread/start rejects runtime changes after lock", async () => {
  await withTempStateDir(async ({ registry }) => {
    registry.threadAgentState.lockRuntime("thread-locked", {
      agentRuntime: "codex",
      agentSessionId: "thread-locked",
    });

    const blocked = registry.validateThreadStartRequest(JSON.stringify({
      id: "thread-start-2",
      method: "thread/start",
      params: {
        threadId: "thread-locked",
        agentRuntime: "opencode",
      },
    }));

    assert.equal(blocked.allowed, false);
    assert.match(blocked.message, /locked/i);
    assert.equal(blocked.errorCode, "agent_runtime_locked");
  });
});

test("initialize responses merge bridge runtime payload on cold reconnect", async () => {
  await withTempStateDir(async ({ registry }) => {
    await registry.refreshInitializeCache();
    const enriched = registry.enrichOutboundResponse(JSON.stringify({
      id: "initialize-1",
      result: {
        serverInfo: { name: "codex" },
      },
    }), { method: "initialize" });

    const parsed = JSON.parse(enriched);
    assert.equal(parsed.result.serverInfo.name, "codex");
    assert.equal(parsed.result.bridgeManaged, true);
    assert.equal(parsed.result.defaultAgentRuntime, "codex");
    assert.equal(parsed.result.agentRuntimes.length, 3);
  }, {
    execFileImpl: missingCommandExecFile,
  });
});

async function withTempStateDir(run, { codexAdapter, execFileImpl, runtimeAdapters } = {}) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-agent-runtime-"));
  process.env.REMODEX_DEVICE_STATE_DIR = stateDir;

  const registry = createAgentRuntimeRegistry({
    threadAgentState: createThreadAgentStateStore(),
    ...(codexAdapter ? { codexAdapter } : {}),
    ...(runtimeAdapters ? { runtimeAdapters } : {}),
    execFileImpl: execFileImpl || missingCommandExecFile,
    logImpl: { warn() {} },
  });

  try {
    await run({ registry, stateDir });
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
}

async function missingCommandExecFile() {
  const error = new Error("ENOENT");
  error.code = "ENOENT";
  throw error;
}
