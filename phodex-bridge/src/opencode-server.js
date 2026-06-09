// FILE: opencode-server.js
// Purpose: Manages the `opencode serve` HTTP server lifecycle. Spawns, health-checks,
//          and shuts down an opencode HTTP process used by the SDK client.
// Layer: Transport adapter
// Exports: createOpenCodeServer
// Depends on: child_process, http, net

const { readString } = require("./normalize");
const { spawn } = require("child_process");
const http = require("http");
const net = require("net");
const path = require("path");

function resolveTimeoutMs(envKey, defaultMs) {
  const numeric = Number(readString(process.env[envKey]));
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return defaultMs;
  }
  return Math.min(Math.floor(numeric), defaultMs);
}

const START_TIMEOUT_MS = resolveTimeoutMs("REMODEX_OPENCODE_START_TIMEOUT_MS", 15_000);
const SHUTDOWN_TIMEOUT_MS = 5_000;
const HEALTH_TIMEOUT_MS = resolveTimeoutMs("REMODEX_OPENCODE_HEALTH_TIMEOUT_MS", 5_000);
const PORT_RANGE_START = 4200;
const PORT_RANGE_END = 4299;
const SERVE_HOST = "127.0.0.1";
const HEALTH_PATHS = ["/global/health", "/health"];

