// FILE: CodexService+Pets.swift
// Purpose: Loads Codex-compatible local pet packages through the paired bridge.
// Layer: Service
// Exports: CodexService pet APIs, PetCompanionStatusSignature
// Depends on: CodexService, JSONValue, PetCompanion

import Foundation

struct PetCompanionStatusSignature: Equatable, Sendable {
    let isConnected: Bool
    let activeThreadId: String?
    let pendingApprovals: [String]
    let runningThreadIDs: [String]
    let protectedRunningThreadIDs: [String]
    let activeTurnThreadIDs: [String]
    let failedThreadIDs: [String]
    let readyThreadIDs: [String]
    let completionBanner: String?

    var hasRunningWork: Bool {
        !runningThreadIDs.isEmpty || !protectedRunningThreadIDs.isEmpty || !activeTurnThreadIDs.isEmpty
    }
}

extension CodexService {
    func listPets(includeData: Bool = false) async throws -> [PetCompanion] {
        let response = try await sendRequest(
            method: "pet/list",
            params: .object([
                "includeData": .bool(includeData),
                "metadataOnly": .bool(!includeData)
            ])
        )

        if let error = response.error {
            throw CodexServiceError.rpcError(error)
        }

        guard let result = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("The bridge returned an invalid pet list.")
        }

