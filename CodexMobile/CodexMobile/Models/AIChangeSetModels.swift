// FILE: AIChangeSetModels.swift
// Purpose: Models assistant-scoped code change sets and revert preview/apply results.
// Layer: Model
// Exports: AIChangeSet, AIFileChange, RevertPreviewResult, RevertApplyResult,
//   AssistantRevertRiskLevel, AssistantRevertPresentation
// Depends on: Foundation, CryptoKit

import Foundation
import CryptoKit

enum AIFileChangeKind: String, Codable, Hashable, Sendable {
    case create
    case update
    case delete
}

struct AIFileChange: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }

    let path: String
    let kind: AIFileChangeKind
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isRenameOrModeOnly: Bool
    let beforeContentHash: String?
    let afterContentHash: String?
}

enum AIChangeSetStatus: String, Codable, Hashable, Sendable {
    case collecting
    case ready
    case reverted
    case failed
    case notRevertable = "not_revertable"
}

enum AIChangeSetSource: String, Codable, Hashable, Sendable {
    case turnDiff = "turnDiff"
    case fileChangeFallback = "fileChangeFallback"
}

struct AIRevertMetadata: Codable, Hashable, Sendable {
    var revertedAt: Date?
    var revertAttemptedAt: Date?
    var lastRevertError: String?

    init(
        revertedAt: Date? = nil,
        revertAttemptedAt: Date? = nil,
        lastRevertError: String? = nil
    ) {
        self.revertedAt = revertedAt
        self.revertAttemptedAt = revertAttemptedAt
        self.lastRevertError = lastRevertError
    }
}

struct AIChangeSet: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var repoRoot: String?
    var threadId: String
    var turnId: String
    var assistantMessageId: String?
    var createdAt: Date
    var finalizedAt: Date?
    var status: AIChangeSetStatus
    var source: AIChangeSetSource
    var forwardUnifiedPatch: String
    var inverseUnifiedPatch: String?
    var patchHash: String
    var fileChanges: [AIFileChange]
    var unsupportedReasons: [String]
    var revertMetadata: AIRevertMetadata
    var fallbackPatchCount: Int

    init(
        id: String = UUID().uuidString,
        repoRoot: String? = nil,
        threadId: String,
        turnId: String,
        assistantMessageId: String? = nil,
        createdAt: Date = Date(),
        finalizedAt: Date? = nil,
        status: AIChangeSetStatus = .collecting,
        source: AIChangeSetSource,
        forwardUnifiedPatch: String = "",
        inverseUnifiedPatch: String? = nil,
        patchHash: String = "",
        fileChanges: [AIFileChange] = [],
        unsupportedReasons: [String] = [],
        revertMetadata: AIRevertMetadata = AIRevertMetadata(),
        fallbackPatchCount: Int = 0
    ) {
        self.id = id
        self.repoRoot = repoRoot
        self.threadId = threadId
        self.turnId = turnId
        self.assistantMessageId = assistantMessageId
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
        self.status = status
        self.source = source
        self.forwardUnifiedPatch = forwardUnifiedPatch
        self.inverseUnifiedPatch = inverseUnifiedPatch
        self.patchHash = patchHash
        self.fileChanges = fileChanges
        self.unsupportedReasons = unsupportedReasons
        self.revertMetadata = revertMetadata
        self.fallbackPatchCount = fallbackPatchCount
    }
}

struct RevertConflict: Codable, Hashable, Sendable {
    let path: String
    let message: String
}

struct RevertPreviewResult: Sendable, Hashable {
    let canRevert: Bool
    let affectedFiles: [String]
    let conflicts: [RevertConflict]
    let unsupportedReasons: [String]
    let stagedFiles: [String]

    init(
        canRevert: Bool,
        affectedFiles: [String],
        conflicts: [RevertConflict],
        unsupportedReasons: [String],
        stagedFiles: [String]
    ) {
        self.canRevert = canRevert
        self.affectedFiles = affectedFiles
        self.conflicts = conflicts
        self.unsupportedReasons = unsupportedReasons
        self.stagedFiles = stagedFiles
    }

    init(from json: [String: JSONValue]) {
        self.canRevert = json["canRevert"]?.boolValue ?? false
        self.affectedFiles = json["affectedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.conflicts = json["conflicts"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return RevertConflict(
                path: object["path"]?.stringValue ?? "unknown",
                message: object["message"]?.stringValue ?? "Patch conflict."
            )
        } ?? []
        self.unsupportedReasons = json["unsupportedReasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.stagedFiles = json["stagedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct RevertApplyResult: Sendable {
    let success: Bool
    let revertedFiles: [String]
    let conflicts: [RevertConflict]
    let unsupportedReasons: [String]
    let stagedFiles: [String]
    let status: GitRepoSyncResult?

    init(
        success: Bool,
        revertedFiles: [String],
        conflicts: [RevertConflict],
        unsupportedReasons: [String],
        stagedFiles: [String],
        status: GitRepoSyncResult?
    ) {
        self.success = success
        self.revertedFiles = revertedFiles
        self.conflicts = conflicts
        self.unsupportedReasons = unsupportedReasons
        self.stagedFiles = stagedFiles
        self.status = status
    }

    init(from json: [String: JSONValue]) {
        self.success = json["success"]?.boolValue ?? false
        self.revertedFiles = json["revertedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.conflicts = json["conflicts"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return RevertConflict(
                path: object["path"]?.stringValue ?? "unknown",
                message: object["message"]?.stringValue ?? "Patch conflict."
            )
        } ?? []
        self.unsupportedReasons = json["unsupportedReasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.stagedFiles = json["stagedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let statusObject = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObject)
        } else {
            self.status = nil
        }
    }
}

