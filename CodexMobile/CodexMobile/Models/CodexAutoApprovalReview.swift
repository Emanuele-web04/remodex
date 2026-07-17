// FILE: CodexAutoApprovalReview.swift
// Purpose: Models Codex automatic approval-review lifecycle state and retry payloads.
// Layer: Model
// Exports: CodexAutoApprovalReview, CodexAutoApprovalReviewStatus
// Depends on: Foundation, JSONValue

import Foundation

nonisolated enum CodexAutoApprovalReviewStatus: Codable, Hashable, Sendable {
    case inProgress
    case approved
    case denied
    case timedOut
    case aborted
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "inProgress": self = .inProgress
        case "approved": self = .approved
        case "denied": self = .denied
        case "timedOut": self = .timedOut
        case "aborted": self = .aborted
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .inProgress: return "inProgress"
        case .approved: return "approved"
        case .denied: return "denied"
        case .timedOut: return "timedOut"
        case .aborted: return "aborted"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var isTerminal: Bool {
        switch self {
        case .inProgress:
            return false
        default:
            return true
        }
    }

    var title: String {
        switch self {
        case .inProgress:
            return "Reviewing approval"
        case .approved:
            return "Approved automatically"
        case .denied:
            return "Approval denied"
        case .timedOut:
            return "Approval review timed out"
        case .aborted:
            return "Approval review stopped"
        case .unknown:
            return "Approval review updated"
        }
    }

    fileprivate var coreValue: String {
        switch self {
        case .inProgress:
            return "in_progress"
        case .approved:
            return "approved"
        case .denied:
            return "denied"
        case .timedOut:
            return "timed_out"
        case .aborted:
            return "aborted"
        case .unknown(let value):
            return value
        }
    }
}

