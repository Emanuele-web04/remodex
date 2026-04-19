// FILE: CodexServiceThreadDisplayPhaseTests.swift
// Purpose: Verifies the empty-thread placeholder does not regress into a loading flash.
// Layer: Unit Test
// Exports: CodexServiceThreadDisplayPhaseTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceThreadDisplayPhaseTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testThreadDisplayPhaseTreatsFreshPlaceholderThreadAsEmpty() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(
                id: threadID,
                title: CodexThread.defaultDisplayTitle,
                preview: nil,
                syncState: .live
            )
        ]

        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .empty)
    }

    func testThreadDisplayPhaseKeepsUnhydratedThreadWithPreviewLoading() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(
                id: threadID,
                title: CodexThread.defaultDisplayTitle,
                preview: "Existing message preview",
                syncState: .live
            )
        ]

        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .loading)
    }

    func testThreadDisplayPhaseKeepsBlankPlaceholderEmptyEvenIfLoadingStateAlreadyStarted() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(
                id: threadID,
                title: CodexThread.defaultDisplayTitle,
                preview: nil,
                syncState: .live
            )
        ]
        service.hydratedThreadIDs.insert(threadID)
        service.loadingThreadIDs.insert(threadID)

        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .empty)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceThreadDisplayPhaseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
