const { createConvexHelperClient } = require("./convex-helper-client");
const { createICloudHelperClient } = require("./icloud-helper-client");

function readString(value) {
  return typeof value === "string" && value ? value : null;
}

function createAsyncHelperClient({
  config,
  helperPath,
  containerId,
  convexSiteUrl,
  getDeviceState,
  deviceStateDir,
  logPrefix,
  onAsyncRequest,
  onStatusChange,
}) {
  if (readString(convexSiteUrl)) {
    return createConvexHelperClient({
      enabled: true,
      siteUrl: convexSiteUrl,
      getDeviceState,
      logPrefix,
      onAsyncRequest,
      onStatusChange,
    });
  }

  return createICloudHelperClient({
    enabled: Boolean(config.cloudAsyncEnabled),
    helperPath,
    containerId,
    deviceStateDir,
    logPrefix,
    onAsyncRequest,
    onStatusChange,
  });
}

module.exports = {
  createAsyncHelperClient,
};
