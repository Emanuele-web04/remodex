// FILE: pet-handler.test.js
// Purpose: Verifies local Codex pet package discovery and safety validation.
// Layer: Test
// Exports: node:test cases
// Depends on: node:test, fs, os, path, ../src/pet-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { handlePetMethod } = require("../src/pet-handler");

test("pet/list returns valid custom Codex pets as data URLs", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;
  writePetPackage(home, "icarus", {
    displayName: "Icarus",
    description: "A winged local pet.",
  });

  const result = await handlePetMethod("pet/list", {});

  assert.equal(result.avatars.length, 1);
  assert.equal(result.avatars[0].id, "custom:icarus");
  assert.equal(result.avatars[0].displayName, "Icarus");
  assert.match(result.avatars[0].spritesheetDataUrl, /^data:image\/png;base64,/);
  assert.equal(result.errors.length, 0);
});

test("pet/list reports invalid packages without failing the whole list", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;
  writePetPackage(home, "good-one", { displayName: "Good One" });

  const badRoot = path.join(home, "pets", "bad-one");
  fs.mkdirSync(badRoot, { recursive: true });
  fs.writeFileSync(
    path.join(badRoot, "pet.json"),
    JSON.stringify({ displayName: "Bad One", spritesheetPath: "../escape.webp" })
  );

  const result = await handlePetMethod("pet/list", {});

  assert.equal(result.avatars.length, 1);
  assert.equal(result.avatars[0].id, "custom:good-one");
  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].errorCode, "pet_spritesheet_path_invalid");
});

test("pet/list can return metadata without embedding spritesheet data", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;
  writePetPackage(home, "metadata-only", { displayName: "Metadata Only" });

  const result = await handlePetMethod("pet/list", { metadataOnly: true });

  assert.equal(result.avatars.length, 1);
  assert.equal(result.avatars[0].id, "custom:metadata-only");
  assert.equal(result.avatars[0].spritesheetDataUrl, undefined);
  assert.equal(result.avatars[0].spritesheetMimeType, "image/png");
});

test("pet/read returns spritesheet data for one selected pet", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;
  writePetPackage(home, "selected-one", { displayName: "Selected One" });
  writePetPackage(home, "other-one", { displayName: "Other One" });

  const result = await handlePetMethod("pet/read", { id: "custom:selected-one" });

  assert.equal(result.id, "custom:selected-one");
  assert.equal(result.displayName, "Selected One");
  assert.match(result.spritesheetDataUrl, /^data:image\/png;base64,/);
});

test("pet/read rejects unsafe pet ids", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;

  await assert.rejects(
    () => handlePetMethod("pet/read", { id: "custom:../escape" }),
    { errorCode: "pet_id_invalid" }
  );
});

test("pet/read falls back to a legacy avatar when the matching pet is invalid", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;

  const badRoot = path.join(home, "pets", "same-name");
  fs.mkdirSync(badRoot, { recursive: true });
  fs.writeFileSync(
    path.join(badRoot, "pet.json"),
    JSON.stringify({ displayName: "Broken Pet", spritesheetPath: "../escape.webp" })
  );
  writeAvatarPackage(home, "same-name", { displayName: "Legacy Avatar" });

  const result = await handlePetMethod("pet/read", { id: "custom:same-name" });

  assert.equal(result.id, "custom:same-name");
  assert.equal(result.kind, "avatar");
  assert.equal(result.displayName, "Legacy Avatar");
  assert.match(result.spritesheetDataUrl, /^data:image\/png;base64,/);
});

test("pet/list prefers pets over legacy avatars with the same folder name", async () => {
  const home = makeTempCodexHome();
  process.env.CODEX_HOME = home;
  writePetPackage(home, "same-name", { displayName: "Modern Pet" });
  writeAvatarPackage(home, "same-name", { displayName: "Legacy Avatar" });

  const result = await handlePetMethod("pet/list", { metadataOnly: true });

  assert.equal(result.avatars.length, 1);
  assert.equal(result.avatars[0].id, "custom:same-name");
  assert.equal(result.avatars[0].displayName, "Modern Pet");
  assert.equal(result.avatars[0].kind, "pet");
});

function makeTempCodexHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-pets-"));
}

function writePetPackage(home, slug, manifest) {
  const root = path.join(home, "pets", slug);
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(
    path.join(root, "pet.json"),
    JSON.stringify({
      id: slug,
      displayName: slug,
      description: "A test pet.",
      spritesheetPath: "spritesheet.png",
      ...manifest,
    })
  );
  fs.writeFileSync(path.join(root, "spritesheet.png"), fakePngHeader(1536, 1872));
}

function writeAvatarPackage(home, slug, manifest) {
  const root = path.join(home, "avatars", slug);
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(
    path.join(root, "avatar.json"),
    JSON.stringify({
      id: slug,
      displayName: slug,
      description: "A test avatar.",
      spritesheetPath: "spritesheet.png",
      ...manifest,
    })
  );
  fs.writeFileSync(path.join(root, "spritesheet.png"), fakePngHeader(1536, 1872));
}

function fakePngHeader(width, height) {
  const data = Buffer.alloc(33);
  data.writeUInt32BE(0x89504e47, 0);
  data.writeUInt32BE(0x0d0a1a0a, 4);
  data.writeUInt32BE(13, 8);
  data.write("IHDR", 12, "ascii");
  data.writeUInt32BE(width, 16);
  data.writeUInt32BE(height, 20);
  data[24] = 8;
  data[25] = 6;
  return data;
}
