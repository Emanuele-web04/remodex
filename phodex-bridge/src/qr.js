// FILE: qr.js
// Purpose: Prints the bridge pairing payload as both QR and a short terminal-friendly pairing code.
// Layer: CLI helper
// Exports: SHORT_PAIRING_CODE_ALPHABET, SHORT_PAIRING_CODE_LENGTH, createShortPairingCode, printQR
// Depends on: crypto, qrcode-terminal

const { randomBytes } = require("crypto");
const qrcode = require("qrcode-terminal");

const SHORT_PAIRING_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const SHORT_PAIRING_CODE_LENGTH = 10;

// Generates a short-lived human-friendly pairing token for reconnect flows.
function createShortPairingCode({
  length = SHORT_PAIRING_CODE_LENGTH,
  randomBytesImpl = randomBytes,
} = {}) {
  const resolvedLength = Number.isInteger(length) && length > 0 ? length : SHORT_PAIRING_CODE_LENGTH;
  const bytes = randomBytesImpl(resolvedLength);
  let code = "";
  for (let index = 0; index < resolvedLength; index += 1) {
    code += SHORT_PAIRING_CODE_ALPHABET[bytes[index] % SHORT_PAIRING_CODE_ALPHABET.length];
  }
  return code;
}

function normalizePairingSession(pairingSessionOrPayload) {
  if (pairingSessionOrPayload?.pairingPayload) {
    return {
      pairingPayload: pairingSessionOrPayload.pairingPayload,
      pairingCode: typeof pairingSessionOrPayload.pairingCode === "string"
        ? pairingSessionOrPayload.pairingCode.trim()
        : "",
    };
  }

  return {
    pairingPayload: pairingSessionOrPayload,
    pairingCode: "",
  };
}

function printQR(pairingSessionOrPayload, options = {}) {
  const { pairingPayload, pairingCode } = normalizePairingSession(pairingSessionOrPayload);
  const payload = JSON.stringify(pairingPayload);
  const sessionId = typeof pairingPayload?.sessionId === "string" ? pairingPayload.sessionId.trim() : "";
  const sessionIdShort = sessionId.length > 12 ? `${sessionId.slice(0, 8)}…` : sessionId;
  const env = options.env || process.env;

  console.log("\nScan this QR with the iPhone:\n");
  qrcode.generate(payload, { small: true });
  if (pairingCode) {
    console.log("Or paste this pairing code in the iPhone app:\n");
    console.log(pairingCode);
  }
  console.log(`\nSession ID: ${sessionIdShort || "(none)"}`);
  console.log(`Device ID: ${pairingPayload.macDeviceId}`);
  console.log(`Expires: ${new Date(pairingPayload.expiresAt).toISOString()}\n`);

  if (shouldPrintPairingJson({ env, explicitValue: options.printPairingJson })) {
    // Opt-in only: this is the same bearer-like payload as the QR scan target.
    console.log("Pairing JSON (debug only; same sensitive bytes as the QR):\n");
    console.log(`${payload}\n`);
  }
}

function shouldPrintPairingJson({ env = process.env, explicitValue } = {}) {
  if (typeof explicitValue === "boolean") {
    return explicitValue;
  }

  const rawValue = env?.REMODEX_PRINT_PAIRING_JSON || env?.PHODEX_PRINT_PAIRING_JSON || "";
  return ["1", "true", "yes", "on"].includes(String(rawValue).trim().toLowerCase());
}

module.exports = {
  SHORT_PAIRING_CODE_ALPHABET,
  SHORT_PAIRING_CODE_LENGTH,
  createShortPairingCode,
  printQR,
  shouldPrintPairingJson,
};
