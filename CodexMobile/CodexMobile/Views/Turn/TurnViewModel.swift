// FILE: TurnViewModel.swift
// Purpose: Owns local TurnView state and user actions while keeping UI components lightweight.
// Layer: View Model
// Exports: TurnViewModel, TurnComposerSendAvailability, TurnComposerAttachmentIntakePlan
// Depends on: SwiftUI, Observation, PhotosUI, CodexService

import SwiftUI
import Observation
import PhotosUI

struct TurnComposerSendAvailability {
    let isSending: Bool
    let isConnected: Bool
    let trimmedInput: String
    let hasReadyImages: Bool
    let hasBlockingAttachmentState: Bool
    let hasReviewSelection: Bool
    let hasPendingReviewSelection: Bool

    // Evaluates whether sending is allowed for the current composer state.
    var isSendDisabled: Bool {
        isSending
            || !isConnected
            || hasPendingReviewSelection
            || (trimmedInput.isEmpty && !hasReadyImages && !hasReviewSelection)
            || hasBlockingAttachmentState
    }
}

struct TurnComposerAttachmentIntakePlan {
    let acceptedCount: Int
    let droppedCount: Int

    var hasOverflow: Bool {
        droppedCount > 0
    }

    // Computes how many picker items can be accepted without exceeding attachment slots.
    static func make(requestedCount: Int, remainingSlots: Int) -> TurnComposerAttachmentIntakePlan {
        let safeRequestedCount = max(0, requestedCount)
        let safeRemainingSlots = max(0, remainingSlots)
        let acceptedCount = min(safeRequestedCount, safeRemainingSlots)
        let droppedCount = safeRequestedCount - acceptedCount
        return TurnComposerAttachmentIntakePlan(acceptedCount: acceptedCount, droppedCount: droppedCount)
    }
}

struct QueuedTurnDraft: Identifiable {
    let id: String
    let text: String
    let attachments: [CodexImageAttachment]
    let skillMentions: [CodexTurnSkillMention]
    let createdAt: Date
}

enum QueuePauseState: Equatable {
    case active
    case paused(errorMessage: String)
}

@MainActor
@Observable
final class TurnViewModel {
    // Preserves the exact composer payload + raw chips so stale-busy recovery can retry cleanly.
    private struct PendingTurnSend {
        let payload: String
        let attachments: [CodexImageAttachment]
        let skillMentions: [CodexTurnSkillMention]
        let collaborationMode: CodexCollaborationModeKind?
        let rawInput: String
        let rawFileMentions: [TurnComposerMentionedFile]
        let rawSkillMentions: [TurnComposerMentionedSkill]
        let rawAttachments: [TurnComposerImageAttachment]
        let rawReviewSelection: TurnComposerReviewSelection?
    }

    // Splits contiguous filename segments into search-friendly word chunks.
    private static let fileMentionSegmentRegex = try? NSRegularExpression(
        pattern: #"[A-Z]+(?=$|[A-Z][a-z]|\d)|[A-Z]?[a-z]+|\d+"#
    )

    var input = ""
    var isSending = false
    var isHandlingApproval = false
    var isPlanModeArmed = false
    var steeringDraftID: String?
    var shouldAnchorToAssistantResponse = false
    var isScrolledToBottom = true
    var isPhotoPickerPresented = false
    var isCameraPresented = false
    var photoPickerItems: [PhotosPickerItem] = []
    var composerAttachments: [TurnComposerImageAttachment] = []
    var composerMentionedFiles: [TurnComposerMentionedFile] = []
    var composerMentionedSkills: [TurnComposerMentionedSkill] = []
    var composerReviewSelection: TurnComposerReviewSelection?
    var fileAutocompleteItems: [CodexFuzzyFileMatch] = []
    var isFileAutocompleteVisible = false
    var isFileAutocompleteLoading = false
    var fileAutocompleteQuery = ""
    var skillAutocompleteItems: [CodexSkillMetadata] = []
    var isSkillAutocompleteVisible = false
    var isSkillAutocompleteLoading = false
    var skillAutocompleteQuery = ""
    var slashCommandPanelState: TurnComposerSlashCommandPanelState = .hidden
    // MARK: - Git state

    var runningGitAction: TurnGitActionKind? = nil
    var isRunningGitAction: Bool { runningGitAction != nil }
    var isShowingNothingToCommitAlert = false
    var gitSyncAlert: TurnGitSyncAlert? = nil
    var isLoadingGitBranchTargets = false
    var isSwitchingGitBranch = false
    var selectedGitBaseBranch = ""
    var currentGitBranch = ""
    var availableGitBranchTargets: [String] = []
    var gitDefaultBranch = ""
    var gitRepoSync: GitRepoSyncResult? = nil
    var gitSyncState: String? { gitRepoSync?.state }
    var shouldShowDiscardRuntimeChangesAndSync: Bool {
        guard let sync = gitRepoSync else { return false }
        let dangerousStates = ["dirty", "dirty_and_behind", "diverged"]
        return dangerousStates.contains(sync.state) || (sync.isDirty && sync.state == "no_upstream")
    }

    // Keeps git mutations scoped to an idle, explicitly bound local repo.
    func canRunGitAction(
        isConnected: Bool,
        isThreadRunning: Bool,
        hasGitWorkingDirectory: Bool
    ) -> Bool {
        isConnected
            && hasGitWorkingDirectory
            && !isThreadRunning
            && !isRunningGitAction
            && !isSwitchingGitBranch
    }

    // Cached projected timeline to avoid re-running TurnTimelineReducer on every SwiftUI evaluation.
    var projectedMessages: [CodexMessage] = []
    @ObservationIgnored private var threadActivationTask: Task<Void, Never>?

    @ObservationIgnored var fileAutocompleteDebounceTask: Task<Void, Never>?
    @ObservationIgnored var skillAutocompleteDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var gitStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var cachedSkillSearchIndexByRoot: [String: [TurnSkillSearchIndexEntry]] = [:]
    @ObservationIgnored var unsupportedSkillsAutocompleteRoots: Set<String> = []

    let maxComposerImages = 4
    let maxFileAutocompleteItems = 6
    let maxSkillAutocompleteItems = 6
    private let fileAutocompleteDebounceNanoseconds: UInt64 = 180_000_000
    private let skillAutocompleteDebounceNanoseconds: UInt64 = 180_000_000
    private let gitStatusRefreshDebounceNanoseconds: UInt64 = 350_000_000

    init() {}

    // MARK: - Cached Timeline Projection

    @ObservationIgnored private var lastProjectedThreadID: String?
    @ObservationIgnored private var lastProjectionChangeToken: Int = -1

    func updateProjectedTimeline(threadID: String, messages: [CodexMessage], changeToken: Int) {
        guard threadID != lastProjectedThreadID || changeToken != lastProjectionChangeToken else { return }
        lastProjectedThreadID = threadID
        lastProjectionChangeToken = changeToken
        projectedMessages = TurnTimelineReducer.project(messages: messages).messages
    }

    // MARK: - Cancellable Thread Activation

    func cancelThreadActivation() { threadActivationTask?.cancel() }

