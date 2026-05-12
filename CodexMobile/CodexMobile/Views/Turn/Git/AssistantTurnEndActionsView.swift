// FILE: AssistantTurnEndActionsView.swift
// Purpose: Renders assistant block-end Diff/Revert/Commit controls.
// Layer: View Component
// Exports: AssistantTurnEndActionsView
// Depends on: SwiftUI, TurnDiffSheet, AssistantBlockAccessoryState

import SwiftUI

struct AssistantTurnEndActionsView: View {
    let message: CodexMessage
    let accessoryState: AssistantBlockAccessoryState
    let inlineCommitAndPushAction: (() -> Void)?
    let inlineCommitAndPushPhase: InlineCommitAndPushPhase?
    let assistantRevertAction: ((CodexMessage) -> Void)?

    @State private var isShowingBlockDiffSheet = false

    private var isInlineCommitAndPushRunning: Bool {
        inlineCommitAndPushPhase != nil
    }

    private var inlineCommitAndPushTitle: String {
        inlineCommitAndPushPhase?.title ?? "Commit & Push"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let revert = accessoryState.blockRevertPresentation {
                assistantRevertButton(
                    presentation: revert,
                    targetMessage: accessoryState.blockRevertMessage ?? message
                )
            }

            HStack(spacing: 10) {
                if let entries = accessoryState.blockDiffEntries, !entries.isEmpty {
                    diffButton(entries: entries)
                }

                if let action = inlineCommitAndPushAction {
                    inlineCommitAndPushButton(action: action)
                }
            }
        }
    }

    private func diffButton(entries: [TurnFileChangeSummaryEntry]) -> some View {
        let totalAdditions = entries.reduce(0) { $0 + $1.additions }
        let totalDeletions = entries.reduce(0) { $0 + $1.deletions }

        return Button {
            isShowingBlockDiffSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(AppFont.system(size: 10, weight: .medium))
                Text("Diff")
                DiffCountsLabel(additions: totalAdditions, deletions: totalDeletions)
            }
            .font(AppFont.mono(.body))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingBlockDiffSheet) {
            TurnDiffSheet(
                title: "Changes",
                entries: entries,
                bodyText: accessoryState.blockDiffText ?? "",
                messageID: message.id
            )
        }
    }

    private func inlineCommitAndPushButton(action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            HStack(spacing: 4) {
                // Mirror the top-bar git feedback so the inline CTA feels responsive too.
                Group {
                    if isInlineCommitAndPushRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image("cloud-upload")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 18, height: 18)
                Text(inlineCommitAndPushTitle)
            }
            .font(AppFont.mono(.body))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isInlineCommitAndPushRunning)
    }

    private func assistantRevertButton(
        presentation: AssistantRevertPresentation,
        targetMessage: CodexMessage
    ) -> some View {
        let iconName: String = {
            switch presentation.riskLevel {
            case .safe:
                return "arrow.uturn.backward.circle"
            case .warning:
                return "exclamationmark.circle"
            case .blocked:
                return "exclamationmark.triangle"
            }
        }()
        let accentColor: Color = {
            switch presentation.riskLevel {
            case .safe:
                return .primary
            case .warning:
                return .orange
            case .blocked:
                return .secondary
            }
        }()

        return Button {
            guard presentation.isEnabled else { return }
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            assistantRevertAction?(targetMessage)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(AppFont.system(size: 10, weight: .medium))
                    .foregroundStyle(accentColor)
                Text(presentation.title)
                    .lineLimit(1)
            }
            .font(AppFont.mono(.body))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .accessibilityHint(presentation.warningText ?? presentation.helperText ?? "")
    }
}
