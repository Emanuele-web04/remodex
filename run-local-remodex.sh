#!/usr/bin/env bash

# FILE: run-local-remodex.sh
# Purpose: Start a local Remodex relay and the bridge CLI together with sensible defaults.
# Layer: developer utility
# Exports: none

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="${ROOT_DIR}/phodex-bridge"
RELAY_MODULE="${ROOT_DIR}/relay/relay.js"

RELAY_HOST="${RELAY_HOST:-0.0.0.0}"
RELAY_PORT="${RELAY_PORT:-9000}"
RELAY_PUBLIC_HOST="${RELAY_PUBLIC_HOST:-}"
RELAY_URL="${RELAY_URL:-}"

RELAY_PID=""
BRIDGE_DEPENDENCIES=("ws" "qrcode-terminal" "uuid")

# ----------------------------
# Output helpers
# ----------------------------

log() {
  echo "[run-local-remodex] $*"
}

warn() {
  echo "[run-local-remodex] Warning: $*" >&2
}

die() {
  echo "[run-local-remodex] $*" >&2
  exit 1
}

# ----------------------------
# CLI parsing
# ----------------------------

usage() {
  cat <<'EOF'
Usage: ./run-local-remodex.sh [options]

Options:
  --hostname HOSTNAME   Hostname or IP advertised to the bridge for relay access
  --bind-host HOST      Interface/address the local relay should listen on
  --port PORT           Relay port to listen on and advertise
  --help                Show this help text

Environment overrides:
  RELAY_PUBLIC_HOST     Same as --hostname
  RELAY_HOST            Same as --bind-host
  RELAY_PORT            Same as --port
  RELAY_URL             Full relay URL override (for example ws://host:9000/relay)

Defaults:
  bind host             0.0.0.0
  port                  9000
  hostname              macOS LocalHostName + ".local", then hostname, then localhost
EOF
}

require_value() {
  local flag_name="$1"
  local remaining_args="$2"
  [[ "${remaining_args}" -ge 2 ]] || die "${flag_name} requires a value."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)
        require_value "--hostname" "$#"
        RELAY_PUBLIC_HOST="$2"
        shift 2
        ;;
      --bind-host)
        require_value "--bind-host" "$#"
        RELAY_HOST="$2"
        shift 2
        ;;
      --port)
        require_value "--port" "$#"
        RELAY_PORT="$2"
        shift 2
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "[run-local-remodex] Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

# ----------------------------
# Configuration helpers
# ----------------------------

# Prefer the macOS Bonjour-friendly name when available so the QR points at a
# hostname the phone can typically resolve on the local network.
default_public_host() {
  if [[ -n "${RELAY_PUBLIC_HOST}" ]]; then
    printf '%s\n' "${RELAY_PUBLIC_HOST}"
    return
  fi

  if command -v scutil >/dev/null 2>&1; then
    local local_host_name
    local_host_name="$(scutil --get LocalHostName 2>/dev/null || true)"
    local_host_name="${local_host_name//[$'\r\n']}"
    if [[ -n "${local_host_name}" ]]; then
      printf '%s.local\n' "${local_host_name}"
      return
    fi
  fi

  local host_name
  host_name="$(hostname 2>/dev/null || true)"
  host_name="${host_name//[$'\r\n']}"
  if [[ -n "${host_name}" ]]; then
    printf '%s\n' "${host_name}"
    return
  fi

  printf 'localhost\n'
}

# The relay may listen on a wildcard address, but the readiness probe needs a
# concrete local destination.
healthcheck_host() {
  case "${RELAY_HOST}" in
    ""|"0.0.0.0")
      printf '127.0.0.1\n'
      ;;
    "::")
      printf '[::1]\n'
      ;;
    *)
      printf '%s\n' "${RELAY_HOST}"
      ;;
  esac
}

# ----------------------------
# Validation and cleanup
# ----------------------------

cleanup() {
  if [[ -n "${RELAY_PID}" ]] && kill -0 "${RELAY_PID}" 2>/dev/null; then
    kill "${RELAY_PID}" 2>/dev/null || true
    wait "${RELAY_PID}" 2>/dev/null || true
  fi
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "Missing required command: ${command_name}"
}

ensure_prerequisites() {
  require_command node
  require_command npm
  require_command curl
  require_command lsof
  require_command python3
}

confirm() {
  local prompt="$1"
  local response

  if [[ ! -t 0 ]]; then
    return 1
  fi

  read -r -p "${prompt} [y/N] " response
  case "${response}" in
    [yY]|[yY][eE][sS])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_dependencies_installed() {
  local dependency
  for dependency in "${BRIDGE_DEPENDENCIES[@]}"; do
    [[ -d "${BRIDGE_DIR}/node_modules/${dependency}" ]] || return 1
  done
  return 0
}

