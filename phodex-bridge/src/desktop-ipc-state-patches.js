// FILE: desktop-ipc-state-patches.js
// Purpose: Immer-style JSON diffing and patch replay for Desktop conversationState broadcasts.
// Layer: CLI helper
// Exports: buildConversationStatePatches, applyPatchesToBaselineState, patch size defaults
// Depends on: ./desktop-ipc-shared

const { cloneJSON, isPlainJSONObject } = require("./desktop-ipc-shared");

const DEFAULT_MAX_PATCH_COUNT = 2_000;
const DEFAULT_MAX_PATCH_BYTES = 512 * 1024;

function buildConversationStatePatches(previousState, currentState, {
  maxPatchCount = DEFAULT_MAX_PATCH_COUNT,
  maxPatchBytes = DEFAULT_MAX_PATCH_BYTES,
} = {}) {
  if (!previousState || typeof previousState !== "object" || !currentState || typeof currentState !== "object") {
    return null;
  }
  const patches = [];
  const ok = collectJSONPatches(previousState, currentState, [], patches, maxPatchCount);
  if (!ok) {
    return null;
  }
  if (patches.length === 0) {
    return patches;
  }
  const patchBytes = Buffer.byteLength(JSON.stringify(patches), "utf8");
  if (patchBytes > maxPatchBytes) {
    return null;
  }
  return patches;
}

function collectJSONPatches(previousValue, currentValue, pathParts, patches, maxPatchCount) {
  if (jsonValuesEqual(previousValue, currentValue)) {
    return true;
  }
  if (patches.length > maxPatchCount) {
    return false;
  }

  if (Array.isArray(previousValue) || Array.isArray(currentValue)) {
    if (!Array.isArray(previousValue) || !Array.isArray(currentValue)) {
      return pushPatch(patches, maxPatchCount, {
        op: "replace",
        path: pathParts,
        value: cloneJSON(currentValue),
      });
    }
    return collectArrayPatches(previousValue, currentValue, pathParts, patches, maxPatchCount);
  }

  if (isPlainJSONObject(previousValue) || isPlainJSONObject(currentValue)) {
    if (!isPlainJSONObject(previousValue) || !isPlainJSONObject(currentValue)) {
      return pushPatch(patches, maxPatchCount, {
        op: "replace",
        path: pathParts,
        value: cloneJSON(currentValue),
      });
    }
    return collectObjectPatches(previousValue, currentValue, pathParts, patches, maxPatchCount);
  }

  return pushPatch(patches, maxPatchCount, {
    op: "replace",
    path: pathParts,
    value: cloneJSON(currentValue),
  });
}

function collectArrayPatches(previousArray, currentArray, pathParts, patches, maxPatchCount) {
  const sharedLength = Math.min(previousArray.length, currentArray.length);
  for (let index = 0; index < sharedLength; index += 1) {
    if (!collectJSONPatches(previousArray[index], currentArray[index], [...pathParts, index], patches, maxPatchCount)) {
      return false;
    }
  }
  for (let index = previousArray.length - 1; index >= currentArray.length; index -= 1) {
    if (!pushPatch(patches, maxPatchCount, {
      op: "remove",
      path: [...pathParts, index],
    })) {
      return false;
    }
  }
  for (let index = sharedLength; index < currentArray.length; index += 1) {
    if (!pushPatch(patches, maxPatchCount, {
      op: "add",
      path: [...pathParts, index],
      value: cloneJSON(currentArray[index]),
    })) {
      return false;
    }
  }
  return true;
}

function collectObjectPatches(previousObject, currentObject, pathParts, patches, maxPatchCount) {
  for (const key of Object.keys(previousObject)) {
    if (Object.prototype.hasOwnProperty.call(currentObject, key)) {
      continue;
    }
    if (!pushPatch(patches, maxPatchCount, {
      op: "remove",
      path: [...pathParts, key],
    })) {
      return false;
    }
  }

  for (const key of Object.keys(currentObject)) {
    if (!Object.prototype.hasOwnProperty.call(previousObject, key)) {
      if (!pushPatch(patches, maxPatchCount, {
        op: "add",
        path: [...pathParts, key],
        value: cloneJSON(currentObject[key]),
      })) {
        return false;
      }
      continue;
    }
    if (!collectJSONPatches(previousObject[key], currentObject[key], [...pathParts, key], patches, maxPatchCount)) {
      return false;
    }
  }
  return true;
}

function pushPatch(patches, maxPatchCount, patch) {
  if (patch.path.length === 0) {
    return false;
  }
  patches.push(patch);
  return patches.length <= maxPatchCount;
}

function applyPatchesToBaselineState(baselineState, patches) {
  for (const patch of patches) {
    if (!applyPatchToBaselineNode(baselineState, patch)) {
      return false;
    }
  }
  return true;
}

function applyPatchToBaselineNode(target, patch) {
  const pathParts = Array.isArray(patch?.path) ? patch.path : [];
  const op = patch?.op;
  if (pathParts.length === 0) {
    return false;
  }

  let parent = target;
  for (let index = 0; index < pathParts.length - 1; index += 1) {
    parent = parent?.[pathParts[index]];
    if (parent == null || typeof parent !== "object") {
      return false;
    }
  }

  const key = pathParts[pathParts.length - 1];
  const isArrayIndex = Array.isArray(parent) && Number.isInteger(key);
  if (op === "remove") {
    if (isArrayIndex) {
      if (key < 0 || key >= parent.length) {
        return false;
      }
      parent.splice(key, 1);
      return true;
    }
    if (parent && typeof parent === "object") {
      delete parent[key];
      return true;
    }
    return false;
  }
  if (op === "add" && isArrayIndex) {
    if (key < 0 || key > parent.length) {
      return false;
    }
    parent.splice(key, 0, patch.value);
    return true;
  }
  if (op === "add" || op === "replace") {
    if (isArrayIndex) {
      if (key < 0 || key >= parent.length) {
        return false;
      }
      parent[key] = patch.value;
      return true;
    }
    if (parent && typeof parent === "object") {
      parent[key] = patch.value;
      return true;
    }
  }
  return false;
}

function jsonValuesEqual(left, right) {
  if (left === right) {
    return true;
  }
  if (left == null || right == null) {
    return left === right;
  }
  if (typeof left !== "object" || typeof right !== "object") {
    return false;
  }
  return false;
}

module.exports = {
  DEFAULT_MAX_PATCH_BYTES,
  DEFAULT_MAX_PATCH_COUNT,
  applyPatchesToBaselineState,
  buildConversationStatePatches,
};
