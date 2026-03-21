// FILE: account-status.test.js
// Purpose: Verifies the bridge-side auth snapshot stays sanitized for the phone UI.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/account-status

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  composeAccountStatus,
  composeSanitizedAuthStatusFromSettledResults,
  redactAuthStatus,
} = require("../src/account-status");

test("composeAccountStatus marks authenticated accounts and carries account metadata", () => {
  const status = composeAccountStatus({
    accountRead: {
      account: {
        type: "chatgpt",
        email: " user@example.com ",
        planType: " plus ",
      },
      requiresOpenaiAuth: false,
    },
    authStatus: {
      authMethod: "chatgpt",
      authToken: "token-value",
    },
  });

  assert.deepEqual(status, {
    status: "authenticated",
    authMethod: "chatgpt",
    email: "user@example.com",
    planType: "plus",
    loginInFlight: false,
    needsReauth: false,
    tokenReady: true,
    expiresAt: null,
    requiresOpenaiAuth: false,
  });
});

test("composeAccountStatus keeps authenticated UI state when account/read still has explicit login info", () => {
  const status = composeAccountStatus({
    accountRead: {
      account: {
        type: "chatgpt",
        email: "user@example.com",
      },
      requiresOpenaiAuth: false,
    },
    authStatus: {
      authMethod: "chatgpt",
      authToken: null,
    },
  });

  assert.deepEqual(status, {
    status: "authenticated",
    authMethod: "chatgpt",
    email: "user@example.com",
    planType: null,
    loginInFlight: false,
    needsReauth: false,
    tokenReady: false,
    expiresAt: null,
    requiresOpenaiAuth: false,
  });
});

test("composeAccountStatus reports reauth when auth status explicitly requires ChatGPT login again", () => {
  const status = composeAccountStatus({
    accountRead: {
      account: {
        type: "chatgpt",
        email: "user@example.com",
      },
      requiresOpenaiAuth: false,
    },
    authStatus: {
      authMethod: "chatgpt",
      authToken: null,
      requiresOpenaiAuth: true,
    },
  });

  assert.deepEqual(status, {
    status: "expired",
    authMethod: "chatgpt",
    email: "user@example.com",
    planType: null,
    loginInFlight: false,
    needsReauth: true,
    tokenReady: false,
    expiresAt: null,
    requiresOpenaiAuth: true,
  });
});

test("redactAuthStatus strips token-bearing fields from the status snapshot", () => {
  const status = redactAuthStatus({
    authMethod: "chatgpt",
    authToken: null,
  }, {
    accountRead: {
      account: null,
      requiresOpenaiAuth: true,
    },
    loginInFlight: true,
  });

  assert.deepEqual(status, {
    authMethod: "chatgpt",
    status: "pending_login",
    email: null,
    planType: null,
    loginInFlight: true,
    needsReauth: false,
    tokenReady: false,
    expiresAt: null,
  });
  assert.equal(Object.prototype.hasOwnProperty.call(status, "authToken"), false);
});

test("composeAccountStatus keeps a fresh signed-out state distinct from reauth", () => {
  const status = composeAccountStatus({
    accountRead: {
      account: null,
      requiresOpenaiAuth: true,
    },
    authStatus: {
      authMethod: null,
      authToken: null,
    },
  });

  assert.deepEqual(status, {
    status: "not_logged_in",
    authMethod: null,
    email: null,
    planType: null,
    loginInFlight: false,
    needsReauth: false,
    tokenReady: false,
    expiresAt: null,
    requiresOpenaiAuth: true,
  });
});

test("composeAccountStatus reports a pending login when no token is available yet", () => {
  const status = composeAccountStatus({
    accountRead: {
      account: null,
      requiresOpenaiAuth: true,
    },
    authStatus: {
      authMethod: null,
      authToken: null,
    },
    loginInFlight: true,
  });

  assert.equal(status.status, "pending_login");
  assert.equal(status.needsReauth, false);
  assert.equal(status.tokenReady, false);
});

test("composeSanitizedAuthStatusFromSettledResults keeps the available auth snapshot when account/read fails", () => {
  const status = composeSanitizedAuthStatusFromSettledResults({
    accountReadResult: {
      status: "rejected",
      reason: new Error("account/read failed"),
    },
    authStatusResult: {
      status: "fulfilled",
      value: {
        authMethod: "chatgpt",
        authToken: "token-value",
      },
    },
    loginInFlight: true,
  });

  assert.deepEqual(status, {
    authMethod: "chatgpt",
    status: "authenticated",
    email: null,
    planType: null,
    loginInFlight: true,
    needsReauth: false,
    tokenReady: true,
    expiresAt: null,
  });
});

test("composeSanitizedAuthStatusFromSettledResults keeps authenticated UI state when getAuthStatus fails", () => {
  const status = composeSanitizedAuthStatusFromSettledResults({
    accountReadResult: {
      status: "fulfilled",
      value: {
        account: {
          type: "chatgpt",
          email: "user@example.com",
        },
        requiresOpenaiAuth: false,
      },
    },
    authStatusResult: {
      status: "rejected",
      reason: new Error("getAuthStatus failed"),
    },
  });

  assert.deepEqual(status, {
    authMethod: "chatgpt",
    status: "authenticated",
    email: "user@example.com",
    planType: null,
    loginInFlight: false,
    needsReauth: false,
    tokenReady: false,
    expiresAt: null,
  });
});

test("composeSanitizedAuthStatusFromSettledResults fails when both auth reads fail", () => {
  assert.throws(() => composeSanitizedAuthStatusFromSettledResults({
    accountReadResult: {
      status: "rejected",
      reason: new Error("account/read failed"),
    },
    authStatusResult: {
      status: "rejected",
      reason: new Error("getAuthStatus failed"),
    },
  }), (error) => error?.errorCode === "auth_status_unavailable");
});
