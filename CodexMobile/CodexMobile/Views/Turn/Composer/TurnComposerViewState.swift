// FILE: TurnComposerViewState.swift
// Purpose: Groups the heaviest composer render inputs into focused value types for smaller view sections.
// Layer: View Support
// Exports: TurnComposerAutocompleteState, TurnComposerAccessoryState
// Depends on: SwiftUI, TurnComposer command/attachment/message models

import SwiftUI

struct TurnComposerAutocompleteState {
    let availableSlashCommands: [TurnComposerSlashCommand]
    let fileAutocompleteItems: [CodexFuzzyFileMatch]
    let isFileAutocompleteVisible: Bool
    let isFileAutocompleteLoading: Bool
    let fileAutocompleteQuery: String
    let skillAutocompleteItems: [CodexSkillMetadata]
    let isSkillAutocompleteVisible: Bool
    let isSkillAutocompleteLoading: Bool
    let skillAutocompleteQuery: String
    let pluginAutocompleteItems: [CodexPluginMetadata]
    let isPluginAutocompleteVisible: Bool
    let isPluginAutocompleteLoading: Bool
    let pluginAutocompleteQuery: String
    let slashCommandPanelState: TurnComposerSlashCommandPanelState
    let hasComposerContentConflictingWithReview: Bool
    let isThreadRunning: Bool
    let showsGitBranchSelector: Bool
    let isLoadingGitBranchTargets: Bool
    let availableGitBranchTargets: [String]
    let selectedGitBaseBranch: String
    let gitDefaultBranch: String
}

struct TurnComposerAccessoryState {
    let queuedDrafts: [QueuedTurnDraft]
    let canSteerQueuedDrafts: Bool
    let canRestoreQueuedDrafts: Bool
    let steeringDraftID: String?
    let composerAttachments: [TurnComposerImageAttachment]
    let composerMentionedFiles: [TurnComposerMentionedFile]
    let composerMentionedSkills: [TurnComposerMentionedSkill]
    let composerMentionedPlugins: [TurnComposerMentionedPlugin]
    let composerReviewSelection: TurnComposerReviewSelection?
    let isSubagentsSelectionArmed: Bool
    let isPlanModeArmed: Bool
    let isVoiceRecording: Bool
    let voiceAudioLevels: [CGFloat]
    let voiceRecordingDuration: TimeInterval

    var hasQueuedDrafts: Bool {
        !queuedDrafts.isEmpty
    }

    var showsComposerAttachments: Bool {
        !composerAttachments.isEmpty
    }

    var showsMentionedFiles: Bool {
        !showsVoiceRecordingCapsule && !hasQueuedDrafts && !composerMentionedFiles.isEmpty
    }

    var showsMentionedSkills: Bool {
        !showsVoiceRecordingCapsule && !hasQueuedDrafts && !composerMentionedSkills.isEmpty
    }

    var showsMentionedPlugins: Bool {
        !showsVoiceRecordingCapsule && !hasQueuedDrafts && !composerMentionedPlugins.isEmpty
    }

    var reviewTarget: TurnComposerReviewTarget? {
        composerReviewSelection?.target
    }

    var showsSubagentsSelection: Bool {
        !showsVoiceRecordingCapsule && !hasQueuedDrafts && isSubagentsSelectionArmed
    }

    var showsPlanModeSelection: Bool {
        !showsVoiceRecordingCapsule && !hasQueuedDrafts && isPlanModeArmed
    }

    var showsReviewSelection: Bool {
        !showsVoiceRecordingCapsule && !hasQueuedDrafts && reviewTarget != nil
    }

    var showsVoiceRecordingCapsule: Bool {
        isVoiceRecording
    }

    var hasTopAccessoryContent: Bool {
        showsComposerAttachments
            || showsMentionedFiles
            || showsMentionedSkills
            || showsMentionedPlugins
            || showsSubagentsSelection
            || showsPlanModeSelection
            || showsReviewSelection
    }

    // Tracks composer content that can make a follow-up send meaningful while a turn is running.
    func hasSendableContent(input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !composerAttachments.isEmpty
            || !composerMentionedFiles.isEmpty
            || !composerMentionedSkills.isEmpty
            || !composerMentionedPlugins.isEmpty
            || composerReviewSelection != nil
            || isSubagentsSelectionArmed
            || isPlanModeArmed
    }

    var topInputPadding: CGFloat {
        hasTopAccessoryContent ? 6 : 10
    }
}
