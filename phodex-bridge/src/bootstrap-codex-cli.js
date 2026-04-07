#!/usr/bin/env node
// FILE: bootstrap-codex-cli.js
// Purpose: Runs during global Remodex installs to transparently bootstrap the global Codex CLI.
// Layer: CLI helper
// Exports: none
// Depends on: ./codex-cli-bootstrap

const {
  ensureCodexCLI,
  shouldSkipCodexBootstrap,
} = require("./codex-cli-bootstrap");

const installLocation = String(process.env.npm_config_location || "").trim().toLowerCase();
const isGlobalInstall = process.env.npm_config_global === "true" || installLocation === "global";

if (shouldSkipCodexBootstrap(process.env)) {
  ensureCodexCLI({
    env: process.env,
    logger: console,
    shouldUpdate: true,
  });
  process.exit(0);
}

if (!isGlobalInstall) {
  process.exit(0);
}

ensureCodexCLI({
  env: process.env,
  logger: console,
  shouldUpdate: true,
});
