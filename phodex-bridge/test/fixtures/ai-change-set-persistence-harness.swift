import Foundation

// Substitute the Keychain boundary so the real key provider can encounter a
// read/write outage without touching the developer's credentials.
nonisolated enum CodexSecureKeys {
    static let messageHistoryKey = "fixture-history-key"
}

nonisolated enum SecureStore {
    nonisolated(unsafe) static var available = false
    nonisolated(unsafe) private static var values: [String: Data] = [:]

    static func readData(for key: String) -> Data? {
        available ? values[key] : nil
    }

    static func addDataIfAbsent(_ data: Data, for key: String) {
        if available, values[key] == nil {
            values[key] = data
        }
    }
}

final class CodexService {
    let aiChangeSetPersistence = AIChangeSetPersistence()
    var canPersistAIChangeSets = false
    var includeLegacyAIChangeSetFallbackOnRetry = false
    var aiChangeSetsByID: [String: AIChangeSet] = [:]
    var aiChangeSetIDByTurnKey: [AIChangeSetTurnKey: String] = [:]
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:]

    func invalidateAssistantRevertStates() {}
}

@main
struct AIChangeSetPersistenceHarness {
    static func main() throws {
        let fileManager = FileManager.default
        let sandbox = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try require(support.resolvingSymlinksInPath().path.hasPrefix(sandbox.path + "/"), "application support is outside the temporary test home")
        let root = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.codexmobile.app")
            .appendingPathComponent("mac")
        let persistence = AIChangeSetPersistence()
        let record = makeChangeSet("existing")
        let sourceURL = ledgerURL(root, "source")
        let legacy = try JSONEncoder().encode([record])
        try fileManager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacy.write(to: sourceURL)

        try require(persistence.load(macDeviceId: "source") == [record], "legacy ledger is unreadable without the key")
        try require(!persistence.save([], macDeviceId: "source"), "key outage let a write overwrite the legacy ledger")
        try require(try Data(contentsOf: sourceURL) == legacy, "key outage modified plaintext on disk")
        try require(!persistence.save([record], macDeviceId: "missing"), "key outage allowed a fresh plaintext save")
        try require(!fileManager.fileExists(atPath: ledgerURL(root, "missing").path), "key outage left a new ledger on disk")

        SecureStore.available = true
        try require(persistence.load(macDeviceId: "source") == [record], "legacy migration lost records")
        let encrypted = try Data(contentsOf: sourceURL)
        try require(encrypted.range(of: Data(record.forwardUnifiedPatch.utf8)) == nil, "migrated patch text is visible on disk")
        try require(AIChangeSetPersistence().load(macDeviceId: "source") == [record], "migrated ledger did not round-trip")

        try exerciseReadRetry(persistence, ledgerURL(root, "retry"), encrypted, record)
        try exerciseSameTurnReadRetry(persistence, ledgerURL(root, "same-turn"))
        try exerciseFailedDeletion(persistence, sourceURL, record)
        print("AI change-set ledger recovery checks passed")
    }

    private static func exerciseReadRetry(
        _ persistence: AIChangeSetPersistence,
        _ url: URL,
        _ encrypted: Data,
        _ existing: AIChangeSet
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        try tampered.write(to: url)
        try require(persistence.load(macDeviceId: "retry") == nil, "tampered ciphertext was accepted")

        let service = CodexService()
        service.loadMacScopedAIChangeSets(for: "retry")
        let captured = makeChangeSet("new")
        service.aiChangeSetsByID[captured.id] = captured
        try require(!service.saveMacScopedAIChangeSets(for: "retry"), "save overwrote an unreadable ledger")
        try require(try Data(contentsOf: url) == tampered, "failed save changed the previous ledger")

        try encrypted.write(to: url)
        try require(service.saveMacScopedAIChangeSets(for: "retry"), "save did not retry on the same scope")
        let reloaded = persistence.load(macDeviceId: "retry") ?? []
        try require(Set(reloaded) == Set([existing, captured]), "recovery failed to preserve old and new changes")
        let turn = AIChangeSetTurnKey(threadId: existing.threadId, turnId: existing.turnId)!
        try require(service.aiChangeSetIDByTurnKey[turn] == existing.id, "recovery did not reindex the old change set")
    }

