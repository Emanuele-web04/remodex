import { createServer } from "http";
import { WebSocketServer } from "ws";
const { setupRelay, getRelayStats } = require("./relay.js");

const PORT = process.env.PORT || 8080;

const server = createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "x-role");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.url === "/health") {
    const stats = getRelayStats();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", ...stats }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

const wss = new WebSocketServer({ server });
setupRelay(wss);

server.listen(PORT, () => {
  console.log(`Relay server running on port ${PORT}`);
});
