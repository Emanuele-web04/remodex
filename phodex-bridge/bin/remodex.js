#!/usr/bin/env node
// FILE: remodex.js
// Purpose: CLI surface for starting the local Remodex bridge, reopening the latest active thread, and tailing its rollout file.
// Layer: CLI binary
// Exports: none
// Depends on: ../src

const {
  parseCliArgs,
  startBridge,
  startTryCloudflareRelay,
  openLastActiveThread,
  watchThreadRollout,
} = require("../src");

main().catch((error) => {
  console.error(`[remodex] ${(error && error.message) || "Unexpected failure."}`);
  process.exit(1);
});

async function main() {
  const { command, options, positionals } = parseCliArgs(process.argv.slice(2));

  if (command === "up") {
    let managedRelay = null;

    if (options.tryCloudflare) {
      console.log("[remodex] Starting the local relay...");
      console.log("[remodex] Requesting a TryCloudflare URL...");

      managedRelay = await startTryCloudflareRelay({
        port: options.tryCloudflarePort,
        onStatus(status) {
          handleTryCloudflareStatus(status);
        },
        onTunnelExit(error) {
          console.error(`[remodex] ${(error && error.message) || "TryCloudflare exited unexpectedly."}`);
          process.exit(1);
        },
      });

      console.log(`[remodex] Local relay: ${managedRelay.httpUrl}`);
      console.log(`[remodex] Health check: ${managedRelay.healthUrl}`);
      console.log(`[remodex] TryCloudflare relay: ${managedRelay.relayUrl}`);
    }

    startBridge({
      relayUrlOverride: managedRelay?.relayUrl,
      beforeShutdown() {
        managedRelay?.close().catch(() => {});
      },
    });
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
      watchThreadRollout(positionals[0] || "");
    } catch (error) {
      console.error(`[remodex] ${(error && error.message) || "Failed to watch the thread rollout."}`);
      process.exit(1);
    }
    return;
  }

  console.error(`Unknown command: ${command}`);
  console.error("Usage: remodex up [--trycloudflare] [--trycloudflare-port <port>] | remodex resume | remodex watch [threadId]");
  process.exit(1);
}

function handleTryCloudflareStatus(status) {
  if (!status || typeof status !== "object") {
    return;
  }

  if (status.type === "public_url_discovered") {
    console.log(
      `[remodex] TryCloudflare assigned a public URL at ${formatStatusTime(status.at)}.`
    );
    return;
  }

  if (status.type === "public_ready") {
    console.log(
      `[remodex] Public tunnel reachable at ${formatStatusTime(status.at)}. You can scan the QR code now.`
    );
  }
}

function formatStatusTime(timestamp) {
  if (!timestamp) {
    return "unknown time";
  }

  const parsed = new Date(timestamp);
  if (Number.isNaN(parsed.getTime())) {
    return timestamp;
  }

  return parsed.toLocaleTimeString([], {
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}