    private static func exerciseSameTurnReadRetry(_ persistence: AIChangeSetPersistence, _ url: URL) throws {
        let first = makePatchBatch("before", "middle")
        let second = makePatchBatch("middle", "after")
        let persisted = AIChangeSet(
            id: "older-uuid", threadId: "resumed-thread", turnId: "resumed-turn",
            source: .fileChangeFallback, forwardUnifiedPatch: first.forwardUnifiedPatch,
            fallbackPatchCount: 1, fallbackPatchBatches: [first]
        )
        let captured = AIChangeSet(
            id: "new-uuid", threadId: persisted.threadId, turnId: persisted.turnId,
            assistantMessageId: "answer", finalizedAt: Date(), status: .ready, source: .fileChangeFallback,
            forwardUnifiedPatch: second.forwardUnifiedPatch,
            fallbackPatchCount: 2, fallbackPatchBatches: [makePatchBatch("before", "middle"), second]
        )
        try require(persistence.save([persisted], macDeviceId: "same-turn"), "could not seed the early patch")
        let encrypted = try Data(contentsOf: url)
        try Data("unreadable ledger".utf8).write(to: url)

        let service = CodexService()
        service.loadMacScopedAIChangeSets(for: "same-turn")
        service.aiChangeSetsByID[captured.id] = captured
        try require(!service.saveMacScopedAIChangeSets(for: "same-turn"), "unreadable ledger was overwritten")

        try encrypted.write(to: url)
        try require(service.saveMacScopedAIChangeSets(for: "same-turn"), "same-turn recovery could not save")
        let reloaded = persistence.load(macDeviceId: "same-turn") ?? []
        try require(reloaded.count == 1, "same turn was persisted under two UUIDs")
        let reconciled = reloaded[0]
        try require(reconciled.fallbackPatchBatches == [first, second], "recovery lost, reordered, or duplicated patch batches")
        try require(reconciled.forwardUnifiedPatch == [first.forwardUnifiedPatch, second.forwardUnifiedPatch].joined(separator: "\n"),
                    "recovery did not rebuild the aggregate patch")
        let reversedPatch = [second.forwardUnifiedPatch, first.forwardUnifiedPatch].joined(separator: "\n")
        try require(reconciled.patchHash == AIUnifiedPatchParser.hash(for: reversedPatch),
                    "recovery changed the order of the revert payload")
        try require(reconciled.fallbackPatchCount == 2 && reconciled.fileChanges.first?.additions == 2,
                    "recovery did not rebuild the file-change summary")
        try require(reconciled.status == .ready, "a finalized, supported revert was no longer available")
        let turn = AIChangeSetTurnKey(threadId: persisted.threadId, turnId: persisted.turnId)!
        try require(service.aiChangeSetIDByTurnKey[turn] == reconciled.id
                    && service.aiChangeSetIDByAssistantMessageID["answer"] == reconciled.id,
                    "the turn and assistant row must both use the reconciled change set")
    }

    private static func makePatchBatch(_ before: String, _ after: String) -> AIPatchBatch {
        let patch = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -\(before)
        +\(after)
        """
        let analysis = AIUnifiedPatchParser.analyze(patch)
        return AIPatchBatch(
            forwardUnifiedPatch: patch,
            patchHash: AIUnifiedPatchParser.hash(for: patch),
            fileChanges: analysis.fileChanges,
            unsupportedReasons: analysis.unsupportedReasons
        )
    }

    private static func exerciseFailedDeletion(
        _ persistence: AIChangeSetPersistence,
        _ sourceURL: URL,
        _ record: AIChangeSet
    ) throws {
        let fileManager = FileManager.default
        let service = CodexService()
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: sourceURL.path)
        defer { try? fileManager.setAttributes([.immutable: false], ofItemAtPath: sourceURL.path) }

        let first = service.mergeMacScopedChangeSets(from: ["source"], to: "target")
        try require(first.changed && first.pending == ["source"], "failed source deletion cleared its pending identity")
        try require(persistence.load(macDeviceId: "source") == [record], "failed cleanup damaged the source ledger")
        try require(persistence.load(macDeviceId: "target") == [record], "source cleanup ran without a durable target")

        try fileManager.setAttributes([.immutable: false], ofItemAtPath: sourceURL.path)
        let retry = service.mergeMacScopedChangeSets(from: ["source"], to: "target")
        try require(retry.pending.isEmpty, "cleanup retry left a stale identity")
        try require(!fileManager.fileExists(atPath: sourceURL.path), "cleanup retry left the old ledger")
        try require(persistence.load(macDeviceId: "target") == [record], "cleanup retry lost the durable target")
    }

    private static func ledgerURL(_ root: URL, _ scope: String) -> URL {
        root.appendingPathComponent(scope).appendingPathComponent("codex-ai-change-sets-v1.json")
    }

    private static func makeChangeSet(_ id: String) -> AIChangeSet {
        AIChangeSet(
            id: id,
            threadId: "\(id)-thread",
            turnId: "turn",
            source: .turnDiff,
            forwardUnifiedPatch: "private patch bytes for \(id)"
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw NSError(domain: "AIChangeSetPersistenceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
