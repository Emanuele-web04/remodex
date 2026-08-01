// FILE: codex-tool-wrapper.js
// Purpose: Safely projects Codex's JavaScript exec wrapper into the nested tool calls it contains.
// Layer: CLI helper
// Exports: expandExecWrapperToolCall, isOrchestrationWaitCall

const EXEC_WRAPPER_NAME = "exec";
const APPLY_PATCH_NAME = "apply_patch";

function expandExecWrapperToolCall(payload) {
  if (!isExecWrapperPayload(payload)) {
    return [payload];
  }

  const calls = extractNestedToolCalls(payload.input);
  if (calls.length === 0) {
    return [payload];
  }

  const outerCallId = firstNonEmptyString([
    payload.call_id,
    payload.callId,
    payload.id,
  ]);

  return calls.map((call, index) => {
    const callId = index === 0 || !outerCallId
      ? outerCallId
      : `${outerCallId}:nested:${index + 1}`;
    const isApplyPatch = normalizeString(call.name).toLowerCase() === APPLY_PATCH_NAME;
    const projected = {
      ...payload,
      type: isApplyPatch ? "custom_tool_call" : "function_call",
      name: call.name,
      tool_name: call.name,
      remodexWrappedExecCallId: outerCallId || undefined,
      remodexWrappedExecCallIndex: index,
      remodexWrappedExecCallCount: calls.length,
    };

    if (callId) {
      projected.id = callId;
      projected.call_id = callId;
      projected.callId = callId;
    }

    if (isApplyPatch) {
      projected.input = typeof call.argument === "string" ? call.argument : "";
      delete projected.arguments;
    } else {
      projected.arguments = JSON.stringify(
        call.argument && typeof call.argument === "object" ? call.argument : {}
      );
      delete projected.input;
    }

    return projected;
  });
}

function isOrchestrationWaitCall(payload) {
  if (normalizeString(payload?.name).toLowerCase() !== "wait") {
    return false;
  }

  const argumentsObject = parseJSON(payload?.arguments);
  return Boolean(
    argumentsObject
      && typeof argumentsObject === "object"
      && !Array.isArray(argumentsObject)
      && (argumentsObject.cell_id !== undefined || argumentsObject.cellId !== undefined)
  );
}

function isExecWrapperPayload(payload) {
  return normalizeString(payload?.name).toLowerCase() === EXEC_WRAPPER_NAME
    && typeof payload?.input === "string"
    && payload.input.includes("tools.");
}

