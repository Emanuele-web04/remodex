// FILE: ios-app-compatibility.js
// Purpose: Centralizes conservative bridge gating for App Store iPhone version compatibility.
// Layer: CLI helper
// Exports: version comparison + bridge/iPhone compatibility helpers
// Depends on: none

const MINIMUM_SUPPORTED_IOS_APP_VERSION = "1.1";
const IOS_APP_COMPATIBILITY_GATE_BRIDGE_VERSION = "1.3.8";
const LEGACY_BRIDGE_VERSION_FOR_IOS_1_0 = "1.3.7";
const LEGACY_BRIDGE_DOWNGRADE_COMMAND = `npm install -g remodex@${LEGACY_BRIDGE_VERSION_FOR_IOS_1_0}`;
const NOTICE_BOX_WIDTH = 74;

function buildIOSAppCompatibilitySnapshot({
  bridgeVersion,
  iosAppVersion,
} = {}) {
  const normalizedBridgeVersion = normalizeVersionString(bridgeVersion);
  const normalizedIOSAppVersion = normalizeVersionString(iosAppVersion);
  const enforcesMinimumIOSAppVersion = shouldEnforceIOSAppCompatibility(normalizedBridgeVersion);

  if (!enforcesMinimumIOSAppVersion) {
    return buildSnapshot({
      bridgeVersion: normalizedBridgeVersion,
      iosAppVersion: normalizedIOSAppVersion,
      enforcesMinimumIOSAppVersion: false,
      isKnownIOSAppVersion: Boolean(normalizedIOSAppVersion),
      isCompatible: true,
      requiresAppUpdate: false,
      message: "",
    });
  }

  if (!normalizedIOSAppVersion) {
    return buildSnapshot({
      bridgeVersion: normalizedBridgeVersion,
      iosAppVersion: "",
      enforcesMinimumIOSAppVersion: true,
      isKnownIOSAppVersion: false,
      isCompatible: true,
      requiresAppUpdate: false,
      message: "",
    });
  }

  const isCompatible = compareNumericVersions(
    normalizedIOSAppVersion,
    MINIMUM_SUPPORTED_IOS_APP_VERSION
  ) >= 0;

  return buildSnapshot({
    bridgeVersion: normalizedBridgeVersion,
    iosAppVersion: normalizedIOSAppVersion,
    enforcesMinimumIOSAppVersion: true,
    isKnownIOSAppVersion: true,
    isCompatible,
    requiresAppUpdate: !isCompatible,
    message: isCompatible
      ? ""
      : buildLegacyIOSAppCompatibilityMessage({
        bridgeVersion: normalizedBridgeVersion,
        iosAppVersion: normalizedIOSAppVersion,
      }),
  });
}

function buildSnapshot({
  bridgeVersion,
  iosAppVersion,
  enforcesMinimumIOSAppVersion,
  isKnownIOSAppVersion,
  isCompatible,
  requiresAppUpdate,
  message,
}) {
  return {
    bridgeVersion,
    iosAppVersion,
    enforcesMinimumIOSAppVersion,
    isKnownIOSAppVersion,
    isCompatible,
    requiresAppUpdate,
    minimumSupportedIOSAppVersion: MINIMUM_SUPPORTED_IOS_APP_VERSION,
    legacyBridgeVersion: LEGACY_BRIDGE_VERSION_FOR_IOS_1_0,
    downgradeCommand: LEGACY_BRIDGE_DOWNGRADE_COMMAND,
    message,
  };
}

function shouldEnforceIOSAppCompatibility(bridgeVersion) {
  const normalizedBridgeVersion = normalizeVersionString(bridgeVersion);
  if (!normalizedBridgeVersion) {
    return false;
  }

  return compareNumericVersions(
    normalizedBridgeVersion,
    IOS_APP_COMPATIBILITY_GATE_BRIDGE_VERSION
  ) >= 0;
}