enum AssistantRevertRiskLevel: String, Equatable, Hashable, Sendable {
    case safe
    case warning
    case blocked
}

struct AssistantRevertPresentation: Equatable, Hashable, Sendable {
    let title: String
    let isEnabled: Bool
    let helperText: String?
    let riskLevel: AssistantRevertRiskLevel
    let warningText: String?
    let overlappingFiles: [String]

    init(
        title: String,
        isEnabled: Bool,
        helperText: String?,
        riskLevel: AssistantRevertRiskLevel = .safe,
        warningText: String? = nil,
        overlappingFiles: [String] = []
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.helperText = helperText
        self.riskLevel = riskLevel
        self.warningText = warningText
        self.overlappingFiles = overlappingFiles
    }
}

struct AIUnifiedPatchAnalysis: Hashable, Sendable {
    let fileChanges: [AIFileChange]
    let unsupportedReasons: [String]

    var affectedFiles: [String] {
        fileChanges.map(\.path)
    }

    var totalAdditions: Int {
        fileChanges.reduce(0) { $0 + $1.additions }
    }

    var totalDeletions: Int {
        fileChanges.reduce(0) { $0 + $1.deletions }
    }
}

enum AIUnifiedPatchParser {
    // Parses a unified patch into per-file summaries and flags unsupported metadata-only changes.
    static func analyze(_ rawPatch: String) -> AIUnifiedPatchAnalysis {
        let patch = rawPatch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !patch.isEmpty else {
            return AIUnifiedPatchAnalysis(fileChanges: [], unsupportedReasons: ["No exact patch was captured."])
        }

        let chunks = splitIntoChunks(patch)
        guard !chunks.isEmpty else {
            return AIUnifiedPatchAnalysis(fileChanges: [], unsupportedReasons: ["No exact patch was captured."])
        }

        var fileChanges: [AIFileChange] = []
        var unsupportedReasons: Set<String> = []

        for chunk in chunks {
            let analysis = analyzeChunk(chunk)
            if let fileChange = analysis.fileChange {
                fileChanges.append(fileChange)
            }
            unsupportedReasons.formUnion(analysis.unsupportedReasons)
        }

        if fileChanges.isEmpty {
            unsupportedReasons.insert("This response cannot be auto-reverted because no exact patch was captured.")
        }

        return AIUnifiedPatchAnalysis(
            fileChanges: fileChanges,
            unsupportedReasons: Array(unsupportedReasons).sorted()
        )
    }

    static func hash(for rawPatch: String) -> String {
        let digest = SHA256.hash(data: Data(rawPatch.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func splitIntoChunks(_ patch: String) -> [[String]] {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var chunks: [[String]] = []
        var current: [String] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = []
        }

        for line in lines {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                flushCurrent()
            }
            current.append(line)
        }

        flushCurrent()
        return chunks
    }

    private static func analyzeChunk(_ lines: [String]) -> (fileChange: AIFileChange?, unsupportedReasons: Set<String>) {
        guard !lines.isEmpty else {
            return (nil, [])
        }

        let path = extractPath(from: lines)
        let isBinary = lines.contains { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }
        let isRenameOrModeOnly = lines.contains {
            $0.hasPrefix("rename from ")
                || $0.hasPrefix("rename to ")
                || $0.hasPrefix("copy from ")
                || $0.hasPrefix("copy to ")
                || $0.hasPrefix("old mode ")
                || $0.hasPrefix("new mode ")
                || $0.hasPrefix("new file mode 120")
                || $0.hasPrefix("deleted file mode 120")
                || $0.hasPrefix("similarity index ")
        }

        let isCreate = lines.contains("new file mode 100644")
            || lines.contains("new file mode 100755")
            || lines.contains("--- /dev/null")
        let isDelete = lines.contains("deleted file mode 100644")
            || lines.contains("deleted file mode 100755")
            || lines.contains("+++ /dev/null")

        var additions = 0
        var deletions = 0
        for line in lines {
            guard let first = line.first else { continue }
            if first == "+", !line.hasPrefix("+++") {
                additions += 1
            } else if first == "-", !line.hasPrefix("---") {
                deletions += 1
            }
        }

        var unsupportedReasons: Set<String> = []
        if isBinary {
            unsupportedReasons.insert("Binary changes are not auto-revertable in v1.")
        }
        if isRenameOrModeOnly {
            unsupportedReasons.insert("Rename, mode-only, or symlink changes are not auto-revertable in v1.")
        }

        let kind: AIFileChangeKind = isCreate ? .create : (isDelete ? .delete : .update)
        let hasPatchBody = additions > 0 || deletions > 0 || isCreate || isDelete
        guard !path.isEmpty, hasPatchBody else {
            if !isBinary && !isRenameOrModeOnly {
                unsupportedReasons.insert("This response cannot be auto-reverted because no exact patch was captured.")
            }
            return (nil, unsupportedReasons)
        }

        return (
            AIFileChange(
                path: path,
                kind: kind,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary,
                isRenameOrModeOnly: isRenameOrModeOnly,
                beforeContentHash: nil,
                afterContentHash: nil
            ),
            unsupportedReasons
        )
    }

    private static func extractPath(from lines: [String]) -> String {
        for line in lines {
            if line.hasPrefix("+++ ") {
                let rawPath = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = normalizeDiffPath(rawPath)
                if !normalized.isEmpty, normalized != "/dev/null" {
                    return normalized
                }
            }
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                let components = line.split(separator: " ", omittingEmptySubsequences: true)
                if components.count >= 4 {
                    let normalized = normalizeDiffPath(String(components[3]))
                    if !normalized.isEmpty {
                        return normalized
                    }
                }
            }
        }

        return ""
    }

    private static func normalizeDiffPath(_ rawPath: String) -> String {
        var value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value
    }
}