function validateOpenCodeCommand(command) {
  if (/[\s;&|<>$`'"\\]/.test(command)) {
    throw Object.assign(
      new Error(`OpenCode command contains disallowed characters: ${command}`),
      { errorCode: "opencode_server_failed", reasonCode: "opencode_command_invalid" },
    );
  }
  const isBareName = path.basename(command) === command;
  if (!isBareName && !path.isAbsolute(command)) {
    throw Object.assign(
      new Error(`OpenCode command path must be absolute or a bare binary name: ${command}`),
      { errorCode: "opencode_server_failed", reasonCode: "opencode_command_invalid" },
    );
  }
  return command;
}

function parsePortEnv(env, key) {
  const numeric = Number(readString(env?.[key]));
  if (!Number.isFinite(numeric) || numeric <= 0 || numeric >= 65536) {
    return 0;
  }
  return Math.floor(numeric);
}

function isPortAvailable(port, host = SERVE_HOST) {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.once("error", () => resolve(false));
    probe.once("listening", () => {
      probe.close(() => resolve(true));
    });
    probe.listen(port, host);
  });
}

async function findAvailablePort(startPort, endPort, host = SERVE_HOST) {
  const start = Math.min(startPort, endPort);
  const end = Math.max(startPort, endPort);
  for (let port = start; port <= end; port += 1) {
    if (await isPortAvailable(port, host)) {
      return port;
    }
  }
  const err = new Error(
    `No free OpenCode port found between ${start} and ${end} on ${host}.`,
  );
  err.reasonCode = "opencode_port_in_use";
  throw err;
}

async function resolveServePort(env = process.env, host = SERVE_HOST) {
  const fixedPort = parsePortEnv(env, "REMODEX_OPENCODE_PORT");
  if (fixedPort > 0) {
    if (!(await isPortAvailable(fixedPort, host))) {
      const err = new Error(`OpenCode port ${fixedPort} is already in use on this Mac.`);
      err.reasonCode = "opencode_port_in_use";
      throw err;
    }
    return fixedPort;
  }

  const rangeStart = parsePortEnv(env, "REMODEX_OPENCODE_PORT_START") || PORT_RANGE_START;
  const rangeEnd = parsePortEnv(env, "REMODEX_OPENCODE_PORT_END") || PORT_RANGE_END;
  return findAvailablePort(rangeStart, rangeEnd, host);
}

function detectStartReasonCode(stderrText, exitCode) {
  const text = readString(stderrText).toLowerCase();
  if (text.includes("port") && text.includes("in use")) {
    return "opencode_port_in_use";
  }
  if (text.includes("serveerror")) {
    return "opencode_server_failed";
  }
  if (exitCode === 127 || text.includes("enoent")) {
    return "opencode_not_installed";
  }
  return "opencode_server_failed";
}

function parseHealthPayload(parsed) {
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, version: "" };
  }
  const ok = parsed.healthy === true || parsed.ok === true;
  return { ok, version: readString(parsed.version) };
}

function formatStartFailure(stderrText, exitCode, port) {
  const trimmed = readString(stderrText).trim();
  const portHint = port ? ` (port ${port})` : "";
  if (trimmed) {
    const firstLine = trimmed.split(/\r?\n/).find((line) => readString(line)) || trimmed;
    return `OpenCode serve failed${portHint}: ${firstLine}`;
  }
  if (exitCode != null) {
    return `OpenCode serve exited before becoming ready${portHint} (code ${exitCode}).`;
  }
  return `OpenCode serve failed${portHint}.`;
}

function createOpenCodeServer({
  env = process.env,
  spawnImpl = spawn,
  httpGetImpl = null,
  logPrefix = "[remodex]",
  port = 0,
  resolvePortImpl = resolveServePort,
} = {}) {
  let child = null;
  let baseUrl = "";
  let version = "";
  let started = false;
  let stopping = false;
  let lastStartFailure = null;
  let activePort = 0;

  function start({ cwd = process.cwd(), extraArgs = [] } = {}) {
    if (child) {
      return Promise.resolve();
    }

    const command = readString(env.REMODEX_OPENCODE_COMMAND) || "opencode";

    return (async () => {
      validateOpenCodeCommand(command);
      let resolvedPort = port;
      if (!resolvedPort || resolvedPort <= 0) {
        resolvedPort = await resolvePortImpl(env, SERVE_HOST);
      } else if (!(await isPortAvailable(resolvedPort, SERVE_HOST))) {
        const err = new Error(`OpenCode port ${resolvedPort} is already in use on this Mac.`);
        err.errorCode = "opencode_server_failed";
        err.reasonCode = "opencode_port_in_use";
        lastStartFailure = {
          message: err.message,
          reasonCode: err.reasonCode,
          port: resolvedPort,
        };
        throw err;
      }
      activePort = resolvedPort;

      const args = [
        "serve",
        `--hostname=${SERVE_HOST}`,
        `--port=${resolvedPort}`,
        ...extraArgs,
      ];

      return new Promise((resolve, reject) => {
        let settled = false;
        let stderrBuffer = "";

        const failStart = (error) => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timeout);
          lastStartFailure = {
            message: error.message,
            reasonCode: error.reasonCode || "opencode_server_failed",
            port: activePort,
          };
          cleanup();
          reject(error);
        };

        const timeout = setTimeout(() => {
          failStart(
            Object.assign(
              new Error(`OpenCode serve did not start within ${START_TIMEOUT_MS / 1000}s.`),
              { errorCode: "opencode_server_failed", reasonCode: "opencode_server_failed" },
            ),
          );
        }, START_TIMEOUT_MS);

        try {
          child = spawnImpl(command, args, {
            env: { ...env },
            stdio: ["pipe", "pipe", "pipe"],
            cwd,
          });
        } catch (error) {
          clearTimeout(timeout);
          const err = new Error(`Failed to spawn OpenCode serve: ${error.message}`);
          err.errorCode = "opencode_server_failed";
          err.reasonCode = "opencode_not_installed";
          err.cause = error;
          failStart(err);
          return;
        }

        let stdoutBuffer = "";

        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk) => {
          stdoutBuffer += String(chunk);
          const match = stdoutBuffer.match(/opencode server listening on (https?:\/\/[^\s]+)/i);
          if (match && match[1]) {
            baseUrl = match[1].replace(/\/+$/, "");
            clearTimeout(timeout);
            waitForHealthy()
              .then(() => {
                if (settled) {
                  return;
                }
                settled = true;
                started = true;
                lastStartFailure = null;
                console.log(`${logPrefix} OpenCode serve ready at ${baseUrl}`);
                resolve();
              })
              .catch((err) => {
                err.errorCode = err.errorCode || "opencode_server_failed";
                err.reasonCode = err.reasonCode || "opencode_server_failed";
                failStart(err);
              });
          }
        });

        child.stderr.setEncoding("utf8");
        child.stderr.on("data", (chunk) => {
          stderrBuffer += String(chunk);
          if (readString(env.REMODEX_DIAGNOSTICS) === "1") {
            process.stderr.write(`${logPrefix} [opencode stderr] ${String(chunk)}`);
          }
        });

        child.on("error", (error) => {
          const err = new Error(`OpenCode serve process error: ${error.message}`);
          err.errorCode = "opencode_server_failed";
          err.reasonCode = "opencode_not_installed";
          err.cause = error;
          failStart(err);
        });

        child.on("close", (code) => {
          if (!stopping && !started && !settled) {
            const err = new Error(formatStartFailure(stderrBuffer, code, activePort));
            err.errorCode = "opencode_server_failed";
            err.reasonCode = detectStartReasonCode(stderrBuffer, code);
            failStart(err);
            return;
          }

          if (!stopping) {
            console.warn(`${logPrefix} OpenCode serve exited unexpectedly (code ${code}).`);
            if (stderrBuffer.trim()) {
              console.warn(
                `${logPrefix} OpenCode serve stderr: ${stderrBuffer.trim().split(/\r?\n/)[0]}`,
              );
            }
          }
          clearTimeout(timeout);
          child = null;
          started = false;
        });
      });
    })();
  }

  function waitForHealthy() {
    return new Promise((resolve, reject) => {
      const check = (attempt = 0, pathIndex = 0) => {
        if (!baseUrl) {
          reject(new Error("No base URL available for health check."));
          return;
        }

        const healthPath = HEALTH_PATHS[pathIndex] || HEALTH_PATHS[0];

        if (httpGetImpl) {
          httpGetImpl(`${baseUrl}${healthPath}`)
            .then(({ ok, version: v }) => {
              if (ok) {
                if (readString(v)) version = readString(v);
                resolve();
                return;
              }
              if (pathIndex + 1 < HEALTH_PATHS.length) {
                check(attempt, pathIndex + 1);
                return;
              }
              reject(new Error("OpenCode health check returned not-ok."));
            })
            .catch(() => {
              if (pathIndex + 1 < HEALTH_PATHS.length) {
                check(attempt, pathIndex + 1);
                return;
              }
              if (attempt > 30) {
                reject(new Error("OpenCode health check timed out."));
                return;
              }
              setTimeout(() => check(attempt + 1, 0), 500);
            });
          return;
        }

        const req = http.get(`${baseUrl}${healthPath}`, { timeout: HEALTH_TIMEOUT_MS }, (res) => {
          let body = "";
          res.on("data", (chunk) => {
            body += chunk;
          });
          res.on("end", () => {
            try {
              const parsed = parseHealthPayload(JSON.parse(body));
              if (parsed.ok) {
                if (readString(parsed.version)) {
                  version = readString(parsed.version);
                }
                resolve();
                return;
              }
              if (pathIndex + 1 < HEALTH_PATHS.length) {
                check(attempt, pathIndex + 1);
                return;
              }
              reject(new Error("OpenCode health check returned not-ok."));
            } catch (e) {
              if (pathIndex + 1 < HEALTH_PATHS.length) {
                check(attempt, pathIndex + 1);
                return;
              }
              reject(new Error(`OpenCode health check failed: ${e.message}`));
            }
          });
        });

        const retry = () => {
          if (attempt > 30) {
            reject(new Error("OpenCode health check timed out."));
            return;
          }
          setTimeout(() => check(attempt + 1, 0), 500);
        };

        req.on("error", () => {
          if (pathIndex + 1 < HEALTH_PATHS.length) {
            check(attempt, pathIndex + 1);
            return;
          }
          retry();
        });
        req.on("timeout", () => {
          req.destroy();
          if (pathIndex + 1 < HEALTH_PATHS.length) {
            check(attempt, pathIndex + 1);
            return;
          }
          retry();
        });
      };

      check(0, 0);
    });
  }

  function stop() {
    stopping = true;
    if (!child) {
      stopping = false;
      return Promise.resolve();
    }

    return new Promise((resolve) => {
      const killed = setTimeout(() => {
        if (child && !child.killed) {
          try {
            child.kill("SIGKILL");
          } catch {}
        }
        child = null;
        started = false;
        stopping = false;
        resolve();
      }, SHUTDOWN_TIMEOUT_MS);

      child.on("close", () => {
        clearTimeout(killed);
        child = null;
        started = false;
        stopping = false;
        resolve();
      });

      try {
        child.kill("SIGTERM");
      } catch {
        clearTimeout(killed);
        child = null;
        started = false;
        stopping = false;
        resolve();
      }
    });
  }

  function cleanup() {
    stopping = true;
    if (child) {
      try {
        child.kill("SIGTERM");
      } catch {}
      child = null;
    }
    started = false;
    stopping = false;
  }

  return {
    get baseUrl() {
      return baseUrl;
    },
    get version() {
      return version;
    },
    get port() {
      return activePort;
    },
    get isRunning() {
      return started && child !== null;
    },
    getLastStartFailure() {
      return lastStartFailure ? { ...lastStartFailure } : null;
    },
    start,
    stop,
  };
}

module.exports = {
  createOpenCodeServer,
  START_TIMEOUT_MS,
  HEALTH_TIMEOUT_MS,
  HEALTH_PATHS,
  PORT_RANGE_START,
  PORT_RANGE_END,
  SERVE_HOST,
  findAvailablePort,
  isPortAvailable,
  parseHealthPayload,
  resolveServePort,
  validateOpenCodeCommand,
};
