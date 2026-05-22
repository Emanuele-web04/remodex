// FILE: CodexTrustedMacSelectionTests.swift
// Purpose: Verifies the app uses an explicit current trusted Mac instead of implicit recency fallback.
// Layer: Unit Test
// Exports: CodexTrustedMacSelectionTests
// Depends on: XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexTrustedMacSelectionTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testServiceMigratesCurrentTrustedMacFromLastTrustedMacWhenMissing() {
        let macDeviceID = "mac-\(UUID().uuidString)"
        let registry = CodexTrustedMacRegistry(
            records: [
                macDeviceID: CodexTrustedMacRecord(
                    macDeviceId: macDeviceID,
                    macIdentityPublicKey: Data(repeating: 3, count: 32).base64EncodedString(),
                    lastPairedAt: Date()
                )
            ]
        )
        SecureStore.writeCodable(registry, for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.writeString(macDeviceID, for: CodexSecureKeys.lastTrustedMacDeviceId)

        let service = makeService()

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(service.preferredTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId),
            macDeviceID
        )
    }

    func testPreferredTrustedMacUsesExplicitCurrentMacInsteadOfLastTrustedFallback() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let lastTrustedMacID = "mac-last-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 4, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-5)
        )
        service.trustedMacRegistry.records[lastTrustedMacID] = CodexTrustedMacRecord(
            macDeviceId: lastTrustedMacID,
            macIdentityPublicKey: Data(repeating: 5, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.lastTrustedMacDeviceId = lastTrustedMacID
        service.setCurrentTrustedMacDeviceId(currentMacID)

        XCTAssertEqual(service.preferredTrustedMacDeviceId, currentMacID)
        XCTAssertEqual(service.currentTrustedMacRecord?.macDeviceId, currentMacID)
    }

    func testHasSavedRelaySessionRejectsSessionForDifferentCurrentMac() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let staleMacID = "mac-stale-\(UUID().uuidString)"

        service.setCurrentTrustedMacDeviceId(currentMacID)
        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = staleMacID

        XCTAssertFalse(service.hasSavedRelaySession)
    }

    func testForgetTrustedMacClearsCurrentTrustedMacDeviceId() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 6, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay"
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)

        service.forgetTrustedMac(deviceId: currentMacID)

        XCTAssertNil(service.normalizedCurrentTrustedMacDeviceId)
        XCTAssertNil(SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId))
    }

    func testTrustedPairPresentationUsesVisibleCurrentMacInsteadOfStaleRelayMac() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let staleRelayMacID = "mac-stale-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            displayName: "Current Mac"
        )
        service.trustedMacRegistry.records[staleRelayMacID] = CodexTrustedMacRecord(
            macDeviceId: staleRelayMacID,
            macIdentityPublicKey: Data(repeating: 8, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            displayName: "Stale Mac"
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)
        service.relayMacDeviceId = staleRelayMacID
        SidebarComputerNicknameStore.setNickname("Current Alias", for: currentMacID)
        SidebarComputerNicknameStore.setNickname("Stale Alias", for: staleRelayMacID)
        defer {
            SidebarComputerNicknameStore.setNickname("", for: currentMacID)
            SidebarComputerNicknameStore.setNickname("", for: staleRelayMacID)
        }

        let presentation = service.trustedPairPresentation

        XCTAssertEqual(presentation?.deviceId, currentMacID)
        XCTAssertEqual(presentation?.name, "Current Alias")
    }

    func testTrustMacCoalescesRowsForTheSameIdentityKey() {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"
        let sharedPublicKey = Data(repeating: 9, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: sharedPublicKey,
            lastPairedAt: Date().addingTimeInterval(-30),
            relayURL: "wss://relay.local/relay",
            displayName: "Studio Mac",
            lastResolvedSessionId: "old-session",
            lastResolvedAt: Date().addingTimeInterval(-20),
            lastUsedAt: Date().addingTimeInterval(-10)
        )
        service.setCurrentTrustedMacDeviceId(staleMacID)
        service.setPreviousTrustedMacDeviceId(staleMacID)

        service.trustMac(
            deviceId: freshMacID,
            publicKey: sharedPublicKey,
            relayURL: nil,
            displayName: nil
        )

        XCTAssertNil(service.trustedMacRegistry.records[staleMacID])
        XCTAssertEqual(service.trustedMacRegistry.records[freshMacID]?.displayName, "Studio Mac")
        XCTAssertEqual(service.trustedMacRegistry.records[freshMacID]?.relayURL, "wss://relay.local/relay")
        XCTAssertEqual(service.trustedMacRegistry.records[freshMacID]?.lastResolvedSessionId, "old-session")
        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, freshMacID)
        XCTAssertNil(service.normalizedPreviousTrustedMacDeviceId)
        XCTAssertEqual(SecureStore.readString(for: CodexSecureKeys.lastTrustedMacDeviceId), freshMacID)
    }

    func testTrustMacMigratesPinnedDefaultsFromCoalescedMacId() throws {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"
        let sharedPublicKey = Data(repeating: 14, count: 32).base64EncodedString()
        let staleThread = CodexThread(id: "thread-stale", title: "Stale Pin")
        let freshThread = CodexThread(id: "thread-fresh", title: "Fresh Pin")

        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: sharedPublicKey,
            lastPairedAt: Date().addingTimeInterval(-30),
            relayURL: "wss://relay.local/relay",
            displayName: "Studio Mac",
            lastUsedAt: Date().addingTimeInterval(-10)
        )
        service.defaults.set(
            try service.encoder.encode([freshThread.id]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: freshMacID)
        )
        service.defaults.set(
            try service.encoder.encode([staleThread.id]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: staleMacID)
        )
        service.defaults.set(
            try service.encoder.encode([freshThread.id: [freshThread]]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadSnapshotsDefaultsKey, macDeviceId: freshMacID)
        )
        service.defaults.set(
            try service.encoder.encode([staleThread.id: [staleThread]]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadSnapshotsDefaultsKey, macDeviceId: staleMacID)
        )

        service.trustMac(
            deviceId: freshMacID,
            publicKey: sharedPublicKey,
            relayURL: nil,
            displayName: nil
        )

        let migratedPinnedIDsData = try XCTUnwrap(service.defaults.data(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: freshMacID)
        ))
        let migratedPinnedIDs = try service.decoder.decode([String].self, from: migratedPinnedIDsData)
        let migratedSnapshotsData = try XCTUnwrap(service.defaults.data(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadSnapshotsDefaultsKey, macDeviceId: freshMacID)
        ))
        let migratedSnapshots = try service.decoder.decode([String: [CodexThread]].self, from: migratedSnapshotsData)

        XCTAssertNil(service.defaults.object(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: staleMacID)
        ))
        XCTAssertNil(service.defaults.object(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadSnapshotsDefaultsKey, macDeviceId: staleMacID)
        ))
        XCTAssertEqual(migratedPinnedIDs, [freshThread.id, staleThread.id])
        XCTAssertEqual(migratedSnapshots[freshThread.id]?.first?.title, freshThread.title)
        XCTAssertEqual(migratedSnapshots[staleThread.id]?.first?.title, staleThread.title)
        XCTAssertEqual(service.pinnedThreadIDs, [freshThread.id, staleThread.id])
        XCTAssertEqual(service.pinnedThreadSnapshotsByRootID[staleThread.id]?.first?.title, staleThread.title)
    }

    func testTrustMacMigratesLocalCachesFromCoalescedMacId() throws {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"
        let sharedPublicKey = Data(repeating: 25, count: 32).base64EncodedString()
        defer {
            service.messagePersistence.delete(macDeviceId: staleMacID)
            service.messagePersistence.delete(macDeviceId: freshMacID)
            service.composerDraftPersistence.delete(macDeviceId: staleMacID)
            service.composerDraftPersistence.delete(macDeviceId: freshMacID)
            service.aiChangeSetPersistence.delete(macDeviceId: staleMacID)
            service.aiChangeSetPersistence.delete(macDeviceId: freshMacID)
        }

        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: sharedPublicKey,
            lastPairedAt: Date().addingTimeInterval(-30),
            relayURL: "wss://relay.local/relay",
            displayName: "Studio Mac",
            lastUsedAt: Date().addingTimeInterval(-10)
        )
        service.messagePersistence.save(
            ["thread-fresh": [makeMessage(threadID: "thread-fresh", text: "fresh")]],
            macDeviceId: freshMacID
        )
        service.messagePersistence.save(
            ["thread-stale": [makeMessage(threadID: "thread-stale", text: "stale")]],
            macDeviceId: staleMacID
        )
        service.composerDraftPersistence.save(
            [
                "thread-stale": TurnComposerLocalDraft.make(
                    input: "old draft",
                    mentionedFiles: [],
                    mentionedSkills: [],
                    mentionedPlugins: [],
                    attachments: [],
                    reviewSelection: nil,
                    isPlanModeArmed: false,
                    isSubagentsSelectionArmed: false
                )
            ],
            macDeviceId: staleMacID
        )
        service.aiChangeSetPersistence.save(
            [
                AIChangeSet(
                    id: "change-stale",
                    threadId: "thread-stale",
                    turnId: "turn-stale",
                    source: .turnDiff,
                    forwardUnifiedPatch: "diff --git a/file b/file"
                )
            ],
            macDeviceId: staleMacID
        )

        service.trustMac(
            deviceId: freshMacID,
            publicKey: sharedPublicKey,
            relayURL: nil,
            displayName: nil
        )

        let migratedMessages = service.messagePersistence.load(macDeviceId: freshMacID)
        let migratedDrafts = service.composerDraftPersistence.load(macDeviceId: freshMacID)
        let migratedChangeSets = service.aiChangeSetPersistence.load(macDeviceId: freshMacID)

        XCTAssertEqual(migratedMessages["thread-fresh"]?.first?.text, "fresh")
        XCTAssertEqual(migratedMessages["thread-stale"]?.first?.text, "stale")
        XCTAssertEqual(migratedDrafts["thread-stale"]?.input, "old draft")
        XCTAssertEqual(migratedChangeSets.first?.id, "change-stale")
        XCTAssertTrue(service.messagePersistence.load(macDeviceId: staleMacID).isEmpty)
        XCTAssertTrue(service.composerDraftPersistence.load(macDeviceId: staleMacID).isEmpty)
        XCTAssertTrue(service.aiChangeSetPersistence.load(macDeviceId: staleMacID).isEmpty)
    }

    func testTrustMacKeepsSpecificDisplayNameWhenIncomingNameIsGeneric() {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"
        let sharedPublicKey = Data(repeating: 12, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: sharedPublicKey,
            lastPairedAt: Date().addingTimeInterval(-30),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: nil,
            lastResolvedAt: nil,
            lastUsedAt: Date().addingTimeInterval(-10)
        )

        service.trustMac(
            deviceId: freshMacID,
            publicKey: sharedPublicKey,
            relayURL: nil,
            displayName: "Mac"
        )

        XCTAssertNil(service.trustedMacRegistry.records[staleMacID])
        XCTAssertEqual(service.trustedMacRegistry.records[freshMacID]?.displayName, "MacBook-Pro-di-Emanuele.local")
    }

    func testTrustMacRecoversSpecificDisplayNameWhenFreshRecordAlreadyExistsAsGeneric() {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"
        let sharedPublicKey = Data(repeating: 12, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[freshMacID] = CodexTrustedMacRecord(
            macDeviceId: freshMacID,
            macIdentityPublicKey: sharedPublicKey,
            lastPairedAt: Date().addingTimeInterval(-60),
            relayURL: "wss://relay.local/relay",
            displayName: "Mac",
            lastResolvedSessionId: nil,
            lastResolvedAt: nil,
            lastUsedAt: Date().addingTimeInterval(-60)
        )
        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: sharedPublicKey,
            lastPairedAt: Date().addingTimeInterval(-30),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: "old-session",
            lastResolvedAt: Date().addingTimeInterval(-20),
            lastUsedAt: Date().addingTimeInterval(-10)
        )

        service.trustMac(
            deviceId: freshMacID,
            publicKey: sharedPublicKey,
            relayURL: nil,
            displayName: "Mac"
        )

        let trustedMac = service.trustedMacRegistry.records[freshMacID]
        XCTAssertNil(service.trustedMacRegistry.records[staleMacID])
        XCTAssertEqual(trustedMac?.displayName, "MacBook-Pro-di-Emanuele.local")
        XCTAssertEqual(trustedMac?.lastResolvedSessionId, "old-session")
    }

    func testTrustMacMarksFreshQRSessionAsResolved() {
        let service = makeService()
        let macID = "mac-live-\(UUID().uuidString)"
        let publicKey = Data(repeating: 13, count: 32).base64EncodedString()

        service.trustMac(
            deviceId: macID,
            publicKey: publicKey,
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            liveSessionId: "live-session"
        )

        let trustedMac = service.trustedMacRegistry.records[macID]
        XCTAssertEqual(trustedMac?.lastResolvedSessionId, "live-session")
        XCTAssertNotNil(trustedMac?.lastResolvedAt)
        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, macID)
    }

    func testTrustMacCoalescesRowsForTheSameHostDisplayName() {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"

        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: Data(repeating: 10, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-14 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: "old-session",
            lastResolvedAt: Date().addingTimeInterval(-14 * 24 * 60 * 60),
            lastUsedAt: Date().addingTimeInterval(-13 * 24 * 60 * 60)
        )

        service.trustMac(
            deviceId: freshMacID,
            publicKey: Data(repeating: 11, count: 32).base64EncodedString(),
            relayURL: nil,
            displayName: "macbook-pro-di-emanuele.local"
        )

        XCTAssertNil(service.trustedMacRegistry.records[staleMacID])
        XCTAssertEqual(service.trustedMacRegistry.records[freshMacID]?.displayName, "macbook-pro-di-emanuele.local")
        XCTAssertNil(service.trustedMacRegistry.records[freshMacID]?.lastResolvedSessionId)
        XCTAssertEqual(service.trustedMacRegistry.records.count, 1)
    }

    func testTrustMacDoesNotCoalesceRecentSameHostDisplayNameWithDifferentIdentityKey() {
        let service = makeService()
        let existingMacID = "mac-existing-\(UUID().uuidString)"
        let freshMacID = "mac-fresh-\(UUID().uuidString)"

        service.trustedMacRegistry.records[existingMacID] = CodexTrustedMacRecord(
            macDeviceId: existingMacID,
            macIdentityPublicKey: Data(repeating: 15, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-60),
            relayURL: "wss://relay.local/relay",
            displayName: "Shared-Host.local",
            lastResolvedSessionId: "existing-session",
            lastResolvedAt: Date().addingTimeInterval(-30),
            lastUsedAt: Date().addingTimeInterval(-20)
        )

        service.trustMac(
            deviceId: freshMacID,
            publicKey: Data(repeating: 16, count: 32).base64EncodedString(),
            relayURL: "wss://relay.local/relay",
            displayName: "shared-host.local"
        )

        XCTAssertNotNil(service.trustedMacRegistry.records[existingMacID])
        XCTAssertEqual(service.trustedMacRegistry.records.count, 2)
        XCTAssertNil(service.trustedMacRegistry.records[freshMacID]?.lastResolvedSessionId)
    }

    func testPresentationCompactsRotatedTrustedMacRecordsWithSameDisplayName() {
        let service = makeService()
        let staleMacID = "mac-stale-\(UUID().uuidString)"
        let liveMacID = "mac-live-\(UUID().uuidString)"
        let displayName = "MacBook-Pro-di-Emanuele.local"

        service.trustedMacRegistry.records[staleMacID] = CodexTrustedMacRecord(
            macDeviceId: staleMacID,
            macIdentityPublicKey: Data(repeating: 30, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-14 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: displayName,
            lastResolvedSessionId: "old-session",
            lastResolvedAt: Date().addingTimeInterval(-14 * 24 * 60 * 60)
        )
        service.trustedMacRegistry.records[liveMacID] = CodexTrustedMacRecord(
            macDeviceId: liveMacID,
            macIdentityPublicKey: Data(repeating: 31, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay",
            displayName: displayName,
            lastResolvedSessionId: "live-session",
            lastResolvedAt: Date()
        )

        let presentationRecords = service.presentationTrustedMacRecords()

        XCTAssertEqual(presentationRecords.map(\.macDeviceId), [liveMacID])
        XCTAssertNotNil(service.trustedMacRegistry.records[staleMacID])
        XCTAssertNotNil(service.trustedMacRegistry.records[liveMacID])
    }

    func testPresentationKeepsRecentSameHostDisplayNameWithDifferentIdentityKeys() {
        let service = makeService()
        let firstMacID = "mac-first-\(UUID().uuidString)"
        let secondMacID = "mac-second-\(UUID().uuidString)"
        let displayName = "Shared-Host.local"

        service.trustedMacRegistry.records[firstMacID] = CodexTrustedMacRecord(
            macDeviceId: firstMacID,
            macIdentityPublicKey: Data(repeating: 33, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-60),
            relayURL: "wss://relay.local/relay",
            displayName: displayName,
            lastResolvedSessionId: "first-session",
            lastResolvedAt: Date().addingTimeInterval(-60)
        )
        service.trustedMacRegistry.records[secondMacID] = CodexTrustedMacRecord(
            macDeviceId: secondMacID,
            macIdentityPublicKey: Data(repeating: 34, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay",
            displayName: displayName,
            lastResolvedSessionId: "second-session",
            lastResolvedAt: Date()
        )

        let presentationIds = Set(service.presentationTrustedMacRecords().map(\.macDeviceId))

        XCTAssertTrue(presentationIds.contains(firstMacID))
        XCTAssertTrue(presentationIds.contains(secondMacID))
    }

    func testPresentationHidesOldGenericUnresolvedMacWhenReliableRecordsExist() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let pairedMacID = "mac-paired-\(UUID().uuidString)"
        let staleGenericMacID = "mac-stale-generic-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 40, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-87.local",
            lastResolvedSessionId: "current-session",
            lastResolvedAt: Date()
        )
        service.trustedMacRegistry.records[pairedMacID] = CodexTrustedMacRecord(
            macDeviceId: pairedMacID,
            macIdentityPublicKey: Data(repeating: 41, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-60),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: "paired-session",
            lastResolvedAt: Date().addingTimeInterval(-60)
        )
        service.trustedMacRegistry.records[staleGenericMacID] = CodexTrustedMacRecord(
            macDeviceId: staleGenericMacID,
            macIdentityPublicKey: Data(repeating: 42, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: "Mac"
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)

        let presentationIds = Set(service.presentationTrustedMacRecords().map(\.macDeviceId))

        XCTAssertTrue(presentationIds.contains(currentMacID))
        XCTAssertTrue(presentationIds.contains(pairedMacID))
        XCTAssertFalse(presentationIds.contains(staleGenericMacID))
        XCTAssertNotNil(service.trustedMacRegistry.records[staleGenericMacID])
    }

    func testPresentationHidesOldGenericResolvedMacWhenReliableRecordsExist() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let staleGenericMacID = "mac-stale-generic-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 43, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-87.local",
            lastResolvedSessionId: "current-session",
            lastResolvedAt: Date()
        )
        service.trustedMacRegistry.records[staleGenericMacID] = CodexTrustedMacRecord(
            macDeviceId: staleGenericMacID,
            macIdentityPublicKey: Data(repeating: 44, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: "Mac",
            lastResolvedSessionId: "old-session",
            lastResolvedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60)
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)

        let presentationIds = Set(service.presentationTrustedMacRecords().map(\.macDeviceId))

        XCTAssertTrue(presentationIds.contains(currentMacID))
        XCTAssertFalse(presentationIds.contains(staleGenericMacID))
        XCTAssertNotNil(service.trustedMacRegistry.records[staleGenericMacID])
    }

    func testPresentationHidesOldGenericPreviousMacWhenReliableRecordsExist() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let staleGenericMacID = "mac-stale-generic-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 45, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-87.local",
            lastResolvedSessionId: "current-session",
            lastResolvedAt: Date()
        )
        service.trustedMacRegistry.records[staleGenericMacID] = CodexTrustedMacRecord(
            macDeviceId: staleGenericMacID,
            macIdentityPublicKey: Data(repeating: 46, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: "Mac",
            lastResolvedSessionId: "old-session",
            lastResolvedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60)
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)
        service.setPreviousTrustedMacDeviceId(staleGenericMacID)

        let presentationIds = Set(service.presentationTrustedMacRecords().map(\.macDeviceId))

        XCTAssertTrue(presentationIds.contains(currentMacID))
        XCTAssertFalse(presentationIds.contains(staleGenericMacID))
        XCTAssertNotNil(service.trustedMacRegistry.records[staleGenericMacID])
    }

    func testPruneOfflineTrustedMacRecordsRemovesOnlySelectedIdentityButKeepsNamedCandidates() {
        let service = makeService()
        let targetMacID = "mac-target-\(UUID().uuidString)"
        let duplicateMacID = "mac-duplicate-\(UUID().uuidString)"
        let resolvedMacID = "mac-resolved-\(UUID().uuidString)"
        let currentMacID = "mac-current-\(UUID().uuidString)"

        let target = CodexTrustedMacRecord(
            macDeviceId: targetMacID,
            macIdentityPublicKey: Data(repeating: 20, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: nil,
            lastResolvedAt: nil,
            lastUsedAt: Date().addingTimeInterval(-20 * 24 * 60 * 60)
        )
        service.trustedMacRegistry.records[targetMacID] = target
        service.trustedMacRegistry.records[duplicateMacID] = CodexTrustedMacRecord(
            macDeviceId: duplicateMacID,
            macIdentityPublicKey: Data(repeating: 20, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-22 * 24 * 60 * 60),
            relayURL: "wss://relay.local/relay",
            displayName: "macbook-pro-di-emanuele.local",
            lastResolvedSessionId: nil,
            lastResolvedAt: nil,
            lastUsedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60)
        )
        service.trustedMacRegistry.records[resolvedMacID] = CodexTrustedMacRecord(
            macDeviceId: resolvedMacID,
            macIdentityPublicKey: Data(repeating: 22, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-100),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: "live-session",
            lastResolvedAt: Date().addingTimeInterval(-90),
            lastUsedAt: Date().addingTimeInterval(-80)
        )
        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 23, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: nil,
            lastResolvedAt: nil,
            lastUsedAt: Date()
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)

        let removedCount = service.pruneOfflineTrustedMacRecords(matching: target)

        XCTAssertEqual(removedCount, 2)
        XCTAssertNil(service.trustedMacRegistry.records[targetMacID])
        XCTAssertNil(service.trustedMacRegistry.records[duplicateMacID])
        XCTAssertNotNil(service.trustedMacRegistry.records[resolvedMacID])
        XCTAssertNotNil(service.trustedMacRegistry.records[currentMacID])
    }

    func testPruneOfflineTrustedMacRecordsKeepsRecentSelectedDevice() {
        let service = makeService()
        let targetMacID = "mac-target-\(UUID().uuidString)"

        let target = CodexTrustedMacRecord(
            macDeviceId: targetMacID,
            macIdentityPublicKey: Data(repeating: 24, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-120),
            relayURL: "wss://relay.local/relay",
            displayName: "MacBook-Pro-di-Emanuele.local",
            lastResolvedSessionId: "recent-session",
            lastResolvedAt: Date().addingTimeInterval(-90),
            lastUsedAt: Date().addingTimeInterval(-80)
        )
        service.trustedMacRegistry.records[targetMacID] = target

        let removedCount = service.pruneOfflineTrustedMacRecords(matching: target)

        XCTAssertEqual(removedCount, 0)
        XCTAssertNotNil(service.trustedMacRegistry.records[targetMacID])
    }

    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.currentTrustedMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexTrustedMacSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeMessage(threadID: String, text: String) -> CodexMessage {
        CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: text
        )
    }
}
