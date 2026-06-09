#!/usr/bin/env bash
# FILE: remodex-dev-pairing.sh
# Purpose: One Mac-side entry for device pairing — single relay owner, fresh QR in Preview.
# Usage: ./scripts/remodex-dev-pairing.sh [LAN-IP]
# Depends on: run-local-remodex.sh, phodex-bridge/scripts/open-pairing-qr-preview.sh, tmux

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTNAME="${1:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")}"
SESSION_NAME="remodex-pairing"
LOG="/tmp/remodex-local.log"

log() {
  echo "[remodex-dev-pairing] $*"
}

die() {
  echo "[remodex-dev-pairing] $*" >&2
  exit 1
}

stop_competing_bridges() {
  launchctl bootout "gui/$(id -u)/com.remodex.bridge" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/com.remodex.local-dev" 2>/dev/null || true
  pkill -f "run-local-remodex.sh" 2>/dev/null || true
  pkill -f "remodex.js run" 2>/dev/null || true
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:9000 -sTCP:LISTEN >/dev/null 2>&1; then
    log "Waiting for port 9000 to free..."
    sleep 2
    if lsof -nP -iTCP:9000 -sTCP:LISTEN >/dev/null 2>&1; then
      die "Port 9000 still in use. Stop the other relay/bridge and rerun."
    fi
  fi
}

wait_for_pairing_file() {
  local attempt
  for attempt in $(seq 1 30); do
    if [[ -f "${HOME}/.remodex/pairing-session.json" ]]; then
      return 0
    fi
    sleep 1
  done
  die "Timed out waiting for ~/.remodex/pairing-session.json — check ${LOG}"
}

wait_for_relay_health() {
  local attempt
  for attempt in $(seq 1 30); do
    if curl --silent --fail "http://127.0.0.1:9000/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "Relay health check failed on :9000 — see ${LOG}"
}

main() {
  command -v tmux >/dev/null 2>&1 || die "tmux is required (brew install tmux)"
  [[ "${HOSTNAME}" != "127.0.0.1" ]] || die "Pass your LAN IP: ./scripts/remodex-dev-pairing.sh 192.168.0.x"

  stop_competing_bridges
  : > "${LOG}"

  tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
  log "Starting relay+bridge in tmux session '${SESSION_NAME}' (hostname ${HOSTNAME})"
  tmux new-session -d -s "${SESSION_NAME}" \
    "cd '${ROOT_DIR}' && REMODEX_RELAY_MESSAGE_LIVENESS=1 exec ./run-local-remodex.sh --hostname '${HOSTNAME}' 2>&1 | tee -a '${LOG}'"

  wait_for_relay_health
  wait_for_pairing_file

  if [[ -x "${ROOT_DIR}/phodex-bridge/scripts/open-pairing-qr-preview.sh" ]]; then
    "${ROOT_DIR}/phodex-bridge/scripts/open-pairing-qr-preview.sh"
  else
    die "Missing phodex-bridge/scripts/open-pairing-qr-preview.sh"
  fi

  open -a Preview /tmp/remodex-pairing-qr.png 2>/dev/null || open /tmp/remodex-pairing-qr.png

  local code
  code="$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.remodex/pairing-session.json')))['pairingCode'])")"

  log "Relay: ws://${HOSTNAME}:9000/relay"
  log "Pairing code (backup): ${code}"
  log "QR opened in Preview — scan within 5 minutes"
  log "Stack runs in tmux attach -t ${SESSION_NAME} (do not close that session)"
}

main "$@"
