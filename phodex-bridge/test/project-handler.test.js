// FILE: project-handler.test.js
// Purpose: Verifies safe local project folder browsing and creation RPC helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/project-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  handleProjectRequest,
  handleProjectMethod,
  projectCreateDirectory,
  projectListDirectory,
  projectValidatePath,
} = require("../src/project-handler");

function makeTempHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-project-handler-"));
}

test("project/quickLocations only returns existing allowed folders", async () => {
  const homeDir = makeTempHome();
  fs.mkdirSync(path.join(homeDir, "Developer"));

  const result = await handleProjectMethod("project/quickLocations", {}, { homeDir });

  assert.deepEqual(
    result.locations.map((location) => location.id),
    ["home", "developer"]
  );
});

test("project/listDirectory returns sorted child folders and skips files or hidden folders by default", async () => {
  const homeDir = makeTempHome();
  fs.mkdirSync(path.join(homeDir, "Zoo"));
  fs.mkdirSync(path.join(homeDir, "app"));
  fs.mkdirSync(path.join(homeDir, ".hidden"));
  fs.mkdirSync(path.join(homeDir, "Library"));
  fs.writeFileSync(path.join(homeDir, "notes.txt"), "hello");

  const result = await projectListDirectory({ path: homeDir }, { homeDir });

  assert.equal(result.path, fs.realpathSync(homeDir));
  assert.equal(result.parentPath, null);
  assert.deepEqual(
    result.entries.map((entry) => entry.name),
    ["app", "Zoo"]
  );
});

test("project/createDirectory creates one child folder under an allowed parent", async () => {
  const homeDir = makeTempHome();

  const result = await projectCreateDirectory({
    parentPath: homeDir,
    name: "New App",
  }, { homeDir });

  assert.equal(result.path, path.join(fs.realpathSync(homeDir), "New App"));
  assert.equal(fs.statSync(result.path).isDirectory(), true);
});

test("project/createDirectory rejects names that escape the selected parent", async () => {
  const homeDir = makeTempHome();

  await assert.rejects(
    () => projectCreateDirectory({
      parentPath: homeDir,
      name: "../escape",
    }, { homeDir }),
    /Folder names cannot contain path separators/
  );
});

test("project/listDirectory rejects relative paths so bridge cwd never decides browsing scope", async () => {
  const homeDir = makeTempHome();

  await assert.rejects(
    () => projectListDirectory({ path: "." }, { homeDir }),
    /Use an absolute folder path/
  );
});

test("project/listDirectory keeps symlink display names while returning the resolved folder path", async () => {
  const homeDir = makeTempHome();
  const targetDir = path.join(homeDir, "ActualRepo");
  const linkPath = path.join(homeDir, "ClientApp");
  fs.mkdirSync(targetDir);
  fs.symlinkSync(targetDir, linkPath, "dir");

  const result = await projectListDirectory({ path: homeDir }, { homeDir });
  const linkEntry = result.entries.find((entry) => entry.name === "ClientApp");

  assert.equal(linkEntry?.path, fs.realpathSync(targetDir));
  assert.equal(linkEntry?.isSymlink, true);
});

test("project/validatePath rejects folders outside the allowed home root", async () => {
  const homeDir = makeTempHome();
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-outside-"));

  const result = await projectValidatePath({ path: outsideDir }, { homeDir });

  assert.equal(result.isAllowed, false);
  assert.equal(result.exists, false);
  assert.equal(result.isDirectory, false);
});

test("handleProjectRequest responds to project JSON-RPC requests", async () => {
  const homeDir = makeTempHome();
  const previousHome = process.env.HOME;
  process.env.HOME = homeDir;
  let response = "";

  try {
    const handled = handleProjectRequest(
      JSON.stringify({
        id: "project-1",
        method: "project/listDirectory",
        params: { path: homeDir },
      }),
      (payload) => {
        response = payload;
      }
    );

    assert.equal(handled, true);
    await new Promise((resolve) => setImmediate(resolve));
  } finally {
    if (previousHome == null) {
      delete process.env.HOME;
    } else {
      process.env.HOME = previousHome;
    }
  }

  assert.equal(JSON.parse(response).id, "project-1");
  assert.equal(JSON.parse(response).result.path, fs.realpathSync(homeDir));
});
