#!/usr/bin/env node
// FILE: remodex.js
// Purpose: CLI surface for starting the local Remodex bridge, relay server, reopening the latest active thread, and tailing its rollout file.
// Layer: CLI binary
// Exports: none
// Depends on: ../src

const {
  listReachableRelayUrls,
  openLastActiveThread,
  startBridge,
  startRelayServer,
  watchThreadRollout,
} = require("../src");

const command = process.argv[2] || "up";

if (command === "--help" || command === "-h" || command === "help") {
  printUsage();
  return;
}

if (command === "up") {
  startBridge();
  return;
}

if (command === "relay") {
  startRelayCommand(process.argv.slice(3));
  return;
}

if (command === "resume") {
  try {
    const state = openLastActiveThread();
    console.log(
      `[remodex] Opened last active thread: ${state.threadId} (${state.source || "unknown"})`
    );
  } catch (error) {
    console.error(`[remodex] ${(error && error.message) || "Failed to reopen the last thread."}`);
    process.exit(1);
  }
  return;
}

if (command === "watch") {
  try {
    watchThreadRollout(process.argv[3] || "");
  } catch (error) {
    console.error(`[remodex] ${(error && error.message) || "Failed to watch the thread rollout."}`);
    process.exit(1);
  }
  return;
}

if (command !== "up") {
  console.error(`Unknown command: ${command}`);
  printUsage();
  process.exit(1);
}

async function startRelayCommand(args) {
  try {
    const options = parseRelayOptions(args);
    const relay = await startRelayServer(options);
    const urls = listReachableRelayUrls({ host: options.host, port: relay.port });

    console.log(`[remodex relay] listening on ${options.host}:${relay.port}`);
    console.log(`[remodex relay] health: http://127.0.0.1:${relay.port}/healthz`);
    console.log("[remodex relay] reachable WebSocket URLs:");
    for (const url of urls) {
      console.log(`- ${url}`);
    }
    console.log("[remodex relay] point the bridge at one of the URLs above:");
    console.log(`REMODEX_RELAY=${urls[0]} remodex up`);

    process.on("SIGINT", () => {
      relay.close().finally(() => process.exit(0));
    });
    process.on("SIGTERM", () => {
      relay.close().finally(() => process.exit(0));
    });
  } catch (error) {
    console.error(`[remodex relay] ${(error && error.message) || "Failed to start relay."}`);
    process.exit(1);
  }
}

function parseRelayOptions(args) {
  const options = {
    host: process.env.REMODEX_RELAY_HOST || "0.0.0.0",
    port: parsePort(process.env.REMODEX_RELAY_PORT, 9000),
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    }
    if (arg === "--host") {
      const nextValue = args[index + 1];
      if (!nextValue) {
        throw new Error("Missing value for --host");
      }
      options.host = nextValue;
      index += 1;
      continue;
    }
    if (arg === "--port") {
      const nextValue = args[index + 1];
      if (!nextValue) {
        throw new Error("Missing value for --port");
      }
      options.port = parsePort(nextValue, NaN);
      index += 1;
      continue;
    }
    throw new Error(`Unknown relay option: ${arg}`);
  }

  if (!Number.isFinite(options.port) || options.port <= 0 || options.port > 65_535) {
    throw new Error("Relay port must be an integer between 1 and 65535.");
  }

  return options;
}

function parsePort(value, fallback) {
  const parsed = Number.parseInt(String(value || ""), 10);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return parsed;
}

function printUsage() {
  console.error("Usage: remodex up | remodex relay [--host HOST] [--port PORT] | remodex resume | remodex watch [threadId]");
}
