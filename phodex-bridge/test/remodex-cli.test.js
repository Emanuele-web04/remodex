// FILE: remodex-cli.test.js
// Purpose: Verifies the public CLI exposes version, service control, and machine-readable status output.
// Layer: Integration-lite test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, child_process, path, ../package.json, ../bin/remodex

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { EventEmitter } = require("events");
const { Readable, Writable } = require("stream");
const { version } = require("../package.json");
const { main } = require("../bin/remodex");

test("remodex --version prints the package version", () => {
  const cliPath = path.join(__dirname, "..", "bin", "remodex.js");
  const output = execFileSync(process.execPath, [cliPath, "--version"], {
    encoding: "utf8",
  }).trim();

  assert.equal(output, version);
});

test("remodex restart reuses the macOS service start flow", async () => {
  const calls = [];
  const messages = [];

  await main({
    argv: ["node", "remodex", "restart"],
    platform: "darwin",
    consoleImpl: {
      log(message) {
        messages.push(message);
      },
      error(message) {
        messages.push(message);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      readBridgeConfig() {
        calls.push("read-config");
      },
      async startMacOSBridgeService(options) {
        calls.push(["start-service", options]);
        return {
          plistPath: "/tmp/remodex.plist",
          pairingSession: { relay: "ws://127.0.0.1:9000/relay" },
        };
      },
    },
  });

  assert.deepEqual(calls, [
    "read-config",
    ["start-service", { waitForPairing: false }],
  ]);
  assert.deepEqual(messages, [
    "[remodex] macOS bridge service restarted.",
  ]);
});

test("remodex up runs the bridge in the foreground on macOS", async () => {
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cli-home-"));
  const calls = [];
  const errors = [];

  await main({
    argv: ["node", "remodex", "up"],
    platform: "darwin",
    env: { HOME: tempHome, REMODEX_RELAY: "ws://127.0.0.1:9000/relay" },
    stdin: nonTTYInput(),
    consoleImpl: {
      log() {},
      error(message) {
        errors.push(message);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      stopMacOSBridgeService() {
        calls.push(["stop-service"]);
      },
      startBridge(options) {
        calls.push(["start-bridge", options]);
      },
    },
  });

  assert.deepEqual(errors, [
    "[remodex] No saved AI backend and stdin is not interactive; defaulting to Codex. Run `remodex up --switch` in a terminal to choose Gemini.",
  ]);
  assert.deepEqual(calls, [
    ["stop-service"],
    ["start-bridge", {
      backendType: "codex",
      config: {
        relayUrl: "ws://127.0.0.1:9000/relay",
      },
    }],
  ]);
});

test("remodex up uses the saved backend and passes it to the foreground bridge", async () => {
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cli-home-"));
  fs.mkdirSync(path.join(tempHome, ".remodex"), { recursive: true });
  fs.writeFileSync(
    path.join(tempHome, ".remodex", "config.json"),
    JSON.stringify({ backend: "gemini" }),
    "utf8"
  );
  const calls = [];

  await main({
    argv: ["node", "remodex", "up"],
    platform: "linux",
    env: { HOME: tempHome, REMODEX_RELAY: "ws://127.0.0.1:9000/relay" },
    stdin: nonTTYInput(),
    consoleImpl: quietConsole(),
    deps: {
      startBridge(options) {
        calls.push(["start-bridge", options]);
      },
    },
  });

  assert.deepEqual(calls, [
    ["start-bridge", {
      backendType: "gemini",
      config: {
        relayUrl: "ws://127.0.0.1:9000/relay",
      },
    }],
  ]);
});

test("remodex up defaults to Codex when backend selection is non-interactive", async () => {
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cli-home-"));
  const calls = [];
  const errors = [];

  await main({
    argv: ["node", "remodex", "up"],
    platform: "linux",
    env: { HOME: tempHome, REMODEX_RELAY: "ws://127.0.0.1:9000/relay" },
    stdin: nonTTYInput(),
    consoleImpl: {
      log() {},
      error(message) {
        errors.push(message);
      },
    },
    deps: {
      startBridge(options) {
        calls.push(["start-bridge", options]);
      },
    },
  });

  assert.deepEqual(calls, [
    ["start-bridge", {
      backendType: "codex",
      config: {
        relayUrl: "ws://127.0.0.1:9000/relay",
      },
    }],
  ]);
  assert.match(errors.join("\n"), /defaulting to Codex/);
  const saved = JSON.parse(fs.readFileSync(path.join(tempHome, ".remodex", "config.json"), "utf8"));
  assert.equal(saved.backend, "codex");
});

test("remodex up --switch can save Gemini from an interactive terminal", async () => {
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cli-home-"));
  const input = Readable.from(["2\n"]);
  input.isTTY = true;
  const output = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
  const calls = [];

  await main({
    argv: ["node", "remodex", "up", "--switch"],
    platform: "linux",
    env: { HOME: tempHome, REMODEX_RELAY: "ws://127.0.0.1:9000/relay" },
    stdin: input,
    stdout: output,
    consoleImpl: quietConsole(),
    deps: {
      startBridge(options) {
        calls.push(["start-bridge", options]);
      },
    },
  });

  assert.deepEqual(calls, [
    ["start-bridge", {
      backendType: "gemini",
      config: {
        relayUrl: "ws://127.0.0.1:9000/relay",
      },
    }],
  ]);
  const saved = JSON.parse(fs.readFileSync(path.join(tempHome, ".remodex", "config.json"), "utf8"));
  assert.equal(saved.backend, "gemini");
});

test("remodex up starts an embedded relay when no relay URL is configured", async () => {
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cli-home-"));
  const calls = [];
  const logs = [];
  const server = createFakeRelayServer({ port: 54321 });

  await main({
    argv: ["node", "remodex", "up"],
    platform: "linux",
    env: {
      HOME: tempHome,
      REMODEX_RELAY_HOST: "192.168.1.50",
    },
    stdin: nonTTYInput(),
    consoleImpl: {
      log(message) {
        logs.push(message);
      },
      error() {},
    },
    deps: {
      createRelayServer() {
        return () => ({ server });
      },
      readBridgeConfig() {
        return {
          keepMacAwakeEnabled: true,
        };
      },
      startBridge(options) {
        calls.push(["start-bridge", options]);
      },
    },
  });

  assert.deepEqual(server.listenArgs, {
    host: "0.0.0.0",
    port: 0,
  });
  assert.deepEqual(calls, [
    ["start-bridge", {
      backendType: "codex",
      config: {
        keepMacAwakeEnabled: true,
        relayUrl: "ws://192.168.1.50:54321/relay",
      },
    }],
  ]);
  assert.match(logs.join("\n"), /local relay listening on 0\.0\.0\.0:54321/);
});

test("remodex status --json exposes daemon metadata for companion apps", async () => {
  const writes = [];
  const originalWrite = process.stdout.write;

  process.stdout.write = (chunk, encoding, callback) => {
    writes.push(String(chunk));
    if (typeof callback === "function") {
      callback();
    }
    return true;
  };

  try {
    await main({
      argv: ["node", "remodex", "status", "--json"],
      platform: "darwin",
      consoleImpl: {
        log() {},
        error(message) {
          throw new Error(`unexpected error: ${message}`);
        },
      },
      exitImpl(code) {
        throw new Error(`unexpected exit ${code}`);
      },
      deps: {
        getMacOSBridgeServiceStatus() {
          return {
            daemonConfig: {
              relayUrl: "ws://127.0.0.1:9000/relay",
            },
            bridgeStatus: {
              connectionStatus: "connected",
              pid: 77,
            },
            pairingSession: {
              pairingPayload: {
                relay: "ws://127.0.0.1:9000/relay",
                sessionId: "session-json",
              },
            },
          };
        },
        printMacOSBridgeServiceStatus() {
          throw new Error("status printer should not run for --json");
        },
      },
    });
  } finally {
    process.stdout.write = originalWrite;
  }

  const payload = JSON.parse(writes.join("").trim());
  assert.equal(payload.currentVersion, version);
  assert.equal(payload.daemonConfig?.relayUrl, "ws://127.0.0.1:9000/relay");
  assert.equal(payload.bridgeStatus?.connectionStatus, "connected");
  assert.equal(payload.pairingSession?.pairingPayload?.sessionId, "session-json");
});

function quietConsole() {
  return {
    log() {},
    error() {},
  };
}

function createFakeRelayServer({ port }) {
  const server = new EventEmitter();
  server.listenArgs = null;
  server.listen = (listenPort, host) => {
    server.listenArgs = {
      host,
      port: listenPort,
    };
    queueMicrotask(() => server.emit("listening"));
  };
  server.address = () => ({ port });
  server.close = (callback) => {
    callback?.();
  };
  return server;
}

function nonTTYInput() {
  const input = Readable.from([]);
  input.isTTY = false;
  return input;
}
