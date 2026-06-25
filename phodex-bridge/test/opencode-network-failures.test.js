// FILE: opencode-network-failures.test.js
// Purpose: Verifies OpenCode client handles network failure scenarios gracefully.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-client

const test = require("node:test");
const assert = require("node:assert/strict");
const { createOpenCodeClient } = require("../src/opencode-client");

test("client handles connection refused during session creation", async () => {
  // Arrange: Mock SDK client that simulates ECONNREFUSED
  const mockClientImpl = () => ({
    session: {
      create: async () => {
        const error = new Error("connect ECONNREFUSED 127.0.0.1:4291");
        error.code = "ECONNREFUSED";
        error.errno = -61;
        error.syscall = "connect";
        throw error;
      },
    },
  });

  // Act & Assert: Client should propagate connection error (session creation is critical)
  await assert.rejects(
    async () => {
      const client = await createOpenCodeClient({
        baseUrl: "http://127.0.0.1:4291",
        createOpencodeClientImpl: mockClientImpl,
      });
      await client.createSession({ cwd: "/tmp/test" });
    },
    (error) => {
      assert.ok(error.message.includes("ECONNREFUSED") || error.message.includes("connection"), 
        "Error should indicate connection failure");
      return true;
    }
  );
});

test("client handles timeout during model listing", async () => {
  // Arrange: Mock SDK client that simulates timeout
  const mockClientImpl = () => ({
    provider: {
      list: async () => {
        const error = new Error("OpenCode SDK request timed out after 90000ms");
        error.code = "TIMEOUT";
        throw error;
      },
    },
  });

  // Act & Assert: Client should handle timeout gracefully with empty result
  const client = await createOpenCodeClient({
    baseUrl: "http://127.0.0.1:4291",
    createOpencodeClientImpl: mockClientImpl,
  });
  const result = await client.listModels();
  
  // Assert: Should return empty result on timeout (graceful degradation)
  assert.equal(result.models.length, 0);
  assert.equal(result.meta.reasonCode, "provider_list_failed");
});

test("client handles connection reset during turn execution", async () => {
  // Arrange: Mock SDK client that simulates connection reset
  const mockClientImpl = () => ({
    session: {
      create: async () => ({ sessionID: "ses_test" }),
      prompt: async () => {
        const error = new Error("read ECONNRESET");
        error.code = "ECONNRESET";
        error.errno = -54;
        error.syscall = "read";
        throw error;
      },
    },
  });

  // Act & Assert: Client should propagate connection reset error (turn execution is critical)
  await assert.rejects(
    async () => {
      const client = await createOpenCodeClient({
        baseUrl: "http://127.0.0.1:4291",
        createOpencodeClientImpl: mockClientImpl,
      });
      const sessionId = await client.createSession({ cwd: "/tmp/test" });
      await client.prompt({
        sessionId,
        input: "test",
        parts: [{ type: "text", text: "test" }],
      });
    },
    (error) => {
      assert.ok(error.message.includes("ECONNRESET") || error.message.includes("connection"), 
        "Error should indicate connection reset");
      return true;
    }
  );
});

test("client handles socket hang up during session listing", async () => {
  // Arrange: Mock SDK client that simulates socket hang up
  const mockClientImpl = () => ({
    session: {
      list: async () => {
        const error = new Error("socket hang up");
        error.code = "ECONNRESET";
        throw error;
      },
    },
  });

  // Act & Assert: Client should handle socket error gracefully with empty result
  const client = await createOpenCodeClient({
    baseUrl: "http://127.0.0.1:4291",
    createOpencodeClientImpl: mockClientImpl,
  });
  const result = await client.listSessions();
  
  // Assert: Should return empty result on socket error (graceful degradation)
  assert.equal(result.data.length, 0);
});

test("client handles host unreachable during agent listing", async () => {
  // Arrange: Mock SDK client that simulates host unreachable
  const mockClientImpl = () => ({
    app: {
      agents: async () => {
        const error = new Error("getaddrinfo ENOTFOUND 127.0.0.1");
        error.code = "ENOTFOUND";
        error.errno = -2;
        error.syscall = "getaddrinfo";
        throw error;
      },
    },
  });

  // Act & Assert: Client should handle host unreachable gracefully with empty result
  const client = await createOpenCodeClient({
    baseUrl: "http://127.0.0.1:4291",
    createOpencodeClientImpl: mockClientImpl,
  });
  const result = await client.listAgents();
  
  // Assert: Should return empty result on host unreachable (graceful degradation)
  assert.equal(result.length, 0);
});
