// FILE: CodexAutoApprovalReviewTests.swift
// Purpose: Verifies automatic approval-review lifecycle, payload mapping, and retry behavior.
// Layer: Unit Test
// Exports: CodexAutoApprovalReviewTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexAutoApprovalReviewTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testStartedAndCompletedNotificationsUpdateOneStableRow() {
        let service = makeService()
        let threadId = "thread-1"

        service.handleNotification(
            method: "item/autoApprovalReview/started",
            params: reviewParams(threadId: threadId, status: .inProgress)
        )
        let started = service.messages(for: threadId).first { $0.kind == .autoApprovalReview }

        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, status: .denied)
        )
        let rows = service.messages(for: threadId).filter { $0.kind == .autoApprovalReview }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, started?.id)
        XCTAssertEqual(rows[0].orderIndex, started?.orderIndex)
        XCTAssertEqual(rows[0].autoApprovalReview?.status, .denied)
        XCTAssertFalse(rows[0].isStreaming)
    }

    func testLateStartedNotificationCannotReplaceTerminalReview() {
        let service = makeService()
        let threadId = "thread-1"

        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, status: .approved)
        )
        service.handleNotification(
            method: "item/autoApprovalReview/started",
            params: reviewParams(threadId: threadId, status: .inProgress)
        )

        XCTAssertEqual(
            service.messages(for: threadId).first?.autoApprovalReview?.status,
            .approved
        )
    }

    func testRetryableStreamingFinalizationPreservesInProgressReview() {
        let service = makeService()
        let threadId = "thread-review-reconnect"
        service.runningThreadIDs.insert(threadId)
        service.handleNotification(
            method: "item/autoApprovalReview/started",
            params: reviewParams(threadId: threadId, status: .inProgress)
        )

        service.finalizeAllStreamingState(preserveRunLifecycle: true)

        let reviewMessage = service.messages(for: threadId).first {
            $0.kind == .autoApprovalReview
        }
        XCTAssertEqual(reviewMessage?.autoApprovalReview?.status, .inProgress)
        XCTAssertTrue(reviewMessage?.isStreaming == true)
    }

    func testReviewIdentityUsesReviewIdInsteadOfTargetItemId() {
        let service = makeService()
        let threadId = "thread-1"

        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, reviewId: "review-1", status: .denied)
        )
        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, reviewId: "review-2", status: .denied)
        )

        XCTAssertEqual(
            service.messages(for: threadId).filter { $0.kind == .autoApprovalReview }.count,
            2
        )
    }

    func testUnknownReviewStatusIsPreservedWithoutLeavingAStreamingRow() {
        let service = makeService()
        let threadId = "thread-1"
        var params = reviewParams(threadId: threadId, status: .denied).objectValue ?? [:]
        params["review"] = .object([
            "status": .string("needsConfirmation"),
            "riskLevel": .string("high"),
        ])

        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: .object(params)
        )

        let message = service.messages(for: threadId).first
        XCTAssertEqual(message?.autoApprovalReview?.status, .unknown("needsConfirmation"))
        XCTAssertFalse(message?.isStreaming ?? true)
    }

    func testUnknownDeniedActionShapeDisablesUnsafeRetry() {
        let service = makeService()
        let threadId = "thread-1"
        var params = reviewParams(threadId: threadId, status: .denied).objectValue ?? [:]
        params["action"] = .object([
            "type": .string("futurePrivilegedAction"),
            "payload": .string("opaque"),
        ])

        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: .object(params)
        )

        XCTAssertEqual(
            service.messages(for: threadId).first?.autoApprovalReview?.retryUnavailableReason,
            "This action cannot be retried safely here. Approve it in Codex."
        )
    }

    func testDeniedEventConvertsAppServerActionToCoreShape() {
        let review = CodexAutoApprovalReview(
            reviewId: "review-1",
            targetItemId: "item-1",
            turnId: "turn-1",
            startedAtMs: 10,
            completedAtMs: 20,
            status: .denied,
            riskLevel: "high",
            userAuthorization: "low",
            rationale: "External write",
            decisionSource: "agent",
            action: .object([
                "type": .string("requestPermissions"),
                "reason": .string("Need a generated file"),
                "permissions": .object([
                    "network": .null,
                    "fileSystem": .object([
                        "globScanMaxDepth": .integer(4),
                        "entries": .array([
                            .object([
                                "path": .object([
                                    "type": .string("special"),
                                    "value": .object([
                                        "kind": .string("project_roots"),
                                        "subpath": .null,
                                    ]),
                                ]),
                                "access": .string("write"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            retryApproved: false
        )

        let event = review.coreDeniedEvent?.objectValue
        let action = event?["action"]?.objectValue
        let permissions = action?["permissions"]?.objectValue
        let fileSystem = permissions?["file_system"]?.objectValue

        XCTAssertEqual(event?["id"], .string("review-1"))
        XCTAssertEqual(event?["target_item_id"], .string("item-1"))
        XCTAssertEqual(event?["turn_id"], .string("turn-1"))
        XCTAssertEqual(event?["status"], .string("denied"))
        XCTAssertEqual(action?["type"], .string("request_permissions"))
        XCTAssertEqual(fileSystem?["glob_scan_max_depth"], .integer(4))
        XCTAssertNil(fileSystem?["globScanMaxDepth"])
        XCTAssertEqual(event?["started_at_ms"], .integer(10))
        XCTAssertEqual(event?["completed_at_ms"], .integer(20))
    }

    func testApprovingDeniedReviewSendsNarrowRetryRequestAndUpdatesRow() async throws {
        let service = makeService()
        let threadId = "thread-1"
        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, status: .denied)
        )

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/approveGuardianDeniedAction")
            capturedParams = params
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        try await service.approveAutoApprovalRetry(threadId: threadId, reviewId: "review-1")

        let params = capturedParams?.objectValue
        XCTAssertEqual(params?["threadId"], .string(threadId))
        XCTAssertEqual(params?["event"]?.objectValue?["id"], .string("review-1"))
        XCTAssertEqual(
            service.messages(for: threadId).first?.autoApprovalReview?.retryApproved,
            true
        )
    }

    func testAutoReviewModeSendsCanonicalReviewer() async throws {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var capturedParams: JSONValue?
        service.requestTransportOverride = { _, params in
            capturedParams = params
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        _ = try await service.sendRequestWithApprovalPolicyFallback(
            method: "turn/start",
            baseParams: [:],
            context: "test"
        )

        XCTAssertEqual(capturedParams?.objectValue?["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(capturedParams?.objectValue?["approvalsReviewer"], .string("auto_review"))
    }

    func testDesktopMirroredResumeDoesNotPretendToReportAppliedSettings() throws {
        let service = makeService()
        let response = RPCMessage(
            id: .string("resume-desktop"),
            result: .object([
                "thread": .object(["id": .string("thread-desktop")]),
                "remodexDesktopIpcMirror": .bool(true),
            ]),
            includeJSONRPC: false
        )

        XCTAssertNoThrow(
            try service.validateAppliedAccessConfiguration(
                in: response,
                expected: RuntimeAccessConfiguration(mode: .autoReview),
                context: "thread/resume"
            )
        )
    }

    func testAutoReviewFallsBackToLegacyReviewer() async throws {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var attempts: [[String: JSONValue]] = []
        service.requestTransportOverride = { _, params in
            let object = params?.objectValue ?? [:]
            attempts.append(object)
            if object["approvalsReviewer"] == .string("auto_review") {
                throw CodexServiceError.rpcError(
                    RPCError(
                        code: -32602,
                        message: "unknown variant `auto_review`, expected `user` or `guardian_subagent`"
                    )
                )
            }
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        _ = try await service.sendRequestWithApprovalPolicyFallback(
            method: "turn/start",
            baseParams: [:],
            context: "test"
        )

        XCTAssertEqual(attempts.last?["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(attempts.last?["approvalsReviewer"], .string("guardian_subagent"))
        // A rejected reviewer advances the reviewer loop directly instead of
        // retrying the remaining policy candidates with the known-bad reviewer.
        XCTAssertEqual(attempts.count, 2)
    }

    func testThreadRequestsUseCanonicalLegacySandboxField() async throws {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var attempts: [[String: JSONValue]] = []
        service.requestTransportOverride = { _, params in
            let object = params?.objectValue ?? [:]
            attempts.append(object)
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        _ = try await service.sendRequestWithSandboxFallback(
            method: "thread/fork",
            baseParams: ["threadId": .string("thread-1")]
        )

        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0]["sandbox"], .string("workspace-write"))
        XCTAssertNil(attempts[0]["sandboxPolicy"])
        XCTAssertEqual(attempts[0]["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(attempts[0]["approvalsReviewer"], .string("auto_review"))
    }

    func testTurnStartUsesCanonicalStructuredSandboxField() async throws {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var capturedParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { _, params in
            capturedParams = params?.objectValue ?? [:]
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        _ = try await service.sendRequestWithSandboxFallback(
            method: "turn/start",
            baseParams: ["threadId": .string("thread-1")]
        )

        XCTAssertEqual(
            capturedParams["sandboxPolicy"],
            service.runtimeSandboxPolicyObject(for: .autoReview)
        )
        XCTAssertNil(capturedParams["sandbox"])
    }

    func testThreadSandboxFallbackNeverDropsWorkspaceBoundary() async throws {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var attempts: [[String: JSONValue]] = []
        service.requestTransportOverride = { _, params in
            let object = params?.objectValue ?? [:]
            attempts.append(object)
            if object["sandbox"] != nil {
                throw CodexServiceError.rpcError(
                    RPCError(code: -32602, message: "unknown field `sandbox`")
                )
            }
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        _ = try await service.sendRequestWithSandboxFallback(
            method: "thread/fork",
            baseParams: ["threadId": .string("thread-1")]
        )

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(
            attempts[1]["sandboxPolicy"],
            service.runtimeSandboxPolicyObject(for: .autoReview)
        )
        XCTAssertNil(attempts[1]["sandbox"])
    }

    func testSandboxFailureNeverRetriesWithoutAnExplicitBoundary() async {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var attempts: [[String: JSONValue]] = []
        service.requestTransportOverride = { _, params in
            let object = params?.objectValue ?? [:]
            attempts.append(object)
            throw CodexServiceError.rpcError(
                RPCError(code: -32602, message: "unsupported sandbox field")
            )
        }

        do {
            _ = try await service.sendRequestWithSandboxFallback(
                method: "thread/fork",
                baseParams: ["threadId": .string("thread-1")]
            )
            XCTFail("Expected both explicit sandbox shapes to be rejected")
        } catch {
            XCTAssertEqual(attempts.count, 2)
            XCTAssertTrue(attempts.allSatisfy { params in
                params["sandbox"] != nil || params["sandboxPolicy"] != nil
            })
        }
    }

    func testInlineReviewResumesWithVerifiedAccessConfigurationBeforeStarting() async throws {
        let service = makeService()
        service.selectedAccessMode = .autoReview
        var methods: [String] = []
        var resumeParams: [String: JSONValue] = [:]
        var reviewParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { method, params in
            methods.append(method)
            switch method {
            case "thread/resume":
                resumeParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string("resume-1"),
                    result: .object([
                        "thread": .object(["id": .string("thread-1")]),
                        "approvalPolicy": .string("on-request"),
                        "approvalsReviewer": .string("auto_review"),
                        "sandbox": service.runtimeSandboxPolicyObject(for: .autoReview),
                    ]),
                    includeJSONRPC: false
                )
            case "review/start":
                reviewParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string("review-1"),
                    result: .object(["turn": .object(["id": .string("turn-review-1")])]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        try await service.startReview(threadId: "thread-1", target: .uncommittedChanges)

        XCTAssertEqual(methods, ["thread/resume", "review/start"])
        XCTAssertEqual(resumeParams["sandbox"], .string("workspace-write"))
        XCTAssertEqual(resumeParams["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(resumeParams["approvalsReviewer"], .string("auto_review"))
        XCTAssertNil(reviewParams["sandbox"])
        XCTAssertNil(reviewParams["sandboxPolicy"])
        XCTAssertNil(reviewParams["approvalPolicy"])
        XCTAssertNil(reviewParams["approvalsReviewer"])
        XCTAssertEqual(reviewParams["delivery"], .string("inline"))
    }

    func testClearingPendingApprovalsAlsoClearsAutoReviewRetryState() {
        let service = makeService()
        let threadId = "thread-volatile-review"
        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, status: .denied)
        )
        service.autoApprovalRetryReviewIDsInFlight.insert("in-flight")

        XCTAssertEqual(service.autoApprovalRetryTokensByReviewKey.count, 1)
        XCTAssertFalse(service.autoApprovalRetryReviewIDsInFlight.isEmpty)

        service.clearPendingApprovals()

        XCTAssertTrue(service.autoApprovalRetryTokensByReviewKey.isEmpty)
        XCTAssertTrue(service.autoApprovalRetryReviewIDsInFlight.isEmpty)
    }

    func testDesktopMirroredReviewDisablesLocalRetry() {
        let service = makeService()
        let threadId = "thread-desktop"
        var params = reviewParams(threadId: threadId, status: .denied).objectValue ?? [:]
        params["remodexDesktopIpcMirror"] = .bool(true)

        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: .object(params)
        )

        XCTAssertEqual(
            service.messages(for: threadId).first?.autoApprovalReview?.retryUnavailableReason,
            "Approve this retry in Codex Desktop."
        )
    }

    func testCoreDeniedEventConvertsSourceAndProtocolEnumValues() {
        let review = CodexAutoApprovalReview(
            reviewId: "review-1",
            targetItemId: nil,
            turnId: "turn-1",
            startedAtMs: 10,
            completedAtMs: 20,
            status: .denied,
            riskLevel: nil,
            userAuthorization: nil,
            rationale: nil,
            decisionSource: "agent",
            action: .object([
                "type": .string("networkAccess"),
                "target": .string("https://example.com"),
                "host": .string("example.com"),
                "protocol": .string("socks5Tcp"),
                "port": .integer(443),
            ]),
            retryApproved: false
        )
        let execveReview = CodexAutoApprovalReview(
            reviewId: "review-2",
            targetItemId: nil,
            turnId: "turn-1",
            startedAtMs: 10,
            completedAtMs: 20,
            status: .denied,
            riskLevel: nil,
            userAuthorization: nil,
            rationale: nil,
            decisionSource: "agent",
            action: .object([
                "type": .string("execve"),
                "source": .string("unifiedExec"),
                "program": .string("/bin/ls"),
                "argv": .array([.string("/bin/ls")]),
                "cwd": .string("/tmp"),
            ]),
            retryApproved: false
        )

        let networkAction = review.coreDeniedEvent?.objectValue?["action"]?.objectValue
        let execveAction = execveReview.coreDeniedEvent?.objectValue?["action"]?.objectValue

        XCTAssertEqual(networkAction?["type"], .string("network_access"))
        XCTAssertEqual(networkAction?["protocol"], .string("socks5_tcp"))
        XCTAssertEqual(execveAction?["type"], .string("execve"))
        XCTAssertEqual(execveAction?["source"], .string("unified_exec"))
    }

    func testCoreDeniedEventConvertsMCPFieldNamesExactly() {
        let review = CodexAutoApprovalReview(
            reviewId: "review-mcp",
            targetItemId: nil,
            turnId: "turn-1",
            startedAtMs: 10,
            completedAtMs: 20,
            status: .denied,
            riskLevel: nil,
            userAuthorization: nil,
            rationale: nil,
            decisionSource: "agent",
            action: .object([
                "type": .string("mcpToolCall"),
                "server": .string("calendar"),
                "toolName": .string("create_event"),
                "toolTitle": .string("Create event"),
                "connectorId": .null,
                "connectorName": .string("Calendar"),
            ]),
            retryApproved: false
        )

        let action = review.coreDeniedEvent?.objectValue?["action"]?.objectValue
        XCTAssertEqual(action?["type"], .string("mcp_tool_call"))
        XCTAssertEqual(action?["tool_name"], .string("create_event"))
        XCTAssertEqual(action?["tool_title"], .string("Create event"))
        XCTAssertEqual(action?["connector_id"], .null)
        XCTAssertEqual(action?["connector_name"], .string("Calendar"))
        XCTAssertNil(action?["toolName"])
    }

    func testRetryUnavailableReviewRefusesLocalRetryWithoutTransportCall() async {
        let service = makeService()
        let threadId = "thread-desktop"
        var params = reviewParams(threadId: threadId, status: .denied).objectValue ?? [:]
        params["remodexDesktopIpcMirror"] = .bool(true)
        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: .object(params)
        )
        service.requestTransportOverride = { method, _ in
            XCTFail("Unexpected transport call: \(method)")
            throw CodexServiceError.invalidInput("Unexpected transport call")
        }

        do {
            try await service.approveAutoApprovalRetry(threadId: threadId, reviewId: "review-1")
            XCTFail("Expected retry to be unavailable for Desktop-mirrored reviews")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Approve this retry in Codex Desktop."
            )
        }
    }

    func testRetryCannotBeApprovedTwice() async throws {
        let service = makeService()
        let threadId = "thread-1"
        service.handleNotification(
            method: "item/autoApprovalReview/completed",
            params: reviewParams(threadId: threadId, status: .denied)
        )

        var transportCallCount = 0
        service.requestTransportOverride = { _, _ in
            transportCallCount += 1
            return RPCMessage(
                id: .string("request-1"),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        try await service.approveAutoApprovalRetry(threadId: threadId, reviewId: "review-1")

        do {
            try await service.approveAutoApprovalRetry(threadId: threadId, reviewId: "review-1")
            XCTFail("Expected an already-approved review to reject a second retry")
        } catch {
            XCTAssertEqual(transportCallCount, 1)
        }
    }

    func testHistoryDecodesDesktopMirroredGuardianReviewItems() {
        let service = makeService()

        // Shape emitted by the bridge's Desktop conversation projector for
        // thread/read backfill of mirrored guardian reviews.
        let messages = service.decodeMessagesFromThreadRead(
            threadId: "thread-desktop",
            threadObject: [
                "id": .string("thread-desktop"),
                "turns": .array([
                    .object([
                        "id": .string("turn-1"),
                        "status": .string("completed"),
                        "items": .array([
                            .object([
                                "type": .string("automaticApprovalReview"),
                                "id": .string("automatic-approval-review:review-9"),
                                "reviewId": .string("review-9"),
                                "targetItemId": .null,
                                "status": .string("denied"),
                                "startedAtMs": .integer(1_710_000_000_000),
                                "completedAtMs": .integer(1_710_000_000_500),
                                "decisionSource": .string("agent"),
                                "review": .object([
                                    "status": .string("denied"),
                                    "riskLevel": .string("high"),
                                    "userAuthorization": .string("low"),
                                    "rationale": .string("Writes outside the workspace"),
                                ]),
                                "action": .object([
                                    "type": .string("command"),
                                    "source": .string("shell"),
                                    "command": .string("rm -rf /"),
                                    "cwd": .string("/tmp"),
                                ]),
                                "remodexDesktopIpcMirror": .bool(true),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        let reviewMessages = messages.filter { $0.kind == .autoApprovalReview }
        XCTAssertEqual(reviewMessages.count, 1)
        XCTAssertEqual(reviewMessages.first?.itemId, "auto-approval-review:review-9")
        XCTAssertEqual(reviewMessages.first?.turnId, "turn-1")
        XCTAssertEqual(reviewMessages.first?.autoApprovalReview?.status, .denied)
        XCTAssertEqual(reviewMessages.first?.autoApprovalReview?.riskLevel, "high")
        XCTAssertEqual(
            reviewMessages.first?.autoApprovalReview?.retryUnavailableReason,
            "Approve this retry in Codex Desktop."
        )
        XCTAssertFalse(reviewMessages.first?.isStreaming ?? true)
    }

    private func reviewParams(
        threadId: String,
        reviewId: String = "review-1",
        status: CodexAutoApprovalReviewStatus
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "turnId": .string("turn-1"),
            "reviewId": .string(reviewId),
            "targetItemId": .string("item-1"),
            "startedAtMs": .integer(10),
            "review": .object([
                "status": .string(status.rawValue),
                "riskLevel": status.isTerminal ? .string("high") : .null,
                "userAuthorization": status.isTerminal ? .string("low") : .null,
                "rationale": status.isTerminal ? .string("Potentially unsafe action") : .null,
            ]),
            "action": .object([
                "type": .string("command"),
                "source": .string("unifiedExec"),
                "command": .string("curl https://example.com"),
                "cwd": .string("/tmp"),
            ]),
        ]
        if status.isTerminal {
            params["completedAtMs"] = .integer(20)
            params["decisionSource"] = .string("agent")
        }
        return .object(params)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexAutoApprovalReviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
