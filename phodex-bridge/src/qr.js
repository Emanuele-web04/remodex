// FILE: qr.js
// Purpose: Prints the pairing QR payload that the iPhone scanner expects.
// Layer: CLI helper
// Exports: printQR
// Depends on: qrcode-terminal

const qrcode = require("qrcode-terminal");

function printQR(pairingPayload) {
  const payload = JSON.stringify(pairingPayload);

  console.log("\nScan this QR with the iPhone:\n");
  qrcode.generate(payload, { small: true });
  console.log(`\nSession ID: ${pairingPayload.sessionId}`);
  console.log(`Relay: ${pairingPayload.relay}`);
  console.log(`Device ID: ${pairingPayload.macDeviceId}`);
  console.log(`Expires: ${new Date(pairingPayload.expiresAt).toISOString()}\n`);
}

module.exports = { printQR };