ensure_dependencies() {
  if bridge_dependencies_installed; then
    return
  fi

  warn "Bridge dependencies are missing in ${BRIDGE_DIR}/node_modules."
  warn "This will install: ${BRIDGE_DEPENDENCIES[*]}"

  if confirm "Install bridge dependencies now?"; then
    log "Installing bridge dependencies..."
    (cd "${BRIDGE_DIR}" && npm install)
    bridge_dependencies_installed || die "Bridge dependencies are still missing after npm install."
    return
  fi

  die "Bridge dependencies are required to run this launcher. Run 'cd ${BRIDGE_DIR} && npm install' and try again."
}

ensure_port_available() {
  if lsof -nP -iTCP:"${RELAY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port ${RELAY_PORT} is already in use.
Stop the existing listener or rerun with RELAY_PORT set to a free port."
  fi
}

wait_for_relay() {
  local attempt
  local probe_host
  probe_host="$(healthcheck_host)"
  for attempt in {1..20}; do
    if [[ -n "${RELAY_PID}" ]] && ! kill -0 "${RELAY_PID}" 2>/dev/null; then
      echo "[run-local-remodex] Relay process exited before becoming healthy." >&2
      return 1
    fi
    if curl --silent --fail "http://${probe_host}:${RELAY_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  echo "[run-local-remodex] Relay did not become healthy on port ${RELAY_PORT}." >&2
  return 1
}

print_host_notice() {
  if ! python3 - <<'PY' "${RELAY_PUBLIC_HOST}" >/dev/null 2>&1
import socket
import sys

socket.gethostbyname(sys.argv[1])
PY
  then
    warn "${RELAY_PUBLIC_HOST} does not currently resolve on this machine.
The relay will still listen locally on ${RELAY_HOST}:${RELAY_PORT},
but the bridge will only connect if ${RELAY_PUBLIC_HOST} resolves to this host."
  fi
}

# ----------------------------
# Embedded relay
# ----------------------------

start_embedded_relay() {
  log "Starting relay on ${RELAY_HOST}:${RELAY_PORT}..."

  HOST="${RELAY_HOST}" \
  PORT="${RELAY_PORT}" \
  RELAY_MODULE="${RELAY_MODULE}" \
  BRIDGE_DIR="${BRIDGE_DIR}" \
  node <<'NODE' &
const http = require("http");
const path = require("path");
const { WebSocketServer } = require(path.join(process.env.BRIDGE_DIR, "node_modules", "ws"));
const { setupRelay, getRelayStats } = require(process.env.RELAY_MODULE);

const host = process.env.HOST || "0.0.0.0";
const port = Number.parseInt(process.env.PORT || "9000", 10);

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("PORT must be an integer between 1 and 65535.");
}

function writeJson(res, statusCode, payload) {
  const json = JSON.stringify(payload);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(json),
  });
  res.end(json);
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    writeJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && req.url === "/stats") {
    writeJson(res, 200, getRelayStats());
    return;
  }

  writeJson(res, 404, { error: "Not found" });
});

const wss = new WebSocketServer({ server });
setupRelay(wss);

server.listen(port, host, () => {
  console.log(`[relay] listening on http://${host}:${port}`);
  console.log(`[relay] websocket path: ws://${host}:${port}/relay/{sessionId}`);
});

function shutdown(signal) {
  console.log(`[relay] shutting down (${signal})`);
  wss.close(() => {
    server.close(() => process.exit(0));
  });
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
NODE

  RELAY_PID=$!
}

# ----------------------------
# Bridge launch
# ----------------------------

print_runtime_summary() {
  cat <<EOF
[run-local-remodex] Configuration
  Relay bind host : ${RELAY_HOST}
  Relay port      : ${RELAY_PORT}
  Relay hostname  : ${RELAY_PUBLIC_HOST}
  Relay URL       : ${RELAY_URL}
EOF
}

start_bridge() {
  log "Starting bridge with REMODEX_RELAY=${RELAY_URL}"
  cd "${BRIDGE_DIR}"
  REMODEX_RELAY="${RELAY_URL}" node ./bin/remodex.js up
}

# ----------------------------
# Main
# ----------------------------

trap cleanup EXIT INT TERM

parse_args "$@"
RELAY_PUBLIC_HOST="$(default_public_host)"

if [[ -z "${RELAY_URL}" ]]; then
  RELAY_URL="ws://${RELAY_PUBLIC_HOST}:${RELAY_PORT}/relay"
fi

ensure_prerequisites
ensure_dependencies
print_host_notice
ensure_port_available
print_runtime_summary
start_embedded_relay
wait_for_relay
log "Relay is healthy."
start_bridge
