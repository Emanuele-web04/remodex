// FILE: index.js
// Purpose: Small entrypoint wrapper for bridge lifecycle commands.
// Layer: CLI entry
// Exports: bridge lifecycle, pairing reset, thread resume/watch, and OS service helpers.
// Depends on: ./bridge, ./secure-device-state, ./session-state, ./rollout-watch, ./macos-launch-agent, ./windows-scheduled-task

const { startBridge } = require("./bridge");
const { readBridgeDeviceState, resetBridgeTrustState } = require("./secure-device-state");
const { openLastActiveThread } = require("./session-state");
const { watchThreadRollout } = require("./rollout-watch");
const { readBridgeConfig } = require("./codex-desktop-refresher");
const {
  getMacOSBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  resetMacOSBridgePairing,
  restartMacOSBridgeService,
  runMacOSBridgeService,
  startMacOSBridgeService,
  stopMacOSBridgeService,
} = require("./macos-launch-agent");
const {
  getWindowsBridgeServiceStatus,
  printWindowsBridgePairingQr,
  printWindowsBridgeServiceStatus,
  resetWindowsBridgePairing,
  restartWindowsBridgeService,
  runWindowsBridgeService,
  startWindowsBridgeService,
  stopWindowsBridgeService,
} = require("./windows-scheduled-task");

module.exports = {
  getMacOSBridgeServiceStatus,
  getWindowsBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  printWindowsBridgePairingQr,
  printWindowsBridgeServiceStatus,
  readBridgeConfig,
  readBridgeDeviceState,
  resetMacOSBridgePairing,
  resetWindowsBridgePairing,
  restartMacOSBridgeService,
  restartWindowsBridgeService,
  startBridge,
  runMacOSBridgeService,
  runWindowsBridgeService,
  startMacOSBridgeService,
  startWindowsBridgeService,
  stopMacOSBridgeService,
  stopWindowsBridgeService,
  resetBridgePairing: resetBridgeTrustState,
  openLastActiveThread,
  watchThreadRollout,
};
