// FILE: SidebarRunBadgePerformanceTests.swift
// Purpose: Benchmarks sidebar run-badge state derivation (clock + CPU) for large thread lists.
// Layer: Unit Test (Performance)
// Exports: SidebarRunBadgePerformanceTests
// Depends on: XCTest, CodexService, CodexThread

import XCTest
@testable import CodexMobile

@MainActor
final class SidebarRunBadgePerformanceTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testSidebarRunBadgeSnapshotPerformance() {
        let service = makeService(threadCount: 1_500)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            var totalSnapshotEntries = 0
            for _ in 0..<150 {
                totalSnapshotEntries += makeRunBadgeSnapshotCount(service: service)
            }
            XCTAssertGreaterThan(totalSnapshotEntries, 0)
        }
    }

    func testSidebarRunBadgeSnapshotWithLargeTimelinePerformance() {
        let service = makeService(threadCount: 800)
        let now = Date()

        for thread in service.threads {
            let messages = (0..<220).map { index in
                CodexMessage(
                    threadId: thread.id,
                    role: .assistant,
                    text: "msg-\(index)",
                    createdAt: now.addingTimeInterval(Double(index)),
                    isStreaming: false
                )
            }
            service.messagesByThread[thread.id] = messages
        }

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            var totalSnapshotEntries = 0
            for _ in 0..<120 {
                totalSnapshotEntries += makeRunBadgeSnapshotCount(service: service)
            }
            XCTAssertGreaterThan(totalSnapshotEntries, 0)
        }
    }
}

private extension SidebarRunBadgePerformanceTests {
    func makeRunBadgeSnapshotCount(service: CodexService) -> Int {
        var snapshot: [String: CodexThreadRunBadgeState] = [:]
        snapshot.reserveCapacity(service.threads.count)

        for thread in service.threads {
            if let state = service.threadRunBadgeState(for: thread.id) {
                snapshot[thread.id] = state
            }
        }

        return snapshot.count
    }

    func makeService(threadCount: Int) -> CodexService {
        let suiteName = "SidebarRunBadgePerformanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let now = Date()
        service.threads = (0..<threadCount).map { index in
            CodexThread(
                id: "thread-\(index)",
                title: "Thread \(index)",
                updatedAt: now.addingTimeInterval(-Double(index))
            )
        }

        for index in 0..<threadCount {
            let threadID = "thread-\(index)"

            if index.isMultiple(of: 3) {
                service.runningThreadIDs.insert(threadID)
                continue
            }

            if index.isMultiple(of: 5) {
                service.failedThreadIDs.insert(threadID)
                continue
            }

            if index.isMultiple(of: 2) {
                service.readyThreadIDs.insert(threadID)
            }
        }

        Self.retainedServices.append(service)
        return service
    }
}
