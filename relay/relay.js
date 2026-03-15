// FILE: relay.js
// Purpose: Compatibility re-export for the shared Remodex relay implementation.
// Layer: Standalone server module
// Exports: setupRelay, getRelayStats, hasActiveMacSession, hasAuthenticatedMacSession

module.exports = require("../phodex-bridge/src/relay-core");
