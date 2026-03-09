// FILE: SidebarThreadListView.swift
// Purpose: Renders sidebar thread groups and empty states.
// Layer: View Component
// Exports: SidebarThreadListView

import SwiftUI

struct SidebarThreadListView: View {
    var isFiltering: Bool = false
    let isConnected: Bool
    let isCreatingThread: Bool
    let threads: [CodexThread]
    let groups: [SidebarThreadGroup]
    let selectedThread: CodexThread?
    let bottomContentInset: CGFloat
    let timingLabelProvider: (CodexThread) -> String?
    let diffTotalsByThreadID: [String: TurnSessionDiffTotals]
    let runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    let onSelectThread: (CodexThread) -> Void
    let onCreateThreadInProjectGroup: (SidebarThreadGroup) -> Void
    var onDeleteProjectGroup: ((SidebarThreadGroup) -> Void)? = nil
    var onRenameThread: ((CodexThread, String) -> Void)? = nil
    var onArchiveToggleThread: ((CodexThread) -> Void)? = nil
    var onDeleteThread: ((CodexThread) -> Void)? = nil
    @State private var expandedProjectGroupIDs: Set<String> = []
    @State private var isArchivedExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                if threads.isEmpty && !isFiltering {
                    Text(isConnected ? "No conversations" : "Connect to view conversations")
                        .foregroundStyle(.secondary)
                        .font(AppFont.subheadline())
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                } else if groups.flatMap(\.threads).isEmpty && isFiltering {
                    Text("No matching conversations")
                        .foregroundStyle(.secondary)
                        .font(AppFont.subheadline())
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                } else {
                    ForEach(groups) { group in
                        groupSection(group)
                    }
                }
            }
            // Keeps the last rows reachable above the floating settings control.
            .padding(.bottom, bottomContentInset)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            syncExpandedProjectGroupState()
        }
        .onChange(of: groups.map(\.id)) { _, _ in
            syncExpandedProjectGroupState()
        }
        .onChange(of: selectedThread?.id) { _, _ in
            syncExpandedProjectGroupState()
        }
    }

    @ViewBuilder
    private func groupSection(_ group: SidebarThreadGroup) -> some View {
        switch group.kind {
        case .project:
            projectGroupSection(group)

        case .archived:
            archivedGroupSection(group)
        }
    }

    private func projectGroupSection(_ group: SidebarThreadGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            projectHeader(group)

            if expandedProjectGroupIDs.contains(group.id) {
                VStack(spacing: 4) {
                    ForEach(group.threads) { thread in
                        threadRow(thread)
                    }
                }
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    private func projectHeader(_ group: SidebarThreadGroup) -> some View {
        HStack(spacing: 12) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                toggleProjectGroupExpansion(group.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.primary)
                    Text(group.label)
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let onDeleteProjectGroup {
                    Button(role: .destructive) {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onDeleteProjectGroup(group)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback()
                onCreateThreadInProjectGroup(group)
            } label: {
                Image(systemName: "plus")
                    .font(AppFont.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || isCreatingThread)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func archivedGroupSection(_ group: SidebarThreadGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isArchivedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.primary)
                    Text(group.label)
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isArchivedExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isArchivedExpanded)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if isArchivedExpanded {
                VStack(spacing: 4) {
                    ForEach(group.threads) { thread in
                        threadRow(thread)
                    }
                }
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    private func threadRow(_ thread: CodexThread) -> some View {
        SidebarThreadRowView(
            thread: thread,
            isSelected: selectedThread?.id == thread.id,
            runBadgeState: runBadgeStateByThreadID[thread.id],
            timingLabel: timingLabelProvider(thread),
            diffTotals: diffTotalsByThreadID[thread.id],
            onTap: { onSelectThread(thread) },
            onRename: onRenameThread.map { handler in { newName in handler(thread, newName) } },
            onArchiveToggle: onArchiveToggleThread.map { handler in { handler(thread) } },
            onDelete: onDeleteThread.map { handler in { handler(thread) } }
        )
    }

    private func toggleProjectGroupExpansion(_ groupID: String) {
        if expandedProjectGroupIDs.contains(groupID) {
            expandedProjectGroupIDs.remove(groupID)
        } else {
            expandedProjectGroupIDs.insert(groupID)
        }
    }

    // Keep project sections expanded after regrouping so live updates do not collapse the sidebar.
    private func syncExpandedProjectGroupState() {
        let allGroupIDs = Set(groups.map(\.id))
        expandedProjectGroupIDs = expandedProjectGroupIDs.union(allGroupIDs)
    }
}
