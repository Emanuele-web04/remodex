#!/usr/bin/env node
// FILE: remodex.js
// Purpose: CLI surface for starting the local Remodex bridge, reopening the latest active thread, and tailing its rollout file.
// Layer: CLI binary
// Exports: none
// Depends on: ../src

const {
  parseCliArgs,
  startBridge,
  startLocalRelayServer,
  startTryCloudflareTunnel,
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
    if (options.tryCloudflare) {
      let localRelay = null;
      let managedTunnel = null;

      console.log("[remodex] Starting the local relay...");
      localRelay = await startLocalRelayServer({
        port: options.tryCloudflarePort,
      });

      console.log(`[remodex] Local relay: ${localRelay.httpUrl}`);
      console.log(`[remodex] Health check: ${localRelay.healthUrl}`);
      console.log("[remodex] Starting bridge on the local relay...");

      const bridge = startBridge({
        relayUrlOverride: localRelay.relayUrl,
        suppressInitialQr: true,
        beforeShutdown() {
          const cleanup = [localRelay?.close()];
          if (managedTunnel) {
            cleanup.push(managedTunnel.close());
          }
          void Promise.allSettled(cleanup);
        },
      });

      console.log("[remodex] Requesting a TryCloudflare URL...");
      console.log("[remodex] The QR code will be printed once the public tunnel is reachable.");

      startTryCloudflareTunnel({
        localUrl: localRelay.httpUrl,
        onStatus(status) {
          handleTryCloudflareStatus(status);
        },
        onUnexpectedExit(error) {
          console.error(`[remodex] ${(error && error.message) || "TryCloudflare exited unexpectedly."}`);
        },
      }).then((tunnel) => {
        managedTunnel = tunnel;
        const publicRelayUrl = `${tunnel.socketBaseUrl}/relay`;
        console.log(`[remodex] TryCloudflare relay: ${publicRelayUrl}`);
        bridge.printPairingQr({ relayUrl: publicRelayUrl });
      }).catch(async (error) => {
        console.error(`[remodex] ${(error && error.message) || "Failed to establish the TryCloudflare tunnel."}`);
        await localRelay.close().catch(() => {});
        process.exit(1);
      });

      return;
    }

    startBridge();
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
      `[remodex] TryCloudflare assigned a public URL at ${formatStatusTime(status.at)}. Waiting for public reachability before printing the QR code.`
    );
    return;
  }

  if (status.type === "public_pending") {
    console.log(
      `[remodex] Public tunnel still warming up as of ${formatStatusTime(status.at)}. The bridge stays connected locally; the QR code will appear once the tunnel is reachable.`
    );
    return;
  }

  if (status.type === "public_ready") {
    console.log(
      `[remodex] Public tunnel reachable at ${formatStatusTime(status.at)}. Printing the QR code now.`
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
