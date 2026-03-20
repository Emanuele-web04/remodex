// FILE: commands-handler.js
// Purpose: Serves local slash-command definitions from the user's CODEX_HOME commands folder.
// Layer: Bridge handler
// Exports: handleCommandsRequest
// Depends on: fs, os, path

const fs = require("fs");
const os = require("os");
const path = require("path");

function handleCommandsRequest(rawMessage, sendResponse) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (method !== "commands/list") {
    return false;
  }

  const id = parsed.id;
  try {
    const commands = loadSlashCommands();
    sendResponse(JSON.stringify({ id, result: { commands } }));
  } catch (err) {
    const errorCode = err.errorCode || "commands_list_error";
    const message = err.userMessage || err.message || "Unable to load commands.";
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
  }

  return true;
}

function loadSlashCommands() {
  const commands = [];
  const promptCommands = loadPromptCommands();
  commands.push(...promptCommands);

  const jsonCommands = loadCommandsFromJsonFolder();
  commands.push(...jsonCommands);

  return dedupeCommands(commands);
}

function resolveCommandsRoot() {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  return path.join(codexHome, "commands");
}

function resolvePromptsRoot() {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  return path.join(codexHome, "prompts");
}

function loadCommandsFromJsonFolder() {
  const commandsRoot = resolveCommandsRoot();
  if (!fs.existsSync(commandsRoot)) {
    return [];
  }

  const entries = fs.readdirSync(commandsRoot, { withFileTypes: true });
  const commands = [];

  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) {
      continue;
    }

    const filePath = path.join(commandsRoot, entry.name);
    const parsed = readCommandsFile(filePath);
    if (!parsed.length) {
      continue;
    }

    for (const item of parsed) {
      const normalized = normalizeCommand(item);
      if (normalized) {
        commands.push(normalized);
      }
    }
  }

  return commands;
}

function loadPromptCommands() {
  const promptsRoot = resolvePromptsRoot();
  if (!fs.existsSync(promptsRoot)) {
    return [];
  }

  const entries = fs.readdirSync(promptsRoot, { withFileTypes: true });
  const commands = [];

  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".md")) {
      continue;
    }

    const filePath = path.join(promptsRoot, entry.name);
    const promptCommand = parsePromptFile(filePath);
    if (promptCommand) {
      commands.push(promptCommand);
    }
  }

  return commands;
}

function readCommandsFile(filePath) {
  let raw = "";
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch {
    return [];
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }

  if (Array.isArray(parsed)) {
    return parsed;
  }

  if (parsed && Array.isArray(parsed.commands)) {
    return parsed.commands;
  }

  return [];
}

function normalizeCommand(command) {
  if (!command || typeof command !== "object") {
    return null;
  }

  const token = readString(command.token || command.command);
  const title = readString(command.title || command.name);
  if (!token || !title) {
    return null;
  }

  const normalizedToken = token.startsWith("/") ? token : `/${token}`;
  const subtitle = readString(command.subtitle || command.description);
  const symbolName = readString(command.symbolName || command.symbol);
  const content = readString(command.content || command.prompt);
  const argumentHint = readString(command.argumentHint || command["argument-hint"]);

  return {
    token: normalizedToken,
    title,
    subtitle: subtitle || null,
    symbolName: symbolName || null,
    content: content || null,
    argumentHint: argumentHint || null,
  };
}

function parsePromptFile(filePath) {
  let raw = "";
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }

  const parsed = parseFrontmatter(raw);
  const frontmatter = parsed.fields;
  const description = readString(frontmatter.description);
  const argumentHint = readString(frontmatter["argument-hint"]);
  const baseName = path.basename(filePath, path.extname(filePath));
  const token = commandTokenFromPromptName(baseName);
  const title = commandTitleFromPromptName(baseName);

  if (!token || !title) {
    return null;
  }

  return {
    token,
    title,
    subtitle: description || null,
    symbolName: null,
    content: parsed.body || null,
    argumentHint: argumentHint || null,
  };
}

function parseFrontmatter(raw) {
  const lines = raw.split(/\r?\n/);
  if (!lines.length || lines[0].trim() !== "---") {
    return { fields: {}, body: raw.trim() };
  }

  const fields = {};
  let endIndex = -1;
  for (let i = 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim() === "---") {
      endIndex = i;
      break;
    }

    const match = line.match(/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/);
    if (!match) {
      continue;
    }

    const key = match[1];
    const value = match[2].trim();
    fields[key] = value.replace(/^"(.*)"$/, "$1");
  }

  const bodyLines = endIndex >= 0 ? lines.slice(endIndex + 1) : [];
  const body = bodyLines.join("\n").trim();
  return { fields, body };
}

function commandTokenFromPromptName(baseName) {
  const trimmed = readString(baseName);
  if (!trimmed) {
    return null;
  }

  if (trimmed.includes(":")) {
    return `/${trimmed}`;
  }

  if (trimmed.startsWith("opsx-")) {
    return `/${trimmed.replace("opsx-", "opsx:")}`;
  }

  return `/${trimmed}`;
}

function commandTitleFromPromptName(baseName) {
  const trimmed = readString(baseName);
  if (!trimmed) {
    return null;
  }

  let titleBase = trimmed;
  if (titleBase.startsWith("opsx-")) {
    titleBase = titleBase.slice("opsx-".length);
  } else if (titleBase.includes(":")) {
    titleBase = titleBase.split(":").pop() || titleBase;
  }

  const parts = titleBase.split(/[-_]/).filter(Boolean);
  if (!parts.length) {
    return null;
  }

  return parts
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function dedupeCommands(commands) {
  const seen = new Set();
  const deduped = [];

  for (const command of commands) {
    const key = `${command.token}`.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    deduped.push(command);
  }

  return deduped;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

module.exports = {
  handleCommandsRequest,
};
