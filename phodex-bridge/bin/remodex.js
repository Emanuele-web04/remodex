#!/usr/bin/env node
// FILE: remodex.js
// Purpose: CLI surface for foreground bridge runs, pairing reset, thread resume, and OS service control.
// Layer: CLI binary
// Exports: none
// Depends on: ../src

const {
  getMacOSBridgeServiceStatus,
  getWindowsBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  printWindowsBridgePairingQr,
  printWindowsBridgeServiceStatus,
  readBridgeConfig,
  resetMacOSBridgePairing,
  resetWindowsBridgePairing,
  restartMacOSBridgeService,
  restartWindowsBridgeService,
  runMacOSBridgeService,
  runWindowsBridgeService,
  startBridge,
  startMacOSBridgeService,
  startWindowsBridgeService,
  stopMacOSBridgeService,
  stopWindowsBridgeService,
  resetBridgePairing,
  openLastActiveThread,
  watchThreadRollout,
} = require("../src");
const { version } = require("../package.json");

const defaultDeps = {
  getMacOSBridgeServiceStatus,
  getWindowsBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  printWindowsBridgePairingQr,
  printWindowsBridgeServiceStatus,
  readBridgeConfig,
  resetMacOSBridgePairing,
  resetWindowsBridgePairing,
  restartMacOSBridgeService,
  restartWindowsBridgeService,
  runMacOSBridgeService,
  runWindowsBridgeService,
  startBridge,
  startMacOSBridgeService,
  startWindowsBridgeService,
  stopMacOSBridgeService,
  stopWindowsBridgeService,
  resetBridgePairing,
  openLastActiveThread,
  watchThreadRollout,
};

if (require.main === module) {
  void runCli();
}

// ─── ENTRY POINT ─────────────────────────────────────────────

