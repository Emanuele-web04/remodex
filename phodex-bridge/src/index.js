// FILE: index.js
// Purpose: Small entrypoint wrapper for the bridge runtime.
// Layer: CLI entry
// Exports: startBridge, openLastActiveThread, watchThreadRollout, parseCliArgs, startLocalRelayServer, startTryCloudflareRelay, startTryCloudflareTunnel
// Depends on: ./bridge, ./session-state, ./rollout-watch, ./cli-options, ./local-relay

const { startBridge } = require("./bridge");
const { parseCliArgs } = require("./cli-options");
const {
  startLocalRelayServer,
  startTryCloudflareRelay,
  startTryCloudflareTunnel,
} = require("./local-relay");
const { openLastActiveThread } = require("./session-state");
const { watchThreadRollout } = require("./rollout-watch");

module.exports = {
  startBridge,
  parseCliArgs,
  startLocalRelayServer,
  startTryCloudflareRelay,
  startTryCloudflareTunnel,
  openLastActiveThread,
  watchThreadRollout,
};
