// FILE: project-known-projects.test.js
// Purpose: Verifies project/knownProjects and project/rememberKnownProject RPCs.

const test = require("node:test");
const assert = require("node:assert/strict");
const os = require("os");
const path = require("path");
const {
  projectKnownProjects,
  projectRememberKnownProject,
  createKnownProjectsRegistry,
} = require("../src/project-handler");

test("rememberKnownProject and knownProjects round-trip", async () => {
  const homeDir = os.homedir();
  const registry = createKnownProjectsRegistry();
  const projectDir = path.join(homeDir, "Documents");

  const remembered = await projectRememberKnownProject(
    { path: projectDir, name: "Docs", provider: "opencode" },
    { homeDir, knownProjectsRegistry: registry },
  );

  assert.equal(remembered.project.name, "Docs");
  assert.equal(remembered.project.provider, "opencode");

  const listed = await projectKnownProjects({ knownProjectsRegistry: registry });
  assert.equal(listed.projects.length, 1);
  assert.equal(listed.projects[0].path, remembered.project.path);
});