// FILE: TurnComposerSecondaryBar.swift
// Purpose: Owns the secondary composer accessories above the main input card: a centered
//          file-change capsule and a horizontally scrollable carousel (chevron, plan, queued).
// Layer: View Component
// Exports: TurnComposerSecondaryBar
// Depends on: SwiftUI, TurnComposerCollapsibleContextCluster, PlanAccessoryCard, QueuedStatusCapsule

import SwiftUI

struct TurnComposerSecondaryBar: View {
    let isEmptyThread: Bool
    let hasWorkingDirectory: Bool
    let isWorktreeProject: Bool
    var activeFileChangeStatus: FileChangeStatusSnapshot? = nil
    var queuedDraftCount: Int = 0
    var onTapQueuedDrafts: () -> Void = {}

    let gitState: TurnComposerGitState
    let gitActions: TurnComposerGitActions

    @Environment(\.pinnedPlanAccessory) private var pinnedPlanAccessory
    @State private var isContextClusterExpanded = false

    // Presence is decided by the call site (TurnComposerView) so the parent
    // VStack never hosts an empty child that could leave stray spacing.
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if hasWorkingDirectory {
                    TurnComposerCollapsibleContextCluster(isExpanded: $isContextClusterExpanded)
                }

                // File changes lead the pills, right after the chevron.
                if let activeFileChangeStatus {
                    FileChangeStatusCapsule(snapshot: activeFileChangeStatus)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                if let pinnedPlanAccessory {
                    PlanAccessoryCard(
                        snapshot: pinnedPlanAccessory.snapshot,
                        onTap: pinnedPlanAccessory.onTap
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                if queuedDraftCount > 0 {
                    QueuedStatusCapsule(count: queuedDraftCount, onTap: onTapQueuedDrafts)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Let the capsules' glass shadows breathe past the scroll bounds.
        .scrollClipDisabled()
        // The expanded pills must overlay the ScrollView from OUTSIDE: content
        // floating above a UIScrollView's bounds renders with clipping off but
        // never receives touches, so hosting the column inside the carousel
        // left "main"/"Local" visible yet dead to taps.
        .overlay(alignment: .bottomLeading) {
            if isContextClusterExpanded {
                TurnComposerContextClusterFloatingColumn(
                    isEmptyThread: isEmptyThread,
                    hasWorkingDirectory: hasWorkingDirectory,
                    isWorktreeProject: isWorktreeProject,
                    gitState: gitState,
                    gitActions: gitActions
                )
                .transition(.contextClusterReveal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: activeFileChangeStatus)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: queuedDraftCount > 0)
    }
}
