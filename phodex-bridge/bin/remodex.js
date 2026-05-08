#!/usr/bin/env node
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const readline = require("readline");
// FILE: remodex.js
// Purpose: CLI surface for foreground bridge runs, pairing reset, thread resume, and macOS service control.
// Layer: CLI binary
// Exports: none
// Depends on: ../src

const {
  getMacOSBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  readBridgeConfig,
  resetMacOSBridgePairing,
  runMacOSBridgeService,
  startBridge,
  startMacOSBridgeService,
  stopMacOSBridgeService,
  resetBridgePairing,
  openLastActiveThread,
  watchThreadRollout,
} = require("../src");
const { version } = require("../package.json");

const defaultDeps = {
  createRelayServer: loadLocalRelayServer,
  getMacOSBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  readBridgeConfig,
  resetMacOSBridgePairing,
  runMacOSBridgeService,
  startBridge,
  startMacOSBridgeService,
  stopMacOSBridgeService,
  resetBridgePairing,
  openLastActiveThread,
  watchThreadRollout,
};

if (require.main === module) {
  void main();
}

// ─── ENTRY POINT ─────────────────────────────────────────────

async function main({
  argv = process.argv,
  platform = process.platform,
  consoleImpl = console,
  exitImpl = process.exit,
  env = process.env,
  stdin = process.stdin,
  stdout = process.stdout,
  deps = defaultDeps,
} = {}) {
  const { command, jsonOutput, watchThreadId, switchBackend } = parseCliArgs(argv.slice(2));

  if (isVersionCommand(command)) {
    emitVersion({ jsonOutput, consoleImpl });
    return;
  }

  if (command === "up") {
    await runForegroundBridge({
      switchBackend,
      env,
      stdin,
      stdout,
      platform,
      deps,
      consoleImpl,
      exitImpl,
    });
    return;
  }

  if (command === "run") {
    await runForegroundBridge({
      switchBackend,
      env,
      stdin,
      stdout,
      platform,
      deps,
      consoleImpl,
      exitImpl,
    });
    return;
  }

  if (command === "run-service") {
    deps.runMacOSBridgeService();
    return;
  }

  if (command === "start") {
    assertMacOSCommand(command, {
      platform,
      consoleImpl,
      exitImpl,
    });
    deps.readBridgeConfig();
    const result = await deps.startMacOSBridgeService({
      waitForPairing: false,
    });
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        plistPath: result?.plistPath,
        pairingSession: result?.pairingSession,
      },
      message: "[remodex] macOS bridge service is running.",
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "restart") {
    assertMacOSCommand(command, {
      platform,
      consoleImpl,
      exitImpl,
    });
    deps.readBridgeConfig();
    const result = await deps.startMacOSBridgeService({
      waitForPairing: false,
    });
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        plistPath: result?.plistPath,
        pairingSession: result?.pairingSession,
      },
      message: "[remodex] macOS bridge service restarted.",
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "stop") {
    assertMacOSCommand(command, {
      platform,
      consoleImpl,
      exitImpl,
    });
    deps.stopMacOSBridgeService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
      },
      message: "[remodex] macOS bridge service stopped.",
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "status") {
    assertMacOSCommand(command, {
      platform,
      consoleImpl,
      exitImpl,
    });
    if (jsonOutput) {
      emitJson({
        ...deps.getMacOSBridgeServiceStatus(),
        currentVersion: version,
      });
      return;
    }
    deps.printMacOSBridgeServiceStatus();
    return;
  }

  if (command === "reset-pairing") {
    try {
      if (platform === "darwin") {
        deps.resetMacOSBridgePairing();
        emitResult({
          payload: {
            ok: true,
            currentVersion: version,
            platform: "darwin",
          },
          message: "[remodex] Stopped the macOS bridge service and cleared the saved pairing state. Run `remodex up` to pair again.",
          jsonOutput,
          consoleImpl,
        });
      } else {
        deps.resetBridgePairing();
        emitResult({
          payload: {
            ok: true,
            currentVersion: version,
            platform,
          },
          message: "[remodex] Cleared the saved pairing state. Run `remodex up` to pair again.",
          jsonOutput,
          consoleImpl,
        });
      }
    } catch (error) {
      consoleImpl.error(`[remodex] ${(error && error.message) || "Failed to clear the saved pairing state."}`);
      exitImpl(1);
    }
    return;
  }

  if (command === "resume") {
    try {
      const state = deps.openLastActiveThread();
      emitResult({
        payload: {
          ok: true,
          currentVersion: version,
          threadId: state.threadId,
          source: state.source || "unknown",
        },
        message: `[remodex] Opened last active thread: ${state.threadId} (${state.source || "unknown"})`,
        jsonOutput,
        consoleImpl,
      });
    } catch (error) {
      consoleImpl.error(`[remodex] ${(error && error.message) || "Failed to reopen the last thread."}`);
      exitImpl(1);
    }
    return;
  }

  if (command === "watch") {
    try {
      deps.watchThreadRollout(watchThreadId);
    } catch (error) {
      consoleImpl.error(`[remodex] ${(error && error.message) || "Failed to watch the thread rollout."}`);
      exitImpl(1);
    }
    return;
  }

  consoleImpl.error(`Unknown command: ${command}`);
  consoleImpl.error(
    "Usage: remodex up | remodex run | remodex start | remodex restart | remodex stop | remodex status | "
    + "remodex reset-pairing | remodex resume | remodex watch [threadId] | remodex --version | "
    + "append --json to start/restart/stop/status/reset-pairing/resume for machine-readable output"
  );
  exitImpl(1);
}

