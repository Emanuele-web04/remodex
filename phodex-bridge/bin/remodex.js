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

const { command, jsonOutput, watchThreadId } = parseCliArgs(process.argv.slice(2));

void main();

// ─── ENTRY POINT ─────────────────────────────────────────────

async function main() {
  if (isVersionCommand(command)) {
    emitVersion();
    return;
  }

  if (command === "up") {
    if (process.platform === "darwin") {
      const result = await startMacOSBridgeService({
        waitForPairing: true,
      });
      printMacOSBridgePairingQr({
        pairingSession: result.pairingSession,
      });
      return;
    }

    startBridge();
    return;
  }

  if (command === "run") {
    startBridge();
    return;
  }

  if (command === "run-service") {
    runMacOSBridgeService();
    return;
  }

  if (command === "start") {
    assertMacOSCommand(command);
    readBridgeConfig();
    const result = await startMacOSBridgeService({
      waitForPairing: false,
    });
    emitResult({
      ok: true,
      currentVersion: version,
      plistPath: result.plistPath,
      pairingSession: result.pairingSession,
    }, "[remodex] macOS bridge service is running.");
    return;
  }

  if (command === "stop") {
    assertMacOSCommand(command);
    stopMacOSBridgeService();
    emitResult({
      ok: true,
      currentVersion: version,
    }, "[remodex] macOS bridge service stopped.");
    return;
  }

  if (command === "status") {
    assertMacOSCommand(command);
    if (jsonOutput) {
      emitJson({
        ...getMacOSBridgeServiceStatus(),
        currentVersion: version,
      });
      return;
    }
    printMacOSBridgeServiceStatus();
    return;
  }

  if (command === "reset-pairing") {
    try {
      if (process.platform === "darwin") {
        resetMacOSBridgePairing();
        emitResult({
          ok: true,
          currentVersion: version,
          platform: "darwin",
        }, "[remodex] Stopped the macOS bridge service and cleared the saved pairing state. Run `remodex up` to pair again.");
      } else {
        resetBridgePairing();
        emitResult({
          ok: true,
          currentVersion: version,
          platform: process.platform,
        }, "[remodex] Cleared the saved pairing state. Run `remodex up` to pair again.");
      }
    } catch (error) {
      console.error(`[remodex] ${(error && error.message) || "Failed to clear the saved pairing state."}`);
      process.exit(1);
    }
    return;
  }

  if (command === "resume") {
    try {
      const state = openLastActiveThread();
      emitResult({
        ok: true,
        currentVersion: version,
        threadId: state.threadId,
        source: state.source || "unknown",
      }, `[remodex] Opened last active thread: ${state.threadId} (${state.source || "unknown"})`);
    } catch (error) {
      console.error(`[remodex] ${(error && error.message) || "Failed to reopen the last thread."}`);
      process.exit(1);
    }
    return;
  }

  if (command === "watch") {
    try {
      watchThreadRollout(watchThreadId);
    } catch (error) {
      console.error(`[remodex] ${(error && error.message) || "Failed to watch the thread rollout."}`);
      process.exit(1);
    }
    return;
  }

  console.error(`Unknown command: ${command}`);
  console.error(
    "Usage: remodex up | remodex run | remodex start | remodex stop | remodex status | "
    + "remodex reset-pairing | remodex resume | remodex watch [threadId] | remodex --version | "
    + "append --json to start/stop/status/reset-pairing/resume for machine-readable output"
  );
  process.exit(1);
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

function emitVersion() {
  if (jsonOutput) {
    emitJson({
      currentVersion: version,
    });
    return;
  }

  console.log(version);
}

function emitResult(payload, message) {
  if (jsonOutput) {
    emitJson(payload);
    return;
  }

  console.log(message);
}

function emitJson(payload) {
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
}

function assertMacOSCommand(name) {
  if (process.platform === "darwin") {
    return;
  }

  console.error(`[remodex] \`${name}\` is only available on macOS. Use \`remodex up\` or \`remodex run\` for the foreground bridge on this OS.`);
  process.exit(1);
}

function isVersionCommand(value) {
  return value === "-v" || value === "--v" || value === "-V" || value === "--version" || value === "version";
}
