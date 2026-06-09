#!/usr/bin/env node
// FILE: test-relay-handshake.js
// Purpose: Smoke-test E2EE clientHello → serverHello through a live relay + Mac bridge.
// Layer: developer utility
// Usage: node scripts/test-relay-handshake.js [relay-ws-url]

const WebSocket = require("ws");
const { generateKeyPairSync } = require("crypto");
const { readPairingSession } = require("../src/daemon-state");
const { loadOrCreateBridgeDeviceState } = require("../src/secure-device-state");

function createOkpKeyPair(type) {
  const { privateKey, publicKey } = generateKeyPairSync(type);
  const publicJwk = publicKey.export({ format: "jwk" });
  const privateJwk = privateKey.export({ format: "jwk" });
  return {
    publicKey: Buffer.from(publicJwk.x, "base64url").toString("base64"),
    privateKey: Buffer.from(privateJwk.d, "base64url").toString("base64"),
  };
}

function onceMessage(socket, timeoutMs = 15_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`Timed out waiting for relay message after ${timeoutMs}ms`));
    }, timeoutMs);
    socket.once("message", (data) => {
      clearTimeout(timer);
      resolve(typeof data === "string" ? data : data.toString("utf8"));
    });
    socket.once("close", (code, reason) => {
      clearTimeout(timer);
      reject(new Error(`Socket closed (${code}): ${reason.toString()}`));
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function main() {
  const pairing = readPairingSession();
  const payload = pairing?.pairingPayload;
  if (!payload?.sessionId || !payload?.relay) {
    console.error(
      "[test-relay-handshake] No ~/.remodex/pairing-session.json. Start ./run-local-remodex.sh first.",
    );
    process.exit(1);
  }

  const relayBase = (process.argv[2] || payload.relay).replace(/\/+$/, "");
  const sessionId = payload.sessionId;
  const deviceState = loadOrCreateBridgeDeviceState();
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const clientNonce = Buffer.alloc(32, 9);

  const iphoneUrl = `${relayBase}/${sessionId}?role=iphone`;
  console.log(`[test-relay-handshake] Connecting iphone → ${iphoneUrl}`);

  const socket = new WebSocket(iphoneUrl, { headers: { "x-role": "iphone" } });
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });

  socket.send(
    JSON.stringify({
      kind: "clientHello",
      protocolVersion: 1,
      sessionId,
      handshakeMode: "qr_bootstrap",
      phoneDeviceId: "handshake-smoke-test",
      phoneIdentityPublicKey: phoneIdentity.publicKey,
      phoneEphemeralPublicKey: phoneEphemeral.publicKey,
      clientNonce: clientNonce.toString("base64"),
    }),
  );

  const raw = await onceMessage(socket);
  const message = JSON.parse(raw);
  if (message.kind !== "serverHello") {
    console.error("[test-relay-handshake] Unexpected message:", message);
    process.exit(1);
  }

  if (message.macIdentityPublicKey !== deviceState.macIdentityPublicKey) {
    console.error("[test-relay-handshake] macIdentityPublicKey mismatch");
    process.exit(1);
  }

  console.log(
    `[test-relay-handshake] OK serverHello keyEpoch=${message.keyEpoch} session=${sessionId.slice(0, 8)}…`,
  );
  socket.close();
}

main().catch((error) => {
  console.error(`[test-relay-handshake] ${error.message}`);
  process.exit(1);
});
