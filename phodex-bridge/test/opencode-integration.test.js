// FILE: opencode-integration.test.js
// Purpose: Real integration tests with live opencode serve
// Note: These tests spawn actual opencode serve processes
// Run with: REMODEX_RUN_INTEGRATION_TESTS=1 npm test -- opencode-integration.test.js

const test = require("node:test");
const assert = require("node:assert");
const { spawn } = require("child_process");
const net = require("net");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { createOpenCodeClient } = require("../src/opencode-client");

const INTEGRATION_TEST_ENABLED = process.env.REMODEX_RUN_INTEGRATION_TESTS === "1";
const OPENCODE_BINARY = process.env.REMODEX_OPENCODE_BINARY || "opencode";
const TEST_TIMEOUT_MS = 30_000; // 30 seconds per test
const SERVER_STARTUP_TIMEOUT_MS = 10_000; // 10 seconds for server startup

class OpenCodeTestServer {
  constructor() {
    this.process = null;
    this.port = null;
    this.baseUrl = null;
    this.tempDir = null;
  }

  async start() {
    // Create temporary directory for test data
    this.tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-integration-"));

    // Reserve an ephemeral loopback port to avoid collisions with local services.
    this.port = await findAvailableLoopbackPort();
    this.baseUrl = `http://127.0.0.1:${this.port}`;

    // Spawn opencode serve (mirror src/opencode-server.js: no --directory flag;
    // the working directory is controlled via cwd)
    const args = [
      "serve",
      "--hostname=127.0.0.1",
      "--port", String(this.port),
    ];

    this.process = spawn(OPENCODE_BINARY, args, {
      stdio: ["ignore", "pipe", "pipe"],
      cwd: this.tempDir,
      env: { ...process.env, NODE_ENV: "test" },
    });

    // Capture output for debugging
    this.stdout = [];
    this.stderr = [];
    this.process.stdout.on("data", (data) => {
      this.stdout.push(data.toString());
    });
    this.process.stderr.on("data", (data) => {
      this.stderr.push(data.toString());
    });

    // Wait for server to be ready
    await this.waitForServerReady();
  }

  async waitForServerReady() {
    const startTime = Date.now();
    while (Date.now() - startTime < SERVER_STARTUP_TIMEOUT_MS) {
      for (const healthPath of ["/global/health", "/health"]) {
        try {
          const response = await fetch(this.baseUrl + healthPath, {
            signal: AbortSignal.timeout(1000),
          }).catch(() => null);
          if (response && response.ok) {
            return;
          }
        } catch {
          // Server not ready yet
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    throw new Error("OpenCode server failed to start within timeout");
  }

  async stop() {
    if (this.process) {
      const child = this.process;
      this.process = null;
      child.kill("SIGTERM");
      try {
        await new Promise((resolve, reject) => {
          const killTimer = setTimeout(() => {
            child.kill("SIGKILL");
            resolve();
          }, 5000);
          child.on("exit", () => {
            clearTimeout(killTimer);
            resolve();
          });
          child.on("error", (error) => {
            clearTimeout(killTimer);
            reject(error);
          });
        });
      } catch {
        // Process already exited
      }
    }

    // Clean up temp directory
    if (this.tempDir && fs.existsSync(this.tempDir)) {
      fs.rmSync(this.tempDir, { recursive: true, force: true });
    }
  }

  getOutput() {
    return {
      stdout: this.stdout.join(""),
      stderr: this.stderr.join(""),
    };
  }
}

async function findAvailableLoopbackPort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
  });
}

test("integration: thread creation with live opencode serve", { timeout: TEST_TIMEOUT_MS }, async (t) => {
  if (!INTEGRATION_TEST_ENABLED) {
    t.skip("Set REMODEX_RUN_INTEGRATION_TESTS=1 to run integration tests");
    return;
  }

  const server = new OpenCodeTestServer();
  try {
    await server.start();

    const client = await createOpenCodeClient({
      baseUrl: server.baseUrl,
      logPrefix: "[integration-test]",
    });

    // Test session creation
    const sessionId = await client.createSession({
      cwd: server.tempDir,
    });
    assert.ok(sessionId, "Session ID should be returned");
    assert.strictEqual(typeof sessionId, "string", "Session ID should be a string");

    // Test session retrieval
    const session = await client.getSession(sessionId, {
      directory: server.tempDir,
    });
    assert.ok(session, "Session should be retrievable");

    // Test project listing
    const projects = await client.listProjects({
      directory: server.tempDir,
    });
    assert.ok(Array.isArray(projects), "Projects should be an array");

  } finally {
    await server.stop();
  }
});

test("integration: provider lifecycle with live opencode serve", { timeout: TEST_TIMEOUT_MS }, async (t) => {
  if (!INTEGRATION_TEST_ENABLED) {
    t.skip("Set REMODEX_RUN_INTEGRATION_TESTS=1 to run integration tests");
    return;
  }

  const server = new OpenCodeTestServer();
  try {
    await server.start();

    const client = await createOpenCodeClient({
      baseUrl: server.baseUrl,
      logPrefix: "[integration-test]",
    });

    // Test model listing
    const modelsResponse = await client.listModels({ force: true });
    assert.ok(modelsResponse, "Models response should exist");
    assert.ok(Array.isArray(modelsResponse.models), "Models should be an array");
    assert.ok(modelsResponse.meta, "Meta should exist");

    // Test agent listing
    const agents = await client.listAgents();
    assert.ok(Array.isArray(agents), "Agents should be an array");

    // Test that we can create multiple sessions
    const session1 = await client.createSession({ cwd: server.tempDir });
    const session2 = await client.createSession({ cwd: server.tempDir });
    assert.notStrictEqual(session1, session2, "Sessions should have unique IDs");

  } finally {
    await server.stop();
  }
});

test("integration: error handling with invalid opencode serve", { timeout: TEST_TIMEOUT_MS }, async (t) => {
  if (!INTEGRATION_TEST_ENABLED) {
    t.skip("Set REMODEX_RUN_INTEGRATION_TESTS=1 to run integration tests");
    return;
  }

  // Test that client handles invalid baseUrl gracefully
  await assert.rejects(
    async () => {
      await createOpenCodeClient({
        baseUrl: "http://invalid-host-that-does-not-exist:9999",
        logPrefix: "[integration-test]",
      });
    },
    /baseUrl must be localhost/,
    "Should reject non-localhost baseUrl"
  );
});

test("integration: server cleanup on error", { timeout: TEST_TIMEOUT_MS }, async (t) => {
  if (!INTEGRATION_TEST_ENABLED) {
    t.skip("Set REMODEX_RUN_INTEGRATION_TESTS=1 to run integration tests");
    return;
  }

  const server = new OpenCodeTestServer();
  try {
    await server.start();

    // Simulate server crash
    if (server.process && server.process.kill) {
      server.process.kill("SIGKILL");
    }
    await new Promise((resolve) => setTimeout(resolve, 100));

    // Should be able to stop without hanging
    await server.stop();

    assert.ok(true, "Server cleanup completed successfully");
  } catch (error) {
    // Ensure cleanup even if test fails
    await server.stop().catch(() => {});
    throw error;
  }
});