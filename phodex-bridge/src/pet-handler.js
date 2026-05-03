// FILE: pet-handler.js
// Purpose: Lists Codex-compatible local pet packages for the mobile companion overlay.
// Layer: Bridge handler
// Exports: handlePetRequest, handlePetMethod
// Depends on: fs, path, ./codex-home

const fs = require("fs");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");

const ATLAS_WIDTH = 1536;
const ATLAS_HEIGHT = 1872;
const MAX_SPRITESHEET_BYTES = 16 * 1024 * 1024;
const IMAGE_MIME_TYPES_BY_EXTENSION = new Map([
  [".png", "image/png"],
  [".webp", "image/webp"],
]);

function handlePetRequest(rawMessage, sendResponse) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!isPetMethod(method)) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};
  handlePetMethod(method, params)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "pet_error";
      const message = err.userMessage || err.message || "Unable to load Codex pets.";
      sendResponse(
        JSON.stringify({
          id,
          error: {
            code: -32000,
            message,
            data: { errorCode },
          },
        })
      );
    });

  return true;
}

async function handlePetMethod(method, params = {}) {
  if (!isPetMethod(method)) {
    throw petError("pet_method_unknown", "Unknown Codex pet method.");
  }

  if (method === "pet/read" || method === "custom-avatar/read") {
    return readPet(params);
  }

  const codexHome = resolveCodexHome();
  const includeData = params.includeData !== false && params.metadataOnly !== true;
  const results = [];
  const errors = [];

  for (const directory of petDirectories(codexHome)) {
    const discovered = await loadPetDirectory(directory, { includeData });
    results.push(...discovered.avatars);
    errors.push(...discovered.errors);
  }

  const avatars = mergeCustomAvatars(results);
  return {
    avatarDirectory: path.join(codexHome, "pets"),
    petDirectory: path.join(codexHome, "pets"),
    avatars,
    pets: avatars,
    errors,
  };
}

// Reads a single selected pet so mobile does not have to embed every atlas in pet/list.
async function readPet(params = {}) {
  const codexHome = resolveCodexHome();
  const folderName = petFolderNameFromID(params.id || params.folderName);
  let lastError = null;

  for (const directory of petDirectories(codexHome)) {
    try {
      const avatar = await loadCustomAvatar(directory, folderName, { includeData: true });
      if (avatar) {
        return avatar;
      }
    } catch (error) {
      lastError = error;
    }
  }

  if (lastError) {
    throw lastError;
  }
  throw petError("pet_not_found", "The selected Codex pet could not be found.");
}

function isPetMethod(method) {
  return method === "pet/list"
    || method === "custom-avatars"
    || method === "pet/read"
    || method === "custom-avatar/read";
}

// Mirrors Codex desktop's pets-first custom avatar lookup while keeping legacy avatars usable.
function petDirectories(codexHome) {
  return [
    {
      root: path.join(codexHome, "pets"),
      manifestName: "pet.json",
      kind: "pet",
    },
    {
      root: path.join(codexHome, "avatars"),
      manifestName: "avatar.json",
      kind: "avatar",
    },
  ];
}

// Accept only a local package id/folder name; the spritesheet path is validated separately.
function petFolderNameFromID(rawID) {
  if (typeof rawID !== "string") {
    throw petError("pet_id_invalid", "A pet id is required.");
  }

  const folderName = rawID.startsWith("custom:") ? rawID.slice("custom:".length) : rawID;
  if (
    !folderName
    || folderName === "."
    || folderName === ".."
    || path.isAbsolute(folderName)
    || folderName.includes("/")
    || folderName.includes("\\")
  ) {
    throw petError("pet_id_invalid", "The selected pet id is invalid.");
  }

  return folderName;
}

async function loadPetDirectory(directory, { includeData }) {
  const avatars = [];
  const errors = [];
  let entries = [];

  try {
    entries = await fs.promises.readdir(directory.root, { withFileTypes: true });
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return { avatars, errors };
    }
    throw petError("pet_directory_unreadable", "Could not read local Codex pet folders.");
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    try {
      const avatar = await loadCustomAvatar(directory, entry.name, { includeData });
      if (avatar) {
        avatars.push(avatar);
      }
    } catch (error) {
      errors.push({
        folderName: entry.name,
        kind: directory.kind,
        message: error.userMessage || error.message || "Invalid pet package.",
        errorCode: error.errorCode || "invalid_pet",
      });
    }
  }

  return { avatars, errors };
}

async function loadCustomAvatar(directory, folderName, { includeData }) {
  const petRoot = path.join(directory.root, folderName);
  const manifestPath = path.join(petRoot, directory.manifestName);
  const manifest = await readManifest(manifestPath);
  if (!manifest) {
    return null;
  }

  const spritesheetPath = resolveSpritesheetPath(
    petRoot,
    typeof manifest.spritesheetPath === "string" ? manifest.spritesheetPath : "spritesheet.webp"
  );
  const image = await readValidatedSpritesheet(spritesheetPath, { includeData });
  const displayName = firstNonEmptyString([manifest.displayName, manifest.name, displayFromSlug(folderName)]);
  const description = firstNonEmptyString([manifest.description]) || "A custom Codex pet.";

  return {
    id: `custom:${folderName}`,
    folderName,
    kind: directory.kind,
    displayName,
    description,
    spritesheetPath,
    spritesheetMimeType: image.mimeType,
    spritesheetByteLength: image.byteLength,
    spritesheetDataUrl: image.dataUrl,
  };
}