// Runs the CLI process and turns expected configuration failures into readable terminal output.
async function runCli({
  mainImpl = main,
  consoleImpl = console,
  exitImpl = process.exit,
} = {}) {
  try {
    await mainImpl();
  } catch (error) {
    const rawMessage = error && typeof error.message === "string"
      ? error.message.trim()
      : String(error || "Command failed");
    const message = rawMessage || "Command failed";
    consoleImpl.error(message.startsWith("[remodex]") ? message : `[remodex] ${message}`);
    exitImpl(1);
  }
}

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

    if (platform === "win32") {
      consoleImpl.log("[remodex] Starting Windows bridge task and pairing QR...");
      const result = await deps.startWindowsBridgeService({
        waitForPairing: true,
      });
      deps.printWindowsBridgePairingQr({
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
    if (platform === "darwin") {
      deps.runMacOSBridgeService();
      return;
    }
    if (platform === "win32") {
      deps.runWindowsBridgeService();
      return;
    }
    consoleImpl.error("[remodex] `run-service` is only available on macOS and Windows service backends. Use `remodex run` for the foreground bridge on this OS.");
    exitImpl(1);
    return;
  }

  if (command === "start") {
    const provider = getServiceProvider(command, { platform, deps, consoleImpl, exitImpl });
    const result = await provider.startService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        ...serviceResultPayload(result),
        pairingSession: sanitizePairingSessionForOutput(result?.pairingSession),
      },
      message: provider.startedMessage,
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "restart") {
    const provider = getServiceProvider(command, { platform, deps, consoleImpl, exitImpl });
    const result = await provider.restartService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        ...serviceResultPayload(result),
        pairingSession: sanitizePairingSessionForOutput(result?.pairingSession),
      },
      message: provider.restartedMessage,
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "qr" || command === "pair") {
    const provider = getServiceProvider(command, { platform, deps, consoleImpl, exitImpl });
    const result = await provider.startService({
      waitForPairing: true,
    });
    if (jsonOutput) {
      emitJson({
        ok: true,
        currentVersion: version,
        ...serviceResultPayload(result),
        pairingSession: result?.pairingSession,
      });
      return;
    }

    consoleImpl.log("[remodex] Refreshing bridge pairing QR...");
    provider.printPairingQr({
      pairingSession: result.pairingSession,
    });
    return;
  }

  if (command === "stop") {
    const provider = getServiceProvider(command, { platform, deps, consoleImpl, exitImpl });
    provider.stopService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
      },
      message: provider.stoppedMessage,
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "status") {
    const provider = getServiceProvider(command, { platform, deps, consoleImpl, exitImpl });
    if (jsonOutput) {
      emitJson({
        ...sanitizeBridgeServiceStatusForOutput(provider.getStatus()),
        currentVersion: version,
      });
      return;
    }
    provider.printStatus();
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
      } else if (platform === "win32") {
        deps.resetWindowsBridgePairing();
        emitResult({
          payload: {
            ok: true,
            currentVersion: version,
            platform: "win32",
          },
          message: "[remodex] Stopped the Windows bridge task and cleared the saved pairing state. Run `remodex up` to pair again.",
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
    "Usage: remodex up | remodex run | remodex start | remodex restart | remodex qr | remodex pair | remodex stop | remodex status | "
    + "remodex reset-pairing | remodex resume | remodex watch [threadId] | remodex --version | "
    + "append --json to start/restart/qr/pair/stop/status/reset-pairing/resume for machine-readable output"
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

// Keeps machine-readable CLI output useful without exposing relay endpoints or live pairing payloads.
function sanitizeBridgeServiceStatusForOutput(status = {}) {
  const sanitized = {
    ...status,
    daemonConfig: sanitizeDaemonConfigForOutput(status.daemonConfig),
    pairingSession: sanitizePairingSessionForOutput(status.pairingSession),
  };
  return sanitized;
}

function sanitizeDaemonConfigForOutput(config) {
  if (!config || typeof config !== "object") {
    return config || null;
  }
  const { relayUrl, pushServiceUrl, ...rest } = config;
  return {
    ...rest,
    relayConfigured: Boolean(relayUrl),
    pushServiceConfigured: Boolean(pushServiceUrl),
  };
}

function sanitizePairingSessionForOutput(pairingSession) {
  if (!pairingSession || typeof pairingSession !== "object") {
    return pairingSession || null;
  }
  const payload = pairingSession.pairingPayload || {};
  return {
    createdAt: pairingSession.createdAt,
    pairingCode: pairingSession.pairingCode,
    pairingPayload: {
      v: payload.v,
      expiresAt: payload.expiresAt,
      hasRelay: Boolean(payload.relay),
      hasSessionId: Boolean(payload.sessionId),
      hasMacIdentityPublicKey: Boolean(payload.macIdentityPublicKey),
      displayName: payload.displayName,
    },
  };
}

function getServiceProvider(name, {
  platform = process.platform,
  deps = defaultDeps,
  consoleImpl = console,
  exitImpl = process.exit,
} = {}) {
  if (platform === "darwin") {
    return {
      startService: deps.startMacOSBridgeService,
      restartService: deps.restartMacOSBridgeService,
      stopService: deps.stopMacOSBridgeService,
      getStatus: deps.getMacOSBridgeServiceStatus,
      printStatus: deps.printMacOSBridgeServiceStatus,
      printPairingQr: deps.printMacOSBridgePairingQr,
      startedMessage: "[remodex] macOS bridge service is running.",
      restartedMessage: "[remodex] macOS bridge service restarted.",
      stoppedMessage: "[remodex] macOS bridge service stopped.",
    };
  }

  if (platform === "win32") {
    return {
      startService: deps.startWindowsBridgeService,
      restartService: deps.restartWindowsBridgeService,
      stopService: deps.stopWindowsBridgeService,
      getStatus: deps.getWindowsBridgeServiceStatus,
      printStatus: deps.printWindowsBridgeServiceStatus,
      printPairingQr: deps.printWindowsBridgePairingQr,
      startedMessage: "[remodex] Windows bridge task is running.",
      restartedMessage: "[remodex] Windows bridge task restarted.",
      stoppedMessage: "[remodex] Windows bridge task stopped.",
    };
  }

  consoleImpl.error(`[remodex] \`${name}\` is only available on macOS or Windows background service backends. Use \`remodex up\` or \`remodex run\` for the foreground bridge on this OS.`);
  exitImpl(1);
  return null;
}

function serviceResultPayload(result = {}) {
  return {
    plistPath: result?.plistPath,
    taskName: result?.taskName,
    taskXmlPath: result?.taskXmlPath,
    runnerPath: result?.runnerPath,
  };
}

function isVersionCommand(value) {
  return value === "-v" || value === "--v" || value === "-V" || value === "--version" || value === "version";
}

module.exports = {
  isVersionCommand,
  main,
  runCli,
};
