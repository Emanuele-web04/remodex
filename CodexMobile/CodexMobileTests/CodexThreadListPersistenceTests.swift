// FILE: CodexThreadListPersistenceTests.swift
// Purpose: Verifies persisted thread list snapshots restore only for matching relay context.
// Layer: Unit Test
// Exports: CodexThreadListPersistenceTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadListPersistenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
        deletePersistedSnapshotFile()
    }

    override func tearDown() {
        deletePersistedSnapshotFile()
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testThreadSnapshotRestoresThreadsAndActiveSelectionForMatchingRelayMac() async {
        let defaults = makeDefaults(testName: "restoreMatchingRelay")
        let service = CodexService(defaults: defaults)

        service.relayMacDeviceId = "mac-test"
        service.threads = [
            makeThread(id: "thread-a", title: "A", updatedAt: Date(timeIntervalSince1970: 100)),
            makeThread(id: "thread-b", title: "B", updatedAt: Date(timeIntervalSince1970: 200)),
        ]
        service.activeThreadId = "thread-b"
        await awaitDebounceFlush()

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.relayMacDeviceId = "mac-test"
        reloadedService.restorePersistedThreadListSnapshotIfNeeded()

        XCTAssertEqual(reloadedService.threads.map(\.id), ["thread-b", "thread-a"])
        XCTAssertEqual(reloadedService.activeThreadId, "thread-b")
    }

    func testThreadSnapshotSkipsRestoreForMismatchedRelayMac() async {
        let defaults = makeDefaults(testName: "mismatchedRelay")
        let service = CodexService(defaults: defaults)

        service.relayMacDeviceId = "mac-a"
        service.threads = [
            makeThread(id: "thread-a", title: "A", updatedAt: Date(timeIntervalSince1970: 100)),
        ]
        service.activeThreadId = "thread-a"
        await awaitDebounceFlush()

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.relayMacDeviceId = "mac-b"
        reloadedService.restorePersistedThreadListSnapshotIfNeeded()

        XCTAssertTrue(reloadedService.threads.isEmpty)
        XCTAssertNil(reloadedService.activeThreadId)
    }

    func testThreadSnapshotDropsActiveSelectionWhenThreadMissingFromSnapshot() {
        let defaults = makeDefaults(testName: "missingActive")
        CodexThreadListPersistence(namespace: CodexService.persistenceNamespace(for: defaults)).save(
            CodexThreadListSnapshot(
                threads: [
                    makeThread(id: "thread-a", title: "A", updatedAt: Date(timeIntervalSince1970: 100)),
                ],
                lastActiveThreadId: "thread-missing",
                savedAt: Date(timeIntervalSince1970: 300),
                serverIdentity: nil,
                relayMacDeviceId: "mac-test"
            )
        )

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.relayMacDeviceId = "mac-test"
        reloadedService.restorePersistedThreadListSnapshotIfNeeded()

        XCTAssertEqual(reloadedService.threads.map(\.id), ["thread-a"])
        XCTAssertNil(reloadedService.activeThreadId)
    }

    func testThreadSnapshotRestoresServerScopedSnapshotImmediatelyFromPersistedContext() {
        let defaults = makeDefaults(testName: "serverScoped")
        CodexThreadListPersistence(namespace: CodexService.persistenceNamespace(for: defaults)).save(
            CodexThreadListSnapshot(
                threads: [
                    makeThread(id: "thread-a", title: "A", updatedAt: Date(timeIntervalSince1970: 100)),
                ],
                lastActiveThreadId: "thread-a",
                savedAt: Date(timeIntervalSince1970: 300),
                serverIdentity: "ws://example.test/socket",
                relayMacDeviceId: nil
            )
        )

        let reloadedService = CodexService(defaults: defaults)

        XCTAssertEqual(reloadedService.threads.map(\.id), ["thread-a"])
        XCTAssertEqual(reloadedService.activeThreadId, "thread-a")
        XCTAssertEqual(reloadedService.connectedServerIdentity, "ws://example.test/socket")
    }

    private func makeDefaults(testName: String) -> UserDefaults {
        let suiteName = "CodexThreadListPersistenceTests.\(testName).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Expected isolated UserDefaults suite")
        }

        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeThread(id: String, title: String, updatedAt: Date) -> CodexThread {
        CodexThread(
            id: id,
            title: title,
            updatedAt: updatedAt,
            cwd: "/tmp/remodex"
        )
    }

    private func awaitDebounceFlush() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }

    private func deletePersistedSnapshotFile() {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let rootURL = baseURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