async function readManifest(manifestPath) {
  let contents;
  try {
    contents = await fs.promises.readFile(manifestPath, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return null;
    }
    throw petError("pet_manifest_unreadable", "Could not read the pet manifest.");
  }

  try {
    const manifest = JSON.parse(contents);
    return manifest && typeof manifest === "object" ? manifest : {};
  } catch {
    throw petError("pet_manifest_invalid", "The pet manifest is not valid JSON.");
  }
}

function resolveSpritesheetPath(petRoot, rawSpritesheetPath) {
  const trimmedPath = rawSpritesheetPath.trim() || "spritesheet.webp";
  if (path.isAbsolute(trimmedPath)) {
    throw petError("pet_spritesheet_path_invalid", "Pet spritesheet paths must be relative.");
  }

  const candidate = path.resolve(petRoot, trimmedPath);
  const relative = path.relative(petRoot, candidate);
  if (relative === "" || relative.startsWith("..") || path.isAbsolute(relative)) {
    throw petError("pet_spritesheet_path_invalid", "Pet spritesheet paths cannot escape the pet folder.");
  }

  return candidate;
}

async function readValidatedSpritesheet(spritesheetPath, { includeData }) {
  const extension = path.extname(spritesheetPath).toLowerCase();
  const mimeType = IMAGE_MIME_TYPES_BY_EXTENSION.get(extension);
  if (!mimeType) {
    throw petError("pet_spritesheet_type_invalid", "Pet spritesheets must be PNG or WebP files.");
  }

  if (!includeData) {
    return readValidatedSpritesheetMetadata(spritesheetPath, mimeType);
  }

  const stat = await readSpritesheetStat(spritesheetPath);
  assertSpritesheetByteLength(stat.size);

  let data;
  try {
    data = await fs.promises.readFile(spritesheetPath);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      throw petError("pet_spritesheet_missing", "The pet spritesheet file does not exist.");
    }
    throw petError("pet_spritesheet_unreadable", "Could not read the pet spritesheet file.");
  }

  const dimensions = imageDimensions(data, mimeType);
  if (!dimensions || dimensions.width !== ATLAS_WIDTH || dimensions.height !== ATLAS_HEIGHT) {
    throw petError("pet_spritesheet_dimensions_invalid", "Pet spritesheets must be exactly 1536x1872 pixels.");
  }

  return {
    mimeType,
    byteLength: data.byteLength,
    dataUrl: includeData ? `data:${mimeType};base64,${data.toString("base64")}` : undefined,
  };
}

async function readValidatedSpritesheetMetadata(spritesheetPath, mimeType) {
  let file;
  try {
    file = await fs.promises.open(spritesheetPath, "r");
    const stat = await file.stat();
    assertSpritesheetByteLength(stat.size);
    const dimensions = await readImageDimensionsFromFile(file, mimeType, stat.size);
    if (!dimensions || dimensions.width !== ATLAS_WIDTH || dimensions.height !== ATLAS_HEIGHT) {
      throw petError("pet_spritesheet_dimensions_invalid", "Pet spritesheets must be exactly 1536x1872 pixels.");
    }

    return {
      mimeType,
      byteLength: stat.size,
      dataUrl: undefined,
    };
  } catch (error) {
    if (error && error.errorCode) {
      throw error;
    }
    if (error && error.code === "ENOENT") {
      throw petError("pet_spritesheet_missing", "The pet spritesheet file does not exist.");
    }
    throw petError("pet_spritesheet_unreadable", "Could not read the pet spritesheet file.");
  } finally {
    await file?.close();
  }
}

// Rejects oversized local packages before base64 expansion can bloat relay payloads.
async function readSpritesheetStat(spritesheetPath) {
  try {
    return await fs.promises.stat(spritesheetPath);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      throw petError("pet_spritesheet_missing", "The pet spritesheet file does not exist.");
    }
    throw petError("pet_spritesheet_unreadable", "Could not read the pet spritesheet file.");
  }
}

function assertSpritesheetByteLength(byteLength) {
  if (byteLength > MAX_SPRITESHEET_BYTES) {
    throw petError("pet_spritesheet_too_large", "Pet spritesheets must be 16 MB or smaller.");
  }
}

async function readImageDimensionsFromFile(file, mimeType, fileSize) {
  if (mimeType === "image/png") {
    return pngDimensions(await readFileSlice(file, 0, 24));
  }
  if (mimeType === "image/webp") {
    return readWebPDimensionsFromFile(file, fileSize);
  }
  return null;
}

