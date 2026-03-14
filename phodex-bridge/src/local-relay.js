// FILE: local-relay.js
// Purpose: Starts a local relay server and optionally exposes it through a TryCloudflare tunnel.
// Layer: CLI helper
// Exports: startLocalRelayServer, startTryCloudflareRelay, startTryCloudflareTunnel, extractTryCloudflareUrl, createTunnelLaunchError, getCloudflaredInstallHint, waitForPublicTunnelReady

const http = require("node:http");
const { spawn } = require("node:child_process");
const { WebSocketServer } = require("ws");
const { setupRelay, getRelayStats } = require("./relay-core");

const DEFAULT_RELAY_HOST = "127.0.0.1";
const DEFAULT_TUNNEL_READY_TIMEOUT_MS = 20_000;
const DEFAULT_TUNNEL_READY_POLL_INTERVAL_MS = 250;
const TRYCLOUDFLARE_URL_PATTERN = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/ig;
const CLOUDFLARED_SETUP_DOCS_URL = "https://developers.cloudflare.com/tunnel/setup/";

async function startLocalRelayServer({
  host = DEFAULT_RELAY_HOST,
  port = 0,
} = {}) {
  const server = http.createServer((req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ ok: true, ...getRelayStats() }));
      return;
    }

    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("Not found");
  });

  const wss = new WebSocketServer({ server });
  setupRelay(wss);

  await listen(server, port, host);

  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("Failed to determine the local relay address.");
  }

  const httpUrl = `http://${host}:${address.port}`;
  let closed = false;

  return {
    host,
    port: address.port,
    httpUrl,
    healthUrl: `${httpUrl}/healthz`,
    async close() {
      if (closed) {
        return;
      }
      closed = true;
      await Promise.all([
        closeWebSocketServer(wss),
        closeHttpServer(server),
      ]);
    },
  };
}

async function startTryCloudflareRelay({
  host = DEFAULT_RELAY_HOST,
  port = 0,
  cloudflaredBin = "cloudflared",
  readyTimeoutMs = DEFAULT_TUNNEL_READY_TIMEOUT_MS,
  onTunnelExit = null,
  onStatus = null,
} = {}) {
  const relayServer = await startLocalRelayServer({ host, port });

  try {
    const tunnel = await startTryCloudflareTunnel({
      localUrl: relayServer.httpUrl,
      cloudflaredBin,
      readyTimeoutMs,
      onStatus,
      onUnexpectedExit: onTunnelExit,
    });

    let closed = false;

    return {
      ...relayServer,
      ...tunnel,
      relayUrl: `${tunnel.socketBaseUrl}/relay`,
      async close() {
        if (closed) {
          return;
        }
        closed = true;
        await Promise.allSettled([
          tunnel.close(),
          relayServer.close(),
        ]);
      },
    };
  } catch (error) {
    await relayServer.close().catch(() => {});
    throw error;
  }
}

function extractTryCloudflareUrl(text) {
  if (typeof text !== "string" || !text) {
    return null;
  }

  const matches = text.match(TRYCLOUDFLARE_URL_PATTERN);
  return matches?.[0] || null;
}

