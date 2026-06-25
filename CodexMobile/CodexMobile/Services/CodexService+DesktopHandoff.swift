// FILE: CodexService+DesktopHandoff.swift
// Purpose: Sends OpenCode desktop handoff RPCs over the active bridge connection.
// Layer: Service
// Exports: CodexService OpenCode desktop handoff
// Depends on: CodexService, OpenCodeDesktopHandoffModels

import Foundation

extension CodexService {
    func continueOnDesktopOpenCode(
        threadId: String,
        sessionId: String? = nil,
        directory: String? = nil
    ) async throws -> OpenCodeDesktopHandoffResult {
        guard let params = OpenCodeDesktopHandoffParams.normalized(
            threadId: threadId,
            sessionId: sessionId,
            directory: directory
        ) else {
            throw CodexServiceError.rpcError(
                RPCError(
                    code: -32602,
                    message: "This chat does not have a valid thread id yet.",
                    data: .object(["errorCode": .string("missing_thread_id")])
                )
            )
        }

        let response = try await sendRequest(
            method: "desktop/continueOpenCode",
            params: params.makeJSONValue()
        )

        guard let resultObject = response.result?.objectValue else {
            throw CodexServiceError.rpcError(
                RPCError(code: -32603, message: "The desktop app did not return a valid response.")
            )
        }

        let result = OpenCodeDesktopHandoffResult(from: resultObject)
        guard result.success else {
            throw CodexServiceError.rpcError(
                RPCError(code: -32603, message: "The desktop app did not return a valid response.")
            )
        }

        return result
    }
}