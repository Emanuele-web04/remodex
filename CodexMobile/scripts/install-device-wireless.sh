#!/usr/bin/env bash
# FILE: install-device-wireless.sh
# Purpose: Build CodexMobile for a paired iOS device and install over Wi‑Fi (devicectl).
# Layer: developer utility
# Usage: ./CodexMobile/scripts/install-device-wireless.sh [device-identifier]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${ROOT_DIR}/CodexMobile.xcodeproj"
SCHEME="CodexMobile"
CONFIGURATION="${XCODE_CONFIGURATION:-Debug}"
# Colons in the workspace path break Swift .d dependency files; keep DerivedData elsewhere.
DERIVED_DATA="${DERIVED_DATA_PATH:-${HOME}/Library/Developer/Xcode/DerivedData/Remodex-CodexMobile-wireless}"
DEVICE_ID="${1:-${IOS_DEVICE_ID:-}}"

log() {
  echo "[install-device-wireless] $*"
}

die() {
  echo "[install-device-wireless] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

select_device_id() {
  local json_path
  json_path="$(mktemp)"
  trap 'rm -f "${json_path}"' RETURN

  xcrun devicectl list devices --json-output "${json_path}" >/dev/null 2>&1 || true
  python3 - "${json_path}" "${DEVICE_ID}" <<'PY'
import json, os, sys

path, override = sys.argv[1], sys.argv[2].strip()
if not os.path.exists(path):
    sys.exit(0)
with open(path) as fh:
    payload = json.load(fh)
devices = payload.get("result", {}).get("devices", [])

def pick(devices):
    candidates = []
    for d in devices:
        props = d.get("deviceProperties", {})
        conn = d.get("connectionProperties", {})
        if conn.get("pairingState") != "paired":
            continue
        candidates.append({
            "id": d.get("identifier", ""),
            "name": props.get("name", ""),
            "transport": conn.get("transportType", ""),
            "tunnel": conn.get("tunnelState", ""),
        })
    if not candidates:
        return None
    # Prefer Wi‑Fi / local network paired devices.
    ranked = sorted(
        candidates,
        key=lambda c: (
            c["transport"] == "localNetwork",
            c["tunnel"] == "connected",
            c["name"],
        ),
        reverse=True,
    )
    return ranked[0]["id"]

if override:
    print(override)
    sys.exit(0)

selected = pick(devices)
if selected:
    print(selected)
PY
}

require_command xcodebuild
require_command xcrun

DEVICE_ID="$(select_device_id)"
[[ -n "${DEVICE_ID}" ]] || die "No paired iOS device found. Pair in Xcode (Window → Devices) with Connect via network enabled."

log "Device: ${DEVICE_ID}"
log "Building ${SCHEME} (${CONFIGURATION})…"

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

APP_PATH="$(find "${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphoneos" -maxdepth 1 -name 'CodexMobile.app' -type d 2>/dev/null | head -1)"
[[ -n "${APP_PATH}" && -d "${APP_PATH}" ]] || die "Build succeeded but CodexMobile.app was not found under ${DERIVED_DATA}"

log "Installing ${APP_PATH}…"
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Info.plist")"
log "Launching ${BUNDLE_ID}…"
xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing "${BUNDLE_ID}" || true

log "Done. Open Remodex on the iPad and scan the QR from ./run-local-remodex.sh --hostname <your-lan-ip>"
