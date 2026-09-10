// FILE: SidebarActivityListView.swift
// Purpose: Collapsible Activity sections and visible-row Git metadata loading.
// Layer: View Component

import SwiftUI

struct SidebarActivityListView<Row: View>: View {
    let threads: [CodexThread]
    let isVisible: Bool
    let refreshGeneration: Int
    @ViewBuilder let row: (CodexThread, GitDiffTotals?) -> Row

    @Environment(CodexService.self) private var codex
    @State private var collapsedSections: Set<SidebarActivitySectionKind> = []
    @State private var now = Date()
    @State private var diffStore = SidebarActivityDiffStore()

    var body: some View {
        // Observe runtime state here, where sections and rows are rendered. A
        // cached parent snapshot can lag when only the running state changes.
        let runBadges = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            codex.threadRunBadgeState(for: thread.id).map { (thread.id, $0) }
        })
        let sortedThreads = SidebarThreadGrouping.activityThreads(
            from: threads,
            runBadgeStateByThreadID: runBadges
        )
        let sections = SidebarActivitySection.makeSections(from: sortedThreads, runBadges: runBadges, now: now)
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { section in
                sectionHeader(section.kind)
                if !collapsedSections.contains(section.kind) {
                    ForEach(section.threads) { thread in
                        activityRow(thread, runBadge: runBadges[thread.id])
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            now = Date()
        }
        .onChange(of: isVisible) { _, visible in
            if visible { now = Date() } else { diffStore.cancelPendingRequests() }
        }
        .onDisappear { diffStore.cancelPendingRequests() }
    }

    private func sectionHeader(_ kind: SidebarActivitySectionKind) -> some View {
        let isExpanded = !collapsedSections.contains(kind)
        return HapticButton {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isExpanded { collapsedSections.insert(kind) } else { collapsedSections.remove(kind) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(kind.title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                RemodexIcon.image(systemName: isExpanded ? "chevron.down" : "chevron.right", size: 10)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func activityRow(_ thread: CodexThread, runBadge: CodexThreadRunBadgeState?) -> some View {
        let path = thread.gitWorkingDirectory
        let canRefresh = isVisible && codex.isConnected && codex.isInitialized && codex.isAppInForeground
        let isRunning = runBadge == .running
        let refreshKey = ActivityRowRefreshKey(path: path, enabled: canRefresh, generation: refreshGeneration, isRunning: isRunning)
        return row(thread, path.flatMap { diffStore.totalsByPath[$0] })
            .padding(.horizontal, 4)
            .task(id: refreshKey) {
                guard canRefresh, let path, !path.isEmpty else { return }
                // The row task is cancelled when hidden, disconnected, or no
                // longer running. The store coalesces polling per checkout.
                repeat {
                    await diffStore.refresh(
                        path: path, codex: codex, revision: refreshGeneration,
                        maxAge: isRunning ? 15 : 30
                    )
                    guard isRunning else { return }
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                } while !Task.isCancelled
            }
            .onChange(of: runBadge) { _, _ in
                guard canRefresh else { return }
                Task { await diffStore.refresh(path: path, codex: codex, revision: refreshGeneration, force: true) }
            }
    }
}

private struct ActivityRowRefreshKey: Equatable {
    let path: String?
    let enabled: Bool
    let generation: Int
    let isRunning: Bool
}