        let rawPets = result["avatars"]?.arrayValue ?? result["pets"]?.arrayValue ?? []
        return rawPets.compactMap { value in
            petCompanion(from: value, requiresSpritesheetData: includeData)
        }
    }

    func readPet(id: String) async throws -> PetCompanion {
        do {
            return try await readPetDirect(id: id)
        } catch {
            guard isUnsupportedPetReadError(error),
                  let fallbackPet = try await listPets(includeData: true).first(where: { $0.id == id }) else {
                throw error
            }

            return fallbackPet
        }
    }

    private func readPetDirect(id: String) async throws -> PetCompanion {
        let response = try await sendRequest(method: "pet/read", params: .object(["id": .string(id)]))
        if let error = response.error {
            throw CodexServiceError.rpcError(error)
        }

        guard let result = response.result,
              let pet = petCompanion(from: result, requiresSpritesheetData: true) else {
            throw CodexServiceError.invalidResponse("The bridge returned an invalid pet.")
        }

        return pet
    }

    private func isUnsupportedPetReadError(_ error: Error) -> Bool {
        guard case CodexServiceError.rpcError(let rpcError) = error else {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("unknown variant")
            || message.contains("unknown method")
            || message.contains("pet/read")
    }

    // Captures only pet-relevant observable state so the overlay does not subscribe to chat timelines.
    func petCompanionStatusSignature() -> PetCompanionStatusSignature {
        PetCompanionStatusSignature(
            isConnected: isConnected,
            activeThreadId: activeThreadId,
            pendingApprovals: pendingApprovals.map { "\($0.id):\($0.threadId ?? "")" }.sorted(),
            runningThreadIDs: runningThreadIDs.sorted(),
            protectedRunningThreadIDs: protectedRunningFallbackThreadIDs.sorted(),
            activeTurnThreadIDs: activeTurnIdByThread.keys.sorted(),
            failedThreadIDs: failedThreadIDs.sorted(),
            readyThreadIDs: readyThreadIDs.sorted(),
            completionBanner: threadCompletionBanner.map { "\($0.id.uuidString):\($0.threadId):\($0.title)" }
        )
    }

    func petCompanionStatusSnapshot() -> PetCompanionStatusSnapshot {
        if let approval = preferredPetApprovalRequest() {
            return PetCompanionStatusSnapshot(
                phase: .waiting,
                title: "Approval needed",
                detail: approval.threadId.map {
                    petProgressPrompt(for: $0, fallback: petThreadTitle(for: $0), prefersActivity: true)
                } ?? "Waiting for you"
            )
        }

        let runningThreadIDs = petRunningThreadIDs()
        if let threadId = preferredPetThreadID(from: runningThreadIDs) {
            return PetCompanionStatusSnapshot(
                phase: .running,
                title: runningThreadIDs.count > 1 ? "Working \(runningThreadIDs.count) chats" : "Working",
                detail: petProgressPrompt(for: threadId, fallback: petThreadTitle(for: threadId), prefersActivity: true)
            )
        }

        if let threadId = preferredPetThreadID(from: failedThreadIDs) {
            return PetCompanionStatusSnapshot(
                phase: .failed,
                title: "Needs a look",
                detail: petProgressPrompt(for: threadId, fallback: petThreadTitle(for: threadId))
            )
        }

        if let banner = threadCompletionBanner {
            return PetCompanionStatusSnapshot(phase: .review, title: "Done", detail: banner.title)
        }

        if let threadId = preferredPetThreadID(from: readyThreadIDs) {
            return PetCompanionStatusSnapshot(
                phase: .review,
                title: "Done",
                detail: petProgressPrompt(for: threadId, fallback: petThreadTitle(for: threadId))
            )
        }

        return .idle
    }

    func petProgressPrompt(for threadId: String, fallback: String, prefersActivity: Bool = false) -> String {
        let recentMessages = (messagesByThread[threadId] ?? []).suffix(12).reversed()
        for message in recentMessages {
            guard message.role != .user else {
                continue
            }
            if prefersActivity, message.kind == .chat, !message.isStreaming {
                continue
            }

            if let prompt = petPrompt(from: message) {
                return prompt
            }
        }

        if !prefersActivity,
           let cached = latestAssistantOutputByThread[threadId],
           let prompt = sanitizedPetPrompt(cached) {
            return prompt
        }

        return fallback
    }

    private func petCompanion(from value: JSONValue, requiresSpritesheetData: Bool) -> PetCompanion? {
        guard let object = value.objectValue else {
            return nil
        }

        guard let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              let displayName = object["displayName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return nil
        }

        let dataURL = object["spritesheetDataUrl"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresSpritesheetData && (dataURL?.isEmpty ?? true) {
            return nil
        }

        return PetCompanion(
            id: id,
            folderName: object["folderName"]?.stringValue ?? id,
            displayName: displayName,
            description: object["description"]?.stringValue,
            spritesheetDataURL: dataURL,
            spritesheetMimeType: object["spritesheetMimeType"]?.stringValue,
            spritesheetByteLength: object["spritesheetByteLength"]?.intValue
        )
    }

    private func petPrompt(from message: CodexMessage) -> String? {
        switch message.kind {
        case .commandExecution:
            return message.isStreaming ? "Running command" : "Ran command"
        case .fileChange:
            return message.isStreaming ? "Editing files" : "Edited files"
        case .toolActivity:
            if let prompt = sanitizedPetPrompt(message.text) {
                return prompt
            }
            return message.isStreaming ? "Using a tool" : "Used a tool"
        case .thinking:
            return sanitizedPetPrompt(message.text) ?? "Thinking"
        case .userInputPrompt:
            return "Waiting for you"
        case .plan:
            return sanitizedPetPrompt(message.text) ?? "Planning"
        case .subagentAction:
            return sanitizedPetPrompt(message.text) ?? "Working with an agent"
        case .chat:
            return sanitizedPetPrompt(message.text)
        }
    }

    private func sanitizedPetPrompt(_ rawText: String) -> String? {
        let trimmed = rawText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.count <= 52 {
            return trimmed
        }

        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 49)
        return String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func preferredPetApprovalRequest() -> CodexApprovalRequest? {
        if let activeThreadId,
           let activeApproval = pendingApprovals.first(where: { $0.threadId == activeThreadId }) {
            return activeApproval
        }
        return pendingApprovals.first
    }

    private func petRunningThreadIDs() -> Set<String> {
        runningThreadIDs
            .union(protectedRunningFallbackThreadIDs)
            .union(Set(activeTurnIdByThread.keys))
    }

    private func preferredPetThreadID(from candidates: Set<String>) -> String? {
        guard !candidates.isEmpty else {
            return nil
        }
        if let activeThreadId, candidates.contains(activeThreadId) {
            return activeThreadId
        }
        return threads.first(where: { candidates.contains($0.id) })?.id
            ?? candidates.sorted().first
    }

    private func petThreadTitle(for threadId: String) -> String {
        let title = thread(for: threadId)?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return "Chat"
        }
        return title
    }
}
