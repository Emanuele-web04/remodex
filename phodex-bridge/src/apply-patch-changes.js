// FILE: apply-patch-changes.js
// Purpose: Converts Codex apply_patch transcript payloads into fileChange-compatible records.
// Layer: Bridge util
// Exports: parseApplyPatchChanges, buildApplyPatchFileChangeItem
// Depends on: path

const path = require("path");

function buildApplyPatchFileChangeItem({
  callId = "",
  patch = "",
  status = "completed",
  idFallback = "apply-patch-file-change",
  cwd = "",
} = {}) {
  const changes = parseApplyPatchChanges(patch, { cwd });
  if (changes.length === 0) {
    return null;
  }

  return {
    id: readString(callId) || idFallback,
    type: "fileChange",
    status: readString(status) || "completed",
    changes,
  };
}

// Parses the custom apply_patch DSL saved in desktop rollouts into the same
// change-array shape that iOS already decodes from app-server fileChange items.
function parseApplyPatchChanges(patchText, { cwd = "" } = {}) {
  const lines = String(patchText || "").split(/\r?\n/);
  const changes = [];
  let current = null;

  function startChange(kind, rawPath) {
    flushCurrentChange();
    const filePath = normalizePatchPath(rawPath, cwd);
    if (!filePath) {
      current = null;
      return;
    }

    current = {
      path: filePath,
      originalPath: filePath,
      kind,
      additions: 0,
      deletions: 0,
      bodyLines: [],
    };
  }

  function flushCurrentChange() {
    if (!current || !current.path) {
      current = null;
      return;
    }

    changes.push({
      path: current.path,
      kind: current.kind,
      additions: current.additions,
      deletions: current.deletions,
      diff: buildUnifiedDiffForApplyPatchChange(current),
    });
    current = null;
  }

  for (const line of lines) {
    if (line.startsWith("*** Add File: ")) {
      startChange("add", line.slice("*** Add File: ".length));
      continue;
    }

    if (line.startsWith("*** Update File: ")) {
      startChange("update", line.slice("*** Update File: ".length));
      continue;
    }

    if (line.startsWith("*** Delete File: ")) {
      startChange("delete", line.slice("*** Delete File: ".length));
      flushCurrentChange();
      continue;
    }

    if (line.startsWith("*** Move to: ")) {
      if (current) {
        current.path = normalizePatchPath(line.slice("*** Move to: ".length), cwd) || current.path;
        current.kind = "rename";
      }
      continue;
    }

    if (line === "*** End Patch") {
      flushCurrentChange();
      break;
    }

    if (line.startsWith("***")) {
      continue;
    }

    if (!current) {
      continue;
    }

    current.bodyLines.push(line);
    if (line.startsWith("+") && !line.startsWith("+++")) {
      current.additions += 1;
    } else if (line.startsWith("-") && !line.startsWith("---")) {
      current.deletions += 1;
    }
  }

  flushCurrentChange();
  return changes.filter((change) => (
    change.additions > 0
    || change.deletions > 0
    || change.kind === "rename"
    || change.kind === "delete"
  ));
}

function buildUnifiedDiffForApplyPatchChange(change) {
  const oldPath = change.originalPath || change.path;
  const newPath = change.path || oldPath;
  const diffLines = [`diff --git ${gitPatchPath("a", oldPath)} ${gitPatchPath("b", newPath)}`];

  if (change.kind === "add") {
    diffLines.push("new file mode 100644", "--- /dev/null", `+++ ${gitPatchPath("b", newPath)}`);
  } else if (change.kind === "delete") {
    diffLines.push("deleted file mode 100644", `--- ${gitPatchPath("a", oldPath)}`, "+++ /dev/null");
  } else if (change.kind === "rename") {
    diffLines.push(`rename from ${oldPath}`, `rename to ${newPath}`);
    if (change.bodyLines.length > 0) {
      diffLines.push(`--- ${gitPatchPath("a", oldPath)}`, `+++ ${gitPatchPath("b", newPath)}`);
    }
  } else {
    diffLines.push(`--- ${gitPatchPath("a", oldPath)}`, `+++ ${gitPatchPath("b", newPath)}`);
  }

  const bodyLines = change.bodyLines || [];
  if (bodyLines.length > 0) {
    if (!bodyLines.some((line) => line.startsWith("@@"))) {
      diffLines.push("@@");
    }
    diffLines.push(...bodyLines);
  }

  return diffLines.join("\n").trim();
}

function gitPatchPath(prefix, filePath) {
  const trimmed = readString(filePath).replace(/^\/+/, "");
  return `${prefix}/${trimmed || filePath || "unknown"}`;
}

function normalizePatchPath(rawPath, cwd) {
  const filePath = readString(rawPath);
  if (!filePath) {
    return "";
  }

  const root = readString(cwd);
  if (!root || !path.isAbsolute(filePath)) {
    return filePath;
  }

  const relativePath = path.relative(root, filePath);
  if (!relativePath || relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
    return filePath;
  }

  return relativePath;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  buildApplyPatchFileChangeItem,
  parseApplyPatchChanges,
};