nonisolated struct CodexAutoApprovalReview: Codable, Hashable, Sendable {
    // Single source for the retry-unavailable copy shown when the backing retry
    // token is missing, so service, persistence, and UI can never drift apart.
    static let liveSessionRetryUnavailableReason =
        "Retry approvals are available only during the live session."
    static let expiredRetryUnavailableReason =
        "This retry is no longer available. Wait for Codex to request the action again."

    let reviewId: String
    let targetItemId: String?
    let turnId: String
    let startedAtMs: Int
    var completedAtMs: Int?
    var status: CodexAutoApprovalReviewStatus
    let riskLevel: String?
    let userAuthorization: String?
    let rationale: String?
    let decisionSource: String?
    var action: JSONValue
    var retryApproved: Bool
    var retryUnavailableReason: String? = nil
    var persistedActionSummary: String? = nil

    var actionSummary: String {
        if let persistedActionSummary,
           !persistedActionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return persistedActionSummary
        }
        guard let object = action.objectValue,
              let type = object["type"]?.stringValue else {
            return "Requested action"
        }

        switch type {
        case "command":
            return object["command"]?.stringValue ?? "Run command"
        case "execve":
            let program = object["program"]?.stringValue ?? "Run command"
            let arguments = object["argv"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return arguments.isEmpty
                ? shellQuoted(program)
                : arguments.map(shellQuoted).joined(separator: " ")
        case "applyPatch":
            let files = object["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if files.isEmpty { return "Apply file changes" }
            return files.count == 1 ? "Edit \(files[0])" : "Edit \(files.count) files: \(files.joined(separator: ", "))"
        case "networkAccess":
            let host = object["host"]?.stringValue ?? object["target"]?.stringValue
            let port = object["port"]?.intValue.map(String.init)
            let target = [host, port].compactMap { $0 }.joined(separator: ":")
            return target.isEmpty ? "Access the network" : "Access \(target)"
        case "mcpToolCall":
            let server = object["server"]?.stringValue
            let tool = object["toolTitle"]?.stringValue ?? object["toolName"]?.stringValue
            return [server, tool].compactMap { $0 }.joined(separator: ".")
        case "requestPermissions":
            return object["reason"]?.stringValue ?? permissionSummary(object["permissions"])
        default:
            return "Requested action"
        }
    }

    private func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./-"))
        if value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func permissionSummary(_ value: JSONValue?) -> String {
        guard let permissions = value?.objectValue else {
            return "Request additional permissions"
        }
        var requested: [String] = []
        if permissions["network"] != nil, permissions["network"] != .null {
            requested.append("network")
        }
        if permissions["fileSystem"] != nil, permissions["fileSystem"] != .null {
            requested.append("file access")
        }
        return requested.isEmpty
            ? "Request additional permissions"
            : "Request \(requested.joined(separator: " and "))"
    }

    var coreDeniedEvent: JSONValue? {
        guard status == .denied,
              let coreAction = coreActionValue(action) else {
            return nil
        }

        var event: [String: JSONValue] = [
            "id": .string(reviewId),
            "turn_id": .string(turnId),
            "started_at_ms": .integer(startedAtMs),
            "status": .string(status.coreValue),
            "action": coreAction,
        ]
        if let completedAtMs {
            event["completed_at_ms"] = .integer(completedAtMs)
        }
        if let targetItemId {
            event["target_item_id"] = .string(targetItemId)
        }
        if let riskLevel {
            event["risk_level"] = .string(riskLevel)
        }
        if let userAuthorization {
            event["user_authorization"] = .string(userAuthorization)
        }
        if let rationale {
            event["rationale"] = .string(rationale)
        }
        if let decisionSource {
            event["decision_source"] = .string(coreIdentifier(decisionSource))
        }
        return .object(event)
    }

    private func coreActionValue(_ value: JSONValue) -> JSONValue? {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue else {
            return nil
        }

        switch type {
        case "command":
            guard let source = object["source"]?.stringValue,
                  let command = object["command"]?.stringValue,
                  let cwd = object["cwd"]?.stringValue else {
                return nil
            }
            return .object([
                "type": .string("command"),
                "source": .string(coreIdentifier(source)),
                "command": .string(command),
                "cwd": .string(cwd),
            ])
        case "execve":
            guard let source = object["source"]?.stringValue,
                  let program = object["program"]?.stringValue,
                  let argv = object["argv"]?.arrayValue,
                  argv.allSatisfy({ $0.stringValue != nil }),
                  let cwd = object["cwd"]?.stringValue else {
                return nil
            }
            return .object([
                "type": .string("execve"),
                "source": .string(coreIdentifier(source)),
                "program": .string(program),
                "argv": .array(argv),
                "cwd": .string(cwd),
            ])
        case "applyPatch":
            guard let cwd = object["cwd"]?.stringValue,
                  let files = object["files"]?.arrayValue,
                  files.allSatisfy({ $0.stringValue != nil }) else {
                return nil
            }
            return .object([
                "type": .string("apply_patch"),
                "cwd": .string(cwd),
                "files": .array(files),
            ])
        case "networkAccess":
            guard let target = object["target"]?.stringValue,
                  let host = object["host"]?.stringValue,
                  let protocolValue = object["protocol"]?.stringValue,
                  let port = object["port"]?.intValue else {
                return nil
            }
            return .object([
                "type": .string("network_access"),
                "target": .string(target),
                "host": .string(host),
                "protocol": .string(coreIdentifier(protocolValue)),
                "port": .integer(port),
            ])
        case "mcpToolCall":
            guard let server = object["server"]?.stringValue,
                  let toolName = object["toolName"]?.stringValue else {
                return nil
            }
            var result: [String: JSONValue] = [
                "type": .string("mcp_tool_call"),
                "server": .string(server),
                "tool_name": .string(toolName),
            ]
            copyOptionalString(from: object, key: "connectorId", to: &result, as: "connector_id")
            copyOptionalString(from: object, key: "connectorName", to: &result, as: "connector_name")
            copyOptionalString(from: object, key: "toolTitle", to: &result, as: "tool_title")
            return .object(result)
        case "requestPermissions":
            guard let permissions = corePermissionProfile(object["permissions"]) else {
                return nil
            }
            var result: [String: JSONValue] = [
                "type": .string("request_permissions"),
                "permissions": permissions,
            ]
            copyOptionalString(from: object, key: "reason", to: &result, as: "reason")
            return .object(result)
        default:
            return nil
        }
    }

    private func corePermissionProfile(_ value: JSONValue?) -> JSONValue? {
        guard let permissions = value?.objectValue else {
            return nil
        }
        var result: [String: JSONValue] = [:]
        if let network = permissions["network"] {
            result["network"] = network
        }
        if let fileSystem = permissions["fileSystem"] {
            guard let mappedFileSystem = coreFileSystemPermissions(fileSystem) else {
                return nil
            }
            result["file_system"] = mappedFileSystem
        }
        return .object(result)
    }

    private func coreFileSystemPermissions(_ value: JSONValue) -> JSONValue? {
        if value == .null {
            return .null
        }
        guard let fileSystem = value.objectValue else {
            return nil
        }

        let globDepth = fileSystem["globScanMaxDepth"]
        if let entries = fileSystem["entries"], entries != .null {
            guard entries.arrayValue != nil else { return nil }
            var canonical: [String: JSONValue] = ["entries": entries]
            if let globDepth, globDepth != .null {
                canonical["glob_scan_max_depth"] = globDepth
            }
            return .object(canonical)
        }

        if let globDepth, globDepth != .null {
            var entries: [JSONValue] = []
            for (key, access) in [("read", "read"), ("write", "write")] {
                guard let paths = fileSystem[key], paths != .null else { continue }
                guard let pathValues = paths.arrayValue,
                      pathValues.allSatisfy({ $0.stringValue != nil }) else {
                    return nil
                }
                entries.append(contentsOf: pathValues.map { path in
                    .object([
                        "path": .object(["type": .string("path"), "path": path]),
                        "access": .string(access),
                    ])
                })
            }
            return .object([
                "entries": .array(entries),
                "glob_scan_max_depth": globDepth,
            ])
        }

        var legacy: [String: JSONValue] = [:]
        for key in ["read", "write"] {
            if let paths = fileSystem[key], paths != .null {
                guard let pathValues = paths.arrayValue,
                      pathValues.allSatisfy({ $0.stringValue != nil }) else {
                    return nil
                }
                legacy[key] = paths
            }
        }
        return .object(legacy)
    }

    private func copyOptionalString(
        from source: [String: JSONValue],
        key: String,
        to destination: inout [String: JSONValue],
        as destinationKey: String
    ) {
        guard let value = source[key] else { return }
        if value == .null {
            destination[destinationKey] = .null
        } else if let string = value.stringValue {
            destination[destinationKey] = .string(string)
        }
    }

    private func coreIdentifier(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count + 4)

        for character in value {
            if character.isUppercase {
                if !result.isEmpty, result.last != "_" {
                    result.append("_")
                }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}
