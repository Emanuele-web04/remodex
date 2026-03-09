// FILE: qr.js
// Purpose: Prints the pairing QR payload that the iPhone scanner expects.
// Layer: CLI helper
// Exports: printQR
// Depends on: qrcode-terminal

const qrcode = require("qrcode-terminal");

function printQR(sessionId, relayUrl) {
  const payload = JSON.stringify({
    relay: relayUrl,
    sessionId,
  });

  console.log("\nScan this QR with the iPhone:\n");
  qrcode.generate(payload, { small: true });
  console.log(`\nSession ID: ${sessionId}`);
  console.log(`Relay: ${relayUrl}\n`);
}

module.exports = { printQR };