function buildLegacyIOSAppCompatibilityMessage({
  bridgeVersion,
  iosAppVersion,
} = {}) {
  const normalizedBridgeVersion = normalizeVersionString(bridgeVersion) || "this bridge";
  const normalizedIOSAppVersion = normalizeVersionString(iosAppVersion) || "an older version";

  return `Remodex bridge ${normalizedBridgeVersion} requires Remodex iPhone `
    + `${MINIMUM_SUPPORTED_IOS_APP_VERSION} or later. `
    + `Update the iPhone app from the App Store first, or install Remodex bridge `
    + `${LEGACY_BRIDGE_VERSION_FOR_IOS_1_0} to keep using iPhone ${normalizedIOSAppVersion}.`;
}

function buildCachedIOSAppCompatibilityWarning({
  bridgeVersion,
  iosAppVersion,
} = {}) {
  const snapshot = buildIOSAppCompatibilitySnapshot({
    bridgeVersion,
    iosAppVersion,
  });

  if (!snapshot.requiresAppUpdate) {
    return "";
  }

  return formatNoticeBox({
    title: "!!! WARNING !!!",
    lines: [
      `Remodex bridge ${snapshot.bridgeVersion || "latest"} requires Remodex iPhone ${snapshot.minimumSupportedIOSAppVersion} or later.`,
      "Update the iPhone app from the App Store first.",
      "",
      `Need to keep using iPhone ${snapshot.iosAppVersion}? Install bridge ${snapshot.legacyBridgeVersion}:`,
      snapshot.downgradeCommand,
    ],
  });
}

function formatNoticeBox({ title, lines }) {
  const innerWidth = NOTICE_BOX_WIDTH - 4;
  const border = `+${"-".repeat(NOTICE_BOX_WIDTH - 2)}+`;
  const body = [];
  const normalizedTitle = normalizeNonEmptyString(title);

  if (normalizedTitle) {
    body.push(...wrapBoxText(normalizedTitle, innerWidth));
    body.push(padBoxLine("", innerWidth));
  }

  for (const line of lines) {
    if (!normalizeNonEmptyString(line)) {
      body.push(padBoxLine("", innerWidth));
      continue;
    }
    body.push(...wrapBoxText(line, innerWidth));
  }

  return [border, ...body, border].join("\n");
}

function wrapBoxText(text, innerWidth) {
  const words = String(text).trim().split(/\s+/);
  const lines = [];
  let currentLine = "";

  for (const word of words) {
    const candidate = currentLine ? `${currentLine} ${word}` : word;
    if (candidate.length <= innerWidth) {
      currentLine = candidate;
      continue;
    }

    if (currentLine) {
      lines.push(padBoxLine(currentLine, innerWidth));
    }

    if (word.length <= innerWidth) {
      currentLine = word;
      continue;
    }

    let remaining = word;
    while (remaining.length > innerWidth) {
      lines.push(padBoxLine(remaining.slice(0, innerWidth), innerWidth));
      remaining = remaining.slice(innerWidth);
    }
    currentLine = remaining;
  }

  if (currentLine || lines.length === 0) {
    lines.push(padBoxLine(currentLine, innerWidth));
  }

  return lines;
}

function padBoxLine(text, innerWidth) {
  return `| ${String(text).padEnd(innerWidth, " ")} |`;
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function normalizeVersionString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function compareNumericVersions(left, right) {
  const leftParts = splitVersionParts(left);
  const rightParts = splitVersionParts(right);
  const maxLength = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = leftParts[index] || 0;
    const rightPart = rightParts[index] || 0;
    if (leftPart === rightPart) {
      continue;
    }
    return leftPart > rightPart ? 1 : -1;
  }

  return 0;
}

function splitVersionParts(value) {
  return normalizeVersionString(value)
    .split(".")
    .map((part) => Number.parseInt(part, 10))
    .filter((part) => Number.isFinite(part) && part >= 0);
}

module.exports = {
  LEGACY_BRIDGE_DOWNGRADE_COMMAND,
  LEGACY_BRIDGE_VERSION_FOR_IOS_1_0,
  IOS_APP_COMPATIBILITY_GATE_BRIDGE_VERSION,
  MINIMUM_SUPPORTED_IOS_APP_VERSION,
  buildCachedIOSAppCompatibilityWarning,
  buildIOSAppCompatibilitySnapshot,
  buildLegacyIOSAppCompatibilityMessage,
  compareNumericVersions,
  normalizeVersionString,
  shouldEnforceIOSAppCompatibility,
};
