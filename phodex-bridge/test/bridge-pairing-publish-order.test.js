// FILE: bridge-pairing-publish-order.test.js
// Purpose: Verifies pairing QR/file emission happens only after relay Mac socket opens.
// Layer: Integration test
// Exports: node:test suite
// Depends on: node:test, ws, fs, os, path, ../src/bridge with mocked transports

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const Module = require("node:module");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: wait } = require("node:timers/promises");
const WebSocket = require("ws");

test("bridge writes pairing session and prints QR only after relay mac socket opens", async (t) => {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-pairing-order-"));
  const pairingPath = path.join(stateDir, "pairing-session.json");
  const relayServer = new WebSocket.Server({ port: 0 });
  const publishEvents = [];
  let relaySocket = null;
  let bridge = null;
  let fakeCodex = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
  });

  const { startBridge } = loadBridgePairingOrderTestDoubles({
    stateDir,
    pairingPath,
    publishEvents,
    createCodexTransportImpl() {
      fakeCodex = createHealthyCodexTransport();
      return fakeCodex;
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    fs.rmSync(stateDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: true,
    onPairingSession(session) {
      publishEvents.push({ type: "callback", at: Date.now(), session });
    },
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

  assert.equal(
    publishEvents.filter((event) => event.type === "write").length,
    0,
    "pairing file must not be written before relay open",
  );
  assert.equal(
    publishEvents.filter((event) => event.type === "print").length,
    0,
    "QR must not be printed before relay open",
  );
  assert.equal(
    publishEvents.filter((event) => event.type === "callback").length,
    0,
    "onPairingSession must not fire before relay open",
  );
  assert.equal(fs.existsSync(pairingPath), false);

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN, 2_000);
  await wait(25);

  assert.equal(publishEvents.filter((event) => event.type === "write").length, 1);
  assert.equal(publishEvents.filter((event) => event.type === "print").length, 1);
  assert.equal(publishEvents.filter((event) => event.type === "callback").length, 1);
  assert.equal(fs.existsSync(pairingPath), true);

  const writeIndex = publishEvents.findIndex((event) => event.type === "write");
  const printIndex = publishEvents.findIndex((event) => event.type === "print");
  assert.ok(writeIndex >= 0);
  assert.ok(printIndex >= 0);
  assert.ok(
    writeIndex < publishEvents.length && printIndex < publishEvents.length,
    "publish events should be recorded",
  );
});

function loadBridgePairingOrderTestDoubles({
  stateDir,
  pairingPath,
  publishEvents,
  createCodexTransportImpl,
} = {}) {
  const bridgePath = require.resolve("../src/bridge");
  const originalLoad = Module._load;
  delete require.cache[bridgePath];
  Module._load = function loadWithPairingOrderDoubles(request, parent, isMain) {
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
      return createRuntimeDetectionDouble("codex+opencode");
    }
    if (parent?.filename === bridgePath && request === "./daemon-state") {
      return {
        readDaemonConfig: () => ({}),
        writeDaemonConfig: () => {},
        writePairingSession(pairingSession) {
          publishEvents.push({ type: "write", at: Date.now(), pairingSession });
          fs.writeFileSync(pairingPath, JSON.stringify(pairingSession));
        },
        resolvePairingSessionPath: () => pairingPath,
      };
    }
    if (parent?.filename === bridgePath && request === "./qr") {
      return {
        printQR(pairingSession) {
          publishEvents.push({ type: "print", at: Date.now(), pairingSession });
        },
        createShortPairingCode: () => "ABCD",
        SHORT_PAIRING_CODE_LENGTH: 4,
      };
    }
    return originalLoad.call(this, request, parent, isMain);
  };

  try {
    process.env.REMODEX_DEVICE_STATE_DIR = stateDir;
    return require("../src/bridge");
  } finally {
    Module._load = originalLoad;
    delete require.cache[bridgePath];
  }
}

function createRuntimeDetectionDouble(mode) {
  const opencodeAvailable = mode !== "codex-only" && mode !== "none";
  const codexAvailable = mode !== "opencode-only" && mode !== "none";
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
        sessionId: "session-pairing-order-test",
        deviceState,
      };
    },
  };
}

function createHealthyCodexTransport() {
  const listeners = {};
  return {
    describe() {
      return "fake codex app-server";
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
      setImmediate(() => handler({ mode: "test" }));
    },
    shutdown() {
      listeners.close?.();
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