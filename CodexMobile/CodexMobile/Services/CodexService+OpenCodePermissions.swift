// FILE: CodexService+OpenCodePermissions.swift
// Purpose: OpenCode permission queue, reply RPC, and fail-safe when permissions UI is disabled.
// Layer: Service
// Exports: CodexService OpenCode permission helpers
// Depends on: OpenCodePermissionRequest

import Foundation

extension CodexService {
    static let maxPendingOpenCodePermissions = 20
    static let openCodePermissionsUIEnabledDefaultsKey = "remodex.opencode.permissions.ui.enabled"

    var isOpenCodePermissionsUIEnabled: Bool {
        if let override = openCodePermissionsUIEnabledOverride {
            return override
        }
        if let env = ProcessInfo.processInfo.environment["REMODEX_OPENCODE_PERMISSIONS_UI"] {
            return env != "0" && env.lowercased() != "false"
        }
        return defaults.object(forKey: Self.openCodePermissionsUIEnabledDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.openCodePermissionsUIEnabledDefaultsKey)
    }

    func pendingOpenCodePermission(for threadId: String? = nil) -> OpenCodePermissionRequest? {
        if let threadId {
            let normalized = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
            return pendingOpenCodePermissions.first(where: { $0.threadId == normalized })
        }
        return pendingOpenCodePermissions.first
    }

    func enqueuePendingOpenCodePermission(_ request: OpenCodePermissionRequest) {
        if let existingIndex = pendingOpenCodePermissions.firstIndex(where: { $0.permissionId == request.permissionId }) {
            pendingOpenCodePermissions[existingIndex] = request
            return
        }

        pendingOpenCodePermissions.append(request)
        if pendingOpenCodePermissions.count > Self.maxPendingOpenCodePermissions {
            let evicted = pendingOpenCodePermissions.removeFirst()
            appendSystemMessage(
                threadId: evicted.threadId,
                text: "Permission queue full — oldest permission request was dropped."
            )
        }
    }

    func removePendingOpenCodePermission(permissionId: String) -> OpenCodePermissionRequest? {
        guard let index = pendingOpenCodePermissions.firstIndex(where: { $0.permissionId == permissionId }) else {
            return nil
        }
        return pendingOpenCodePermissions.remove(at: index)
    }

    func clearPendingOpenCodePermissions() {
        pendingOpenCodePermissions.removeAll()
        sessionGrantedOpenCodeTools.removeAll()
    }

    func handleOpenCodePermissionRequest(paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }

        let permissionId = firstStringValue(
            in: paramsObject,
            keys: ["permissionId", "permission_id", "requestId", "request_id"]
        ) ?? ""
        let threadId = resolveThreadID(from: paramsObject, turnIdHint: extractTurnID(from: paramsObject)) ?? ""
        let turnId = extractTurnID(from: paramsObject)
        let sessionId = firstStringValue(in: paramsObject, keys: ["sessionId", "session_id"])
        let tool = firstStringValue(in: paramsObject, keys: ["tool", "toolName", "tool_name"]) ?? "tool"
        let cwd = firstStringValue(in: paramsObject, keys: ["cwd", "directory", "working_directory"])

        let argsSummary = firstStringValue(in: paramsObject, keys: ["argsSummary", "args_summary"])
        var argsObject: [String: JSONValue]?
        if argsSummary == nil, let rawArgs = paramsObject["args"]?.objectValue {
            argsObject = rawArgs
        }

        guard let request = OpenCodePermissionRequest.build(
            permissionId: permissionId,
            threadId: threadId,
            turnId: turnId,
            sessionId: sessionId,
            tool: tool,
            args: argsObject,
            argsSummary: argsSummary,
            cwd: cwd
        ) else {
            return
        }

        if !isOpenCodePermissionsUIEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                appendSystemMessage(
                    threadId: request.threadId,
                    text: "Permission required — update Remodex to respond."
                )
                enqueuePendingOpenCodePermission(request)
                _ = try? await replyToOpenCodePermission(request, allow: false, scope: .once)
            }
            return
        }

        if let sessionId = request.sessionId,
           sessionGrantedOpenCodeTools.contains(Self.sessionGrantKey(sessionId: sessionId, tool: request.tool)) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = try? await replyToOpenCodePermission(
                    request,
                    allow: true,
                    scope: .session,
                    bypassPendingQueueCheck: true
                )
            }
            return
        }

        enqueuePendingOpenCodePermission(request)
    }

    enum OpenCodePermissionReplyScope: String, Sendable {
        case once
        case session
    }

    func replyToOpenCodePermission(
        _ request: OpenCodePermissionRequest,
        allow: Bool,
        scope: OpenCodePermissionReplyScope,
        bypassPendingQueueCheck: Bool = false
    ) async throws {
        let isQueued = pendingOpenCodePermissions.contains(where: { $0.permissionId == request.permissionId })
        guard isQueued || (allow && bypassPendingQueueCheck) else {
            return
        }

        var params: [String: JSONValue] = [
            "permissionId": .string(request.permissionId),
            "threadId": .string(request.threadId),
            "allow": .bool(allow),
            "scope": .string(scope.rawValue),
        ]
        if let sessionId = request.sessionId {
            params["sessionId"] = .string(sessionId)
        }

        _ = try await sendRequest(method: "permission/reply", params: .object(params))

        if allow, scope == .session, let sessionId = request.sessionId {
            sessionGrantedOpenCodeTools.insert(Self.sessionGrantKey(sessionId: sessionId, tool: request.tool))
        }

        _ = removePendingOpenCodePermission(permissionId: request.permissionId)
    }

    static func sessionGrantKey(sessionId: String, tool: String) -> String {
        "\(sessionId)::\(tool)"
    }
}