    func activateThread(threadID: String, codex: CodexService, onComplete: @escaping () -> Void) {
        threadActivationTask?.cancel()
        threadActivationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await codex.prepareThreadForDisplay(threadId: threadID)
            guard !Task.isCancelled else { return }
            self?.flushQueueIfPossible(codex: codex, threadID: threadID)
            onComplete()
        }
    }

    // Normalized composer input reused by send validation and turn creation.
    var trimmedComposerInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Any loading/failed attachment must block send to avoid partial payloads.
    var hasBlockingAttachmentState: Bool {
        composerAttachments.contains(where: { $0.state == .loading || $0.state == .failed })
    }

    var readyComposerAttachments: [CodexImageAttachment] {
        composerAttachments.compactMap { attachment in
            if case .ready(let value) = attachment.state {
                return value
            }
            return nil
        }
    }

    var hasReadyImages: Bool {
        !readyComposerAttachments.isEmpty
    }

    var hasComposerReviewSelection: Bool {
        composerReviewSelection?.target != nil
    }

    var hasPendingComposerReviewSelection: Bool {
        composerReviewSelection != nil && composerReviewSelection?.target == nil
    }

    var hasComposerContentConflictingWithReview: Bool {
        TurnComposerCommandLogic.hasContentConflictingWithReview(
            trimmedInput: trimmedComposerInput,
            mentionedFileCount: composerMentionedFiles.count,
            mentionedSkillCount: composerMentionedSkills.count,
            attachmentCount: composerAttachments.count
        )
    }

    var remainingAttachmentSlots: Int {
        max(0, maxComposerImages - composerAttachments.count)
    }

    func queuedCount(codex: CodexService, threadID: String) -> Int {
        queuedDrafts(codex: codex, threadID: threadID).count
    }

    func isQueuePaused(codex: CodexService, threadID: String) -> Bool {
        if case .paused = queuePauseState(codex: codex, threadID: threadID) {
            return true
        }
        return false
    }

    func queuedDraftsList(codex: CodexService, threadID: String) -> [QueuedTurnDraft] {
        queuedDrafts(codex: codex, threadID: threadID)
    }

    func removeQueuedDraft(id: String, codex: CodexService, threadID: String) {
        var drafts = queuedDrafts(codex: codex, threadID: threadID)
        drafts.removeAll { $0.id == id }
        setQueuedDrafts(drafts, codex: codex, threadID: threadID)
    }

    func isSteeringQueuedDraft(_ draftID: String) -> Bool {
        steeringDraftID == draftID
    }

    func queuePauseMessage(codex: CodexService, threadID: String) -> String? {
        if case .paused(let errorMessage) = queuePauseState(codex: codex, threadID: threadID) {
            return errorMessage
        }
        return nil
    }

    func isComposerInteractionLocked(activeTurnID: String?) -> Bool {
        _ = activeTurnID
        return isSending
    }

    func isSendDisabled(isConnected: Bool, activeTurnID: String?) -> Bool {
        _ = activeTurnID
        return TurnComposerSendAvailability(
            isSending: isSending,
            isConnected: isConnected,
            trimmedInput: trimmedComposerInput,
            hasReadyImages: hasReadyImages,
            hasBlockingAttachmentState: hasBlockingAttachmentState,
            hasReviewSelection: hasComposerReviewSelection,
            hasPendingReviewSelection: hasPendingComposerReviewSelection
        ).isSendDisabled
    }

    func clearComposer() {
        resetFileAutocompleteState()
        resetSkillAutocompleteState()
        resetSlashCommandState(clearPendingSelection: true, clearConfirmedSelection: true)
        input = ""
        composerAttachments.removeAll()
        composerMentionedFiles.removeAll()
        composerMentionedSkills.removeAll()
    }

    func setPlanModeArmed(_ isArmed: Bool) {
        isPlanModeArmed = isArmed
    }

    func clearFileAutocomplete() {
        resetFileAutocompleteState()
    }

    func clearSkillAutocomplete() {
        resetSkillAutocompleteState()
    }

    func clearComposerAutocomplete() {
        resetFileAutocompleteState()
        resetSkillAutocompleteState()
        resetSlashCommandState(clearPendingSelection: true)
    }

    func removeComposerAttachment(id: String) {
        composerAttachments.removeAll(where: { $0.id == id })
    }

    // Debounces server-side fuzzy search when input ends with a valid `@query` token.
    func onInputChangedForFileAutocomplete(
        _ text: String,
        codex: CodexService,
        thread: CodexThread,
        activeTurnID: String?
    ) {
        guard !isComposerInteractionLocked(activeTurnID: activeTurnID),
              codex.isConnected,
              let root = normalizedAutocompleteRoot(for: thread),
              let token = Self.trailingFileAutocompleteToken(in: text) else {
            resetFileAutocompleteState()
            return
        }

        // Keep one autocomplete namespace visible at a time.
        resetSkillAutocompleteState()
        resetSlashCommandState(clearPendingSelection: true)

        let query = token.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            fileAutocompleteDebounceTask?.cancel()
            fileAutocompleteDebounceTask = nil
            fileAutocompleteItems = []
            fileAutocompleteQuery = query
            isFileAutocompleteLoading = false
            isFileAutocompleteVisible = false
            return
        }

        fileAutocompleteQuery = query
        isFileAutocompleteVisible = true
        isFileAutocompleteLoading = true
        fileAutocompleteDebounceTask?.cancel()

        let searchRoots = [root]
        let expectedQuery = query
        let cancellationToken = fileAutocompleteCancellationToken(for: thread.id)

        fileAutocompleteDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: fileAutocompleteDebounceNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            do {
                let matches = try await codex.fuzzyFileSearch(
                    query: expectedQuery,
                    roots: searchRoots,
                    cancellationToken: cancellationToken
                )
                guard !Task.isCancelled else { return }

                // Drops stale responses if the user already typed another query.
                guard self.fileAutocompleteQuery == expectedQuery else { return }

                self.fileAutocompleteItems = Array(matches.prefix(self.maxFileAutocompleteItems))
                self.isFileAutocompleteLoading = false
                self.isFileAutocompleteVisible = true
            } catch {
                guard self.fileAutocompleteQuery == expectedQuery else { return }
                self.fileAutocompleteItems = []
                self.isFileAutocompleteLoading = false
                self.isFileAutocompleteVisible = false
            }
        }
    }

    // Debounces skill suggestions when input ends with a valid `$query` token.
    func onInputChangedForSkillAutocomplete(
        _ text: String,
        codex: CodexService,
        thread: CodexThread,
        activeTurnID: String?
    ) {
        guard !isComposerInteractionLocked(activeTurnID: activeTurnID),
              codex.isConnected,
              let root = normalizedAutocompleteRoot(for: thread),
              let token = Self.trailingSkillAutocompleteToken(in: text) else {
            resetSkillAutocompleteState()
            return
        }

        // Keep one autocomplete namespace visible at a time.
        resetFileAutocompleteState()
        resetSlashCommandState(clearPendingSelection: true)

        let query = token.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            skillAutocompleteDebounceTask?.cancel()
            skillAutocompleteDebounceTask = nil
            skillAutocompleteItems = []
            skillAutocompleteQuery = query
            isSkillAutocompleteLoading = false
            isSkillAutocompleteVisible = false
            return
        }

        let normalizedRoot = root
        skillAutocompleteQuery = query
        isSkillAutocompleteVisible = true
        let hasCachedSkillIndex = cachedSkillSearchIndexByRoot[normalizedRoot] != nil
        let rootIsUnsupported = unsupportedSkillsAutocompleteRoots.contains(normalizedRoot)
        isSkillAutocompleteLoading = !hasCachedSkillIndex && !rootIsUnsupported
        skillAutocompleteDebounceTask?.cancel()

        let expectedQuery = query

        skillAutocompleteDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: skillAutocompleteDebounceNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            do {
                if unsupportedSkillsAutocompleteRoots.contains(normalizedRoot),
                   cachedSkillSearchIndexByRoot[normalizedRoot] == nil {
                    guard self.skillAutocompleteQuery == expectedQuery else { return }
                    self.skillAutocompleteItems = []
                    self.isSkillAutocompleteLoading = false
                    self.isSkillAutocompleteVisible = false
                    return
                }

                let indexedSkills: [TurnSkillSearchIndexEntry]
                if let cachedIndex = self.cachedSkillSearchIndexByRoot[normalizedRoot] {
                    indexedSkills = cachedIndex
                } else {
                    let listedSkills = try await codex.listSkills(cwds: [normalizedRoot], forceReload: false)
                    guard !Task.isCancelled else { return }
                    indexedSkills = listedSkills
                        .filter { $0.enabled }
                        .map(TurnSkillSearchIndexEntry.init(skill:))
                    self.cachedSkillSearchIndexByRoot[normalizedRoot] = indexedSkills
                }

                guard !Task.isCancelled else { return }
                guard self.skillAutocompleteQuery == expectedQuery else { return }

                self.skillAutocompleteItems = self.filteredSkillAutocompleteItems(
                    for: expectedQuery,
                    indexedSkills: indexedSkills
                )
                self.isSkillAutocompleteLoading = false
                self.isSkillAutocompleteVisible = true
            } catch {
                guard self.skillAutocompleteQuery == expectedQuery else { return }

                if Self.isMethodNotFoundRPCError(error) {
                    self.unsupportedSkillsAutocompleteRoots.insert(normalizedRoot)
                }

                self.skillAutocompleteItems = []
                self.isSkillAutocompleteLoading = false
                self.isSkillAutocompleteVisible = false
            }
        }
    }

    // Replaces `@query` with `@filename` in text and adds chip above input.
    func onSelectFileAutocomplete(_ item: CodexFuzzyFileMatch) {
        clearComposerReviewSelectionIfNeededForNonReviewContent()

        let fullPath = item.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? item.fileName
            : item.path

        // Replace @query with @filename inline in the text.
        if let updatedInput = Self.replacingTrailingFileAutocompleteToken(
            in: input, with: item.fileName
        ) {
            input = updatedInput
        }

        if !composerMentionedFiles.contains(where: { $0.path == fullPath }) {
            composerMentionedFiles.append(
                TurnComposerMentionedFile(fileName: item.fileName, path: fullPath)
            )
        }
        resetFileAutocompleteState()
    }

    // Replaces `$query` with `$skill` and stores the selected skill mention for turn/start.
    func onSelectSkillAutocomplete(_ skill: CodexSkillMetadata) {
        clearComposerReviewSelectionIfNeededForNonReviewContent()

        let normalizedSkillName = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSkillName.isEmpty else {
            resetSkillAutocompleteState()
            return
        }

        if let updatedInput = Self.replacingTrailingSkillAutocompleteToken(
            in: input, with: normalizedSkillName
        ) {
            input = updatedInput
        }

        let normalizedPath = skill.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composerMentionedSkills.contains(where: { $0.name.caseInsensitiveCompare(normalizedSkillName) == .orderedSame }) {
            composerMentionedSkills.append(
                TurnComposerMentionedSkill(
                    name: normalizedSkillName,
                    path: (normalizedPath?.isEmpty == false) ? normalizedPath : nil,
                    description: skill.description
                )
            )
        }

        resetSkillAutocompleteState()
    }

    // Keeps `/` command discovery separate from @/$ autocomplete while supporting a bare trailing slash.
    func onInputChangedForSlashCommandAutocomplete(
        _ text: String,
        activeTurnID: String?
    ) {
        clearComposerReviewSelectionIfNeededForInput(text)

        guard !isComposerInteractionLocked(activeTurnID: activeTurnID) else {
            resetSlashCommandState(clearPendingSelection: true)
            return
        }

        if case .codeReviewTargets = slashCommandPanelState {
            return
        }

        guard let token = Self.trailingSlashCommandToken(in: text) else {
            if case .commands = slashCommandPanelState {
                resetSlashCommandState()
            }
            return
        }

        resetFileAutocompleteState()
        resetSkillAutocompleteState()
        slashCommandPanelState = .commands(query: token.query)
    }

    // Turns the selected slash command into an inline composer flow instead of injecting plain text.
    func onSelectSlashCommand(_ command: TurnComposerSlashCommand) {
        removeTrailingSlashCommandTokenFromInputIfNeeded()

        switch command {
        case .codeReview:
            armCodeReviewSelection(command: command, target: nil)
        case .status:
            resetSlashCommandState(clearPendingSelection: true)
        }
    }

    func onSelectCodeReviewTarget(_ target: TurnComposerReviewTarget) {
        removeTrailingSlashCommandTokenFromInputIfNeeded()
        armCodeReviewSelection(command: .codeReview, target: target)
    }

    func clearComposerReviewSelection() {
        composerReviewSelection = nil
        resetSlashCommandState()
    }

    func removeMentionedFile(id: String) {
        if let mention = composerMentionedFiles.first(where: { $0.id == id }) {
            let ambiguousKeys = Self.ambiguousFileNameAliasKeys(in: composerMentionedFiles)
            let collisionKey = Self.fileNameAliasCollisionKey(for: mention.fileName)
            let allowFileNameAliases = collisionKey.map { !ambiguousKeys.contains($0) } ?? true
            input = Self.removingFileMentionAliases(
                for: mention,
                from: input,
                allowFileNameAliases: allowFileNameAliases
            )
        }
        composerMentionedFiles.removeAll(where: { $0.id == id })
    }

    func removeMentionedSkill(id: String) {
        if let mention = composerMentionedSkills.first(where: { $0.id == id }) {
            input = Self.removeBoundedToken("$\(mention.name)", from: input)
        }
        composerMentionedSkills.removeAll(where: { $0.id == id })
    }

    func openCamera(codex: CodexService) {
        guard remainingAttachmentSlots > 0 else {
            codex.lastErrorMessage = "You can attach up to \(maxComposerImages) images per message."
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            codex.lastErrorMessage = "Camera is not available on this device."
            return
        }
        isCameraPresented = true
    }

    func enqueueCapturedImageData(_ data: Data, codex: CodexService) {
        enqueuePastedImageData([data], codex: codex)
    }

    func openPhotoLibraryPicker(codex: CodexService) {
        guard remainingAttachmentSlots > 0 else {
            codex.lastErrorMessage = "You can attach up to \(maxComposerImages) images per message."
            return
        }

        isPhotoPickerPresented = true
    }

    // Converts the picker results into loading slots and async image pipeline jobs.
    func enqueuePhotoPickerItems(_ items: [PhotosPickerItem], codex: CodexService) {
        guard !items.isEmpty else {
            return
        }

        let intakePlan = TurnComposerAttachmentIntakePlan.make(
            requestedCount: items.count,
            remainingSlots: remainingAttachmentSlots
        )

        guard intakePlan.acceptedCount > 0 else {
            codex.lastErrorMessage = "You can attach up to \(maxComposerImages) images per message."
            return
        }

        let acceptedItems = Array(items.prefix(intakePlan.acceptedCount))
        if intakePlan.hasOverflow {
            codex.lastErrorMessage = "Only \(maxComposerImages) images are allowed per message."
        }

        clearComposerReviewSelectionIfNeededForNonReviewContent()

        for item in acceptedItems {
            let attachmentID = UUID().uuidString
            composerAttachments.append(TurnComposerImageAttachment(id: attachmentID, state: .loading))

            Task {
                let state = await Self.loadComposerAttachmentState(from: item)
                await MainActor.run {
                    self.updateComposerAttachment(id: attachmentID, state: state)
                }
            }
        }
    }

    // Reuses the picker intake pipeline so pasted images obey the same limits and processing.
    func enqueuePastedImageData(_ imageDataItems: [Data], codex: CodexService) {
        guard !imageDataItems.isEmpty else {
            return
        }

        let intakePlan = TurnComposerAttachmentIntakePlan.make(
            requestedCount: imageDataItems.count,
            remainingSlots: remainingAttachmentSlots
        )

        guard intakePlan.acceptedCount > 0 else {
            codex.lastErrorMessage = "You can attach up to \(maxComposerImages) images per message."
            return
        }

        let acceptedItems = Array(imageDataItems.prefix(intakePlan.acceptedCount))
        if intakePlan.hasOverflow {
            codex.lastErrorMessage = "Only \(maxComposerImages) images are allowed per message."
        }

        clearComposerReviewSelectionIfNeededForNonReviewContent()

        for imageData in acceptedItems {
            let attachmentID = UUID().uuidString
            composerAttachments.append(TurnComposerImageAttachment(id: attachmentID, state: .loading))

            Task {
                let state = Self.loadComposerAttachmentState(fromData: imageData)
                await MainActor.run {
                    self.updateComposerAttachment(id: attachmentID, state: state)
                }
            }
        }
    }

    private func updateComposerAttachment(id: String, state: TurnComposerImageAttachmentState) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else {
            return
        }

        composerAttachments[index].state = state
    }

    // Sends a composer payload, preferring turn/steer when a run is already active.
    func sendTurn(codex: CodexService, threadID: String) {
        let payload = buildPayloadWithMentions()
        let attachments = readyComposerAttachments
        let skillMentions = composerMentionedSkills.map {
            CodexTurnSkillMention(id: $0.name, name: $0.name, path: $0.path)
        }
        let reviewSelection = composerReviewSelection

        guard (!payload.isEmpty || !attachments.isEmpty || reviewSelection != nil),
              !isSending,
              codex.isConnected,
              !hasBlockingAttachmentState else {
            return
        }

        if reviewSelection != nil, hasComposerContentConflictingWithReview {
            codex.lastErrorMessage = "Clear text, files, skills, and images before starting a code review."
            return
        }

        let queuedDraft = reviewSelection == nil ? QueuedTurnDraft(
            id: UUID().uuidString,
            text: payload,
            attachments: attachments,
            skillMentions: skillMentions,
            createdAt: Date()
        ) : nil
        let pendingSend = PendingTurnSend(
            payload: payload,
            attachments: attachments,
            skillMentions: skillMentions,
            collaborationMode: isPlanModeArmed ? .plan : nil,
            rawInput: input,
            rawFileMentions: composerMentionedFiles,
            rawSkillMentions: composerMentionedSkills,
            rawAttachments: composerAttachments,
            rawReviewSelection: reviewSelection
        )
        let threadBusy = isThreadBusy(codex: codex, threadID: threadID)
        let queuePaused = isQueuePaused(codex: codex, threadID: threadID)

        isSending = true
        Task { @MainActor in
            defer { isSending = false }

            let stillBusy = await refreshBusyStateIfNeeded(codex: codex, threadID: threadID, wasBusy: threadBusy)
            if stillBusy {
                await performBusyThreadSend(
                    pendingSend,
                    codex: codex,
                    threadID: threadID
                )
                return
            }

            if queuePaused, let queuedDraft {
                appendQueuedDraft(queuedDraft, codex: codex, threadID: threadID)
                shouldAnchorToAssistantResponse = true
                clearComposer()

                resumeQueueAndFlushIfPossible(codex: codex, threadID: threadID)
                return
            }

            await performTurnSend(pendingSend, codex: codex, threadID: threadID)
        }
    }

    func flushQueueIfPossible(codex: CodexService, threadID: String) {
        guard !queuedDrafts(codex: codex, threadID: threadID).isEmpty,
              !isSending,
              steeringDraftID == nil,
              codex.isConnected,
              !isQueuePaused(codex: codex, threadID: threadID),
              !isThreadBusy(codex: codex, threadID: threadID) else {
            return
        }

        guard let nextDraft = dequeueQueuedDraft(codex: codex, threadID: threadID) else {
            return
        }
        isSending = true
        shouldAnchorToAssistantResponse = true

        Task { @MainActor in
            defer { isSending = false }

            do {
                try await codex.startTurn(
                    userInput: nextDraft.text,
                    threadId: threadID,
                    attachments: nextDraft.attachments,
                    skillMentions: nextDraft.skillMentions
                )
            } catch {
                shouldAnchorToAssistantResponse = false
                prependQueuedDraft(nextDraft, codex: codex, threadID: threadID)
                let queueErrorMessage = codex.userFacingTurnErrorMessage(from: error)
                setQueuePauseState(.paused(errorMessage: queueErrorMessage), codex: codex, threadID: threadID)
                codex.lastErrorMessage = "Queue paused: \(queueErrorMessage)"
            }
        }
    }

    private func shouldRearmPlanModeAfterSendFailure(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError else {
            return false
        }

        guard case .invalidResponse(let reason) = serviceError else {
            return false
        }

        return reason.localizedCaseInsensitiveContains("plan mode requires an available model")
    }

    // Sends one queued draft into the active turn without disturbing the rest of the queue.
    func steerQueuedDraft(id: String, codex: CodexService, threadID: String) {
        guard codex.isConnected,
              steeringDraftID == nil,
              isThreadBusy(codex: codex, threadID: threadID),
              let draft = queuedDrafts(codex: codex, threadID: threadID).first(where: { $0.id == id }) else {
            return
        }

        steeringDraftID = id
        shouldAnchorToAssistantResponse = true

        Task { @MainActor in
            defer { steeringDraftID = nil }

            do {
                let stillBusy = await refreshBusyStateIfNeeded(codex: codex, threadID: threadID, wasBusy: true)
                if !stillBusy {
                    try await codex.startTurn(
                        userInput: draft.text,
                        threadId: threadID,
                        attachments: draft.attachments,
                        skillMentions: draft.skillMentions
                    )
                    removeQueuedDraft(id: id, codex: codex, threadID: threadID)
                    return
                }

                let expectedTurnID = try await resolveSteerExpectedTurnID(
                    codex: codex,
                    threadID: threadID
                )
                try await codex.steerTurn(
                    userInput: draft.text,
                    threadId: threadID,
                    expectedTurnId: expectedTurnID,
                    attachments: draft.attachments,
                    skillMentions: draft.skillMentions,
                    shouldAppendUserMessage: true
                )
                removeQueuedDraft(id: id, codex: codex, threadID: threadID)
            } catch {
                shouldAnchorToAssistantResponse = false
                codex.removeLatestFailedUserMessage(
                    threadId: threadID,
                    matchingText: draft.text,
                    matchingAttachments: draft.attachments
                )
                codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
            }
        }
    }

    func resumeQueueAndFlushIfPossible(codex: CodexService, threadID: String) {
        setQueuePauseState(.active, codex: codex, threadID: threadID)
        flushQueueIfPossible(codex: codex, threadID: threadID)
    }

    func interruptTurn(_ turnID: String?, codex: CodexService, threadID: String) {
        Task { @MainActor in
            do {
                try await codex.interruptTurn(turnId: turnID, threadId: threadID)
            } catch {
                // Error message already stored in CodexService.
            }
        }
    }

    func approve(codex: CodexService) {
        Task { @MainActor in
            isHandlingApproval = true
            defer { isHandlingApproval = false }

            do {
                try await codex.approvePendingRequest()
            } catch {
                // Error message already stored in CodexService.
            }
        }
    }

    func decline(codex: CodexService) {
        Task { @MainActor in
            isHandlingApproval = true
            defer { isHandlingApproval = false }

            do {
                try await codex.declinePendingRequest()
            } catch {
                // Error message already stored in CodexService.
            }
        }
    }

    private static func loadComposerAttachmentState(from item: PhotosPickerItem) async -> TurnComposerImageAttachmentState {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  !data.isEmpty else {
                return .failed
            }
            return loadComposerAttachmentState(fromData: data)
        } catch {
            return .failed
        }
    }

    private static func loadComposerAttachmentState(fromData data: Data) -> TurnComposerImageAttachmentState {
        guard let attachment = TurnAttachmentPipeline.makeAttachment(from: data) else {
            return .failed
        }
        return .ready(attachment)
    }

    // Extracts only a final `@query` token at the end of composer text.
    static func trailingFileAutocompleteToken(in text: String) -> TurnTrailingFileAutocompleteToken? {
        guard let token = trailingFileToken(in: text) else {
            return nil
        }

        return TurnTrailingFileAutocompleteToken(
            query: token.query,
            tokenRange: token.tokenRange
        )
    }

    // Extracts only a final `$query` token at the end of composer text.
    static func trailingSkillAutocompleteToken(in text: String) -> TurnTrailingSkillAutocompleteToken? {
        guard let token = trailingToken(in: text, trigger: "$") else {
            return nil
        }

        // Reject pure-numeric queries like `$100`, `$42` — not skill names.
        guard token.query.contains(where: { $0.isLetter }) else {
            return nil
        }

        return TurnTrailingSkillAutocompleteToken(
            query: token.query,
            tokenRange: token.tokenRange
        )
    }

    // Extracts only a final `/query` token so slash commands open from the same composer input.
    static func trailingSlashCommandToken(in text: String) -> TurnTrailingSlashCommandToken? {
        TurnComposerCommandLogic.trailingSlashCommandToken(in: text)
    }

    static func replacingTrailingFileAutocompleteToken(in text: String, with selectedPath: String) -> String? {
        let trimmedPath = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              let token = trailingFileAutocompleteToken(in: text) else {
            return nil
        }

        var updated = text
        updated.replaceSubrange(token.tokenRange, with: "@\(trimmedPath) ")
        return updated
    }

    // Resolves file mentions from either the exact path or normalized alias forms.
    static func replacingFileMentionAliases(
        in text: String,
        with mention: TurnComposerMentionedFile,
        allowFileNameAliases: Bool = true
    ) -> String {
        let replacement = "@\(mention.path)"
        let placeholder = "__codex_file_mention__\(mention.path.hashValue)__"
        let replacedText = fileMentionAliases(
            fileName: mention.fileName,
            path: mention.path,
            allowFileNameAliases: allowFileNameAliases
        )
            .reduce(text) { partialText, alias in
                // Replace into a placeholder first so shorter aliases cannot re-match inside the canonical path.
                replaceBoundedToken(
                    "@\(alias)",
                    with: placeholder,
                    in: partialText,
                    caseInsensitive: true
                )
            }
        return replacedText.replacingOccurrences(of: placeholder, with: replacement)
    }

    // Removes any alias form for a selected file mention so chip deletion stays in sync with text.
    static func removingFileMentionAliases(
        for mention: TurnComposerMentionedFile,
        from text: String,
        allowFileNameAliases: Bool = true
    ) -> String {
        fileMentionAliases(
            fileName: mention.fileName,
            path: mention.path,
            allowFileNameAliases: allowFileNameAliases
        )
            .reduce(text) { partialText, alias in
                removeBoundedToken(
                    "@\(alias)",
                    from: partialText,
                    caseInsensitive: true
                )
            }
    }

    // Generates raw and normalized aliases so matching survives spaces, separators, and casing changes.
    static func fileMentionAliases(
        fileName: String,
        path: String,
        allowFileNameAliases: Bool = true
    ) -> [String] {
        var aliases: Set<String> = []
        var seeds = [path, deletingPathExtension(from: path)]

        if allowFileNameAliases {
            seeds.insert(fileName, at: 0)
            seeds.append(deletingPathExtension(from: fileName))
        }

        for seed in seeds {
            let trimmedSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSeed.isEmpty else {
                continue
            }

            aliases.insert(trimmedSeed)
            appendNormalizedFileMentionAliases(for: trimmedSeed, into: &aliases)
        }

        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted {
                if $0.count == $1.count {
                    return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return $0.count > $1.count
            }
    }

    // When multiple mentions normalize to the same basename, only folder-aware aliases are safe.
    static func ambiguousFileNameAliasKeys(in mentions: [TurnComposerMentionedFile]) -> Set<String> {
        let groupedKeys = Dictionary(grouping: mentions.compactMap { mention in
            fileNameAliasCollisionKey(for: mention.fileName)
        }) { $0 }

        return Set(groupedKeys.compactMap { key, bucket in
            bucket.count > 1 ? key : nil
        })
    }

    static func replacingTrailingSkillAutocompleteToken(in text: String, with selectedSkill: String) -> String? {
        let trimmedSkill = selectedSkill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSkill.isEmpty,
              let token = trailingSkillAutocompleteToken(in: text) else {
            return nil
        }

        var updated = text
        updated.replaceSubrange(token.tokenRange, with: "$\(trimmedSkill) ")
        return updated
    }

    static func removingTrailingSlashCommandToken(in text: String) -> String? {
        TurnComposerCommandLogic.removingTrailingSlashCommandToken(in: text)
    }

    // Allows file autocomplete queries to span spaces once they already look like a file or path.
    private static func trailingFileToken(in text: String) -> TurnTrailingToken? {
        guard !text.isEmpty,
              let lastCharacter = text.last,
              !lastCharacter.isWhitespace,
              let triggerIndex = text.lastIndex(of: "@") else {
            return nil
        }

        if triggerIndex > text.startIndex {
            let previousCharacter = text[text.index(before: triggerIndex)]
            guard previousCharacter.isWhitespace else {
                return nil
            }
        }

        let queryStart = text.index(after: triggerIndex)
        let rawQuery = String(text[queryStart..<text.endIndex])
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              !query.contains(where: \.isNewline) else {
            return nil
        }

        if query.contains(where: \.isWhitespace) {
            let looksFileLike = query.contains("/")
                || query.contains("\\")
                || query.contains(".")
            guard looksFileLike else {
                return nil
            }
        }

        return TurnTrailingToken(query: query, tokenRange: triggerIndex..<text.endIndex)
    }

    // Shared parser for final-token autocomplete triggers (`@`, `$`).
    private static func trailingToken(
        in text: String,
        trigger: Character
    ) -> TurnTrailingToken? {
        guard !text.isEmpty else {
            return nil
        }

        let tokenStart: String.Index
        if let lastWhitespaceIndex = text.lastIndex(where: { $0.isWhitespace }) {
            tokenStart = text.index(after: lastWhitespaceIndex)
        } else {
            tokenStart = text.startIndex
        }

        guard tokenStart < text.endIndex else {
            return nil
        }

        guard text[tokenStart] == trigger else {
            return nil
        }

        let queryStart = text.index(after: tokenStart)
        let query = String(text[queryStart..<text.endIndex])
        guard !query.contains(where: { $0.isWhitespace }),
              !query.isEmpty else {
            return nil
        }

        return TurnTrailingToken(query: query, tokenRange: tokenStart..<text.endIndex)
    }

    private static func appendNormalizedFileMentionAliases(
        for seed: String,
        into aliases: inout Set<String>
    ) {
        let trimmedSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSeed.isEmpty else {
            return
        }

        let pathExtension = (trimmedSeed as NSString).pathExtension
        let normalizedExtension = pathExtension.lowercased()
        let stem = normalizedExtension.isEmpty
            ? trimmedSeed
            : (trimmedSeed as NSString).deletingPathExtension
        let tokens = mentionSearchTokens(from: stem)
        guard !tokens.isEmpty else {
            return
        }

        var baseVariants: Set<String> = [
            tokens.joined(separator: " "),
            tokens.joined(separator: "-"),
            tokens.joined(separator: "_"),
            tokens.joined(),
            lowerCamelCase(from: tokens),
            upperCamelCase(from: tokens),
        ]
        baseVariants = baseVariants.filter { !$0.isEmpty }

        for variant in baseVariants {
            aliases.insert(variant)
            if !normalizedExtension.isEmpty {
                aliases.insert("\(variant).\(normalizedExtension)")
            }
        }
    }

    private static func mentionSearchTokens(from value: String) -> [String] {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return []
        }

        return trimmedValue
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .flatMap(tokensFromMentionSegment)
    }

    // Keeps Apple-style prefixes like `iOS` together so alias variants stay natural.
    private static func tokensFromMentionSegment(_ segment: String) -> [String] {
        let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSegment.isEmpty else {
            return []
        }

        guard let regex = fileMentionSegmentRegex else {
            return [trimmedSegment.lowercased()]
        }

        let range = NSRange(trimmedSegment.startIndex..., in: trimmedSegment)
        let rawTokens = regex.matches(in: trimmedSegment, range: range).compactMap { match in
            Range(match.range, in: trimmedSegment).map { String(trimmedSegment[$0]) }
        }
        guard !rawTokens.isEmpty else {
            return [trimmedSegment.lowercased()]
        }

        var normalizedTokens: [String] = []
        var index = 0

        while index < rawTokens.count {
            let token = rawTokens[index]

            if token.count == 1,
               token == token.lowercased(),
               index + 1 < rawTokens.count,
               isAllCapsAcronym(rawTokens[index + 1]) {
                normalizedTokens.append((token + rawTokens[index + 1]).lowercased())
                index += 2
                continue
            }

            normalizedTokens.append(token.lowercased())
            index += 1
        }

        return normalizedTokens
    }

    private static func isAllCapsAcronym(_ token: String) -> Bool {
        token.count > 1
            && token.unicodeScalars.allSatisfy {
                CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
    }

    private static func lowerCamelCase(from tokens: [String]) -> String {
        guard let first = tokens.first else {
            return ""
        }

        let tail = tokens.dropFirst().map(capitalizedToken).joined()
        return first + tail
    }

    private static func upperCamelCase(from tokens: [String]) -> String {
        tokens.map(capitalizedToken).joined()
    }

    private static func capitalizedToken(_ token: String) -> String {
        guard let first = token.first else {
            return token
        }

        return first.uppercased() + token.dropFirst()
    }

    private static func deletingPathExtension(from value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return ""
        }
        return (trimmedValue as NSString).deletingPathExtension
    }

    private static func fileNameAliasCollisionKey(for fileName: String) -> String? {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return nil
        }

        let normalizedExtension = (trimmedName as NSString).pathExtension.lowercased()
        let stem = deletingPathExtension(from: trimmedName)
        let tokens = mentionSearchTokens(from: stem)
        guard !tokens.isEmpty else {
            return normalizedExtension.isEmpty ? nil : ".\(normalizedExtension)"
        }

        let tokenKey = tokens.joined(separator: "|")
        return normalizedExtension.isEmpty ? tokenKey : "\(tokenKey).\(normalizedExtension)"
    }

    private static func isMethodNotFoundRPCError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("method not found")
            || message.contains("unsupported")
            || message.contains("code -32601")
    }

    // Filters pre-indexed skills using a single normalized search blob to reduce per-keystroke work.
    private func filteredSkillAutocompleteItems(
        for query: String,
        indexedSkills: [TurnSkillSearchIndexEntry]
    ) -> [CodexSkillMetadata] {
        let needle = query.lowercased()
        let filtered = indexedSkills.lazy
            .filter { $0.searchBlob.contains(needle) }
            .map(\.skill)
        return Array(filtered.prefix(maxSkillAutocompleteItems))
    }

    private func normalizedAutocompleteRoot(for thread: CodexThread) -> String? {
        if let normalizedProjectPath = thread.normalizedProjectPath {
            return normalizedProjectPath
        }

        guard let rawCwd = thread.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCwd.isEmpty else {
            return nil
        }
        return rawCwd
    }

    private func fileAutocompleteCancellationToken(for threadID: String) -> String {
        "ios-at-file-\(threadID)"
    }

    // Reuses the stop-button refresh path so queued sends do not trust stale running flags.
    private func refreshBusyStateIfNeeded(
        codex: CodexService,
        threadID: String,
        wasBusy: Bool
    ) async -> Bool {
        guard wasBusy,
              codex.activeTurnID(for: threadID) == nil,
              codex.runningThreadIDs.contains(threadID) else {
            return wasBusy
        }

        _ = await codex.refreshInFlightTurnState(threadId: threadID)
        return isThreadBusy(codex: codex, threadID: threadID)
    }

    private func isThreadBusy(codex: CodexService, threadID: String) -> Bool {
        codex.activeTurnID(for: threadID) != nil || codex.runningThreadIDs.contains(threadID)
    }

    // Reuses the active turn when possible so follow-up chat sends steer the current run instead of waiting in queue.
    private func performBusyThreadSend(
        _ pendingSend: PendingTurnSend,
        codex: CodexService,
        threadID: String
    ) async {
        if pendingSend.rawReviewSelection != nil {
            restoreComposerState(from: pendingSend)
            shouldAnchorToAssistantResponse = false
            codex.lastErrorMessage = "Wait for the current run to finish before starting a code review."
            return
        }

        isPlanModeArmed = false
        shouldAnchorToAssistantResponse = true
        clearComposer()

        do {
            let expectedTurnID = try await resolveSteerExpectedTurnID(
                codex: codex,
                threadID: threadID
            )

            try await codex.steerTurn(
                userInput: pendingSend.payload,
                threadId: threadID,
                expectedTurnId: expectedTurnID,
                attachments: pendingSend.attachments,
                skillMentions: pendingSend.skillMentions,
                shouldAppendUserMessage: true
            )
        } catch {
            let stillBusy = await refreshBusyStateIfNeeded(codex: codex, threadID: threadID, wasBusy: true)
            if !stillBusy {
                codex.removeLatestFailedUserMessage(
                    threadId: threadID,
                    matchingText: pendingSend.payload,
                    matchingAttachments: pendingSend.attachments
                )
                await performTurnSend(pendingSend, codex: codex, threadID: threadID)
                return
            }

            shouldAnchorToAssistantResponse = false
            restoreComposerState(from: pendingSend)
            if codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
            }
        }
    }

    // Sends the prepared payload and restores the exact raw composer state if startTurn fails.
    private func performTurnSend(
        _ pendingSend: PendingTurnSend,
        codex: CodexService,
        threadID: String
    ) async {
        isPlanModeArmed = false
        shouldAnchorToAssistantResponse = true
        clearComposer()

        do {
            if let reviewSelection = pendingSend.rawReviewSelection {
                try await codex.startReview(
                    threadId: threadID,
                    target: reviewSelection.target?.codexReviewTarget,
                    baseBranch: reviewBaseBranchName(for: reviewSelection)
                )
            } else {
                try await codex.startTurn(
                    userInput: pendingSend.payload,
                    threadId: threadID,
                    attachments: pendingSend.attachments,
                    skillMentions: pendingSend.skillMentions,
                    collaborationMode: pendingSend.collaborationMode
                )
            }
        } catch {
            shouldAnchorToAssistantResponse = false
            restoreComposerState(from: pendingSend)
            if pendingSend.collaborationMode == .plan,
               shouldRearmPlanModeAfterSendFailure(error) {
                isPlanModeArmed = true
            }
            if codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                codex.lastErrorMessage = error.localizedDescription
            }
        }
    }

    // Restores the exact draft state after a failed send so slash/file/skill context survives retries.
    private func restoreComposerState(from pendingSend: PendingTurnSend) {
        input = pendingSend.rawInput
        composerMentionedFiles = pendingSend.rawFileMentions
        composerMentionedSkills = pendingSend.rawSkillMentions
        composerAttachments = pendingSend.rawAttachments
        composerReviewSelection = pendingSend.rawReviewSelection
    }

    // Resolves the active turn id for manual steer without relying on async autoclosure operators.
    private func resolveSteerExpectedTurnID(
        codex: CodexService,
        threadID: String
    ) async throws -> String? {
        if let activeTurnID = codex.activeTurnID(for: threadID) {
            return activeTurnID
        }

        return try await codex.resolveInFlightTurnID(threadId: threadID)
    }

    private func queuedDrafts(codex: CodexService, threadID: String) -> [QueuedTurnDraft] {
        codex.queuedTurnDraftsByThread[threadID] ?? []
    }

    private func setQueuedDrafts(_ drafts: [QueuedTurnDraft], codex: CodexService, threadID: String) {
        if drafts.isEmpty {
            codex.queuedTurnDraftsByThread.removeValue(forKey: threadID)
            return
        }
        codex.queuedTurnDraftsByThread[threadID] = drafts
    }

    private func appendQueuedDraft(_ draft: QueuedTurnDraft, codex: CodexService, threadID: String) {
        var drafts = queuedDrafts(codex: codex, threadID: threadID)
        drafts.append(draft)
        setQueuedDrafts(drafts, codex: codex, threadID: threadID)
    }

    private func prependQueuedDraft(_ draft: QueuedTurnDraft, codex: CodexService, threadID: String) {
        var drafts = queuedDrafts(codex: codex, threadID: threadID)
        drafts.insert(draft, at: 0)
        setQueuedDrafts(drafts, codex: codex, threadID: threadID)
    }

    private func dequeueQueuedDraft(codex: CodexService, threadID: String) -> QueuedTurnDraft? {
        var drafts = queuedDrafts(codex: codex, threadID: threadID)
        guard !drafts.isEmpty else { return nil }
        let nextDraft = drafts.removeFirst()
        setQueuedDrafts(drafts, codex: codex, threadID: threadID)
        return nextDraft
    }

    private func queuePauseState(codex: CodexService, threadID: String) -> QueuePauseState {
        codex.queuePauseStateByThread[threadID] ?? .active
    }

    private func setQueuePauseState(_ state: QueuePauseState, codex: CodexService, threadID: String) {
        switch state {
        case .active:
            codex.queuePauseStateByThread.removeValue(forKey: threadID)
        case .paused:
            codex.queuePauseStateByThread[threadID] = state
        }
    }

    private func resetFileAutocompleteState() {
        fileAutocompleteDebounceTask?.cancel()
        fileAutocompleteDebounceTask = nil
        fileAutocompleteItems = []
        isFileAutocompleteVisible = false
        isFileAutocompleteLoading = false
        fileAutocompleteQuery = ""
    }

    private func resetSkillAutocompleteState() {
        skillAutocompleteDebounceTask?.cancel()
        skillAutocompleteDebounceTask = nil
        skillAutocompleteItems = []
        isSkillAutocompleteVisible = false
        isSkillAutocompleteLoading = false
        skillAutocompleteQuery = ""
    }

    private func resetSlashCommandState(
        clearPendingSelection: Bool = false,
        clearConfirmedSelection: Bool = false
    ) {
        slashCommandPanelState = .hidden
        if clearConfirmedSelection {
            composerReviewSelection = nil
            return
        }
        if clearPendingSelection, composerReviewSelection?.target == nil {
            composerReviewSelection = nil
        }
    }

    // Normalizes the composer when a slash action is accepted so the helper token does not leak into the draft.
    private func removeTrailingSlashCommandTokenFromInputIfNeeded() {
        if let updatedInput = Self.removingTrailingSlashCommandToken(in: input) {
            input = updatedInput
        }
    }

    // Arms the inline review flow while keeping its state transitions in one place.
    private func armCodeReviewSelection(
        command: TurnComposerSlashCommand,
        target: TurnComposerReviewTarget?
    ) {
        guard !hasComposerContentConflictingWithReview else {
            resetSlashCommandState(clearPendingSelection: true)
            return
        }

        composerReviewSelection = TurnComposerReviewSelection(command: command, target: target)
        slashCommandPanelState = (target == nil) ? .codeReviewTargets : .hidden
    }

    private func clearComposerReviewSelectionIfNeededForInput(_ text: String) {
        guard composerReviewSelection?.target != nil else {
            return
        }

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearComposerReviewSelection()
        }
    }

    private func clearComposerReviewSelectionIfNeededForNonReviewContent() {
        guard composerReviewSelection?.target != nil else {
            return
        }

        clearComposerReviewSelection()
    }

    // Replaces inline `@filename` with `@fullpath` for each mentioned file.
    private func buildPayloadWithMentions() -> String {
        var text = trimmedComposerInput
        guard !composerMentionedFiles.isEmpty else {
            return text
        }

        let ambiguousKeys = Self.ambiguousFileNameAliasKeys(in: composerMentionedFiles)

        for mention in composerMentionedFiles {
            let collisionKey = Self.fileNameAliasCollisionKey(for: mention.fileName)
            let allowFileNameAliases = collisionKey.map { !ambiguousKeys.contains($0) } ?? true
            text = Self.replacingFileMentionAliases(
                in: text,
                with: mention,
                allowFileNameAliases: allowFileNameAliases
            )
        }

        return text
    }

    // Reuses the git base-branch selector so review requests stay aligned with the visible compare target.
    private func reviewBaseBranchName(for selection: TurnComposerReviewSelection) -> String? {
        guard selection.target == .baseBranch else {
            return nil
        }
        return selectedGitBaseBranch.nilIfEmpty ?? gitDefaultBranch.nilIfEmpty
    }

    /// Removes the first occurrence of `token` that sits at a word boundary
    /// (followed by whitespace, punctuation, or end-of-string). Consumes one trailing space when present.
    static func removeBoundedToken(
        _ token: String,
        from text: String,
        caseInsensitive: Bool = false
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(
            pattern: escaped + "(?:[\\s,.;:!?)\\]}>]|$)",
            options: options
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return text
        }
        var result = text
        let matchRange = Range(match.range, in: text)!
        result.replaceSubrange(matchRange, with: "")
        return result
    }

    /// Replaces all boundary-safe occurrences of `token` with `replacement`.
    /// Boundary = followed by whitespace, punctuation, or end-of-string.
    static func replaceBoundedToken(
        _ token: String,
        with replacement: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(
            pattern: escaped + "(?=[\\s,.;:!?)\\]}>]|$)",
            options: options
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let safeReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: safeReplacement)
    }

    // MARK: - Git Actions

    func triggerGitAction(
        _ action: TurnGitActionKind,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        guard !isRunningGitAction else { return }
        runningGitAction = action

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runningGitAction = nil }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)

            do {
                switch action {
                case .syncNow:
                    let result = try await gitService.status()
                    applyGitRepoSync(result)
                    if result.state == "behind_only" || result.state == "diverged" || result.state == "dirty_and_behind" {
                        gitSyncAlert = TurnGitSyncAlert(
                            title: "Branch is behind remote",
                            message: "Pull with rebase to update?",
                            action: .pullRebase
                        )
                    }

                case .commit:
                    let result = try await gitService.commit(message: nil)
                    let statusAfter = try? await gitService.status()
                    if let statusAfter { applyGitRepoSync(statusAfter) }
                    _ = result // commit succeeded

                case .push:
                    let result = try await gitService.push()
                    handleSuccessfulPush(
                        result,
                        codex: codex,
                        workingDirectory: workingDirectory,
                        threadID: threadID
                    )

                case .commitAndPush:
                    _ = try await gitService.commit(message: nil)
                    let pushResult = try await gitService.push()
                    handleSuccessfulPush(
                        pushResult,
                        codex: codex,
                        workingDirectory: workingDirectory,
                        threadID: threadID
                    )

                case .createPR:
                    let remoteResult = try await getRemoteURL(codex: codex, workingDirectory: workingDirectory)
                    guard let ownerRepo = remoteResult.ownerRepo else {
                        throw GitActionsError.bridgeError(code: "no_remote", message: "Could not determine repository from remote URL.")
                    }
                    let branch = gitRepoSync?.currentBranch ?? currentGitBranch.nilIfEmpty ?? ""
                    guard !branch.isEmpty else {
                        throw GitActionsError.bridgeError(code: "no_branch", message: "No current branch found.")
                    }
                    let base = selectedGitBaseBranch.nilIfEmpty ?? gitDefaultBranch
                    let prURL = buildPRURL(ownerRepo: ownerRepo, branch: branch, base: base)
                    if let url = URL(string: prURL) {
                        await UIApplication.shared.open(url)
                    }

                case .discardRuntimeChangesAndSync:
                    let result = try await gitService.resetToRemote()
                    if let status = result.status { applyGitRepoSync(status) }
                }
            } catch let error as GitActionsError {
                switch error {
                case .bridgeError(let code, _) where code == "nothing_to_commit":
                    isShowingNothingToCommitAlert = true
                default:
                    gitSyncAlert = TurnGitSyncAlert(
                        title: "Git Error",
                        message: error.errorDescription ?? "Operation failed.",
                        action: .dismissOnly
                    )
                }
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Git Error",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    func inlineCommitAndPush(codex: CodexService, workingDirectory: String?, threadID: String) {
        guard !isRunningGitAction else { return }
        runningGitAction = .commitAndPush

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runningGitAction = nil }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                _ = try await gitService.commit(message: nil)
                let pushResult = try await gitService.push()
                handleSuccessfulPush(
                    pushResult,
                    codex: codex,
                    workingDirectory: workingDirectory,
                    threadID: threadID
                )
            } catch let error as GitActionsError {
                switch error {
                case .bridgeError(let code, _) where code == "nothing_to_commit":
                    isShowingNothingToCommitAlert = true
                default:
                    gitSyncAlert = TurnGitSyncAlert(
                        title: "Git Error",
                        message: error.errorDescription ?? "Operation failed.",
                        action: .dismissOnly
                    )
                }
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Git Error",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    func refreshGitBranchTargets(codex: CodexService, workingDirectory: String?, threadID: String) {
        guard !isLoadingGitBranchTargets else { return }
        isLoadingGitBranchTargets = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingGitBranchTargets = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.branchesWithStatus()
                availableGitBranchTargets = result.branches
                if let current = result.currentBranch, !current.isEmpty {
                    currentGitBranch = current
                }
                if let defaultBranch = result.defaultBranch, !defaultBranch.isEmpty {
                    gitDefaultBranch = defaultBranch
                    if selectedGitBaseBranch.isEmpty {
                        selectedGitBaseBranch = defaultBranch
                    }
                }
                if let status = result.status {
                    applyObservedGitRepoSync(
                        status,
                        codex: codex,
                        workingDirectory: workingDirectory,
                        threadID: threadID
                    )
                }
            } catch {
                // Silently fail — branches will just be empty
            }
        }
    }

    // Debounces repo status refreshes so live file-change streams can update the topbar safely.
    func scheduleGitStatusRefresh(codex: CodexService, workingDirectory: String?, threadID: String) {
        gitStatusRefreshTask?.cancel()
        gitStatusRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: gitStatusRefreshDebounceNanoseconds)
            } catch {
                return
            }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.status()
                applyObservedGitRepoSync(
                    result,
                    codex: codex,
                    workingDirectory: workingDirectory,
                    threadID: threadID
                )
            } catch {
                // Non-fatal: the next lifecycle refresh/manual action can recover the badge.
            }
        }
    }

    func switchGitBranch(
        to branch: String,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeTurnID == nil,
                  !codex.runningThreadIDs.contains(threadID),
                  !self.isRunningGitAction,
                  !self.isSwitchingGitBranch else { return }

            self.isSwitchingGitBranch = true
            defer { self.isSwitchingGitBranch = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.checkout(branch: branch)
                currentGitBranch = result.currentBranch
                if let status = result.status { applyGitRepoSync(status) }
            } catch let error as GitActionsError {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Switch Failed",
                    message: error.errorDescription ?? "Could not switch branch.",
                    action: .dismissOnly
                )
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Switch Failed",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    func selectGitBaseBranch(_ branch: String) {
        selectedGitBaseBranch = branch
    }

    func applyGitRepoSync(_ result: GitRepoSyncResult) {
        gitRepoSync = result
        if let branch = result.currentBranch, !branch.isEmpty {
            currentGitBranch = branch
        }
    }

    // Detects push-like repo transitions that happen outside the toolbar callback path.
    private func applyObservedGitRepoSync(
        _ result: GitRepoSyncResult,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String
    ) {
        let previousSync = gitRepoSync
        applyGitRepoSync(result)

        guard let previousSync else {
            return
        }

        let branchStayedStable = previousSync.currentBranch == result.currentBranch
        let didClearAheadQueue = previousSync.aheadCount > 0 && result.aheadCount == 0
        guard branchStayedStable, didClearAheadQueue else {
            return
        }

        codex.appendHiddenPushResetMarkers(
            threadId: threadID,
            workingDirectory: workingDirectory,
            branch: result.currentBranch ?? "",
            remote: trackingRemoteName(from: result.trackingBranch)
        )
    }

    // Keeps repo totals fresh and resets the per-chat sidebar badge after a manual push.
    private func handleSuccessfulPush(
        _ result: GitPushResult,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String
    ) {
        if let status = result.status {
            applyGitRepoSync(status)
        }

        codex.appendHiddenPushResetMarkers(
            threadId: threadID,
            workingDirectory: workingDirectory,
            branch: result.branch,
            remote: result.remote
        )
    }

    private func trackingRemoteName(from trackingBranch: String?) -> String? {
        guard let trackingBranch else {
            return nil
        }

        let trimmed = trackingBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
    }

    func dismissGitSyncAlert() {
        gitSyncAlert = nil
    }

    func confirmGitSyncAlertAction(
        _ alertAction: TurnGitSyncAlertAction,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        gitSyncAlert = nil
        guard alertAction == .pullRebase else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeTurnID == nil,
                  !codex.runningThreadIDs.contains(threadID),
                  !self.isRunningGitAction,
                  !self.isSwitchingGitBranch else { return }

            self.runningGitAction = .syncNow
            defer { self.runningGitAction = nil }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.pull()
                if let status = result.status { applyGitRepoSync(status) }
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Pull Failed",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    private func getRemoteURL(codex: CodexService, workingDirectory: String?) async throws -> GitRemoteUrlResult {
        let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
        return try await gitService.remoteUrl()
    }

    private func buildPRURL(ownerRepo: String, branch: String, base: String) -> String {
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let encodedBase = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        return "https://github.com/\(ownerRepo)/compare/\(encodedBase)...\(encodedBranch)?expand=1"
    }
}

struct TurnComposerMentionedFile: Identifiable, Equatable {
    let id = UUID().uuidString
    let fileName: String
    let path: String
}

struct TurnComposerMentionedSkill: Identifiable, Equatable {
    let id = UUID().uuidString
    let name: String
    let path: String?
    let description: String?
}

struct TurnTrailingFileAutocompleteToken: Equatable {
    let query: String
    let tokenRange: Range<String.Index>
}

struct TurnTrailingSkillAutocompleteToken: Equatable {
    let query: String
    let tokenRange: Range<String.Index>
}

private struct TurnTrailingToken: Equatable {
    let query: String
    let tokenRange: Range<String.Index>
}

private struct TurnSkillSearchIndexEntry: Equatable {
    let skill: CodexSkillMetadata
    let searchBlob: String

    init(skill: CodexSkillMetadata) {
        self.skill = skill
        let name = skill.name.lowercased()
        let description = skill.description?.lowercased() ?? ""
        if description.isEmpty {
            self.searchBlob = name
        } else {
            self.searchBlob = "\(name)\n\(description)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
