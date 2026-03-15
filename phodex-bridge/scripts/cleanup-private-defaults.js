#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const outputPath = path.join(__dirname, "..", "src", "private-defaults.json");

try {
  fs.unlinkSync(outputPath);
} catch (error) {
  if (!error || error.code !== "ENOENT") {
    throw error;
  }
}