async function startTryCloudflareTunnel({
  localUrl,
  cloudflaredBin,
  readyTimeoutMs,
  readyPollIntervalMs = DEFAULT_TUNNEL_READY_POLL_INTERVAL_MS,
  onStatus = null,
  onUnexpectedExit,
  fetchImpl = globalThis.fetch,
  spawnImpl = spawn,
} = {}) {
  if (!localUrl) {
    throw new Error("A local relay URL is required to start TryCloudflare.");
  }

  const child = spawnImpl(
    cloudflaredBin,
    ["tunnel", "--url", localUrl, "--no-autoupdate"],
    {
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    }
  );

  const recentLogs = [];
  let outputBuffer = "";
  let resolved = false;
  let closed = false;
  let publicReadyPromise = null;
  let publicUrlDiscoveredAt = "";
  let readyTimeout = null;

  const registerLogChunk = (chunk) => {
    const text = chunk.toString("utf8");
    outputBuffer += text;

    const lines = outputBuffer.split(/\r?\n/);
    outputBuffer = lines.pop() || "";

    for (const line of lines) {
      const trimmedLine = line.trim();
      if (!trimmedLine) {
        continue;
      }
      recentLogs.push(trimmedLine);
      if (recentLogs.length > 30) {
        recentLogs.shift();
      }
    }
    return text;
  };

  const startup = new Promise((resolve, reject) => {
    const fail = (error) => {
      if (resolved) {
        return;
      }
      resolved = true;
      closed = true;
      clearTimeout(readyTimeout);
      if (child.exitCode == null && !child.killed) {
        child.kill("SIGTERM");
      }
      reject(error);
    };

    const maybeResolve = (chunk) => {
      if (resolved) {
        return;
      }

      registerLogChunk(chunk);
      const publicUrl = extractTryCloudflareUrl(outputBuffer) || extractTryCloudflareUrl(recentLogs.join("\n"));
      if (!publicUrl || publicReadyPromise) {
        return;
      }

      publicUrlDiscoveredAt = formatStatusTimestamp();
      emitStatus(onStatus, {
        type: "public_url_discovered",
        publicUrl,
        at: publicUrlDiscoveredAt,
      });

      clearTimeout(readyTimeout);
      publicReadyPromise = waitForPublicTunnelReady({
        publicUrl,
        timeoutMs: readyTimeoutMs,
        pollIntervalMs: readyPollIntervalMs,
        fetchImpl,
      }).then(() => {
        if (resolved) {
          return;
        }

        resolved = true;
        clearTimeout(readyTimeout);
        const publicReadyAt = formatStatusTimestamp();
        emitStatus(onStatus, {
          type: "public_ready",
          publicUrl,
          at: publicReadyAt,
        });
        resolve(createTunnelHandle(publicUrl, {
          publicReadyAt,
          publicUrlDiscoveredAt,
        }));
      }).catch((error) => {
        fail(createTunnelStartupError(
          `TryCloudflare assigned ${publicUrl}, but it did not become reachable within ${readyTimeoutMs} ms. ${error.message}`,
          recentLogs
        ));
      });
    };

    readyTimeout = setTimeout(() => {
      fail(createTunnelStartupError(
        `Timed out waiting for TryCloudflare after ${readyTimeoutMs} ms.`,
        recentLogs
      ));
    }, readyTimeoutMs);

    child.stdout?.on("data", maybeResolve);
    child.stderr?.on("data", maybeResolve);

    child.once("error", (error) => {
      fail(createTunnelLaunchError(cloudflaredBin, error));
    });

    child.once("exit", (code, signal) => {
      if (!resolved) {
        fail(createTunnelStartupError(
          `TryCloudflare exited before becoming ready (code=${code ?? "null"}, signal=${signal ?? "null"}).`,
          recentLogs
        ));
        return;
      }

      if (!closed && typeof onUnexpectedExit === "function") {
        onUnexpectedExit(createTunnelStartupError(
          `TryCloudflare exited unexpectedly (code=${code ?? "null"}, signal=${signal ?? "null"}).`,
          recentLogs
        ));
      }
    });
  });

  return startup;

  function createTunnelHandle(publicUrl, {
    publicReadyAt = "",
    publicUrlDiscoveredAt = "",
  } = {}) {
    const socketBaseUrl = upgradeHttpUrlToWebSocket(publicUrl);
    return {
      publicUrl,
      publicReadyAt,
      publicUrlDiscoveredAt,
      socketBaseUrl,
      async close() {
        if (closed) {
          return;
        }
        closed = true;
        if (child.exitCode == null && !child.killed) {
          child.kill("SIGTERM");
        }
        await onceExit(child);
      },
    };
  }

}

function upgradeHttpUrlToWebSocket(urlString) {
  const parsed = new URL(urlString);
  parsed.protocol = parsed.protocol === "https:" ? "wss:" : "ws:";
  return parsed.toString().replace(/\/+$/, "");
}

function createTunnelStartupError(message, recentLogs) {
  const suffix = recentLogs.length > 0
    ? ` Recent cloudflared logs: ${recentLogs.join(" | ")}`
    : "";
  return new Error(`${message}${suffix}`);
}

