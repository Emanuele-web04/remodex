// FILE: OpenCodePermissionRequest.swift
// Purpose: Models OpenCode SDK permission prompts separately from Codex approval requests (D16).
// Layer: Model
// Exports: OpenCodePermissionRequest
// Depends on: Foundation

import Foundation

struct OpenCodePermissionRequest: Identifiable, Sendable, Equatable {
    var id: String { permissionId }

    let permissionId: String
    let threadId: String
    let turnId: String?
    let sessionId: String?
    let tool: String
    let argsSummary: String
    let cwd: String?
    let receivedAt: Date

    init(
        permissionId: String,
        threadId: String,
        turnId: String? = nil,
        sessionId: String? = nil,
        tool: String,
        argsSummary: String,
        cwd: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.permissionId = permissionId
        self.threadId = threadId
        self.turnId = turnId
        self.sessionId = sessionId
        self.tool = tool
        self.argsSummary = argsSummary
        self.cwd = cwd
        self.receivedAt = receivedAt
    }

    private static let sensitiveArgKeys: Set<String> = ["command", "script", "token", "secret", "password"]

    static func redactedArgsSummary(from raw: String, maxLength: Int = 500) -> String {
        let redacted = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard let equalsIndex = text.firstIndex(of: "=") else { return text }
                let key = text[..<equalsIndex]
                if key.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil
                    || sensitiveArgKeys.contains(key.lowercased()) {
                    return "\(key)=***"
                }
                return text
            }
            .joined(separator: "\n")

        guard redacted.count > maxLength else { return redacted }
        let truncated = String(redacted.prefix(maxLength))
        return "\(truncated)…(truncated)"
    }

    static func build(
        permissionId: String,
        threadId: String,
        turnId: String?,
        sessionId: String?,
        tool: String,
        args: [String: JSONValue]? = nil,
        argsSummary: String? = nil,
        cwd: String?
    ) -> OpenCodePermissionRequest? {
        let normalizedPermissionId = permissionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPermissionId.isEmpty, !normalizedThreadId.isEmpty, !normalizedTool.isEmpty else {
            return nil
        }

        let summary: String
        if let bridgeSummary = argsSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !bridgeSummary.isEmpty {
            summary = bridgeSummary
        } else if let args, !args.isEmpty {
            let pairs = args
                .sorted { $0.key < $1.key }
                .map { key, value in "\(key)=\(value.debugDescription)" }
            summary = redactedArgsSummary(from: pairs.joined(separator: "\n"))
        } else {
            summary = ""
        }

        return OpenCodePermissionRequest(
            permissionId: normalizedPermissionId,
            threadId: normalizedThreadId,
            turnId: turnId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sessionId: sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tool: normalizedTool,
            argsSummary: summary,
            cwd: cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}