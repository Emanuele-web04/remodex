// FILE: local-relay.test.js
// Purpose: Verifies CLI argument parsing and the embedded relay server used by TryCloudflare mode.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ws, ../src/cli-options, ../src/local-relay

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const WebSocket = require("ws");

const { parseCliArgs } = require("../src/cli-options");
const {
  createTunnelLaunchError,
  extractTryCloudflareUrl,
  getCloudflaredInstallHint,
  startLocalRelayServer,
  startTryCloudflareTunnel,
  waitForPublicTunnelReady,
} = require("../src/local-relay");

test("parseCliArgs reads TryCloudflare flags for `up`", () => {
  const result = parseCliArgs(["up", "--trycloudflare", "--trycloudflare-port", "8787"]);

  assert.equal(result.command, "up");
  assert.equal(result.options.tryCloudflare, true);
  assert.equal(result.options.tryCloudflarePort, 8787);
  assert.deepEqual(result.positionals, []);
});

test("parseCliArgs ignores a bare `--` separator from npm-style script forwarding", () => {
  const result = parseCliArgs(["up", "--", "--trycloudflare"]);

  assert.equal(result.command, "up");
  assert.equal(result.options.tryCloudflare, true);
});

test("parseCliArgs rejects unknown options", () => {
  assert.throws(
    () => parseCliArgs(["up", "--nope"]),
    /Unknown option: --nope/
  );
});

test("parseCliArgs rejects TryCloudflare options for non-up commands", () => {
  assert.throws(
    () => parseCliArgs(["resume", "--trycloudflare"]),
    /--trycloudflare is only supported with `remodex up`/
  );
  assert.throws(
    () => parseCliArgs(["watch", "--trycloudflare-port", "8787"]),
    /--trycloudflare-port is only supported with `remodex up`/
  );
});

test("parseCliArgs requires --trycloudflare when a TryCloudflare port is provided", () => {
  assert.throws(
    () => parseCliArgs(["up", "--trycloudflare-port", "8787"]),
    /--trycloudflare-port requires --trycloudflare/
  );
});

test("parseCliArgs rejects out-of-range TryCloudflare ports", () => {
  assert.throws(
    () => parseCliArgs(["up", "--trycloudflare", "--trycloudflare-port", "70000"]),
    /expects an integer between 0 and 65535/
  );
});

test("extractTryCloudflareUrl reads the public quick tunnel URL from logs", () => {
  const line = "INF | Your quick Tunnel has been created! Visit it at https://alpha-beta.trycloudflare.com";
  assert.equal(
    extractTryCloudflareUrl(line),
    "https://alpha-beta.trycloudflare.com"
  );
});

test("createTunnelLaunchError explains how to install cloudflared when it is missing", () => {
  const error = createTunnelLaunchError("cloudflared", {
    code: "ENOENT",
    message: "spawn cloudflared ENOENT",
  }, "darwin");

  assert.match(error.message, /requires `cloudflared` to be installed/);
  assert.match(error.message, /brew install cloudflared/);
});

test("getCloudflaredInstallHint provides Linux-safe guidance without macOS-specific commands", () => {
  const hint = getCloudflaredInstallHint("linux");

  assert.match(hint, /Linux instructions/);
  assert.match(hint, /developers\.cloudflare\.com\/tunnel\/setup/);
  assert.doesNotMatch(hint, /brew install cloudflared/);
});

test("waitForPublicTunnelReady retries until the public health endpoint responds", async () => {
  let attempts = 0;

  await waitForPublicTunnelReady({
    publicUrl: "https://alpha-beta.trycloudflare.com",
    timeoutMs: 200,
    pollIntervalMs: 0,
    async fetchImpl(url) {
      attempts += 1;
      assert.equal(url, "https://alpha-beta.trycloudflare.com/healthz");

      if (attempts < 3) {
        throw new Error("tunnel not ready yet");
      }

      return { ok: true, status: 200 };
    },
  });

  assert.equal(attempts, 3);
});

test("waitForPublicTunnelReady fails with a clear timeout error when health checks never pass", async () => {
  await assert.rejects(
    () => waitForPublicTunnelReady({
      publicUrl: "https://alpha-beta.trycloudflare.com",
      timeoutMs: 20,
      pollIntervalMs: 0,
      async fetchImpl() {
        throw new Error("connect ECONNRESET");
      },
    }),
    /Timed out waiting for public tunnel readiness/
  );
});