async function runForegroundBridge({
  switchBackend = false,
  env = process.env,
  stdin = process.stdin,
  stdout = process.stdout,
  platform = process.platform,
  deps = defaultDeps,
  consoleImpl = console,
  exitImpl = process.exit,
} = {}) {
  const backendType = await resolveSelectedBackend({
    forceSwitch: switchBackend,
    env,
    stdin,
    stdout,
    consoleImpl,
  });
  stopMacOSServiceBeforeForegroundRun({
    platform,
    deps,
    consoleImpl,
  });
  const relay = await ensureForegroundRelay({
    env,
    deps,
    consoleImpl,
    exitImpl,
  });
  const config = {
    ...deps.readBridgeConfig?.(),
    relayUrl: relay.relayUrl,
  };
  deps.startBridge({
    backendType,
    config,
  });
}

function parseCliArgs(rawArgs) {
  const positionals = [];
  let jsonOutput = false;
  let switchBackend = false;

  for (const arg of rawArgs) {
    if (arg === "--json") {
      jsonOutput = true;
      continue;
    }
    if (arg === "--switch") {
      switchBackend = true;
      continue;
    }

    positionals.push(arg);
  }

  return {
    command: positionals[0] || "up",
    jsonOutput,
    switchBackend,
    watchThreadId: positionals[1] || "",
  };
}

async function ensureForegroundRelay({
  env = process.env,
  deps = defaultDeps,
  consoleImpl = console,
  exitImpl = process.exit,
} = {}) {
  const explicitRelayUrl = readFirstDefinedEnv(["REMODEX_RELAY", "PHODEX_RELAY"], env);
  if (explicitRelayUrl) {
    return {
      relayUrl: explicitRelayUrl,
      server: null,
    };
  }

  const createRelayServer = typeof deps.createRelayServer === "function"
    ? deps.createRelayServer()
    : null;
  if (typeof createRelayServer !== "function") {
    consoleImpl.error("[remodex] Unable to start the local relay bundled with this CLI.");
    exitImpl(1);
    return { relayUrl: "", server: null };
  }

  const bindHost = readFirstDefinedEnv(["REMODEX_RELAY_BIND_HOST", "PHODEX_RELAY_BIND_HOST"], env)
    || "0.0.0.0";
  const requestedPort = parseOptionalPort(
    readFirstDefinedEnv(["REMODEX_RELAY_PORT", "PHODEX_RELAY_PORT"], env)
  );
  const advertisedHost = normalizeAdvertisedHost(
    readFirstDefinedEnv(["REMODEX_RELAY_HOST", "PHODEX_RELAY_HOST", "REMODEX_HOSTNAME"], env)
      || selectDefaultAdvertisedHost()
  );
  const { server } = createRelayServer();
  const port = requestedPort || 0;
  await listen(server, {
    host: bindHost,
    port,
  });
  const address = server.address();
  const actualPort = typeof address === "object" && address ? address.port : port;
  const relayUrl = `ws://${formatRelayHost(advertisedHost)}:${actualPort}/relay`;

  consoleImpl.log(`[remodex] local relay listening on ${bindHost}:${actualPort}`);
  consoleImpl.log(`[remodex] advertising relay as ${relayUrl}`);
  installRelayShutdownHandlers({
    server,
    consoleImpl,
    exitImpl,
  });

  return {
    relayUrl,
    server,
  };
}

function listen(server, { host, port }) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port, host);
  });
}

function installRelayShutdownHandlers({
  server,
  consoleImpl = console,
  exitImpl = process.exit,
} = {}) {
  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    consoleImpl.log(`[remodex] shutting down local relay (${signal})`);
    server.close(() => exitImpl(0));
    setTimeout(() => exitImpl(0), 2_000).unref?.();
  };
  process.once("SIGINT", () => shutdown("SIGINT"));
  process.once("SIGTERM", () => shutdown("SIGTERM"));
}

