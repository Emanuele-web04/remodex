// FILE: CodexService+IncomingSupport.swift
// Purpose: Shared parsing helpers and lightweight models used by inbound event handling.
// Layer: Service support
// Exports: Incoming decode helpers for CodexService inbound routing
// Depends on: Foundation

import Foundation

enum CommandRunPhase: String {
    case running
    case completed
    case failed
    case stopped
}

struct CommandRunViewState {
    let itemId: String?
    let phase: CommandRunPhase
    let shortCommand: String
    let fullCommand: String
    let cwd: String?
    let exitCode: Int?
    let durationMs: Int?
}

func normalizedIncomingMethodName(_ method: String) -> String {
    method.trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeThreadStatusType(_ rawStatusType: String) -> String {
    rawStatusType
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")
}

func threadTerminalState(from normalizedStatusType: String) -> CodexTurnTerminalState? {
    if normalizedStatusType == "stopped" {
        return .stopped
    }
    if normalizedStatusType.contains("error") {
        return .failed
    }
    if normalizedStatusType == "idle"
        || normalizedStatusType == "notloaded"
        || normalizedStatusType == "completed"
        || normalizedStatusType == "done"
        || normalizedStatusType == "finished" {
        return .completed
    }
    return nil
}

func firstNonEmptyString(_ values: [String?]) -> String? {
    for value in values {
        guard let value else { continue }
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
    }
    return nil
}

func firstStringValue(in object: IncomingParamsObject?, keys: [String]) -> String? {
    guard let object else { return nil }
    for key in keys {
        if let value = trimmedNonEmptyString(object[key]?.stringValue) {
            return value
        }
    }
    return nil
}

func firstIntValue(in object: IncomingParamsObject?, keys: [String]) -> Int? {
    guard let object else { return nil }
    for key in keys {
        if let value = jsonIntValue(object[key]) {
            return value
        }
    }
    return nil
}

// Keeps generic tool rows compact and human-readable across live and history paths.
func normalizedToolActivityDescriptor(_ rawDescriptor: String?) -> String? {
    guard let rawDescriptor = trimmedNonEmptyString(rawDescriptor) else {
        return nil
    }

    let normalized = rawDescriptor
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        return nil
    }

    var uniqueTokens: [String] = []
    for token in normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
        if uniqueTokens.last?.caseInsensitiveCompare(token) == .orderedSame {
            continue
        }
        uniqueTokens.append(token)
    }

    let joined = uniqueTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
}

func normalizedToolActivityStatus(_ rawStatus: String?, isCompleted: Bool) -> String {
    let normalized = rawStatus?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")

    switch normalized {
    case "failed", "error":
        return "Failed"
    case "stopped", "cancelled", "canceled", "interrupted":
        return "Stopped"
    case "completed", "complete", "done", "finished", "success", "succeeded":
        return "Completed"
    case "running", "inprogress", "working":
        return "Running"
    default:
        return isCompleted ? "Completed" : "Running"
    }
}

func toolActivitySummaryLine(
    descriptor: String?,
    rawStatus: String?,
    isCompleted: Bool,
    fallback: String = "tool"
) -> String {
    let statusLabel = normalizedToolActivityStatus(rawStatus, isCompleted: isCompleted)
    let descriptorLabel = normalizedToolActivityDescriptor(descriptor) ?? fallback
    return "\(statusLabel) \(descriptorLabel)"
}

func extractContextWindowUsage(from object: IncomingParamsObject?) -> ContextWindowUsage? {
    guard let object else { return nil }

    let root = JSONValue.object(object)
    let tokensUsed = firstInt(forAnyKey: [
        "tokensUsed",
        "tokens_used",
        "totalTokens",
        "total_tokens",
        "usedTokens",
        "used_tokens",
        "inputTokens",
        "input_tokens",
    ], in: root)

    let explicitLimit = firstInt(forAnyKey: [
        "tokenLimit",
        "token_limit",
        "maxTokens",
        "max_tokens",
        "contextWindow",
        "context_window",
        "contextSize",
        "context_size",
        "maxContextTokens",
        "max_context_tokens",
        "inputTokenLimit",
        "input_token_limit",
        "maxInputTokens",
        "max_input_tokens",
    ], in: root)

    let tokensRemaining = firstInt(forAnyKey: [
        "tokensRemaining",
        "tokens_remaining",
        "remainingTokens",
        "remaining_tokens",
        "remainingInputTokens",
        "remaining_input_tokens",
    ], in: root)

    let resolvedTokensUsed = max(0, tokensUsed ?? 0)
    let resolvedTokenLimit = explicitLimit ?? {
        guard let tokensRemaining else { return nil }
        return resolvedTokensUsed + max(0, tokensRemaining)
    }()

    guard let resolvedTokenLimit, resolvedTokenLimit > 0 else {
        return nil
    }

    return ContextWindowUsage(
        tokensUsed: min(resolvedTokensUsed, resolvedTokenLimit),
        tokenLimit: resolvedTokenLimit
    )
}

