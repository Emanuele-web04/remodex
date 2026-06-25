// FILE: project-path-policy.test.js
// Purpose: Verifies home-root allowlist and sensitive-subdir denylist for project paths.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/project-path-policy

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  assertProjectPathAllowed,
  isPathAllowed,
  isSensitiveHomeSubpath,
} = require("../src/project-path-policy");

test("isPathAllowed rejects sensitive home subdirectories", () => {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-home-"));
  const projectsDir = path.join(homeDir, "Projects", "app");
  fs.mkdirSync(projectsDir, { recursive: true });

  assert.equal(isPathAllowed(projectsDir, { homeDir }), true);
  assert.equal(isPathAllowed(path.join(homeDir, ".ssh"), { homeDir }), false);
  assert.equal(isPathAllowed(path.join(homeDir, ".aws", "credentials"), { homeDir }), false);
  assert.equal(isSensitiveHomeSubpath(path.join(homeDir, ".gnupg"), { homeDir }), true);
});

test("assertProjectPathAllowed throws for sensitive subpaths under home", () => {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-home-"));
  const sshDir = path.join(homeDir, ".ssh");
  fs.mkdirSync(sshDir, { recursive: true });

  assert.throws(
    () => assertProjectPathAllowed(sshDir, { homeDir }),
    (error) => error.errorCode === "path_not_allowed",
  );
});
