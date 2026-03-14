// FILE: notifications-handler.js
// Purpose: Intercepts notifications/push/* bridge RPCs and forwards device registration to the configured push service.
// Layer: Bridge handler
// Exports: createNotificationsHandler
// Depends on: none

function createNotificationsHandler({ pushServiceClient, logPrefix = "[remodex]" } = {}) {
  function handleNotificationsRequest(rawMessage, sendResponse) {
    let parsed;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "notifications/push/register") {
      return false;
    }

    const id = parsed.id;
    const params = parsed.params || {};

    handleNotificationsMethod(method, params)
      .then((result) => {
        sendResponse(JSON.stringify({ id, result }));
      })
      .catch((error) => {
        console.error(`${logPrefix} push registration failed: ${error.message}`);
        sendResponse(JSON.stringify({
          id,
          error: {
            code: -32000,
            message: error.userMessage || error.message || "Push registration failed.",
            data: {
              errorCode: error.errorCode || "push_registration_failed",
            },
          },
        }));
      });

    return true;
  }

  async function handleNotificationsMethod(method, params) {
    if (!pushServiceClient?.hasConfiguredBaseUrl) {
      return { ok: false, skipped: true };
    }

    const deviceToken = readString(params.deviceToken);
    const alertsEnabled = Boolean(params.alertsEnabled);
    const apnsEnvironment = readAPNsEnvironment(params.appEnvironment);
    if (!deviceToken) {
      throw notificationsError(
        "missing_device_token",
        "notifications/push/register requires a deviceToken."
      );
    }

    await pushServiceClient.registerDevice({
      deviceToken,
      alertsEnabled,
      apnsEnvironment,
    });

    return {
      ok: true,
      alertsEnabled,
      apnsEnvironment,
    };
  }

  return {
    handleNotificationsRequest,
  };
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function readAPNsEnvironment(value) {
  return value === "development" ? "development" : "production";
}

function notificationsError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  createNotificationsHandler,
};