// Decodes persisted/live `token_count` payloads that wrap totals under `info`.
func extractContextWindowUsageFromTokenCountPayload(_ payload: IncomingParamsObject?) -> ContextWindowUsage? {
    guard let payload else { return nil }

    let infoObject = payload["info"]?.objectValue ?? payload
    let infoRoot = JSONValue.object(infoObject)
    let lastUsageRoot = firstValue(forAnyKey: [
        "last_token_usage",
        "lastTokenUsage",
    ], in: infoRoot)
    let totalUsageRoot = firstValue(forAnyKey: [
        "total_token_usage",
        "totalTokenUsage",
        "last_token_usage",
        "lastTokenUsage",
    ], in: infoRoot) ?? infoRoot
    let preferredUsageRoot = lastUsageRoot ?? totalUsageRoot

    let explicitTotal = firstInt(forAnyKey: [
        "total_tokens",
        "totalTokens",
    ], in: preferredUsageRoot)
    let inputTokens = firstInt(forAnyKey: [
        "input_tokens",
        "inputTokens",
    ], in: preferredUsageRoot) ?? 0
    let outputTokens = firstInt(forAnyKey: [
        "output_tokens",
        "outputTokens",
    ], in: preferredUsageRoot) ?? 0
    let reasoningTokens = firstInt(forAnyKey: [
        "reasoning_output_tokens",
        "reasoningOutputTokens",
    ], in: preferredUsageRoot) ?? 0

    let tokenLimit = firstInt(forAnyKey: [
        "model_context_window",
        "modelContextWindow",
        "context_window",
        "contextWindow",
        "tokenLimit",
        "token_limit",
    ], in: infoRoot)

    guard let tokenLimit, tokenLimit > 0 else {
        return nil
    }

    let resolvedTokensUsed = explicitTotal ?? (inputTokens + outputTokens + reasoningTokens)

    return ContextWindowUsage(
        tokensUsed: min(resolvedTokensUsed, tokenLimit),
        tokenLimit: tokenLimit
    )
}

func hasAnyValue(in object: IncomingParamsObject?, keys: [String]) -> Bool {
    guard let object else { return false }
    return keys.contains(where: { object[$0] != nil })
}

func looksLikePatchText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.contains("diff --git ") { return true }
    if trimmed.contains("\n@@ ") || trimmed.hasPrefix("@@ ") { return true }
    if trimmed.contains("\n+++ ") && trimmed.contains("\n--- ") { return true }
    if trimmed.contains("\nPath: ") && trimmed.contains("\nKind: ") { return true }
    return false
}

func firstValue(forAnyKey keys: [String], in root: JSONValue, maxDepth: Int = 8) -> JSONValue? {
    for key in keys {
        if let value = firstValue(forKey: key, in: root, maxDepth: maxDepth) {
            return value
        }
    }
    return nil
}

func firstValue(forKey key: String, in root: JSONValue, maxDepth: Int = 8) -> JSONValue? {
    guard maxDepth >= 0 else { return nil }

    switch root {
    case .object(let object):
        if let value = object[key], !isEmptyJSONValue(value) {
            return value
        }
        for value in object.values {
            if let match = firstValue(forKey: key, in: value, maxDepth: maxDepth - 1) {
                return match
            }
        }
    case .array(let array):
        for value in array {
            if let match = firstValue(forKey: key, in: value, maxDepth: maxDepth - 1) {
                return match
            }
        }
    default:
        break
    }
    return nil
}

func firstString(forKey key: String, in root: JSONValue, maxDepth: Int = 8) -> String? {
    guard let value = firstValue(forKey: key, in: root, maxDepth: maxDepth) else {
        return nil
    }
    if let text = value.stringValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return flattenNestedText(from: value)
}