test("startTryCloudflareTunnel keeps waiting after the initial readiness window and resolves once the public tunnel is reachable", async () => {
  const child = createFakeChildProcess();
  const statuses = [];
  let attempts = 0;
  const startup = startTryCloudflareTunnel({
    localUrl: "http://127.0.0.1:8787",
    cloudflaredBin: "cloudflared",
    readyTimeoutMs: 20,
    readyPollIntervalMs: 0,
    onStatus(status) {
      statuses.push(status.type);
    },
    async fetchImpl() {
      attempts += 1;
      if (attempts === 1) {
        await delay(25);
        throw new Error("connect ECONNRESET");
      }

      return { ok: true, status: 200 };
    },
    spawnImpl() {
      queueMicrotask(() => {
        child.stdout.emit("data", Buffer.from(
          "INF Your quick Tunnel has been created! Visit it at https://alpha-beta.trycloudflare.com\n",
          "utf8"
        ));
      });
      return child;
    },
  });

  const tunnel = await startup;

  assert.equal(tunnel.publicUrl, "https://alpha-beta.trycloudflare.com");
  assert.equal(tunnel.socketBaseUrl, "wss://alpha-beta.trycloudflare.com");
  assert.deepEqual(statuses, ["public_url_discovered", "public_pending", "public_ready"]);

  await tunnel.close();
  assert.equal(child.killSignals[0], "SIGTERM");
});

test("startTryCloudflareTunnel emits a ready status once the public tunnel becomes reachable", async () => {
  const child = createFakeChildProcess();
  const statuses = [];
  const startup = startTryCloudflareTunnel({
    localUrl: "http://127.0.0.1:8787",
    cloudflaredBin: "cloudflared",
    readyTimeoutMs: 200,
    readyPollIntervalMs: 0,
    onStatus(status) {
      statuses.push(status.type);
    },
    async fetchImpl() {
      return { ok: true, status: 200 };
    },
    spawnImpl() {
      queueMicrotask(() => {
        child.stdout.emit("data", Buffer.from(
          "INF Your quick Tunnel has been created! Visit it at https://alpha-beta.trycloudflare.com\n",
          "utf8"
        ));
      });
      return child;
    },
  });

  const tunnel = await startup;

  assert.equal(tunnel.publicReadyAt.length > 0, true);
  assert.deepEqual(statuses, ["public_url_discovered", "public_ready"]);

  await tunnel.close();
});

test("startLocalRelayServer forwards messages between the Mac and iPhone roles", async () => {
  const relay = await startLocalRelayServer();
  const sessionUrl = `ws://127.0.0.1:${relay.port}/relay/test-session`;
  const mac = new WebSocket(sessionUrl, {
    headers: { "x-role": "mac" },
  });
  const iphone = new WebSocket(sessionUrl, {
    headers: { "x-role": "iphone" },
  });

  await Promise.all([
    onceOpen(mac),
    onceOpen(iphone),
  ]);

  const forwardedText = await new Promise((resolve, reject) => {
    iphone.once("message", (payload) => resolve(payload.toString("utf8")));
    iphone.once("error", reject);
    mac.send("hello-through-local-relay");
  });

  assert.equal(forwardedText, "hello-through-local-relay");

  mac.close();
  iphone.close();
  await relay.close();
});

test("startLocalRelayServer exposes a websocket relay URL for the local bridge", async () => {
  const relay = await startLocalRelayServer();

  assert.match(relay.socketBaseUrl, /^ws:\/\/127\.0\.0\.1:\d+$/);
  assert.match(relay.relayUrl, /^ws:\/\/127\.0\.0\.1:\d+\/relay$/);

  await relay.close();
});

function onceOpen(socket) {
  return new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function createFakeChildProcess() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.exitCode = null;
  child.killed = false;
  child.killSignals = [];
  child.kill = (signal) => {
    child.killed = true;
    child.killSignals.push(signal);
    child.exitCode = 0;
    queueMicrotask(() => {
      child.emit("exit", 0, signal);
    });
    return true;
  };
  return child;
}
