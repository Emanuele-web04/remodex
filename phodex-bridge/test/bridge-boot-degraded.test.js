// FILE: bridge-boot-degraded.test.js
// Purpose: Verifies OpenCode-only bridge boot survives Codex ENOENT and registers on relay.
// Layer: Integration test
// Exports: node:test suite
// Depends on: node:test, ws, ../src/bridge with mocked transports

const test = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");
const { setTimeout: wait } = require("node:timers/promises");
const WebSocket = require("ws");

test("bridge stays up in degraded mode when Codex ENOENT and OpenCode is available", async (t) => {
  const relayServer = new WebSocket.Server({ port: 0 });
  let relaySocket = null;
  let bridge = null;
  let fakeCodex = null;
  let processExitCode = null;
  const originalExit = process.exit;
  process.exit = (code = 0) => {
    processExitCode = code;
    throw new Error(`process.exit(${code})`);
  };

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket, request) => {
    relaySocket = socket;
    assert.equal(request.headers["x-role"], "mac");
  });

  const { startBridge } = loadBridgeBootTestDoubles({
    runtimeMode: "opencode-only",
    createCodexTransportImpl() {
      fakeCodex = createFailingCodexTransport();
      return fakeCodex;
    },
  });

  t.after(() => {
    process.exit = originalExit;
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN, 2_000);
  fakeCodex.emitError(Object.assign(new Error("spawn codex ENOENT"), { code: "ENOENT" }));
  await wait(50);

  assert.equal(processExitCode, null, "bridge must not call process.exit when OpenCode carries it");
  assert.equal(relaySocket.readyState, WebSocket.OPEN, "relay mac socket should stay connected");
  assert.equal(fakeCodex.shutdownCalls, 0, "degraded boot should not tear down on Codex ENOENT");
});

function loadBridgeBootTestDoubles({
  runtimeMode = "opencode-only",
  createCodexTransportImpl,
} = {}) {
  const bridgePath = require.resolve("../src/bridge");
  const originalLoad = Module._load;
  delete require.cache[bridgePath];
  Module._load = function loadWithBridgeBootDoubles(request, parent, isMain) {
    if (parent?.filename === bridgePath && request === "./codex-transport") {
      return { createCodexTransport: createCodexTransportImpl };
    }
    if (parent?.filename === bridgePath && request === "./secure-transport") {
      return { createBridgeSecureTransport: createPlaintextSecureTransport };
    }
    if (parent?.filename === bridgePath && request === "./secure-device-state") {
      return createSecureDeviceStateDouble();
    }
    if (parent?.filename === bridgePath && request === "./runtime-detection") {
      return createRuntimeDetectionDouble(runtimeMode);
    }
    return originalLoad.call(this, request, parent, isMain);
  };

  try {
    return require("../src/bridge");
  } finally {
    Module._load = originalLoad;
    delete require.cache[bridgePath];
  }
}

function createRuntimeDetectionDouble(mode) {
  const opencodeAvailable = mode === "opencode-only" || mode === "codex+opencode";
  const codexAvailable = mode === "codex-only" || mode === "codex+opencode";
  return {
    resolveAvailableRuntimes() {
      return {
        mode,
        codexAvailable,
        opencodeAvailable,
        opencodeEnabled: opencodeAvailable,
        opencodeCommand: "opencode",
      };
    },
    formatRuntimePreflightFailureMessage() {
      return "no runtime";
    },
    opencodeCarriesBridge(runtimes) {
      return runtimes?.opencodeAvailable === true;
    },
  };
}

function createPlaintextSecureTransport() {
  return {
    createPairingPayload() {
      return { v: 1, expiresAt: Date.now() + 60_000 };
    },
    bindLiveSendWireMessage() {},
    handleIncomingWireMessage(message, { onApplicationMessage }) {
      onApplicationMessage(message);
      return true;
    },
    queueOutboundApplicationMessage(message, sendWireMessage) {
      sendWireMessage(message);
    },
  };
}

function createSecureDeviceStateDouble() {
  return {
    loadOrCreateBridgeDeviceState() {
      return {
        macDeviceId: "mac-test",
        macIdentityPublicKey: "mac-key-test",
        trustedPhones: {},
      };
    },
    rememberLastSeenPhoneAppVersion(deviceState) {
      return deviceState;
    },
    resolveBridgeRelaySession(deviceState) {
      return {
        sessionId: "session-degraded-test",
        deviceState,
      };
    },
  };
}

function createFailingCodexTransport() {
  const listeners = {};
  return {
    shutdownCalls: 0,
    describe() {
      return "`codex app-server`";
    },
    send() {},
    onMessage(handler) {
      listeners.message = handler;
    },
    onClose(handler) {
      listeners.close = handler;
    },
    onError(handler) {
      listeners.error = handler;
    },
    onStarted(handler) {
      listeners.started = handler;
    },
    shutdown() {
      this.shutdownCalls += 1;
      listeners.close?.();
    },
    emitError(error) {
      listeners.error?.(error);
    },
  };
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