function createTunnelLaunchError(binaryName, error, platform = process.platform) {
  if (error?.code === "ENOENT") {
    return new Error(
      `TryCloudflare requires \`${binaryName}\` to be installed before running \`remodex up --trycloudflare\`. ${getCloudflaredInstallHint(platform)}`
    );
  }

  return new Error(`Failed to start \`${binaryName}\`: ${error?.message || "Unknown launch failure."}`);
}

function getCloudflaredInstallHint(platform = process.platform) {
  if (platform === "darwin") {
    return `Install Cloudflare Tunnel with Homebrew (\`brew install cloudflared\`) and ensure \`cloudflared\` is on your PATH. Docs: ${CLOUDFLARED_SETUP_DOCS_URL}`;
  }

  if (platform === "linux") {
    return `Install Cloudflare Tunnel using Cloudflare's Linux instructions and ensure \`cloudflared\` is on your PATH. Docs: ${CLOUDFLARED_SETUP_DOCS_URL}`;
  }

  if (platform === "win32") {
    return `Install Cloudflare Tunnel for Windows and ensure \`cloudflared.exe\` is available from your shell. Docs: ${CLOUDFLARED_SETUP_DOCS_URL}`;
  }

  return `Install Cloudflare Tunnel and ensure \`cloudflared\` is on your PATH. Docs: ${CLOUDFLARED_SETUP_DOCS_URL}`;
}

async function waitForPublicTunnelReady({
  publicUrl,
  timeoutMs,
  pollIntervalMs = DEFAULT_TUNNEL_READY_POLL_INTERVAL_MS,
  fetchImpl = globalThis.fetch,
  shouldContinue = () => true,
} = {}) {
  if (!publicUrl) {
    throw new Error("A public tunnel URL is required before readiness can be checked.");
  }
  if (typeof fetchImpl !== "function") {
    throw new Error("Global fetch is unavailable; cannot verify tunnel readiness.");
  }

  const startedAt = Date.now();
  const healthUrl = `${publicUrl.replace(/\/+$/, "")}/healthz`;
  let lastError = null;

  while (shouldContinue() && !hasWaitDeadlineElapsed(startedAt, timeoutMs)) {
    try {
      const response = await fetchImpl(healthUrl, {
        method: "GET",
        redirect: "follow",
        signal: AbortSignal.timeout(getTunnelHealthRequestTimeout(timeoutMs)),
      });
      if (response?.ok) {
        return true;
      }

      lastError = new Error(`HTTP ${response?.status || "unknown"}`);
    } catch (error) {
      lastError = error;
    }

    await delay(pollIntervalMs);
  }

  if (!shouldContinue()) {
    return false;
  }

  const detail = lastError?.message ? ` Last check: ${lastError.message}.` : "";
  throw new Error(`Timed out waiting for public tunnel readiness at ${healthUrl} after ${timeoutMs} ms.${detail}`);
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const handleError = (error) => {
      server.off("listening", handleListening);
      reject(error);
    };
    const handleListening = () => {
      server.off("error", handleError);
      resolve();
    };

    server.once("error", handleError);
    server.once("listening", handleListening);
    server.listen(port, host);
  });
}

function closeHttpServer(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

function closeWebSocketServer(wss) {
  return new Promise((resolve) => {
    wss.close(() => resolve());
    for (const client of wss.clients) {
      client.terminate();
    }
  });
}

function onceExit(child) {
  return new Promise((resolve) => {
    if (child.exitCode != null) {
      resolve();
      return;
    }

    child.once("exit", () => resolve());
  });
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function emitStatus(callback, status) {
  if (typeof callback !== "function") {
    return;
  }

  callback(status);
}

function formatStatusTimestamp(date = new Date()) {
  return date.toISOString();
}

function getTunnelHealthRequestTimeout(timeoutMs) {
  if (!Number.isFinite(timeoutMs)) {
    return 3_000;
  }

  return Math.min(3_000, timeoutMs);
}

function hasWaitDeadlineElapsed(startedAt, timeoutMs) {
  if (!Number.isFinite(timeoutMs)) {
    return false;
  }

  return Date.now() - startedAt >= timeoutMs;
}

module.exports = {
  createTunnelLaunchError,
  extractTryCloudflareUrl,
  getCloudflaredInstallHint,
  startLocalRelayServer,
  startTryCloudflareRelay,
  startTryCloudflareTunnel,
  waitForPublicTunnelReady,
};