function readFirstDefinedEnv(names, env = process.env) {
  for (const name of names) {
    const value = env?.[name];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return "";
}

function parseOptionalPort(value) {
  if (!value) {
    return 0;
  }
  const port = Number.parseInt(value, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid relay port: ${value}`);
  }
  return port;
}

function selectDefaultAdvertisedHost({
  networkInterfaces = os.networkInterfaces,
} = {}) {
  const interfaces = networkInterfaces();
  for (const addresses of Object.values(interfaces)) {
    for (const address of addresses || []) {
      if (address?.family === "IPv4" && !address.internal) {
        return address.address;
      }
    }
  }
  return "127.0.0.1";
}

function normalizeAdvertisedHost(host) {
  const trimmed = String(host || "").trim();
  if (!trimmed) {
    return "127.0.0.1";
  }
  if (trimmed.includes("://")) {
    throw new Error("Relay host must be a hostname or IP address, not a URL.");
  }
  return trimmed.replace(/^\[|\]$/g, "");
}

function formatRelayHost(host) {
  return net.isIP(host) === 6 ? `[${host}]` : host;
}

function loadLocalRelayServer() {
  return require("../src/local-relay").createRelayServer;
}

async function resolveSelectedBackend({
  forceSwitch = false,
  env = process.env,
  stdin = process.stdin,
  stdout = process.stdout,
  consoleImpl = console,
} = {}) {
  const configPath = resolveUserConfigPath({ env });
  let config = readUserConfig(configPath);
  const configuredBackend = normalizeBackendType(config.backend);
  if (configuredBackend && !forceSwitch) {
    return configuredBackend;
  }

  let backend = "codex";
  if (stdin?.isTTY) {
    backend = await promptForBackend({ stdin, stdout, consoleImpl });
  } else {
    consoleImpl.error("[remodex] No saved AI backend and stdin is not interactive; defaulting to Codex. Run `remodex up --switch` in a terminal to choose Gemini.");
  }

  config = {
    ...config,
    backend,
  };
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  return backend;
}

function resolveUserConfigPath({ env = process.env } = {}) {
  const home = env.HOME || os.homedir();
  return path.join(home, ".remodex", "config.json");
}

function readUserConfig(configPath) {
  try {
    if (fs.existsSync(configPath)) {
      const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
      if (parsed && typeof parsed === "object") {
        return parsed;
      }
    }
  } catch {
    // Ignore malformed user config and re-prompt/default safely.
  }
  return {};
}

function normalizeBackendType(value) {
  return value === "gemini" || value === "codex" ? value : "";
}

async function promptForBackend({
  stdin = process.stdin,
  stdout = process.stdout,
  consoleImpl = console,
} = {}) {
  const rl = readline.createInterface({
    input: stdin,
    output: stdout,
  });
  const ask = (question) => new Promise((resolve) => rl.question(question, resolve));
  try {
    consoleImpl.log("");
    consoleImpl.log("Which AI backend do you want to use?");
    consoleImpl.log("  1) Codex (OpenAI)");
    consoleImpl.log("  2) Gemini CLI (Google)");
    const answer = (await ask("Enter 1 or 2: ")).trim();
    return answer === "2" ? "gemini" : "codex";
  } finally {
    rl.close();
  }
}

function emitVersion({
  jsonOutput = false,
  consoleImpl = console,
} = {}) {
  if (jsonOutput) {
    emitJson({
      currentVersion: version,
    });
    return;
  }

  consoleImpl.log(version);
}

function emitResult({
  payload,
  message,
  jsonOutput = false,
  consoleImpl = console,
} = {}) {
  if (jsonOutput) {
    emitJson(payload);
    return;
  }

  consoleImpl.log(message);
}

function emitJson(payload) {
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
}

function assertMacOSCommand(name, {
  platform = process.platform,
  consoleImpl = console,
  exitImpl = process.exit,
} = {}) {
  if (platform === "darwin") {
    return;
  }

  consoleImpl.error(`[remodex] \`${name}\` is only available on macOS. Use \`remodex up\` or \`remodex run\` for the foreground bridge on this OS.`);
  exitImpl(1);
}

function stopMacOSServiceBeforeForegroundRun({
  platform,
  deps,
  consoleImpl,
}) {
  if (platform !== "darwin" || typeof deps.stopMacOSBridgeService !== "function") {
    return;
  }

  try {
    deps.stopMacOSBridgeService();
  } catch (error) {
    consoleImpl.error(`[remodex] Could not stop the existing macOS bridge service: ${error.message}`);
  }
}

function isVersionCommand(value) {
  return value === "-v" || value === "--v" || value === "-V" || value === "--version" || value === "version";
}

module.exports = {
  isVersionCommand,
  main,
  normalizeBackendType,
  parseCliArgs,
  resolveSelectedBackend,
};
