// FILE: TurnComposerViewState.swift
// Purpose: Groups the heaviest composer render inputs into focused value types for smaller view sections.
// Layer: View Support
// Exports: TurnComposerAutocompleteState, TurnComposerAccessoryState
// Depends on: SwiftUI, TurnComposer command/attachment/message models

import SwiftUI

struct TurnComposerAutocompleteState {
    let fileAutocompleteItems: [CodexFuzzyFileMatch]
    let isFileAutocompleteVisible: Bool
    let isFileAutocompleteLoading: Bool
    let fileAutocompleteQuery: String
    let skillAutocompleteItems: [CodexSkillMetadata]
    let isSkillAutocompleteVisible: Bool
    let isSkillAutocompleteLoading: Bool
    let skillAutocompleteQuery: String
    let slashCommandPanelState: TurnComposerSlashCommandPanelState
    let hasComposerContentConflictingWithReview: Bool
    let showsGitBranchSelector: Bool
    let isLoadingGitBranchTargets: Bool
    let selectedGitBaseBranch: String
    let gitDefaultBranch: String
}

struct TurnComposerAccessoryState {
    let queuedDrafts: [QueuedTurnDraft]
    let canSteerQueuedDrafts: Bool
    let steeringDraftID: String?
    let composerAttachments: [TurnComposerImageAttachment]
    let composerMentionedFiles: [TurnComposerMentionedFile]
    let composerMentionedSkills: [TurnComposerMentionedSkill]
    let composerReviewSelection: TurnComposerReviewSelection?
    let isSubagentsSelectionArmed: Bool

    var showsComposerAttachments: Bool {
        !composerAttachments.isEmpty
    }

    var showsMentionedFiles: Bool {
        !composerMentionedFiles.isEmpty
    }

    var showsMentionedSkills: Bool {
        !composerMentionedSkills.isEmpty
    }

    var reviewTarget: TurnComposerReviewTarget? {
        composerReviewSelection?.target
    }

    var showsSubagentsSelection: Bool {
        isSubagentsSelectionArmed
    }

    var topInputPadding: CGFloat {
        showsComposerAttachments || showsMentionedFiles || showsMentionedSkills || showsSubagentsSelection || reviewTarget != nil ? 8 : 14
    }
}
