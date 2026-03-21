// FILE: account-status.js
// Purpose: Converts raw codex account/auth responses into a sanitized status payload for the phone UI.
// Layer: CLI helper
// Exports: composeAccountStatus, composeSanitizedAuthStatusFromSettledResults, redactAuthStatus
// Depends on: none

// ─── Status composition ─────────────────────────────────────

function composeAccountStatus({
  accountRead = null,
  authStatus = null,
  loginInFlight = false,
} = {}) {
  const account = accountRead?.account || null;
  const authToken = normalizeString(authStatus?.authToken);
  const hasAccountLogin = hasExplicitAccountLogin(account);
  const authMethod = firstNonEmpty([
    normalizeString(authStatus?.authMethod),
    normalizeString(account?.type),
  ]) || null;
  const tokenReady = Boolean(authToken);
  const requiresOpenaiAuth = Boolean(accountRead?.requiresOpenaiAuth || authStatus?.requiresOpenaiAuth);
  const hasPriorLoginContext = hasAccountLogin || Boolean(authMethod);
  const needsReauth = !loginInFlight && requiresOpenaiAuth && hasPriorLoginContext;
  const isAuthenticated = !needsReauth && (tokenReady || hasAccountLogin);
  const status = isAuthenticated
    ? "authenticated"
    : (loginInFlight ? "pending_login" : (needsReauth ? "expired" : "not_logged_in"));

  return {
    status,
    authMethod,
    email: normalizeString(account?.email) || null,
    planType: normalizeString(account?.planType) || null,
    loginInFlight: Boolean(loginInFlight),
    needsReauth,
    tokenReady,
    expiresAt: null,
    requiresOpenaiAuth,
  };
}

// Removes any token-bearing fields before the bridge sends auth state to the phone.
function redactAuthStatus(authStatus = null, extras = {}) {
  const composed = composeAccountStatus({
    accountRead: extras.accountRead || null,
    authStatus,
    loginInFlight: Boolean(extras.loginInFlight),
  });

  return {
    authMethod: composed.authMethod,
    status: composed.status,
    email: composed.email,
    planType: composed.planType,
    loginInFlight: composed.loginInFlight,
    needsReauth: composed.needsReauth,
    tokenReady: composed.tokenReady,
    expiresAt: composed.expiresAt,
  };
}

// ─── Settled snapshot helpers ───────────────────────────────

// Collapses settled bridge RPC results into one safe snapshot, even if one side fails.
// Input: Promise.allSettled-style results → Output: sanitized account status object
// Throws if both the account read and auth status fail, so the bridge can surface a real error.
function composeSanitizedAuthStatusFromSettledResults({
  accountReadResult = null,
  authStatusResult = null,
  loginInFlight = false,
} = {}) {
  const accountRead = accountReadResult?.status === "fulfilled" ? accountReadResult.value : null;
  const authStatus = authStatusResult?.status === "fulfilled" ? authStatusResult.value : null;

  if (!accountRead && !authStatus) {
    const error = new Error("Unable to read ChatGPT account status from the bridge.");
    error.errorCode = "auth_status_unavailable";
    throw error;
  }

  return redactAuthStatus(authStatus, {
    accountRead,
    loginInFlight: Boolean(loginInFlight),
  });
}

// Treat explicit account signals as authenticated when the token read is temporarily unavailable.
function hasExplicitAccountLogin(account) {
  if (!account || typeof account !== "object") {
    return false;
  }

  if (parseBoolean(account.loggedIn) || parseBoolean(account.logged_in) || parseBoolean(account.isLoggedIn)) {
    return true;
  }

  return Boolean(normalizeString(account.email));
}

// Normalizes empty strings and picks the first meaningful value from a short list.
function firstNonEmpty(values) {
  for (const value of values) {
    const normalized = normalizeString(value);
    if (normalized) {
      return normalized;
    }
  }
  return "";
}

// Keeps auth/account fields compact and consistent in the status snapshot.
function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function parseBoolean(value) {
  return value === true;
}

module.exports = {
  composeAccountStatus,
  composeSanitizedAuthStatusFromSettledResults,
  redactAuthStatus,
};
