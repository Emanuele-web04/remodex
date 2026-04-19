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
    let hasSubagentsSelection: Bool

    // Evaluates whether sending is allowed for the current composer state.
    var isSendDisabled: Bool {
        isSending
            || !isConnected
            || hasPendingReviewSelection
            || (trimmedInput.isEmpty && !hasReadyImages && !hasReviewSelection && !hasSubagentsSelection)
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
    // Preserves special send semantics, such as plan mode, while a busy thread queues locally.
    let collaborationMode: CodexCollaborationModeKind?
    // Preserves the original composer state so a queued row can move back into the input intact.
    let rawInput: String
    let rawFileMentions: [TurnComposerMentionedFile]
    let rawSkillMentions: [TurnComposerMentionedSkill]
    let rawAttachments: [TurnComposerImageAttachment]
    let rawSubagentsSelectionArmed: Bool
    let createdAt: Date

    init(
        id: String,
        text: String,
        attachments: [CodexImageAttachment],
        skillMentions: [CodexTurnSkillMention],
        collaborationMode: CodexCollaborationModeKind?,
        rawInput: String? = nil,
        rawFileMentions: [TurnComposerMentionedFile] = [],
        rawSkillMentions: [TurnComposerMentionedSkill] = [],
        rawAttachments: [TurnComposerImageAttachment] = [],
        rawSubagentsSelectionArmed: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.skillMentions = skillMentions
        self.collaborationMode = collaborationMode
        self.rawInput = rawInput ?? text
        self.rawFileMentions = rawFileMentions
        self.rawSkillMentions = rawSkillMentions
        self.rawAttachments = rawAttachments
        self.rawSubagentsSelectionArmed = rawSubagentsSelectionArmed
        self.createdAt = createdAt
    }
}

enum QueuePauseState: Equatable {
    case active
    case paused(errorMessage: String)
}

@MainActor
@Observable
final class TurnViewModel {
    enum GitBranchUserOperation: Equatable {
        case create(String)
        case switchTo(String)
        case createWorktree(
            branchName: String,
            baseBranch: String,
            changeTransfer: GitWorktreeChangeTransferMode
        )
        case createManagedWorktree(
            baseBranch: String,
            changeTransfer: GitWorktreeChangeTransferMode
        )
    }

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
        let rawSubagentsSelectionArmed: Bool
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
    var isSubagentsSelectionArmed = false
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
    var inlineCommitAndPushPhase: InlineCommitAndPushPhase? = nil
    var isRunningGitAction: Bool { runningGitAction != nil }
    var isShowingNothingToCommitAlert = false
    var gitSyncAlert: TurnGitSyncAlert? = nil
    var isLoadingGitBranchTargets = false
    var isSwitchingGitBranch = false
    var isCreatingGitWorktree = false
    var selectedGitBaseBranch = ""
    var currentGitBranch = ""
    var availableGitBranchTargets: [String] = []
    var gitBranchesCheckedOutElsewhere: Set<String> = []
    var gitWorktreePathsByBranch: [String: String] = [:]
    var gitLocalCheckoutPath: String?
    var gitDefaultBranch = ""
    var gitRepoSync: GitRepoSyncResult? = nil
    var gitSyncState: String? { gitRepoSync?.state }
    // Keeps PR creation tied to live Git state instead of chat-local remembered branch state.
    var createPullRequestValidationMessage: String? {
        guard let repoSync = gitRepoSync else {
            return "Git status is still loading. Wait a moment and retry."
        }

        let branch = (repoSync.currentBranch ?? currentGitBranch).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            return "No current branch found."
        }

        let defaultBranch = gitDefaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !defaultBranch.isEmpty else {
            return "Could not determine the repository default branch."
        }

        guard branch != defaultBranch else {
            return "Switch to a feature branch before creating a PR."
        }

        let trackingBranch = repoSync.trackingBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trackingBranch.isEmpty || repoSync.isPublishedToRemote else {
            return "Push this branch before creating a PR."
        }

        guard repoSync.aheadCount == 0 else {
            return "Push this branch before creating a PR."
        }

