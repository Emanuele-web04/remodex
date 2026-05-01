#!/usr/bin/env node
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
  deps = defaultDeps,
} = {}) {
  const { command, jsonOutput, watchThreadId } = parseCliArgs(argv.slice(2));

  if (isVersionCommand(command)) {
    emitVersion({ jsonOutput, consoleImpl });
    return;
  }

  if (command === "up") {
    if (platform === "darwin") {
      consoleImpl.log("[remodex] Starting bridge and pairing QR...");
      const result = await deps.startMacOSBridgeService({
        waitForPairing: true,
      });
      deps.printMacOSBridgePairingQr({
        pairingSession: result.pairingSession,
      });
      return;
    }

    deps.startBridge();
    return;
  }

  if (command === "run") {
    deps.startBridge();
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

function parseCliArgs(rawArgs) {
  const positionals = [];
  let jsonOutput = false;

  for (const arg of rawArgs) {
    if (arg === "--json") {
      jsonOutput = true;
      continue;
    }

    positionals.push(arg);
  }

  return {
    command: positionals[0] || "up",
    jsonOutput,
    watchThreadId: positionals[1] || "",
  };
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

function isVersionCommand(value) {
  return value === "-v" || value === "--v" || value === "-V" || value === "--version" || value === "version";
}

module.exports = {
  isVersionCommand,
  main,
};
