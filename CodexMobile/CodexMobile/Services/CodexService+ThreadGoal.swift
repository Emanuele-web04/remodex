// FILE: CodexService+ThreadGoal.swift
// Purpose: RPC surface for the Codex app-server persisted thread goal (`thread/goal/set|get|clear`).
// Layer: Service
// Exports: CodexService.setThreadGoal, CodexService.readThreadGoal, CodexService.clearThreadGoal, CodexThreadGoalError
// Depends on: CodexService+Transport, CodexThreadGoal

import Foundation

enum CodexThreadGoalError: LocalizedError, Equatable {
    case ephemeralThread
    case goalsUnsupported
    case invalidBudget
    case rpcFailure(String)

    var errorDescription: String? {
        switch self {
        case .ephemeralThread:
            return "Goals need a saved chat. This chat is temporary, so a goal cannot be attached to it."
        case .goalsUnsupported:
            return "Goals are not available on the connected Codex runtime. Update the Codex CLI on your Mac (npm install -g @openai/codex@latest) and enable the goals feature."
        case .invalidBudget:
            return "Token budget must be a positive whole number."
        case .rpcFailure(let message):
            return message
        }
    }
}

// The wire protocol distinguishes "omit = keep server value" from "null = remove
// budget", so the wrapper needs a tri-state instead of Int?.
enum CodexThreadGoalBudgetUpdate: Equatable, Sendable {
    case keep
    case clear
    case set(Int)
}

extension CodexService {
    // Creates or updates the thread goal. Omitted fields keep their server-side value:
    // pause = status .paused, resume = status .active, edit = objective only.
    @discardableResult
    func setThreadGoal(
        threadId: String,
        objective: String? = nil,
        status: CodexThreadGoalStatus? = nil,
        tokenBudget: CodexThreadGoalBudgetUpdate = .keep
    ) async throws -> CodexThreadGoal {
        var params: [String: JSONValue] = ["threadId": .string(threadId)]
        if let objective {
            params["objective"] = .string(objective)
        }
        if let status {
            params["status"] = .string(status.rawValue)
        }
        switch tokenBudget {
        case .keep:
            break
        case .clear:
            params["tokenBudget"] = .null
        case .set(let budget):
            params["tokenBudget"] = .integer(budget)
        }

        let response = try await sendGoalRequest(method: "thread/goal/set", params: .object(params))
        guard let goal = CodexThreadGoal(object: response.result?.objectValue?["goal"]?.objectValue) else {
            throw CodexThreadGoalError.rpcFailure("The Codex runtime returned an unexpected goal payload.")
        }

        // The `thread/goal/updated` notification confirms the same state, but applying
        // the response immediately keeps the chip/sheet in sync without a round trip.
        goalByThreadID[goal.threadId] = goal
        return goal
    }

    // Reads the persisted goal; nil means the thread has no goal.
    @discardableResult
    func readThreadGoal(
        threadId: String,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> CodexThreadGoal? {
        let response = try await sendGoalRequest(
            method: "thread/goal/get",
            params: .object(["threadId": .string(threadId)]),
            timeoutNanoseconds: timeoutNanoseconds
        )

        guard let goal = CodexThreadGoal(object: response.result?.objectValue?["goal"]?.objectValue) else {
            goalByThreadID.removeValue(forKey: threadId)
            return nil
        }

        goalByThreadID[goal.threadId] = goal
        return goal
    }

    // Refreshes the local goal mirror for one thread. Definitive "goals impossible"
    // answers drop a stale entry; transient transport failures keep it, so the chip
    // does not flicker away during reconnects.
    func refreshThreadGoalMirror(threadId: String) async {
        guard supportsThreadGoals, isConnected else { return }
        do {
            _ = try await readThreadGoal(threadId: threadId)
        } catch let error as CodexThreadGoalError {
            switch error {
            case .goalsUnsupported, .ephemeralThread:
                goalByThreadID.removeValue(forKey: threadId)
            case .invalidBudget, .rpcFailure:
                break
            }
        } catch {
            debugRuntimeLog("thread goal refresh failed for \(threadId): \(error.localizedDescription)")
        }
    }

    // Rehydrates sidebar goal badges after connect/relaunch, when live
    // `thread/goal/updated` events were missed. Bounded to recent live threads so
    // large sidebars do not stampede the app-server.
    func hydrateThreadGoalsSnapshot(limit: Int = 30) async {
        guard supportsThreadGoals, isConnected else { return }

        let candidateThreadIDs = threads.lazy
            .filter { $0.syncState == .live }
            .prefix(limit)
            .map(\.id)

        for threadId in candidateThreadIDs {
            guard supportsThreadGoals, isConnected else { return }
            do {
                _ = try await readThreadGoal(
                    threadId: threadId,
                    timeoutNanoseconds: 5_000_000_000
                )
            } catch let error as CodexThreadGoalError where error == .goalsUnsupported {
                // Old runtime: sendGoalRequest already lowered the flag; stop probing.
                return
            } catch let error as CodexThreadGoalError where error == .ephemeralThread {
                // One temporary thread must not prevent later persisted threads from hydrating.
                goalByThreadID.removeValue(forKey: threadId)
                continue
            } catch {
                // Transient failure: stop the pass quietly; the next connect retries.
                debugRuntimeLog("thread goal hydration stopped: \(error.localizedDescription)")
                return
            }
        }
    }

    // Removes the persisted goal; returns whether the server actually deleted one.
    @discardableResult
    func clearThreadGoal(threadId: String) async throws -> Bool {
        let response = try await sendGoalRequest(
            method: "thread/goal/clear",
            params: .object(["threadId": .string(threadId)])
        )

        goalByThreadID.removeValue(forKey: threadId)
        return response.result?.objectValue?["cleared"]?.boolValue ?? false
    }

    private func sendGoalRequest(
        method: String,
        params: JSONValue,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> RPCMessage {
        do {
            return try await sendRequest(
                method: method,
                params: params,
                timeoutNanoseconds: timeoutNanoseconds
            )
        } catch {
            let mappedError = mapThreadGoalError(error)
            if case CodexThreadGoalError.goalsUnsupported = mappedError {
                // Remember the runtime limitation so hydration/refresh stop probing.
                supportsThreadGoals = false
            }
            throw mappedError
        }
    }

    // Degrades server-side goal failures into actionable user-facing messages.
    private func mapThreadGoalError(_ error: Error) -> Error {
        guard case CodexServiceError.rpcError(let rpcError) = error else {
            return error
        }

        let message = rpcError.message.lowercased()
        if message.contains("ephemeral thread does not support goals")
            || message.contains("thread goals require a persisted thread") {
            return CodexThreadGoalError.ephemeralThread
        }
        if message.contains("goals feature is disabled")
            || rpcError.code == -32601 {
            return CodexThreadGoalError.goalsUnsupported
        }
        return error
    }
}
