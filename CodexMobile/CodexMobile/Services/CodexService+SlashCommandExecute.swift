// FILE: CodexService+SlashCommandExecute.swift
// Purpose: Executes OpenCode bridge slash commands via command/execute RPC.
// Layer: Service
// Exports: BridgeSlashCommandExecuteResult, CodexService slash execute helpers
// Depends on: Foundation, CodexService, RPCMessage

import Foundation

struct BridgeSlashCommandExecuteResult: Equatable, Sendable {
    let ok: Bool
    let sessionId: String?
    let errorCode: String?
    let deduped: Bool

    init(ok: Bool, sessionId: String? = nil, errorCode: String? = nil, deduped: Bool = false) {
        self.ok = ok
        self.sessionId = sessionId
        self.errorCode = errorCode
        self.deduped = deduped
    }
}

extension CodexService {
    /// Runs `command/execute` for a zero-argument OpenCode slash token (PR5a tap-to-send).
    func executeBridgeSlashCommand(
        threadId: String,
        command: String,
        arguments: String = "",
        directory: String?,
        clientCommandId: UUID
    ) async throws -> BridgeSlashCommandExecuteResult {
        try await executeBridgeSlashCommand(
            threadId: threadId,
            command: command,
            arguments: arguments,
            directory: directory,
            clientCommandId: clientCommandId,
            argumentFields: nil,
            template: nil,
            hints: nil
        )
    }

    /// Runs `command/execute` with structured argument fields (PR5b).
    func executeBridgeSlashCommand(
        threadId: String,
        command: String,
        arguments: String = "",
        directory: String?,
        clientCommandId: UUID,
        argumentFields: [BridgeSlashCommandArgumentField]?,
        template: String?,
        hints: [String]?
    ) async throws -> BridgeSlashCommandExecuteResult {
        var paramsObject: RPCObject = [
            "threadId": .string(threadId),
            "command": .string(command),
            "arguments": .string(arguments),
            "clientCommandId": .string(clientCommandId.uuidString),
        ]
        if let normalizedDirectory = Self.normalizedSlashCommandDirectory(directory) {
            paramsObject["directory"] = .string(normalizedDirectory)
        }
        if let template, !template.isEmpty {
            paramsObject["template"] = .string(template)
        }
        if let hints, !hints.isEmpty {
            paramsObject["hints"] = .array(hints.map { .string($0) })
        }
        if let argumentFields, !argumentFields.isEmpty {
            paramsObject["argumentFields"] = .array(
                argumentFields.map { field in
                    .object([
                        "key": .string(field.key),
                        "value": .string(field.value),
                    ])
                }
            )
        }

        do {
            let response = try await sendRequest(method: "command/execute", params: .object(paramsObject))
            return decodeBridgeSlashCommandExecuteResult(from: response.result) ?? BridgeSlashCommandExecuteResult(ok: false)
        } catch let serviceError as CodexServiceError {
            if case .rpcError(let rpcError) = serviceError {
                let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
                return BridgeSlashCommandExecuteResult(ok: false, errorCode: errorCode)
            }
            throw serviceError
        }
    }

    func decodeBridgeSlashCommandExecuteResult(from result: JSONValue?) -> BridgeSlashCommandExecuteResult? {
        guard let resultObject = result?.objectValue else {
            return nil
        }
        let ok = resultObject["ok"]?.boolValue ?? false
        let sessionId = resultObject["sessionId"]?.stringValue
        let errorCode = resultObject["errorCode"]?.stringValue
        let deduped = resultObject["deduped"]?.boolValue ?? false
        return BridgeSlashCommandExecuteResult(
            ok: ok,
            sessionId: sessionId,
            errorCode: errorCode,
            deduped: deduped
        )
    }

    static func bridgeSlashCommandExecuteErrorCode(from error: Error) -> String? {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return nil
        }
        return rpcError.data?.objectValue?["errorCode"]?.stringValue
    }
}