async function readWebPDimensionsFromFile(file, fileSize) {
  const riffHeader = await readFileSlice(file, 0, 12);
  if (
    riffHeader.length < 12
    || riffHeader.toString("ascii", 0, 4) !== "RIFF"
    || riffHeader.toString("ascii", 8, 12) !== "WEBP"
  ) {
    return null;
  }

  let offset = 12;
  while (offset + 8 <= fileSize) {
    const chunkHeader = await readFileSlice(file, offset, 8);
    if (chunkHeader.length < 8) {
      return null;
    }

    const chunkType = chunkHeader.toString("ascii", 0, 4);
    const chunkSize = chunkHeader.readUInt32LE(4);
    const payloadOffset = offset + 8;
    if (payloadOffset + chunkSize > fileSize) {
      return null;
    }

    const dimensionsPayloadLength = webpDimensionsPayloadLength(chunkType);
    if (dimensionsPayloadLength > 0) {
      const payload = await readFileSlice(file, payloadOffset, Math.min(chunkSize, dimensionsPayloadLength));
      const chunkBuffer = Buffer.concat([chunkHeader, payload]);
      const dimensions = webpChunkDimensions(chunkBuffer, chunkType, 8, chunkSize);
      if (dimensions) {
        return dimensions;
      }
    }

    offset = payloadOffset + chunkSize + (chunkSize % 2);
  }

  return null;
}

function webpDimensionsPayloadLength(chunkType) {
  if (chunkType === "VP8X") {
    return 10;
  }
  if (chunkType === "VP8L") {
    return 5;
  }
  if (chunkType === "VP8 ") {
    return 10;
  }
  return 0;
}

async function readFileSlice(file, offset, length) {
  const buffer = Buffer.alloc(length);
  const { bytesRead } = await file.read(buffer, 0, length, offset);
  return buffer.subarray(0, bytesRead);
}

function imageDimensions(data, mimeType) {
  if (mimeType === "image/png") {
    return pngDimensions(data);
  }
  if (mimeType === "image/webp") {
    return webpDimensions(data);
  }
  return null;
}

function pngDimensions(data) {
  if (data.length < 24 || data.readUInt32BE(0) !== 0x89504e47 || data.readUInt32BE(4) !== 0x0d0a1a0a) {
    return null;
  }
  return {
    width: data.readUInt32BE(16),
    height: data.readUInt32BE(20),
  };
}

function webpDimensions(data) {
  if (
    data.length < 30
    || data.toString("ascii", 0, 4) !== "RIFF"
    || data.toString("ascii", 8, 12) !== "WEBP"
  ) {
    return null;
  }

  let offset = 12;
  while (offset + 8 <= data.length) {
    const chunkType = data.toString("ascii", offset, offset + 4);
    const chunkSize = data.readUInt32LE(offset + 4);
    const payloadOffset = offset + 8;
    if (payloadOffset + chunkSize > data.length) {
      return null;
    }

    const dimensions = webpChunkDimensions(data, chunkType, payloadOffset, chunkSize);
    if (dimensions) {
      return dimensions;
    }

    offset = payloadOffset + chunkSize + (chunkSize % 2);
  }

  return null;
}

function webpChunkDimensions(data, chunkType, payloadOffset, chunkSize) {
  if (chunkType === "VP8X" && chunkSize >= 10) {
    return {
      width: readUInt24LE(data, payloadOffset + 4) + 1,
      height: readUInt24LE(data, payloadOffset + 7) + 1,
    };
  }

  if (chunkType === "VP8L" && chunkSize >= 5 && data[payloadOffset] === 0x2f) {
    const bits = data.readUInt32LE(payloadOffset + 1);
    return {
      width: (bits & 0x3fff) + 1,
      height: ((bits >> 14) & 0x3fff) + 1,
    };
  }

  if (chunkType === "VP8 " && chunkSize >= 10) {
    const startCodeOffset = payloadOffset + 3;
    if (
      data[startCodeOffset] !== 0x9d
      || data[startCodeOffset + 1] !== 0x01
      || data[startCodeOffset + 2] !== 0x2a
    ) {
      return null;
    }

    return {
      width: data.readUInt16LE(payloadOffset + 6) & 0x3fff,
      height: data.readUInt16LE(payloadOffset + 8) & 0x3fff,
    };
  }

  return null;
}

function readUInt24LE(data, offset) {
  return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
}

// Keeps ~/.codex/pets entries authoritative when legacy ~/.codex/avatars has the same folder.
function mergeCustomAvatars(avatars) {
  const byID = new Map();
  for (const avatar of avatars) {
    const existing = byID.get(avatar.id);
    if (!existing || avatar.kind === "pet") {
      byID.set(avatar.id, avatar);
    }
  }
  return Array.from(byID.values()).sort((left, right) => left.displayName.localeCompare(right.displayName));
}

function firstNonEmptyString(candidates) {
  for (const candidate of candidates) {
    if (typeof candidate !== "string") {
      continue;
    }
    const trimmed = candidate.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return null;
}

function displayFromSlug(slug) {
  return slug
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((word) => word.slice(0, 1).toUpperCase() + word.slice(1))
    .join(" ") || slug;
}

function petError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handlePetMethod,
  handlePetRequest,
  imageDimensions,
};
