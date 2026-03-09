// FILE: index.js
// Purpose: Small entrypoint wrapper for the bridge runtime.
// Layer: CLI entry
// Exports: startBridge, openLastActiveThread, watchThreadRollout
// Depends on: ./bridge, ./session-state, ./rollout-watch

const { startBridge } = require("./bridge");
const { openLastActiveThread } = require("./session-state");
const { watchThreadRollout } = require("./rollout-watch");

module.exports = { startBridge, openLastActiveThread, watchThreadRollout };
