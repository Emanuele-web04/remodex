// FILE: structured-logger.test.js
// Purpose: Test structured logging with consistent JSON format

const test = require("node:test");
const assert = require("node:assert");
const { createStructuredLogger, extractLogContext } = require("../src/structured-logger");

test("createStructuredLogger creates logger with default prefix", () => {
  const logger = createStructuredLogger();
  assert.strictEqual(typeof logger.info, "function");
  assert.strictEqual(typeof logger.warn, "function");
  assert.strictEqual(typeof logger.error, "function");
  assert.strictEqual(typeof logger.debug, "function");
});

test("createStructuredLogger uses custom component prefix", () => {
  const logger = createStructuredLogger("[test-component]");
  assert.strictEqual(typeof logger.info, "function");
});

test("logger.info outputs structured JSON log", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalLog = console.log;
  console.log = (message) => logs.push(message);

  logger.info("test message", { threadId: "thread-123", turnId: "turn-456" });

  console.log = originalLog;
  assert.strictEqual(logs.length, 1);

  const parsed = JSON.parse(logs[0]);
  assert.strictEqual(parsed.level, "info");
  assert.strictEqual(parsed.component, "[test]");
  assert.strictEqual(parsed.message, "test message");
  assert.strictEqual(parsed.threadId, "thread-123");
  assert.strictEqual(parsed.turnId, "turn-456");
  assert.strictEqual(typeof parsed.timestamp, "string");
});

test("logger.warn outputs structured JSON warning", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalWarn = console.warn;
  console.warn = (message) => logs.push(message);

  logger.warn("warning message", { context: "test" });

  console.warn = originalWarn;
  assert.strictEqual(logs.length, 1);

  const parsed = JSON.parse(logs[0]);
  assert.strictEqual(parsed.level, "warn");
  assert.strictEqual(parsed.message, "warning message");
  assert.strictEqual(parsed.context, "test");
});

test("logger.error outputs structured JSON error with Error object", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalError = console.error;
  console.error = (message) => logs.push(message);

  const testError = new Error("test error");
  testError.code = "TEST_ERROR";
  logger.error("error message", testError, { threadId: "thread-123" });

  console.error = originalError;
  assert.strictEqual(logs.length, 1);

  const parsed = JSON.parse(logs[0]);
  assert.strictEqual(parsed.level, "error");
  assert.strictEqual(parsed.message, "error message");
  assert.strictEqual(parsed.threadId, "thread-123");
  assert.strictEqual(parsed.error.message, "test error");
  assert.strictEqual(parsed.error.code, "TEST_ERROR");
  assert.strictEqual(typeof parsed.error.stack, "string");
});

test("logger.error outputs structured JSON error with plain object", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalError = console.error;
  console.error = (message) => logs.push(message);

  logger.error("error message", { customError: "details" }, { context: "test" });

  console.error = originalError;
  assert.strictEqual(logs.length, 1);

  const parsed = JSON.parse(logs[0]);
  assert.strictEqual(parsed.level, "error");
  assert.strictEqual(parsed.error.customError, "details");
  assert.strictEqual(parsed.context, "test");
});

test("logger.error outputs structured JSON error without error object", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalError = console.error;
  console.error = (message) => logs.push(message);

  logger.error("error message", null, { context: "test" });

  console.error = originalError;
  assert.strictEqual(logs.length, 1);

  const parsed = JSON.parse(logs[0]);
  assert.strictEqual(parsed.level, "error");
  assert.strictEqual(parsed.context, "test");
  assert.strictEqual(parsed.error, undefined);
});

test("logger.debug only outputs in debug mode", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalLog = console.log;
  console.log = (message) => logs.push(message);

  // Should not log by default
  logger.debug("debug message", { context: "test" });
  assert.strictEqual(logs.length, 0);

  // Should log when REMODEX_DEBUG=1
  process.env.REMODEX_DEBUG = "1";
  logger.debug("debug message", { context: "test" });
  assert.strictEqual(logs.length, 1);

  const parsed = JSON.parse(logs[0]);
  assert.strictEqual(parsed.level, "debug");
  assert.strictEqual(parsed.message, "debug message");

  // Cleanup
  delete process.env.REMODEX_DEBUG;
  console.log = originalLog;
});

test("logger.debug outputs in test environment", () => {
  const logger = createStructuredLogger("[test]");
  const logs = [];
  const originalLog = console.log;
  console.log = (message) => logs.push(message);

  const originalNodeEnv = process.env.NODE_ENV;
  process.env.NODE_ENV = "test";

  logger.debug("debug message", { context: "test" });
  assert.strictEqual(logs.length, 1);

  // Cleanup
  process.env.NODE_ENV = originalNodeEnv;
  console.log = originalLog;
});

test("extractLogContext extracts common context fields", () => {
  const params = {
    threadId: "thread-123",
    turnId: "turn-456",
    sessionId: "session-789",
    method: "test/method",
    extraField: "should not be extracted"
  };

  const context = extractLogContext(params);
  assert.strictEqual(context.threadId, "thread-123");
  assert.strictEqual(context.turnId, "turn-456");
  assert.strictEqual(context.sessionId, "session-789");
  assert.strictEqual(context.method, "test/method");
  assert.strictEqual(context.extraField, undefined);
});

test("extractLogContext handles snake_case variants", () => {
  const params = {
    thread_id: "thread-123",
    turn_id: "turn-456",
    session_id: "session-789"
  };

  const context = extractLogContext(params);
  assert.strictEqual(context.threadId, "thread-123");
  assert.strictEqual(context.turnId, "turn-456");
  assert.strictEqual(context.sessionId, "session-789");
});

test("extractLogContext prefers camelCase over snake_case", () => {
  const params = {
    threadId: "thread-camel",
    thread_id: "thread-snake"
  };

  const context = extractLogContext(params);
  assert.strictEqual(context.threadId, "thread-camel");
});

test("extractLogContext handles empty params", () => {
  const context = extractLogContext();
  assert.deepStrictEqual(context, {});
});

test("extractLogContext handles null params", () => {
  const context = extractLogContext(null);
  // The function should handle null gracefully and return empty object
  assert.deepStrictEqual(context, {});
});