function extractNestedToolCalls(source) {
  const bindings = collectLiteralBindings(source);
  const code = maskNonCode(source);
  const pattern = /\btools\.([A-Za-z_$][\w$]*)\s*\(/g;
  const calls = [];
  let match;

  while ((match = pattern.exec(code)) !== null) {
    const openParenthesis = code.indexOf("(", match.index);
    const parsed = parseLiteralAt(source, openParenthesis + 1, bindings);
    calls.push({
      name: match[1],
      argument: parsed.ok ? parsed.value : null,
    });
  }

  return calls;
}

function collectLiteralBindings(source) {
  const bindings = new Map();
  const code = maskNonCode(source);
  const pattern = /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/g;
  let match;

  while ((match = pattern.exec(code)) !== null) {
    const equalsIndex = code.indexOf("=", match.index);
    const parsed = parseLiteralAt(source, equalsIndex + 1, bindings);
    if (parsed.ok) {
      bindings.set(match[1], parsed.value);
    }
  }

  return bindings;
}

function parseLiteralAt(source, startIndex, bindings = new Map()) {
  const parser = new SafeLiteralParser(source, bindings);
  return parser.parse(startIndex);
}

class SafeLiteralParser {
  constructor(source, bindings) {
    this.source = source;
    this.bindings = bindings;
  }

  parse(startIndex) {
    const index = this.skipTrivia(startIndex);
    const parsed = this.parseValue(index);
    return parsed || { ok: false, value: null, end: index };
  }

  parseValue(startIndex) {
    const index = this.skipTrivia(startIndex);
    const character = this.source[index];

    if (character === "\"" || character === "'") {
      return this.parseQuotedString(index, character);
    }
    if (character === "`") {
      return this.parseTemplateString(index);
    }
    if (character === "{") {
      return this.parseObject(index);
    }
    if (character === "[") {
      return this.parseArray(index);
    }
    if (character === "-" || isDigit(character)) {
      return this.parseNumber(index);
    }
    if (isIdentifierStart(character)) {
      return this.parseIdentifierValue(index);
    }
    return null;
  }

  parseObject(startIndex) {
    const value = {};
    let index = this.skipTrivia(startIndex + 1);

    while (index < this.source.length && this.source[index] !== "}") {
      if (this.source.startsWith("...", index)) {
        index = this.skipUnknownExpression(index + 3, new Set([",", "}"]));
        index = this.consumeObjectDelimiter(index);
        continue;
      }

      const key = this.parsePropertyKey(index);
      if (!key) {
        return null;
      }
      index = this.skipTrivia(key.end);

      if (this.source[index] === ":") {
        const parsedValue = this.parseValue(index + 1);
        if (parsedValue) {
          value[key.value] = parsedValue.value;
          index = parsedValue.end;
        } else {
          index = this.skipUnknownExpression(index + 1, new Set([",", "}"]));
        }
      } else if (this.bindings.has(key.value)) {
        value[key.value] = this.bindings.get(key.value);
      }

      index = this.consumeObjectDelimiter(index);
    }

    if (this.source[index] !== "}") {
      return null;
    }
    return { ok: true, value, end: index + 1 };
  }

  consumeObjectDelimiter(startIndex) {
    let index = this.skipTrivia(startIndex);
    if (this.source[index] === ",") {
      index = this.skipTrivia(index + 1);
    }
    return index;
  }

  parsePropertyKey(startIndex) {
    const index = this.skipTrivia(startIndex);
    const character = this.source[index];
    if (character === "\"" || character === "'") {
      return this.parseQuotedString(index, character);
    }
    return this.parseIdentifier(index);
  }

  parseArray(startIndex) {
    const value = [];
    let index = this.skipTrivia(startIndex + 1);

    while (index < this.source.length && this.source[index] !== "]") {
      const parsedValue = this.parseValue(index);
      if (parsedValue) {
        value.push(parsedValue.value);
        index = parsedValue.end;
      } else {
        index = this.skipUnknownExpression(index, new Set([",", "]"]));
      }

      index = this.skipTrivia(index);
      if (this.source[index] === ",") {
        index = this.skipTrivia(index + 1);
      }
    }

    if (this.source[index] !== "]") {
      return null;
    }
    return { ok: true, value, end: index + 1 };
  }

  parseQuotedString(startIndex, quote) {
    let value = "";
    let index = startIndex + 1;

    while (index < this.source.length) {
      const character = this.source[index];
      if (character === quote) {
        return { ok: true, value, end: index + 1 };
      }
      if (character !== "\\") {
        value += character;
        index += 1;
        continue;
      }

      const escape = decodeEscape(this.source, index + 1);
      if (!escape) {
        return null;
      }
      value += escape.value;
      index = escape.end;
    }

    return null;
  }

  parseTemplateString(startIndex) {
    let value = "";
    let index = startIndex + 1;

    while (index < this.source.length) {
      const character = this.source[index];
      if (character === "`") {
        return { ok: true, value, end: index + 1 };
      }
      if (character === "$" && this.source[index + 1] === "{") {
        return null;
      }
      if (character !== "\\") {
        value += character;
        index += 1;
        continue;
      }

      const escape = decodeEscape(this.source, index + 1);
      if (!escape) {
        return null;
      }
      value += escape.value;
      index = escape.end;
    }

    return null;
  }

  parseNumber(startIndex) {
    const match = /^-?(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/
      .exec(this.source.slice(startIndex));
    if (!match) {
      return null;
    }
    const value = Number(match[0]);
    return Number.isFinite(value)
      ? { ok: true, value, end: startIndex + match[0].length }
      : null;
  }

  parseIdentifierValue(startIndex) {
    const identifier = this.parseIdentifier(startIndex);
    if (!identifier) {
      return null;
    }

    switch (identifier.value) {
    case "true":
      return { ok: true, value: true, end: identifier.end };
    case "false":
      return { ok: true, value: false, end: identifier.end };
    case "null":
      return { ok: true, value: null, end: identifier.end };
    case "undefined":
      return { ok: true, value: undefined, end: identifier.end };
    default:
      return this.bindings.has(identifier.value)
        ? { ok: true, value: this.bindings.get(identifier.value), end: identifier.end }
        : null;
    }
  }

  parseIdentifier(startIndex) {
    const match = /^[A-Za-z_$][\w$]*/.exec(this.source.slice(startIndex));
    return match
      ? { ok: true, value: match[0], end: startIndex + match[0].length }
      : null;
  }

  skipUnknownExpression(startIndex, delimiters) {
    const code = maskNonCode(this.source);
    const stack = [];
    let index = this.skipTrivia(startIndex);

    while (index < code.length) {
      const character = code[index];
      if (character === "(" || character === "[" || character === "{") {
        stack.push(character);
      } else if (character === ")" || character === "]" || character === "}") {
        if (stack.length === 0 && delimiters.has(character)) {
          return index;
        }
        stack.pop();
      } else if (stack.length === 0 && delimiters.has(character)) {
        return index;
      }
      index += 1;
    }

    return index;
  }

  skipTrivia(startIndex) {
    let index = startIndex;
    while (index < this.source.length) {
      if (/\s/.test(this.source[index])) {
        index += 1;
        continue;
      }
      if (this.source.startsWith("//", index)) {
        const newline = this.source.indexOf("\n", index + 2);
        index = newline === -1 ? this.source.length : newline + 1;
        continue;
      }
      if (this.source.startsWith("/*", index)) {
        const end = this.source.indexOf("*/", index + 2);
        index = end === -1 ? this.source.length : end + 2;
        continue;
      }
      break;
    }
    return index;
  }
}

function maskNonCode(source) {
  // Keep UTF-16 indexes aligned with String#indexOf/RegExp even when wrapper
  // strings contain emoji or other surrogate pairs.
  const characters = source.split("");
  let index = 0;

  while (index < source.length) {
    const character = source[index];
    if (character === "\"" || character === "'" || character === "`") {
      index = maskQuotedRange(source, characters, index, character);
      continue;
    }
    if (source.startsWith("//", index)) {
      const end = source.indexOf("\n", index + 2);
      index = maskRange(characters, index, end === -1 ? source.length : end);
      continue;
    }
    if (source.startsWith("/*", index)) {
      const end = source.indexOf("*/", index + 2);
      index = maskRange(characters, index, end === -1 ? source.length : end + 2);
      continue;
    }
    index += 1;
  }

  return characters.join("");
}

function maskQuotedRange(source, characters, startIndex, quote) {
  let index = startIndex;
  while (index < source.length) {
    const character = source[index];
    characters[index] = " ";
    index += 1;
    if (character === "\\" && index < source.length) {
      characters[index] = " ";
      index += 1;
      continue;
    }
    if (index > startIndex + 1 && character === quote) {
      break;
    }
  }
  return index;
}

function maskRange(characters, startIndex, endIndex) {
  for (let index = startIndex; index < endIndex; index += 1) {
    characters[index] = " ";
  }
  return endIndex;
}

function decodeEscape(source, escapeIndex) {
  const character = source[escapeIndex];
  const simple = {
    "0": "\0",
    b: "\b",
    f: "\f",
    n: "\n",
    r: "\r",
    t: "\t",
    v: "\v",
    "\\": "\\",
    "\"": "\"",
    "'": "'",
    "`": "`",
  };
  if (Object.prototype.hasOwnProperty.call(simple, character)) {
    return { value: simple[character], end: escapeIndex + 1 };
  }
  if (character === "\n") {
    return { value: "", end: escapeIndex + 1 };
  }
  if (character === "x") {
    return decodeHexEscape(source, escapeIndex + 1, 2);
  }
  if (character === "u") {
    if (source[escapeIndex + 1] === "{") {
      const endBrace = source.indexOf("}", escapeIndex + 2);
      if (endBrace === -1) {
        return null;
      }
      const codePoint = Number.parseInt(source.slice(escapeIndex + 2, endBrace), 16);
      return Number.isFinite(codePoint)
        ? { value: String.fromCodePoint(codePoint), end: endBrace + 1 }
        : null;
    }
    return decodeHexEscape(source, escapeIndex + 1, 4);
  }
  return { value: character || "", end: escapeIndex + 1 };
}

function decodeHexEscape(source, startIndex, length) {
  const text = source.slice(startIndex, startIndex + length);
  if (!new RegExp(`^[0-9a-fA-F]{${length}}$`).test(text)) {
    return null;
  }
  return {
    value: String.fromCodePoint(Number.parseInt(text, 16)),
    end: startIndex + length,
  };
}

function parseJSON(value) {
  if (value && typeof value === "object") {
    return value;
  }
  if (typeof value !== "string" || !value.trim()) {
    return null;
  }
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function firstNonEmptyString(values) {
  for (const value of values) {
    const normalized = normalizeString(value);
    if (normalized) {
      return normalized;
    }
  }
  return "";
}

function normalizeString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function isDigit(character) {
  return typeof character === "string" && /\d/.test(character);
}

function isIdentifierStart(character) {
  return typeof character === "string" && /[A-Za-z_$]/.test(character);
}

module.exports = {
  expandExecWrapperToolCall,
  isOrchestrationWaitCall,
};