func flattenNestedText(from root: JSONValue, maxDepth: Int = 8) -> String? {
    guard maxDepth >= 0 else { return nil }
    switch root {
    case .string(let value):
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case .array(let values):
        var parts: [String] = []
        for value in values {
            if let chunk = flattenNestedText(from: value, maxDepth: maxDepth - 1) {
                parts.append(chunk)
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    case .object(let object):
        let preferredKeys = ["text", "message", "summary", "output_text", "outputText", "content", "output"]
        for key in preferredKeys {
            if let value = object[key],
               let text = flattenNestedText(from: value, maxDepth: maxDepth - 1) {
                return text
            }
        }
        for value in object.values {
            if let text = flattenNestedText(from: value, maxDepth: maxDepth - 1) {
                return text
            }
        }
        return nil
    default:
        return nil
    }
}

func commandExecutionOutputChunk(
    paramsObject: IncomingParamsObject,
    eventObject: IncomingParamsObject?
) -> String? {
    let paramsCandidates: [String?] = [
        paramsObject["delta"]?.stringValue,
        paramsObject["textDelta"]?.stringValue,
        paramsObject["text"]?.stringValue,
        paramsObject["output"]?.stringValue,
    ]
    if let paramsChunk = firstNonEmptyString(paramsCandidates) {
        return paramsChunk
    }

    let eventCandidates: [String?] = [
        eventObject?["delta"]?.stringValue,
        eventObject?["text"]?.stringValue,
    ]
    return firstNonEmptyString(eventCandidates)
}

func decodeCommandRunViewState(
    payloadObject: IncomingParamsObject,
    paramsObject: IncomingParamsObject?,
    eventType: String?
) -> CommandRunViewState {
    let status = firstNonEmptyString(
        commandExecutionStatusCandidates(payloadObject: payloadObject, paramsObject: paramsObject)
    )
    let phase = commandRunPhase(from: status, eventType: eventType)

    let rawCommand = extractCommandExecutionCommand(from: payloadObject) ?? "command"
    let shortCommand = shortCommandPreview(from: rawCommand)
    let cwd = firstNonEmptyString(
        commandExecutionWorkingDirectoryCandidates(payloadObject: payloadObject, paramsObject: paramsObject)
    )
    let itemId = commandExecutionItemID(payloadObject: payloadObject, paramsObject: paramsObject)

    let exitCode = commandExecutionExitCode(from: payloadObject)
    let durationMs = commandExecutionDurationMs(from: payloadObject)

    return CommandRunViewState(
        itemId: itemId,
        phase: phase,
        shortCommand: shortCommand,
        fullCommand: rawCommand,
        cwd: cwd,
        exitCode: exitCode,
        durationMs: durationMs
    )
}

func extractCommandExecutionCommand(from itemObject: IncomingParamsObject) -> String? {
    if let commandArray = extractLegacyCommandArray(itemObject["command"]) {
        return commandArray
    }

    let candidates = ["command", "cmd", "raw_command", "rawCommand", "input", "invocation"]
    for key in candidates {
        if let value = firstString(forKey: key, in: .object(itemObject)) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }
    return nil
}

func shortCommandPreview(from rawCommand: String, maxLength: Int = 92) -> String {
    let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "command" }

    let compact = trimmed.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    let unwrapped = unwrapShellCommandIfPresent(compact)
    let normalized = unwrapped.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )

    let components = normalized
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
    guard !components.isEmpty else {
        return "command"
    }

    var preview = components.joined(separator: " ")
    if preview.count > maxLength {
        let cutoff = preview.index(preview.startIndex, offsetBy: maxLength - 1)
        preview = String(preview[..<cutoff]) + "..."
    }
    return preview
}

