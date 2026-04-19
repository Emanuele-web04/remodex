// FILE: package-version-status.test.js
// Purpose: Verifies bridge package version lookups stay non-blocking for local account refreshes.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/package-version-status

const test = require("node:test");
const assert = require("node:assert/strict");
const { version: bridgePackageVersion } = require("../package.json");

const {
  createBridgePackageVersionStatusReader,
} = require("../src/package-version-status");

function createDeferred() {
  let resolve;
  let reject;
  const promise = new Promise((innerResolve, innerReject) => {
    resolve = innerResolve;
    reject = innerReject;
  });

  return { promise, resolve, reject };
}

test("readBridgePackageVersionStatus returns immediately while latest version loads in background", async () => {
  const deferred = createDeferred();
  let fetchCallCount = 0;
  const readBridgePackageVersionStatus = createBridgePackageVersionStatusReader({
    emptyCacheRetryMs: 0,
    initialFetchWaitMs: 0,
    fetchLatestPublishedVersionImpl: async () => {
      fetchCallCount += 1;
      return deferred.promise;
    },
  });

  const firstResult = await readBridgePackageVersionStatus();

  assert.equal(fetchCallCount, 1);
  assert.equal(firstResult.bridgeVersion, bridgePackageVersion);
  assert.equal(firstResult.bridgeLatestVersion, null);

  deferred.resolve("9.9.9");
  await deferred.promise;
  await new Promise((resolve) => setImmediate(resolve));

  const secondResult = await readBridgePackageVersionStatus();

  assert.equal(fetchCallCount, 1);
  assert.equal(secondResult.bridgeLatestVersion, "9.9.9");
});

test("readBridgePackageVersionStatus includes the latest version on the first read when the fetch resolves quickly", async () => {
  let fetchCallCount = 0;
  const readBridgePackageVersionStatus = createBridgePackageVersionStatusReader({
    emptyCacheRetryMs: 0,
    initialFetchWaitMs: 50,
    fetchLatestPublishedVersionImpl: async () => {
      fetchCallCount += 1;
      return "9.9.9";
    },
  });

  const firstResult = await readBridgePackageVersionStatus();

  assert.equal(fetchCallCount, 1);
  assert.equal(firstResult.bridgeLatestVersion, "9.9.9");
});

test("readBridgePackageVersionStatus serves stale cache immediately while revalidating in background", async () => {
  const deferred = createDeferred();
  let fetchCallCount = 0;
  const fetchLatestPublishedVersionImpl = async () => {
    fetchCallCount += 1;
    if (fetchCallCount === 1) {
      return "9.9.9";
    }
    return deferred.promise;
  };
  const readBridgePackageVersionStatus = createBridgePackageVersionStatusReader({
    cacheTtlMs: 0,
    emptyCacheRetryMs: 0,
    initialFetchWaitMs: 0,
    fetchLatestPublishedVersionImpl,
  });

  const freshResult = await readBridgePackageVersionStatus();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(freshResult.bridgeLatestVersion, null);

  const staleWhileRefreshing = await readBridgePackageVersionStatus();

  assert.equal(fetchCallCount, 2);
  assert.equal(staleWhileRefreshing.bridgeLatestVersion, "9.9.9");

  deferred.resolve("10.0.0");
  await deferred.promise;
  await new Promise((resolve) => setImmediate(resolve));

  const refreshedResult = await readBridgePackageVersionStatus();

  assert.equal(refreshedResult.bridgeLatestVersion, "10.0.0");
});
