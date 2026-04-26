// FILE: TurnToolbarContent.swift
// Purpose: Encapsulates the TurnView navigation toolbar and thread-path sheet.
// Layer: View Component
// Exports: TurnToolbarContent, TurnThreadNavigationContext

import SwiftUI

struct TurnThreadNavigationContext {
    let folderName: String
    let subtitle: String
    let fullPath: String
}

struct TurnToolbarContent: ToolbarContent {
    let displayTitle: String
    let navigationContext: TurnThreadNavigationContext?
    let showsThreadActions: Bool
    let isHandingOffToMac: Bool
    let isStartingNewChat: Bool
    let canHandOffToWorktree: Bool
    let worktreeHandoffTitle: String
    let isCreatingGitWorktree: Bool
    let repoDiffTotals: GitDiffTotals?
    let isLoadingRepoDiff: Bool
    let showsGitActions: Bool
    let isGitActionEnabled: Bool
    let disabledGitActions: Set<TurnGitActionKind>
    let isRunningGitAction: Bool
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    var onTapMacHandoff: (() -> Void)?
    var onTapWorktreeHandoff: (() -> Void)?
    var onTapNewChat: (() -> Void)?
    var onTapRepoDiff: (() -> Void)?
    let onGitAction: (TurnGitActionKind) -> Void

    @Binding var isShowingPathSheet: Bool

    var body: some ToolbarContent {
        let hasTrailingCluster = repoDiffTotals != nil || showsGitActions
        let isThreadActionLoading = isHandingOffToMac || isStartingNewChat
        let canTapMacHandoff = onTapMacHandoff != nil && !isThreadActionLoading
        let canTapWorktreeHandoff = onTapWorktreeHandoff != nil
            && canHandOffToWorktree
            && !isCreatingGitWorktree
            && !isThreadActionLoading
        let canTapNewChat = onTapNewChat != nil && !isThreadActionLoading

        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(AppFont.headline())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let context = navigationContext {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        isShowingPathSheet = true
                    } label: {
                        Text(context.subtitle)
                            .font(AppFont.mono(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if showsThreadActions {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Keeps all "branch from here" actions together behind the compact toolbar affordance.
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onTapMacHandoff?()
                    } label: {
                        HStack(spacing: 10) {
                            ResizableThreadActionSymbol(systemName: "arrow.left.arrow.right", pointSize: 13)
                            Text("Continue on Desktop App")
                        }
                    }
                    .disabled(!canTapMacHandoff)

                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onTapWorktreeHandoff?()
                    } label: {
                        CodexWorktreeMenuLabelRow(
                            title: isCreatingGitWorktree ? "Preparing worktree..." : worktreeHandoffTitle,
                            pointSize: 12,
                            weight: .regular
                        )
                    }
                    .disabled(!canTapWorktreeHandoff)

                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onTapNewChat?()
                    } label: {
                        HStack(spacing: 10) {
                            ResizableThreadActionSymbol(systemName: "plus.app", pointSize: 13)
                            Text("New chat")
                        }
                    }
                    .disabled(!canTapNewChat)
                } label: {
                    TurnMacHandoffToolbarLabel(isLoading: isThreadActionLoading)
                }
                .accessibilityLabel("Thread actions")
            }
        }

        if showsThreadActions, hasTrailingCluster {
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }

        if repoDiffTotals != nil || showsGitActions {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let repoDiffTotals {
                    TurnToolbarDiffTotalsLabel(
                        totals: repoDiffTotals,
                        isLoading: isLoadingRepoDiff,
                        onTap: onTapRepoDiff
                    )
                }

                if showsGitActions {
                    TurnGitActionsToolbarButton(
                        isEnabled: isGitActionEnabled,
                        disabledActions: disabledGitActions,
                        isRunningAction: isRunningGitAction,
                        showsDiscardRuntimeChangesAndSync: showsDiscardRuntimeChangesAndSync,
                        gitSyncState: gitSyncState,
                        onSelect: onGitAction
                    )
                }
            }
        }
    }
}

private struct TurnMacHandoffToolbarLabel: View {
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                ResizableThreadActionSymbol(systemName: "arrow.trianglehead.branch", pointSize: 14)
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
            }
        }
        .contentShape(Circle())
        .adaptiveToolbarItem(in: Circle())
    }
}

private struct ResizableThreadActionSymbol: View {
    let systemName: String
    let pointSize: CGFloat
    var weight: UIImage.SymbolWeight = .semibold

    var body: some View {
        Image(uiImage: resizedSymbol(named: systemName, pointSize: pointSize, weight: weight))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
    }

    private func resizedSymbol(named name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = UIImage(systemName: name, withConfiguration: config)?
            .withRenderingMode(.alwaysTemplate) else {
            return UIImage()
        }

        let canvasSide = max(symbol.size.width, symbol.size.height)
        let canvasSize = CGSize(width: canvasSide, height: canvasSide)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let scale = min(canvasSize.width / symbol.size.width, canvasSize.height / symbol.size.height)
        let scaledSize = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let origin = CGPoint(
            x: (canvasSize.width - scaledSize.width) / 2,
            y: (canvasSize.height - scaledSize.height) / 2
        )

        return renderer.image { _ in
            symbol.draw(in: CGRect(origin: origin, size: scaledSize))
        }
        .withRenderingMode(.alwaysTemplate)
    }
}

private struct TurnToolbarDiffTotalsLabel: View {
    let totals: GitDiffTotals
    let isLoading: Bool
    let onTap: (() -> Void)?

    // Keeps small diff totals tappable without forcing large-count pills into a fixed width.
    private let minPillWidth: CGFloat = 50

    var body: some View {
        Group {
            if let onTap {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onTap()
                } label: {
                    labelContent
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            } else {
                labelContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Repository diff total")
        .accessibilityValue(accessibilityValue)
    }

    private var labelContent: some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text("+\(totals.additions)")
                .foregroundStyle(Color.green)
            Text("-\(totals.deletions)")
                .foregroundStyle(Color.red)
            if totals.binaryFiles > 0 {
                Text("B\(totals.binaryFiles)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(AppFont.mono(.caption))
        .frame(minWidth: minPillWidth, minHeight: 28)
        .contentShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .opacity(isLoading ? 0.8 : 1)
        .adaptiveToolbarItem(in: Capsule())
    }

    private var accessibilityValue: String {
        if totals.binaryFiles > 0 {
            return "+\(totals.additions) -\(totals.deletions) binary \(totals.binaryFiles)"
        }
        return "+\(totals.additions) -\(totals.deletions)"
    }
}

struct TurnThreadPathSheet: View {
    let context: TurnThreadNavigationContext
    let threadTitle: String
    var onRenameThread: ((String) -> Void)? = nil

    @State private var renamePrompt = ThreadRenamePromptState()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if onRenameThread != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Thread")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(.secondary)

                            HStack(alignment: .center, spacing: 12) {
                                Text(threadTitle)
                                    .font(AppFont.body(weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                    renamePrompt.present(currentTitle: threadTitle)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(AppFont.system(size: 14, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Rename conversation")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Path")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(context.fullPath)
                            .font(AppFont.mono(.callout))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle(context.folderName)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
        }
        .presentationDetents([.fraction(0.4), .medium])
        .threadRenamePrompt(state: $renamePrompt) { newTitle in
            onRenameThread?(newTitle)
        }
    }
}
