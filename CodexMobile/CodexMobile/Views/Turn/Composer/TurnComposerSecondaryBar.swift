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
    var threadGoal: CodexThreadGoal? = nil
    var isThreadRunning = false
    var onEditGoal: () -> Void = {}
    var onRemoveGoal: () -> Void = {}
    var queuedDraftCount: Int = 0
    var onTapQueuedDrafts: () -> Void = {}

    let gitState: TurnComposerGitState
    let gitActions: TurnComposerGitActions

    @Environment(\.pinnedPlanAccessory) private var pinnedPlanAccessory
    @State private var isContextClusterExpanded = false
    @State private var isGoalExpanded = false
    @State private var displayedFileChangeStatus: FileChangeStatusSnapshot?

    private enum AccessoryID: Hashable {
        case context
        case fileChanges
        case goal
        case plan
        case queuedDrafts
    }

    // Presence is decided by the call site (TurnComposerView) so the parent
    // VStack never hosts an empty child that could leave stray spacing.
    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 8) {
                    if hasWorkingDirectory {
                        TurnComposerCollapsibleContextCluster(isExpanded: $isContextClusterExpanded)
                            .id(AccessoryID.context)
                    }

                    // File changes lead the pills, right after the chevron.
                    if let displayedFileChangeStatus {
                        FileChangeStatusCapsule(snapshot: displayedFileChangeStatus)
                            .id(AccessoryID.fileChanges)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }

                    // Goal follows file changes and uses the same compact pill language.
                    if let threadGoal {
                        GoalStatusChip(
                            goal: threadGoal,
                            isThreadRunning: isThreadRunning,
                            onEdit: onEditGoal,
                            onRemove: onRemoveGoal,
                            onExpansionChange: { isExpanded in
                                isGoalExpanded = isExpanded
                                centerGoal(using: scrollProxy)
                            }
                        )
                        .id(AccessoryID.goal)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }

                    if let pinnedPlanAccessory {
                        PlanAccessoryCard(
                            snapshot: pinnedPlanAccessory.snapshot,
                            onTap: pinnedPlanAccessory.onTap
                        )
                        .id(AccessoryID.plan)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }

                    if queuedDraftCount > 0 {
                        QueuedStatusCapsule(count: queuedDraftCount, onTap: onTapQueuedDrafts)
                            .id(AccessoryID.queuedDrafts)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollBounceBehavior(.basedOnSize)
            // Let the capsules' glass shadows breathe past the scroll bounds.
            .scrollClipDisabled()
            // Re-center an open goal if a leading capsule is inserted or removed.
            .onChange(of: displayedFileChangeStatus != nil) { _, _ in
                guard isGoalExpanded else { return }
                centerGoal(using: scrollProxy)
            }
            .onChange(of: threadGoal != nil) { _, isPresent in
                if !isPresent {
                    isGoalExpanded = false
                }
            }
        }
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
        // Animate structural insertions/removals only. Count, status and timer
        // updates should not re-animate and reflow the entire accessory strip.
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: displayedFileChangeStatus != nil)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: threadGoal != nil)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: queuedDraftCount > 0)
        .task(id: activeFileChangeStatus) {
            if let activeFileChangeStatus {
                // Count and label changes stay live without rebuilding the row.
                displayedFileChangeStatus = activeFileChangeStatus
                return
            }

            // App-server refreshes can briefly publish nil between two snapshots.
            // Keep the slot stable across that gap to avoid remove/reinsert reflow.
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            displayedFileChangeStatus = nil
        }
    }

    private func centerGoal(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            // Wait one layout pass so scrollTo sees the expanded card width.
            await Task.yield()
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(AccessoryID.goal, anchor: .center)
            }
        }
    }
}
