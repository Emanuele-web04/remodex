const { promisify } = require("util");
const { execFile } = require("child_process");
const execFileAsync = promisify(execFile);
const { composeSanitizedAuthStatusFromSettledResults } = require("./account-status");
const { resolveVoiceAuth } = require("./voice-handler");

function parseBridgeJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

// Keeps reconnect handshakes transport-agnostic so warm initialize responses can
// flow back over either the live relay or an async helper transport.
function handleBridgeManagedHandshakeMessage(rawMessage, {
  codexHandshakeState,
  forwardedInitializeRequestIds,
  sendResponse,
}) {
  const parsed = parseBridgeJSON(rawMessage);
  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method) {
    return false;
  }

  if (method === "initialize" && parsed.id != null) {
    if (codexHandshakeState !== "warm") {
      forwardedInitializeRequestIds.add(String(parsed.id));
      return false;
    }

    sendResponse(JSON.stringify({
      id: parsed.id,
      result: {
        bridgeManaged: true,
      },
    }));
    return true;
  }

  if (method === "initialized") {
    return codexHandshakeState === "warm";
  }

  return false;
}

function createBridgeManagedAccountHandler({
  sendCodexRequest,
  readBridgePackageVersionStatus,
  getPendingAuthLogin,
}) {
  function handleBridgeManagedAccountRequest(rawMessage, sendResponse) {
    const parsed = parseBridgeJSON(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (
      method !== "account/status/read" &&
      method !== "getAuthStatus" &&
      method !== "account/login/openOnMac" &&
      method !== "voice/resolveAuth"
    ) {
      return false;
    }

    const requestId = parsed.id;
    const shouldRespond = requestId != null;

    readBridgeManagedAccountResult(method, parsed.params || {})
      .then((result) => {
        if (shouldRespond) {
          sendResponse(JSON.stringify({ id: requestId, result }));
        }
      })
      .catch((error) => {
        if (shouldRespond) {
          sendResponse(createJsonRpcErrorResponse(requestId, error, "auth_status_failed"));
        }
      });

    return true;
  }

  async function readBridgeManagedAccountResult(method, params) {
    switch (method) {
      case "account/status/read":
      case "getAuthStatus":
        return readSanitizedAuthStatus();
      case "account/login/openOnMac":
        return openPendingAuthLoginOnMac(params);
      case "voice/resolveAuth":
        return resolveVoiceAuth(sendCodexRequest);
      default:
        throw new Error(`Unsupported bridge-managed account method: ${method}`);
    }
  }

  async function readSanitizedAuthStatus() {
    const [accountReadResult, authStatusResult, bridgeVersionInfoResult] = await Promise.allSettled([
      sendCodexRequest("account/read", { refreshToken: false }),
      sendCodexRequest("getAuthStatus", { includeToken: true, refreshToken: true }),
      readBridgePackageVersionStatus(),
    ]);

    const pendingAuthLogin = getPendingAuthLogin();

    return composeSanitizedAuthStatusFromSettledResults({
      accountReadResult:
        accountReadResult.status === "fulfilled"
          ? {
              status: "fulfilled",
              value: normalizeAccountRead(accountReadResult.value),
            }
          : accountReadResult,
      authStatusResult,
      loginInFlight: Boolean(pendingAuthLogin.loginId),
      bridgeVersionInfo:
        bridgeVersionInfoResult.status === "fulfilled" ? bridgeVersionInfoResult.value : null,
    });
  }

  async function openPendingAuthLoginOnMac(params) {
    if (process.platform !== "darwin") {
      const error = new Error("Opening ChatGPT sign-in on the bridge is only supported on macOS.");
      error.errorCode = "unsupported_platform";
      throw error;
    }

    const authUrl =
      (typeof params?.authUrl === "string" && params.authUrl ? params.authUrl : null) ||
      getPendingAuthLogin().authUrl;

    if (!authUrl) {
      const error = new Error("No pending ChatGPT sign-in URL is available on this bridge.");
      error.errorCode = "missing_auth_url";
      throw error;
    }

    await execFileAsync("open", [authUrl], { timeout: 15_000 });
    return {
      success: true,
      openedOnMac: true,
    };
  }

  function normalizeAccountRead(payload) {
    if (!payload || typeof payload !== "object") {
      return {
        account: null,
        requiresOpenaiAuth: true,
      };
    }

    return {
      account: payload.account && typeof payload.account === "object" ? payload.account : null,
      requiresOpenaiAuth: Boolean(payload.requiresOpenaiAuth),
    };
  }

  function createJsonRpcErrorResponse(requestId, error, defaultErrorCode) {
    return JSON.stringify({
      id: requestId,
      error: {
        code: -32000,
        message: error?.userMessage || error?.message || "Bridge request failed.",
        data: {
          errorCode: error?.errorCode || defaultErrorCode,
        },
      },
    });
  }

  return {
    handleBridgeManagedAccountRequest,
  };
}

module.exports = {
  handleBridgeManagedHandshakeMessage,
  createBridgeManagedAccountHandler,
};
