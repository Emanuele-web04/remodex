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
  resetMacOSDesktopTarget,
  restartMacOSBridgeService,
  runMacOSBridgeService,
  startBridge,
  startMacOSBridgeService,
  setMacOSDesktopTarget,
  stopMacOSBridgeService,
  uninstallMacOSBridgeService,
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
  resetMacOSDesktopTarget,
  restartMacOSBridgeService,
  runMacOSBridgeService,
  startBridge,
  startMacOSBridgeService,
  setMacOSDesktopTarget,
  stopMacOSBridgeService,
  uninstallMacOSBridgeService,
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
    const result = await deps.startMacOSBridgeService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        plistPath: result?.plistPath,
        pairingSession: sanitizePairingSessionForOutput(result?.pairingSession),
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
    const result = await deps.restartMacOSBridgeService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        plistPath: result?.plistPath,
        pairingSession: sanitizePairingSessionForOutput(result?.pairingSession),
      },
      message: "[remodex] macOS bridge service restarted.",
      jsonOutput,
      consoleImpl,
    });
    return;
  }

  if (command === "qr" || command === "pair") {
    assertMacOSCommand(command, {
      platform,
      consoleImpl,
      exitImpl,
    });
    const result = await deps.startMacOSBridgeService({
      waitForPairing: true,
    });
    if (jsonOutput) {
      emitJson({
        ok: true,
        currentVersion: version,
        plistPath: result?.plistPath,
        pairingSession: result?.pairingSession,
      });
      return;
    }

    consoleImpl.log("[remodex] Refreshing bridge pairing QR...");
    deps.printMacOSBridgePairingQr({
      pairingSession: result.pairingSession,
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

  if (command === "uninstall-service") {
    assertMacOSCommand(command, {
      platform,
      consoleImpl,
      exitImpl,
    });
    const result = deps.uninstallMacOSBridgeService();
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        plistPath: result?.plistPath,
        removed: result?.removed,
      },
      message: "[remodex] Removed the macOS bridge service. You can now run `npm uninstall -g remodex`.",
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
        ...sanitizeBridgeServiceStatusForOutput(deps.getMacOSBridgeServiceStatus()),
        currentVersion: version,
      });
      return;
    }
    deps.printMacOSBridgeServiceStatus();
    return;
  }

  if (command === "target") {
    assertMacOSCommand(command, { platform, consoleImpl, exitImpl });
    const targetCommand = parseTargetCommand(argv.slice(2));
    let result;
    if (targetCommand.action === "set") {
      result = await deps.setMacOSDesktopTarget({
        target: {
          codexHome: targetCommand.codexHome,
          codexBundleId: targetCommand.bundleId,
          codexAppPath: targetCommand.appPath,
          codexUrlScheme: targetCommand.urlScheme,
        },
        restart: targetCommand.restart,
      });
    } else if (targetCommand.action === "reset") {
      result = await deps.resetMacOSDesktopTarget({ restart: targetCommand.restart });
    } else {
      throw new Error("Usage: remodex target set --codex-home <path> --bundle-id <id> --app-path <path> --url-scheme <scheme> [--restart] | remodex target reset [--restart]");
    }
    emitResult({
      payload: {
        ok: true,
        currentVersion: version,
        target: result.target,
        restarted: result.restarted,
        rolledBack: result.rolledBack,
      },
      message: `[remodex] Desktop target ${targetCommand.action === "reset" ? "reset" : "updated"}${result.restarted ? " and service restarted" : ""}.`,
      jsonOutput,
      consoleImpl,
    });
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
      const config = deps.readBridgeConfig();
      const state = deps.openLastActiveThread({
        bundleId: config.codexBundleId,
        appPath: config.codexAppPath,
        urlScheme: config.codexUrlScheme,
      });
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
    "Usage: remodex up | remodex run | remodex start | remodex restart | remodex qr | remodex pair | remodex stop | remodex uninstall-service | remodex status | remodex target ... | "
    + "remodex reset-pairing | remodex resume | remodex watch [threadId] | remodex --version | "
    + "append --json to start/restart/qr/pair/stop/uninstall-service/status/reset-pairing/resume for machine-readable output"
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

function parseTargetCommand(rawArgs) {
  const args = rawArgs.filter((arg) => arg !== "--json");
  const action = args[1] || "";
  const result = {
    action,
    restart: false,
    codexHome: "",
    bundleId: "",
    appPath: "",
    urlScheme: "",
  };
  const valueFlags = new Map([
    ["--codex-home", "codexHome"],
    ["--bundle-id", "bundleId"],
    ["--app-path", "appPath"],
    ["--url-scheme", "urlScheme"],
  ]);
  for (let index = 2; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--restart") {
      result.restart = true;
      continue;
    }
    const field = valueFlags.get(argument);
    if (!field || index + 1 >= args.length) {
      throw new Error(`Unknown or incomplete target option: ${argument}`);
    }
    result[field] = args[index + 1];
    index += 1;
  }
  if (action === "set") {
    for (const [field, label] of [
      ["codexHome", "--codex-home"],
      ["bundleId", "--bundle-id"],
      ["appPath", "--app-path"],
      ["urlScheme", "--url-scheme"],
    ]) {
      if (!result[field]) {
        throw new Error(`remodex target set requires ${label}.`);
      }
    }
  }
  return result;
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
  runCli,
};
