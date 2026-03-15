// FILE: index.js
// Purpose: Small entrypoint wrapper for the bridge runtime.
// Layer: CLI entry
// Exports: startBridge, openLastActiveThread, startRelayServer, listReachableRelayUrls, watchThreadRollout
// Depends on: ./bridge, ./relay-server, ./session-state, ./rollout-watch

const { startBridge } = require("./bridge");
const { startRelayServer, listReachableRelayUrls } = require("./relay-server");
const { openLastActiveThread } = require("./session-state");
const { watchThreadRollout } = require("./rollout-watch");

module.exports = {
  listReachableRelayUrls,
  openLastActiveThread,
  startBridge,
  startRelayServer,
  watchThreadRollout,
};