func unwrapShellCommandIfPresent(_ command: String) -> String {
    let tokens = command
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
    guard !tokens.isEmpty else { return command }

    let shellNames = ["bash", "zsh", "sh", "fish"]
    var shellIndex = 0

    if tokens.count >= 2 {
        let first = tokens[0].lowercased()
        let second = tokens[1].lowercased()
        if (first == "env" || first.hasSuffix("/env")),
           shellNames.contains(where: { second == $0 || second.hasSuffix("/\($0)") }) {
            shellIndex = 1
        }
    }

    let shell = tokens[shellIndex].lowercased()
    guard shellNames.contains(where: { shell == $0 || shell.hasSuffix("/\($0)") }) else {
        return command
    }

    var index = shellIndex + 1
    while index < tokens.count {
        let token = tokens[index]
        if token == "-c" || token == "-lc" || token == "-cl" || token == "-ic" || token == "-ci" {
            index += 1
            guard index < tokens.count else { return command }
            return stripWrappingQuotes(from: tokens[index...].joined(separator: " "))
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        return stripWrappingQuotes(from: tokens[index...].joined(separator: " "))
    }

    return command
}

private func trimmedNonEmptyString(_ candidate: String?) -> String? {
    guard let candidate else { return nil }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func jsonIntValue(_ value: JSONValue?) -> Int? {
    guard let value else { return nil }

    if let directInt = value.intValue {
        return directInt
    }

    if let directDouble = value.doubleValue {
        return Int(directDouble)
    }

    if let directString = value.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       let parsed = Int(directString) {
        return parsed
    }

    return nil
}

private func firstInt(forAnyKey keys: [String], in root: JSONValue, maxDepth: Int = 8) -> Int? {
    for key in keys {
        if let value = firstValue(forKey: key, in: root, maxDepth: maxDepth),
           let parsed = jsonIntValue(value) {
            return parsed
        }
    }
    return nil
}

private func isEmptyJSONValue(_ value: JSONValue) -> Bool {
    switch value {
    case .null:
        return true
    case .string(let text):
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .array(let values):
        return values.isEmpty
    case .object(let object):
        return object.isEmpty
    default:
        return false
    }
}

private func commandExecutionStatusCandidates(
    payloadObject: IncomingParamsObject,
    paramsObject: IncomingParamsObject?
) -> [String?] {
    [
        payloadObject["status"]?.stringValue,
        payloadObject["result"]?.objectValue?["status"]?.stringValue,
        payloadObject["output"]?.objectValue?["status"]?.stringValue,
        paramsObject?["status"]?.stringValue,
        paramsObject?["event"]?.objectValue?["status"]?.stringValue,
    ]
}

private func commandExecutionWorkingDirectoryCandidates(
    payloadObject: IncomingParamsObject,
    paramsObject: IncomingParamsObject?
) -> [String?] {
    [
        payloadObject["cwd"]?.stringValue,
        payloadObject["working_directory"]?.stringValue,
        paramsObject?["cwd"]?.stringValue,
    ]
}

private func commandExecutionItemID(
    payloadObject: IncomingParamsObject,
    paramsObject: IncomingParamsObject?
) -> String? {
    let payloadCandidates: [String?] = [
        payloadObject["id"]?.stringValue,
        payloadObject["call_id"]?.stringValue,
        payloadObject["callId"]?.stringValue,
    ]
    if let payloadID = firstNonEmptyString(payloadCandidates) {
        return payloadID
    }

    let paramsCandidates: [String?] = [
        paramsObject?["itemId"]?.stringValue,
        paramsObject?["item_id"]?.stringValue,
    ]
    return firstNonEmptyString(paramsCandidates)
}

private func commandExecutionExitCode(from payloadObject: IncomingParamsObject) -> Int? {
    let directCandidates: [Int?] = [
        payloadObject["exitCode"]?.intValue,
        payloadObject["exit_code"]?.intValue,
    ]
    if let direct = firstNonNilInt(directCandidates) {
        return direct
    }

    let resultObject = payloadObject["result"]?.objectValue
    let nestedCandidates: [Int?] = [
        resultObject?["exitCode"]?.intValue,
        resultObject?["exit_code"]?.intValue,
    ]
    return firstNonNilInt(nestedCandidates)
}

private func commandExecutionDurationMs(from payloadObject: IncomingParamsObject) -> Int? {
    let directCandidates: [Int?] = [
        payloadObject["durationMs"]?.intValue,
        payloadObject["duration_ms"]?.intValue,
    ]
    if let direct = firstNonNilInt(directCandidates) {
        return direct
    }

    let resultObject = payloadObject["result"]?.objectValue
    let nestedCandidates: [Int?] = [
        resultObject?["durationMs"]?.intValue,
    ]
    return firstNonNilInt(nestedCandidates)
}

private func firstNonNilInt(_ values: [Int?]) -> Int? {
    values.compactMap { $0 }.first
}

private func commandRunPhase(from rawStatus: String?, eventType: String?) -> CommandRunPhase {
    let normalizedStatus = rawStatus?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    let normalizedEventType = eventType?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""

    if normalizedStatus.contains("fail") || normalizedStatus.contains("error") {
        return .failed
    }
    if normalizedStatus.contains("cancel") || normalizedStatus.contains("abort") || normalizedStatus.contains("interrupt") {
        return .stopped
    }
    if normalizedStatus.contains("complete") || normalizedStatus.contains("success") || normalizedStatus.contains("done") {
        return .completed
    }

    if normalizedEventType == "exec_command_end" {
        return .completed
    }
    return .running
}

private func extractLegacyCommandArray(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    if let array = value.arrayValue {
        let parts = array.compactMap { item -> String? in
            let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }
    return value.stringValue
}

private func stripWrappingQuotes(from input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return trimmed }

    if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
        return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
}
