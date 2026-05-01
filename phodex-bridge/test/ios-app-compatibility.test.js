// FILE: ios-app-compatibility.test.js
// Purpose: Verifies the bridge-side App Store iPhone compatibility policy stays conservative and explicit.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/ios-app-compatibility

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildCachedIOSAppCompatibilityWarning,
  buildIOSAppCompatibilitySnapshot,
  compareNumericVersions,
  shouldEnforceIOSAppCompatibility,
} = require("../src/ios-app-compatibility");

test("compareNumericVersions compares dotted versions numerically", () => {
  assert.equal(compareNumericVersions("1.3.8", "1.3.7"), 1);
  assert.equal(compareNumericVersions("1.1", "1.5"), -1);
  assert.equal(compareNumericVersions("1.5", "1.5.0"), 0);
});

test("shouldEnforceIOSAppCompatibility only turns on from bridge 1.3.9", () => {
  assert.equal(shouldEnforceIOSAppCompatibility("1.3.8"), false);
  assert.equal(shouldEnforceIOSAppCompatibility("1.3.9"), true);
  assert.equal(shouldEnforceIOSAppCompatibility("1.4.0"), true);
});

test("buildIOSAppCompatibilitySnapshot blocks iPhone 1.1 on bridge 1.3.9", () => {
  const snapshot = buildIOSAppCompatibilitySnapshot({
    bridgeVersion: "1.3.9",
    iosAppVersion: "1.1",
  });

  assert.equal(snapshot.requiresAppUpdate, true);
  assert.equal(snapshot.minimumSupportedIOSAppVersion, "1.5");
  assert.equal(snapshot.legacyBridgeVersion, "1.3.7");
  assert.equal(snapshot.downgradeCommand, "npm install -g remodex@1.3.7");
  assert.match(snapshot.message, /requires Remodex iPhone 1\.5 or later/i);
  assert.match(snapshot.message, /install Remodex bridge 1\.3\.7 to keep using iPhone 1\.1/i);
});

test("buildIOSAppCompatibilitySnapshot allows iPhone 1.5 on bridge 1.3.9", () => {
  const snapshot = buildIOSAppCompatibilitySnapshot({
    bridgeVersion: "1.3.9",
    iosAppVersion: "1.5",
  });

  assert.equal(snapshot.requiresAppUpdate, false);
  assert.equal(snapshot.isCompatible, true);
});

test("buildIOSAppCompatibilitySnapshot stays permissive when the iPhone version is unknown", () => {
  const snapshot = buildIOSAppCompatibilitySnapshot({
    bridgeVersion: "1.3.9",
    iosAppVersion: "",
  });

  assert.equal(snapshot.requiresAppUpdate, false);
  assert.equal(snapshot.isKnownIOSAppVersion, false);
});

test("buildCachedIOSAppCompatibilityWarning warns when the last seen iPhone app is 1.1", () => {
  const warning = buildCachedIOSAppCompatibilityWarning({
    bridgeVersion: "1.3.9",
    iosAppVersion: "1.1",
  });

  assert.match(warning, /!!! WARNING !!!/i);
  assert.match(warning, /requires Remodex iPhone 1\.5 or later/i);
  assert.match(warning, /Update the iPhone app from the App Store first/i);
  assert.match(warning, /npm install -g remodex@1\.3\.7/i);
});
