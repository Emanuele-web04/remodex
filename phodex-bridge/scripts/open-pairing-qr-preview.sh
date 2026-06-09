#!/usr/bin/env bash
# FILE: open-pairing-qr-preview.sh
# Purpose: Render ~/.remodex/pairing-session.json as /tmp/remodex-pairing-qr.png for Preview.
# Depends on: python3, qrcode (pip)

set -euo pipefail

PAIRING_FILE="${HOME}/.remodex/pairing-session.json"
OUT="/tmp/remodex-pairing-qr.png"

[[ -f "${PAIRING_FILE}" ]] || {
  echo "[open-pairing-qr-preview] Missing ${PAIRING_FILE} — start the bridge first." >&2
  exit 1
}

python3 <<'PY'
import json, os, sys
try:
    import qrcode
except ImportError:
    sys.stderr.write("Install qrcode: pip3 install qrcode[pil]\n")
    sys.exit(1)

path = os.path.expanduser("~/.remodex/pairing-session.json")
data = json.load(open(path))
payload = data.get("pairingPayload")
if not payload:
    raise SystemExit("pairing-session.json has no pairingPayload")
out = "/tmp/remodex-pairing-qr.png"
qrcode.make(json.dumps(payload, separators=(",", ":"))).save(out)
print(out)
PY

chmod 644 "${OUT}" 2>/dev/null || true
echo "[open-pairing-qr-preview] Wrote ${OUT}"