        return nil
    }
    var canCreatePullRequest: Bool { createPullRequestValidationMessage == nil }
    var localSelectableGitDefaultBranch: String? {
        remodexSelectableDefaultBranch(
            defaultBranch: gitDefaultBranch,
            availableGitBranchTargets: availableGitBranchTargets
        )
    }
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
            && !isCreatingGitWorktree
    }

    // Cached projected timeline to avoid re-running TurnTimelineReducer on every SwiftUI evaluation.
    var projectedMessages: [CodexMessage] = []
    @ObservationIgnored private var threadActivationTask: Task<Void, Never>?

    @ObservationIgnored var fileAutocompleteDebounceTask: Task<Void, Never>?
    @ObservationIgnored var skillAutocompleteDebounceTask: Task<Void, Never>?
    @ObservationIgnored var gitStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored var pendingGitBranchOperation: GitBranchUserOperation?
    @ObservationIgnored var pendingGitWorktreeOpenHandler: ((GitCreateWorktreeResult) -> Void)?
    @ObservationIgnored var pendingManagedGitWorktreeOpenHandler: ((GitCreateManagedWorktreeResult) -> Void)?
    @ObservationIgnored private var cachedSkillSearchIndexByRoot: [String: [TurnSkillSearchIndexEntry]] = [:]
    @ObservationIgnored var unsupportedSkillsAutocompleteRoots: Set<String> = []
    @ObservationIgnored private var dismissedStructuredPlanPromptRequestKeys: Set<String> = []
    @ObservationIgnored private var dismissingStructuredPlanPromptRequestKeys: Set<String> = []

    let maxComposerImages = 4
    let maxFileAutocompleteItems = 6
    let maxSkillAutocompleteItems = 6
    private let fileAutocompleteDebounceNanoseconds: UInt64 = 180_000_000
    private let skillAutocompleteDebounceNanoseconds: UInt64 = 180_000_000
    let gitStatusRefreshDebounceNanoseconds: UInt64 = 350_000_000

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

    // Cancels view-scoped async work before the chat view model disappears.
    func cancelTransientTasks() {
        threadActivationTask?.cancel()
        threadActivationTask = nil
        fileAutocompleteDebounceTask?.cancel()
        fileAutocompleteDebounceTask = nil
        skillAutocompleteDebounceTask?.cancel()
        skillAutocompleteDebounceTask = nil
        gitStatusRefreshTask?.cancel()
        gitStatusRefreshTask = nil
    }

    func activateThread(threadID: String, codex: CodexService, onComplete: @escaping () -> Void) {
        threadActivationTask?.cancel()
        threadActivationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let didPrepare = await codex.prepareThreadForDisplay(threadId: threadID)
            guard didPrepare, !Task.isCancelled, codex.activeThreadId == threadID else { return }
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

    // Keeps queue restore disabled whenever the composer already contains something meaningful.
    var hasComposerDraftContent: Bool {
        !trimmedComposerInput.isEmpty
            || !composerAttachments.isEmpty
            || !composerMentionedFiles.isEmpty
            || !composerMentionedSkills.isEmpty
            || composerReviewSelection != nil
            || isSubagentsSelectionArmed
            || isPlanModeArmed
    }

    // Allows only one queued row at a time to move back into the composer.
    var canRestoreQueuedDrafts: Bool {
        !isSending
            && steeringDraftID == nil
            && !hasComposerDraftContent
    }

    var hasPendingComposerReviewSelection: Bool {
        composerReviewSelection != nil && composerReviewSelection?.target == nil
    }

    var hasComposerContentConflictingWithReview: Bool {
        TurnComposerCommandLogic.hasContentConflictingWithReview(
            trimmedInput: trimmedComposerInput,
            mentionedFileCount: composerMentionedFiles.count,
            mentionedSkillCount: composerMentionedSkills.count,
            attachmentCount: composerAttachments.count,
            hasSubagentsSelection: isSubagentsSelectionArmed
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

    // Moves one queued row back into the composer so the user can edit/resend it manually.
    func restoreQueuedDraftToComposer(id: String, codex: CodexService, threadID: String) {
        guard canRestoreQueuedDrafts else {
            return
        }

        var drafts = queuedDrafts(codex: codex, threadID: threadID)
        guard let draftIndex = drafts.firstIndex(where: { $0.id == id }) else {
            return
        }

        let draft = drafts.remove(at: draftIndex)
        setQueuedDrafts(drafts, codex: codex, threadID: threadID)
        restoreComposerState(from: draft)
        clearComposerAutocomplete()
        shouldAnchorToAssistantResponse = false
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
            hasPendingReviewSelection: hasPendingComposerReviewSelection,
            hasSubagentsSelection: isSubagentsSelectionArmed
        ).isSendDisabled
    }

    func clearComposer() {
        resetFileAutocompleteState()
        resetSkillAutocompleteState()
        resetSlashCommandState(clearPendingSelection: true, clearConfirmedSelection: true)
        isSubagentsSelectionArmed = false
        input = ""
        composerAttachments.removeAll()
        composerMentionedFiles.removeAll()
        composerMentionedSkills.removeAll()
    }

    // Appends spoken text into the composer without sending it automatically.
    func appendVoiceTranscript(_ transcript: String) {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            return
        }

        if input.isEmpty {
            input = normalizedTranscript
            return
        }

        if input.last?.isWhitespace == true {
            input += normalizedTranscript
        } else {
            input += " \(normalizedTranscript)"
        }
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

    // Dismisses only the transient slash-command picker without touching confirmed composer chips.
    func closeSlashCommandPanel() {
        resetSlashCommandState(clearPendingSelection: true)
    }

    // Clears the transient slash token before routing the user into another composer flow.
    func prepareForThreadRerouteFromSlashCommand() {
        removeTrailingSlashCommandTokenFromInputIfNeeded()
        resetSlashCommandState(clearPendingSelection: true)
    }

    // Applies one-shot composer state that a fresh thread should show on first open.
    func applyPendingComposerAction(_ action: CodexPendingThreadComposerAction) {
        switch action {
        case .codeReview(let target):
            armCodeReviewSelection(
                command: .codeReview,
                target: Self.turnComposerReviewTarget(for: target)
            )
        }
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

        // Keeps a confirmed `@file` mention closed once the user resumes normal prose after it.
        guard !Self.hasClosedConfirmedFileMentionPrefix(
            in: text,
            confirmedMentions: composerMentionedFiles
        ) else {
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

        switch slashCommandPanelState {
        case .codeReviewTargets, .forkDestinations:
            return
        case .hidden, .commands:
            break
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

    // Turns the selected slash command into the matching inline composer behavior.
    func onSelectSlashCommand(
        _ command: TurnComposerSlashCommand,
        availableForkDestinations: [TurnComposerForkDestination] = [.local]
    ) {
        switch command {
        case .codeReview:
            removeTrailingSlashCommandTokenFromInputIfNeeded()
            armCodeReviewSelection(command: command, target: nil)
        case .feedback:
            removeTrailingSlashCommandTokenFromInputIfNeeded()
            resetSlashCommandState(clearPendingSelection: true)
        case .fork:
            slashCommandPanelState = .forkDestinations(availableForkDestinations)
        case .status:
            removeTrailingSlashCommandTokenFromInputIfNeeded()
            resetSlashCommandState(clearPendingSelection: true)
        case .subagents:
            armSubagentsSelection()
        }
    }

    func onSelectCodeReviewTarget(_ target: TurnComposerReviewTarget) {
        removeTrailingSlashCommandTokenFromInputIfNeeded()
        armCodeReviewSelection(command: .codeReview, target: target)
    }

    // Keeps slash token cleanup and submenu dismissal consistent before a fork flow reroutes threads.
    func onSelectForkDestination(_ destination: TurnComposerForkDestination) {
        prepareForThreadRerouteFromSlashCommand()
    }

    func clearComposerReviewSelection() {
        composerReviewSelection = nil
        resetSlashCommandState()
    }

    func clearSubagentsSelection() {
        isSubagentsSelectionArmed = false
        resetSlashCommandState(clearPendingSelection: true)
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

    // Sends a composer payload, queueing follow-ups while the current run is still active.
    func sendTurn(
        codex: CodexService,
        subscriptions: SubscriptionService? = nil,
        threadID: String
    ) {
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

        if let subscriptions, !subscriptions.hasAppAccess {
            codex.lastErrorMessage = "Your 5 free messages are over. Unlock Remodex Pro to keep chatting."
            return
        }

        let queuedDraft = reviewSelection == nil ? QueuedTurnDraft(
            id: UUID().uuidString,
            text: payload,
            attachments: attachments,
            skillMentions: skillMentions,
            collaborationMode: isPlanModeArmed ? .plan : nil,
            rawInput: input,
            rawFileMentions: composerMentionedFiles,
            rawSkillMentions: composerMentionedSkills,
            rawAttachments: composerAttachments,
            rawSubagentsSelectionArmed: isSubagentsSelectionArmed,
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
            rawReviewSelection: reviewSelection,
            rawSubagentsSelectionArmed: isSubagentsSelectionArmed
        )
        let threadBusy = isThreadBusy(codex: codex, threadID: threadID)
        let queuePaused = isQueuePaused(codex: codex, threadID: threadID)

        subscriptions?.consumeFreeSendAttemptIfNeeded()
        isSending = true
        Task { @MainActor in
            defer { isSending = false }

            let stillBusy = await refreshBusyStateIfNeeded(codex: codex, threadID: threadID, wasBusy: threadBusy)
            if stillBusy {
                await performBusyThreadSend(
                    pendingSend,
                    queuedDraft: queuedDraft,
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
                    skillMentions: nextDraft.skillMentions,
                    fileMentions: confirmedFileMentionPaths(from: nextDraft.rawFileMentions),
                    collaborationMode: nextDraft.collaborationMode
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
                        skillMentions: draft.skillMentions,
                        fileMentions: confirmedFileMentionPaths(from: draft.rawFileMentions),
                        collaborationMode: draft.collaborationMode
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
                    fileMentions: confirmedFileMentionPaths(from: draft.rawFileMentions),
                    shouldAppendUserMessage: true,
                    collaborationMode: draft.collaborationMode
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

    func dismissStructuredPlanPrompt(_ message: CodexMessage, codex: CodexService, threadID: String) {
        guard let request = message.structuredUserInputRequest else {
            return
        }

        let requestKey = codex.idKey(from: request.requestID)
        guard !dismissedStructuredPlanPromptRequestKeys.contains(requestKey) else {
            return
        }
        guard dismissingStructuredPlanPromptRequestKeys.insert(requestKey).inserted else {
            return
        }

        isPlanModeArmed = false
        clearComposerAutocomplete()

        Task { @MainActor in
            defer {
                dismissingStructuredPlanPromptRequestKeys.remove(requestKey)
            }

            do {
                try await codex.cancelStructuredPlanSession(
                    requestID: request.requestID,
                    turnId: message.turnId,
                    threadId: threadID
                )
                dismissedStructuredPlanPromptRequestKeys.insert(requestKey)
            } catch {
                codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
            }
        }
    }

    func isStructuredPlanPromptDismissed(_ requestID: JSONValue, codex: CodexService) -> Bool {
        dismissedStructuredPlanPromptRequestKeys.contains(codex.idKey(from: requestID))
    }

    func isStructuredPlanPromptDismissing(_ requestID: JSONValue, codex: CodexService) -> Bool {
        dismissingStructuredPlanPromptRequestKeys.contains(codex.idKey(from: requestID))
    }

    func reconcileDismissedStructuredPlanPrompts(messages: [CodexMessage], codex: CodexService) {
        let activeRequestKeys: Set<String> = Set(messages.compactMap { message in
            guard message.kind == .userInputPrompt,
                  let request = message.structuredUserInputRequest else {
                return nil
            }
            return codex.idKey(from: request.requestID)
        })

        dismissedStructuredPlanPromptRequestKeys = dismissedStructuredPlanPromptRequestKeys.intersection(activeRequestKeys)
        dismissingStructuredPlanPromptRequestKeys = dismissingStructuredPlanPromptRequestKeys.intersection(activeRequestKeys)
    }

    func approve(
        _ request: CodexApprovalRequest,
        codex: CodexService,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        Task { @MainActor in
            isHandlingApproval = true
            defer { isHandlingApproval = false }

            do {
                try await codex.approvePendingRequest(request)
                completion(true)
            } catch {
                // Error message already stored in CodexService.
                if let serviceError = error as? CodexServiceError,
                   case .noPendingApproval = serviceError {
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    func decline(
        _ request: CodexApprovalRequest,
        codex: CodexService,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        Task { @MainActor in
            isHandlingApproval = true
            defer { isHandlingApproval = false }

            do {
                try await codex.declinePendingRequest(request)
                completion(true)
            } catch {
                // Error message already stored in CodexService.
                if let serviceError = error as? CodexServiceError,
                   case .noPendingApproval = serviceError {
                    completion(true)
                } else {
                    completion(false)
                }
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

    static func replacingTrailingSlashCommandToken(in text: String, with replacement: String) -> String? {
        TurnComposerCommandLogic.replacingTrailingSlashCommandToken(in: text, with: replacement)
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

    // Detects when the last `@mention` already matches a confirmed chip and the user is now typing prose after it.
    static func hasClosedConfirmedFileMentionPrefix(
        in text: String,
        confirmedMentions: [TurnComposerMentionedFile]
    ) -> Bool {
        guard !confirmedMentions.isEmpty,
              let triggerIndex = text.lastIndex(of: "@") else {
            return false
        }

        if triggerIndex > text.startIndex {
            let previousCharacter = text[text.index(before: triggerIndex)]
            guard previousCharacter.isWhitespace else {
                return false
            }
        }

        let tail = String(text[text.index(after: triggerIndex)...])
        guard !tail.isEmpty else {
            return false
        }

        let ambiguousKeys = ambiguousFileNameAliasKeys(in: confirmedMentions)
        for mention in confirmedMentions {
            let collisionKey = fileNameAliasCollisionKey(for: mention.fileName)
            let allowFileNameAliases = collisionKey.map { !ambiguousKeys.contains($0) } ?? true
            let aliases = fileMentionAliases(
                fileName: mention.fileName,
                path: mention.path,
                allowFileNameAliases: allowFileNameAliases
            )

            for alias in aliases {
                guard let range = tail.range(
                    of: alias,
                    options: [.anchored, .caseInsensitive]
                ) else {
                    continue
                }

                guard range.upperBound < tail.endIndex,
                      tail[range.upperBound].isWhitespace else {
                    continue
                }

                return true
            }
        }

        return false
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
              !query.contains(where: \.isNewline),
              isAllowedFileAutocompleteQuery(query) else {
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

    // Allows flexible file aliases while keeping common Swift attributes out of file search.
    private static func isAllowedFileAutocompleteQuery(_ query: String) -> Bool {
        TurnFileMentionHeuristics.isAllowedAutocompleteQuery(query)
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
        thread.gitWorkingDirectory
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
              (codex.runningThreadIDs.contains(threadID)
                || codex.protectedRunningFallbackThreadIDs.contains(threadID)) else {
            return wasBusy
        }

        _ = await codex.refreshInFlightTurnState(threadId: threadID)
        return isThreadBusy(codex: codex, threadID: threadID)
    }

    private func isThreadBusy(codex: CodexService, threadID: String) -> Bool {
        codex.threadHasActiveOrRunningTurn(threadID)
    }

    // Queues normal follow-ups while a run is active; explicit steer stays behind the queued-draft action.
    private func performBusyThreadSend(
        _ pendingSend: PendingTurnSend,
        queuedDraft: QueuedTurnDraft?,
        codex: CodexService,
        threadID: String
    ) async {
        if pendingSend.rawReviewSelection != nil {
            restoreComposerState(from: pendingSend)
            shouldAnchorToAssistantResponse = false
            codex.lastErrorMessage = "Wait for the current run to finish before starting a code review."
            return
        }

        guard let queuedDraft else {
            restoreComposerState(from: pendingSend)
            shouldAnchorToAssistantResponse = false
            return
        }

        isPlanModeArmed = false
        shouldAnchorToAssistantResponse = true
        appendQueuedDraft(queuedDraft, codex: codex, threadID: threadID)
        clearComposer()
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
                    fileMentions: confirmedFileMentionPaths(from: pendingSend.rawFileMentions),
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
            let fallbackMessage = codex.userFacingTurnErrorMessage(from: error)
            if (codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && !fallbackMessage.isEmpty {
                codex.lastErrorMessage = fallbackMessage
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
        isSubagentsSelectionArmed = pendingSend.rawSubagentsSelectionArmed
        isPlanModeArmed = pendingSend.collaborationMode == .plan
    }

    // Carries only autocomplete-confirmed file selections into the timeline renderer.
    private func confirmedFileMentionPaths(from mentions: [TurnComposerMentionedFile]) -> [String] {
        var uniquePaths: [String] = []
        var seenPaths: Set<String> = []

        for mention in mentions {
            let path = mention.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seenPaths.insert(path).inserted else {
                continue
            }
            uniquePaths.append(path)
        }

        return uniquePaths
    }

    // Restores a queued row using the exact composer payload captured before it entered the queue.
    private func restoreComposerState(from draft: QueuedTurnDraft) {
        input = draft.rawInput
        composerMentionedFiles = draft.rawFileMentions
        composerMentionedSkills = draft.rawSkillMentions
        composerAttachments = draft.rawAttachments
        composerReviewSelection = nil
        isSubagentsSelectionArmed = draft.rawSubagentsSelectionArmed
        isPlanModeArmed = draft.collaborationMode == .plan
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

    // Arms the composer-level subagents chip without leaking a slash token into the draft.
    private func armSubagentsSelection() {
        removeTrailingSlashCommandTokenFromInputIfNeeded()
        clearComposerReviewSelectionIfNeededForNonReviewContent()
        isSubagentsSelectionArmed = true
        resetSlashCommandState(clearPendingSelection: true)
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

    private static func turnComposerReviewTarget(
        for target: CodexPendingCodeReviewTarget
    ) -> TurnComposerReviewTarget {
        switch target {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            return .baseBranch
        }
    }

    // Prefixes the composer draft with the canned delegation prompt when the chip is armed.
    static func applyingSubagentsSelection(to text: String, isSelected: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSelected,
              let cannedPrompt = TurnComposerSlashCommand.subagents.cannedPrompt else {
            return trimmed
        }

        guard !trimmed.isEmpty else {
            return cannedPrompt
        }

        return "\(cannedPrompt)\n\n\(trimmed)"
    }

    // Replaces inline `@filename` with `@fullpath` for each mentioned file.
    private func buildPayloadWithMentions() -> String {
        var text = input

        if !composerMentionedFiles.isEmpty {
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
        }

        return Self.applyingSubagentsSelection(
            to: text,
            isSelected: isSubagentsSelectionArmed
        )
    }

    // Reuses the git base-branch selector so review requests stay aligned with the visible compare target.
    private func reviewBaseBranchName(for selection: TurnComposerReviewSelection) -> String? {
        guard selection.target == .baseBranch else {
            return nil
        }
        return selectedGitBaseBranch.nilIfEmpty ?? localSelectableGitDefaultBranch
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
                    if result.state == "behind_only" {
                        let pullResult = try await gitService.pull()
                        if let status = pullResult.status {
                            applyGitRepoSync(status)
                        }
                    } else if result.state == "diverged" || result.state == "dirty_and_behind" {
                        gitSyncAlert = TurnGitSyncAlert(
                            title: result.state == "diverged" ? "Branch diverged from remote" : "Local changes need attention",
                            message: result.state == "diverged"
                                ? "Local and remote history both moved. Pull with rebase to reconcile them?"
                                : "You have local changes and the remote branch moved ahead. Pull with rebase only if you're ready to reconcile those changes.",
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
                    if let validationMessage = createPullRequestValidationMessage {
                        throw GitActionsError.bridgeError(code: "pull_request_unavailable", message: validationMessage)
                    }
                    let remoteResult = try await getRemoteURL(codex: codex, workingDirectory: workingDirectory)
                    guard let ownerRepo = remoteResult.ownerRepo else {
                        throw GitActionsError.bridgeError(code: "no_remote", message: "Could not determine repository from remote URL.")
                    }
                    let branch = gitRepoSync?.currentBranch ?? currentGitBranch.nilIfEmpty ?? ""
                    guard !branch.isEmpty else {
                        throw GitActionsError.bridgeError(code: "no_branch", message: "No current branch found.")
                    }
                    let base = gitDefaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !base.isEmpty else {
                        throw GitActionsError.bridgeError(
                            code: "no_default_branch",
                            message: "Could not determine the repository default branch."
                        )
                    }
                    let prURL = buildPRURL(ownerRepo: ownerRepo, branch: branch, base: base)
                    if let url = URL(string: prURL) {
                        await UIApplication.shared.open(url)
                    }

                case .discardRuntimeChangesAndSync:
                    let unpushedCommitWarning: String
                    if let repoSync = gitRepoSync, repoSync.aheadCount > 0 {
                        let commitLabel = repoSync.aheadCount == 1 ? "1 local commit" : "\(repoSync.aheadCount) local commits"
                        unpushedCommitWarning = " This also deletes \(commitLabel) that have not been pushed."
                    } else {
                        unpushedCommitWarning = ""
                    }
                    gitSyncAlert = TurnGitSyncAlert(
                        title: "Discard local changes?",
                        message: "This resets the current branch to match the remote and removes local uncommitted changes.\(unpushedCommitWarning) This cannot be undone from the app.",
                        buttons: [
                            TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                            TurnGitSyncAlertButton(title: "Discard Changes", role: .destructive, action: .discardRuntimeChanges)
                        ]
                    )
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
        inlineCommitAndPushPhase = .committing

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.runningGitAction = nil
                self.inlineCommitAndPushPhase = nil
            }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                _ = try await gitService.commit(message: nil)
                inlineCommitAndPushPhase = .pushing
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
