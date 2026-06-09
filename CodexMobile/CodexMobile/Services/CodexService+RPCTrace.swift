// FILE: CodexService+RPCTrace.swift
// Purpose: DEBUG-only turn/start and running-state correlation logs for iPad repro bundles.
// Layer: Service
// Exports: CodexService RPC trace helpers
// Depends on: os.log

import Foundation
import os

private enum RemodexRPCTrace {
    static let subsystem = "com.remodex.codex.rpc-trace"
    static let logger = Logger(subsystem: subsystem, category: "rpc")

    static var isEnabled: Bool = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment["REMODEX_IOS_RPC_TRACE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return env == "1"
        #else
        return false
        #endif
    }()
}

extension CodexService {
    var isRemodexRPCTraceEnabled: Bool {
        RemodexRPCTrace.isEnabled
    }

    func traceTurnStartRequest(
        threadId: String,
        rpcId: JSONValue?,
        params: RPCObject
    ) {
        guard RemodexRPCTrace.isEnabled else { return }
        let thread = thread(for: threadId)
        let visibleComposerModelId = visibleSelectedModelIDForComposer(threadId: threadId) ?? ""
        let runtimeProvider = runtimeModelProviderForTurn(threadId: threadId)
        let threadModel = thread?.model ?? ""
        let threadModelProvider = thread?.modelProvider ?? ""
        let paramsModelProvider = params["modelProvider"]?.stringValue ?? ""
        RemodexRPCTrace.logger.debug(
            """
            turn_start_request threadId=\(threadId, privacy: .public) \
            rpcId=\(Self.traceRPCId(rpcId), privacy: .public) \
            visibleComposerModelId=\(visibleComposerModelId, privacy: .public) \
            runtimeModelProviderForTurn=\(runtimeProvider, privacy: .public) \
            thread.model=\(threadModel, privacy: .public) \
            thread.modelProvider=\(threadModelProvider, privacy: .public) \
            params.modelProvider=\(paramsModelProvider, privacy: .public)
            """
        )
    }

    func traceTurnStartResult(
        threadId: String,
        rpcId: JSONValue?,
        error: Error?
    ) {
        guard RemodexRPCTrace.isEnabled else { return }
        // Hoisted (per review nit on dupe from Issue 4 symmetry fix): safe, no side effects,
        // always computed when trace enabled for result (used in failed/ok logs; snapshot after doesn't need).
        let runtimeProvider = runtimeModelProviderForTurn(threadId: threadId)
        let threadModelProvider = thread(for: threadId)?.modelProvider ?? ""
        if let error {
            let rpcCode: Int
            let errorCode: String
            let userMessage: String
            if case CodexServiceError.rpcError(let rpcError) = error {
                rpcCode = rpcError.code
                errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue ?? ""
                userMessage = userFacingTurnErrorMessageForFooter(from: error) ?? ""
            } else {
                rpcCode = -1
                errorCode = ""
                userMessage = userFacingTurnErrorMessageForFooter(from: error) ?? ""
            }
            RemodexRPCTrace.logger.debug(
                """
                turn_start_result_failed threadId=\(threadId, privacy: .public) \
                rpcId=\(Self.traceRPCId(rpcId), privacy: .public) \
                errorCode=\(errorCode, privacy: .public) \
                rpcCode=\(rpcCode, privacy: .public) \
                userMessage=\(userMessage, privacy: .public)
                """
            )
        } else {
            RemodexRPCTrace.logger.debug(
                "turn_start_result_ok threadId=\(threadId, privacy: .public) rpcId=\(Self.traceRPCId(rpcId), privacy: .public)"
            )
        }
        traceRunningSnapshot(threadId: threadId, label: "turn_start_result")
    }

    func traceAssistantDeltaDrop(threadId: String?, reason: String, turnId: String? = nil) {
        guard RemodexRPCTrace.isEnabled else { return }
        if let turnId, !turnId.isEmpty {
            RemodexRPCTrace.logger.debug(
                "assistant_delta_drop threadId=\(threadId ?? "", privacy: .public) turnId=\(turnId, privacy: .public) reason=\(reason, privacy: .public)"
            )
        } else {
            RemodexRPCTrace.logger.debug(
                "assistant_delta_drop threadId=\(threadId ?? "", privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        if let threadId {
            traceRunningSnapshot(threadId: threadId, label: "delta_drop")
        }
    }

    func traceRunningSnapshot(threadId: String, label: String) {
        guard RemodexRPCTrace.isEnabled else { return }
        let isSendInFlight = runningThreadIDs.contains(threadId)
        let protectedRunning = protectedRunningFallbackThreadIDs.contains(threadId)
        let activeTurn = activeTurnID(for: threadId) ?? ""
        let desktopMirrored = desktopMirroredRunningThreadIDs.contains(threadId)
        let lastIncomingMethod = lastIncomingNotificationMethodByThread[threadId] ?? ""
        RemodexRPCTrace.logger.debug(
            """
            running_snapshot label=\(label, privacy: .public) threadId=\(threadId, privacy: .public) \
            isSendInFlight=\(isSendInFlight, privacy: .public) \
            protectedRunningFallback=\(protectedRunning, privacy: .public) \
            activeTurnId=\(activeTurn, privacy: .public) \
            desktopMirroredRunning=\(desktopMirrored, privacy: .public) \
            lastIncomingMethod=\(lastIncomingMethod, privacy: .public)
            """
        )
    }

    private static func traceRPCId(_ value: JSONValue?) -> String {
        switch value {
        case .string(let string):
            return string
        case .integer(let number):
            return String(number)
        case .double(let number):
            return String(number)
        case .null, .none:
            return ""
        default:
            return ""
        }
    }
}