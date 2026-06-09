// FILE: attachment-store.js
// Purpose: Durable local attachment store for OpenCode image prompt parts (WP-06 threat model).
// Layer: Bridge utility
// Exports: createAttachmentStore, isAttachmentsEnabled
// Depends on: fs, os, path, crypto

const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomUUID } = require("crypto");

const DEFAULT_STORE_DIR = path.join(os.homedir(), ".remodex", "attachments");
const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const MAX_IMAGES_PER_TURN = 4;

function isAttachmentsEnabled(env = process.env) {
  const raw = readString(env?.REMODEX_OPENCODE_ATTACHMENTS);
  return raw !== "0" && raw?.toLowerCase() !== "false";
}

function createAttachmentStore({
  rootDir = DEFAULT_STORE_DIR,
  ttlMs = DEFAULT_TTL_MS,
  now = () => Date.now(),
} = {}) {
  ensureStoreDir(rootDir);

  function ensureStoreDir(targetDir) {
    fs.mkdirSync(targetDir, { recursive: true, mode: 0o700 });
    try {
      fs.chmodSync(targetDir, 0o700);
    } catch {
      // Best effort on platforms that restrict chmod.
    }
  }

  function resolveSafePath(filename) {
    const base = path.basename(readString(filename));
    if (!base || base.includes("..")) {
      throw attachmentError("invalid_filename", "Attachment filename is invalid.");
    }
    const candidate = path.resolve(rootDir, base);
    const relative = path.relative(rootDir, candidate);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw attachmentError("path_not_allowed", "Attachment path is outside the store.");
    }
    return candidate;
  }

  function sniffMime(buffer) {
    if (!buffer || buffer.length < 4) {
      return "application/octet-stream";
    }
    if (buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47) {
      return "image/png";
    }
    if (buffer[0] === 0xff && buffer[1] === 0xd8) {
      return "image/jpeg";
    }
    if (buffer[0] === 0x47 && buffer[1] === 0x49 && buffer[2] === 0x46) {
      return "image/gif";
    }
    if (buffer.length >= 12
      && buffer.toString("ascii", 0, 4) === "RIFF"
      && buffer.toString("ascii", 8, 12) === "WEBP") {
      return "image/webp";
    }
    return "application/octet-stream";
  }

  function storeImageBuffer(buffer, { filename = "", mime = "" } = {}) {
    if (!Buffer.isBuffer(buffer)) {
      throw attachmentError("invalid_buffer", "Attachment payload must be a buffer.");
    }
    if (buffer.length > MAX_IMAGE_BYTES) {
      throw attachmentError("image_too_large", `Images must be <= ${MAX_IMAGE_BYTES} bytes.`);
    }

    const sniffedMime = sniffMime(buffer);
    const declaredMime = readString(mime);
    if (
      declaredMime
      && declaredMime.startsWith("image/")
      && sniffedMime.startsWith("image/")
      && declaredMime !== sniffedMime
    ) {
      throw attachmentError("mime_mismatch", "Declared MIME does not match file content.");
    }
    const detectedMime = sniffedMime.startsWith("image/")
      ? sniffedMime
      : (declaredMime || sniffedMime);
    if (!detectedMime.startsWith("image/")) {
      throw attachmentError("invalid_mime", "Only image attachments are supported.");
    }

    const storedName = `${randomUUID()}${extensionForMime(detectedMime)}`;
    const storedPath = resolveSafePath(storedName);
    fs.writeFileSync(storedPath, buffer, { mode: 0o600 });
    return {
      path: storedPath,
      filename: readString(filename) || storedName,
      mime: detectedMime,
      bytes: buffer.length,
      storedAt: now(),
    };
  }

  function storeFromDataUrl(dataUrl, { filename = "" } = {}) {
    const raw = readString(dataUrl);
    if (!raw || !raw.startsWith("data:")) {
      throw attachmentError("invalid_data_url", "Attachment data URL is invalid.");
    }
    const commaIndex = raw.indexOf(",");
    if (commaIndex < 0) {
      throw attachmentError("invalid_data_url", "Attachment data URL is malformed.");
    }
    const header = raw.slice(5, commaIndex);
    const payload = raw.slice(commaIndex + 1);
    const mime = header.split(";")[0] || "application/octet-stream";
    const buffer = header.includes(";base64")
      ? Buffer.from(payload, "base64")
      : Buffer.from(decodeURIComponent(payload), "utf8");
    return storeImageBuffer(buffer, { filename, mime });
  }

  function resolveExistingPath(candidatePath) {
    const raw = readString(candidatePath);
    if (!raw) {
      return null;
    }
    if (raw.startsWith("file://")) {
      const decoded = decodeURI(raw.slice("file://".length));
      const resolved = path.resolve(decoded);
      const relative = path.relative(rootDir, resolved);
      if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
        throw attachmentError("path_not_allowed", "Attachment path is outside the store.");
      }
      return resolved;
    }
    return resolveSafePath(raw);
  }

  function deleteAttachment(candidatePath) {
    const resolved = resolveExistingPath(candidatePath);
    if (!resolved || !fs.existsSync(resolved)) {
      return false;
    }
    const stat = fs.lstatSync(resolved);
    if (!stat.isFile()) {
      throw attachmentError("not_file", "Attachment path is not a file.");
    }
    fs.unlinkSync(resolved);
    return true;
  }

  function cleanupExpired() {
    const cutoff = now() - ttlMs;
    let removed = 0;
    for (const entry of fs.readdirSync(rootDir)) {
      const fullPath = resolveSafePath(entry);
      try {
        const stat = fs.statSync(fullPath);
        if (stat.mtimeMs < cutoff) {
          fs.unlinkSync(fullPath);
          removed += 1;
        }
      } catch {
        // Ignore races while cleaning.
      }
    }
    return removed;
  }

  return {
    rootDir,
    maxImagesPerTurn: MAX_IMAGES_PER_TURN,
    maxImageBytes: MAX_IMAGE_BYTES,
    storeImageBuffer,
    storeFromDataUrl,
    resolveExistingPath,
    deleteAttachment,
    cleanupExpired,
  };
}

function extensionForMime(mime) {
  switch (mime) {
    case "image/png":
      return ".png";
    case "image/jpeg":
      return ".jpg";
    case "image/gif":
      return ".gif";
    case "image/webp":
      return ".webp";
    default:
      return ".bin";
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function attachmentError(errorCode, message) {
  const error = new Error(message);
  error.errorCode = errorCode;
  return error;
}

module.exports = {
  createAttachmentStore,
  isAttachmentsEnabled,
  DEFAULT_STORE_DIR,
  MAX_IMAGE_BYTES,
  MAX_IMAGES_PER_TURN,
};