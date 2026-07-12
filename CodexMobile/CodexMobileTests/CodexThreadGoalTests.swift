// FILE: CodexThreadGoalTests.swift
// Purpose: Locks in the thread/goal/set wire encoding (omit vs null vs value) and error mapping.
// Layer: Unit Test
// Exports: CodexThreadGoalTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadGoalTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testGoalCapsuleElapsedTimeAlwaysIncludesSeconds() {
        XCTAssertEqual(GoalStatusChip.formatElapsedSeconds(11_839), "3h 17m 19s")
        XCTAssertEqual(GoalStatusChip.formatElapsedSeconds(79), "1m 19s")
        XCTAssertEqual(GoalStatusChip.formatElapsedSeconds(9), "9s")
    }

    func testSetThreadGoalOmitsTokenBudgetWhenKeeping() async throws {
        let (service, captured) = makeCapturingService()

        _ = try await service.setThreadGoal(
            threadId: "thread-1",
            objective: "Ship goal mode",
            status: .active,
            tokenBudget: .keep
        )

        let params = try XCTUnwrap(captured().first?.objectValue)
        XCTAssertEqual(params["objective"]?.stringValue, "Ship goal mode")
        XCTAssertEqual(params["status"]?.stringValue, "active")
        XCTAssertNil(params["tokenBudget"], "`.keep` must omit tokenBudget so the server keeps its value")
    }

    func testSetThreadGoalSendsExplicitNullWhenClearingBudget() async throws {
        let (service, captured) = makeCapturingService()

        _ = try await service.setThreadGoal(threadId: "thread-1", tokenBudget: .clear)

        let params = try XCTUnwrap(captured().first?.objectValue)
        XCTAssertEqual(params["tokenBudget"], .null, "`.clear` must send explicit null to remove the budget")
    }

    func testSetThreadGoalSendsIntegerBudget() async throws {
        let (service, captured) = makeCapturingService()

        _ = try await service.setThreadGoal(threadId: "thread-1", tokenBudget: .set(200_000))

        let params = try XCTUnwrap(captured().first?.objectValue)
        XCTAssertEqual(params["tokenBudget"]?.intValue, 200_000)
    }

    func testSetThreadGoalOmitsStatusOnObjectiveOnlyEdit() async throws {
        let (service, captured) = makeCapturingService()

        _ = try await service.setThreadGoal(threadId: "thread-1", objective: "Refined objective")

        let params = try XCTUnwrap(captured().first?.objectValue)
        XCTAssertEqual(params["objective"]?.stringValue, "Refined objective")
        XCTAssertNil(params["status"], "objective edits must omit status so paused goals stay paused")
        XCTAssertNil(params["tokenBudget"])
    }

    func testSetThreadGoalUpdatesLocalMirrorFromResponse() async throws {
        let (service, _) = makeCapturingService()

        let goal = try await service.setThreadGoal(threadId: "thread-1", objective: "Ship goal mode")

        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(service.goalByThreadID["thread-1"]?.objective, "Ship goal mode")
    }

    func testEphemeralThreadErrorIsMappedToUserFacingMessage() async {
        let service = makeService()
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(
                RPCError(code: -32600, message: "ephemeral thread does not support goals: thread-1")
            )
        }

        do {
            _ = try await service.readThreadGoal(threadId: "thread-1")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CodexThreadGoalError, .ephemeralThread)
        }
    }

    func testMethodNotFoundIsMappedToGoalsUnsupported() async {
        let service = makeService()
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32601, message: "Method not found"))
        }

        do {
            _ = try await service.setThreadGoal(threadId: "thread-1", objective: "x")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CodexThreadGoalError, .goalsUnsupported)
        }
    }

    func testClearThreadGoalRemovesLocalMirror() async throws {
        let service = makeService()
        service.goalByThreadID["thread-1"] = makeGoal(threadId: "thread-1")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/goal/clear")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["cleared": .bool(true)]),
                includeJSONRPC: false
            )
        }

        let cleared = try await service.clearThreadGoal(threadId: "thread-1")

        XCTAssertTrue(cleared)
        XCTAssertNil(service.goalByThreadID["thread-1"])
    }

    // MARK: - Helpers

    private func makeCapturingService() -> (CodexService, () -> [JSONValue]) {
        let service = makeService()
        var capturedParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/goal/set")
            capturedParams.append(params ?? .null)
            let requestObjective = params?.objectValue?["objective"]?.stringValue ?? "existing objective"
            let requestStatus = params?.objectValue?["status"]?.stringValue ?? "active"
            let threadId = params?.objectValue?["threadId"]?.stringValue ?? "thread-1"
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "goal": .object([
                        "threadId": .string(threadId),
                        "objective": .string(requestObjective),
                        "status": .string(requestStatus),
                        "tokenBudget": .null,
                        "tokensUsed": .integer(0),
                        "timeUsedSeconds": .integer(0),
                        "createdAt": .integer(1),
                        "updatedAt": .integer(1),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }
        return (service, { capturedParams })
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexThreadGoalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeGoal(threadId: String) -> CodexThreadGoal {
        CodexThreadGoal(object: [
            "threadId": .string(threadId),
            "objective": .string("Existing objective"),
            "status": .string("active"),
            "tokensUsed": .integer(0),
            "timeUsedSeconds": .integer(0),
            "createdAt": .integer(1),
            "updatedAt": .integer(1),
        ])!
    }
}
