const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

test("completed assistant image cards remain visible beside the final answer", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-timeline-images-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  const messages = path.join(mobile, "Views/Turn/Messages");
  // Compile the real Foundation-only parser declarations without the SwiftUI
  // views that share this source file. The projection itself is compiled whole.
  const source = fs.readFileSync(path.join(messages, "CommandExecutionViews.swift"), "utf8");
  const parser = path.join(directory, "ImageReferences.swift");
  fs.writeFileSync(parser, "import Foundation\n" + source.slice(
    source.indexOf("struct CommandOutputImageReference:"), source.indexOf("// MARK: - Card Body")
  ));
  const binary = path.join(directory, "timeline-images");
  execFileSync("xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(directory, "cache"),
    parser, path.join(mobile, "Models/String+PathDisplayName.swift"),
    ...["TurnMessageRegexCache", "ThinkingDisclosureParser", "CodeCommentDirectiveParser"]
      .map((name) => path.join(messages, `${name}.swift`)),
    path.join(mobile, "Views/Turn/Timeline/TurnTimelineRenderProjection.swift"),
    path.join(__dirname, "fixtures/timeline-images-harness.swift"), "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, { encoding: "utf8", timeout: 10000 });
  assert.match(output, /timeline image visibility checks passed/);
});
