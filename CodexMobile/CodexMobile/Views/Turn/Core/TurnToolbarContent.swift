// FILE: TurnToolbarContent.swift
// Purpose: Encapsulates the TurnView navigation toolbar and thread-path sheet.
// Layer: View Component
// Exports: TurnToolbarContent, TurnThreadNavigationContext,
//          TurnThreadActionsMenuButton, TurnThreadActionMenuItem

import SwiftUI
import UIKit

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
    let gitActionLoadingTitle: String?
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    var onTapMacHandoff: (() -> Void)?
    var onTapWorktreeHandoff: (() -> Void)?
    var onTapNewChat: (() -> Void)?
    var onTapTerminal: (() -> Void)?
    var onTapRepoDiff: (() -> Void)?
    let onGitAction: (TurnGitActionKind) -> Void

    @Binding var isShowingPathSheet: Bool

    var body: some ToolbarContent {
        let isThreadActionLoading = isHandingOffToMac || isStartingNewChat
        let canTapMacHandoff = onTapMacHandoff != nil && !isThreadActionLoading
        // Worktree handoff has its own Git/worktree gates; keep it aligned with the composer Local menu.
        let canTapWorktreeHandoff = onTapWorktreeHandoff != nil
            && canHandOffToWorktree
            && !isCreatingGitWorktree
        let canTapNewChat = onTapNewChat != nil && !isThreadActionLoading
        let canTapTerminal = onTapTerminal != nil
        let threadActions = threadActionItems(
            canTapMacHandoff: canTapMacHandoff,
            canTapWorktreeHandoff: canTapWorktreeHandoff,
            canTapNewChat: canTapNewChat,
            canTapTerminal: canTapTerminal
        )

        // Keep title + path as one leading-aligned control. Splitting them into
        // iOS 26 `.title` / `.subtitle` placements lets the system align each
        // row independently, which makes the stack look offset.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .title) {
                titleTapTarget
            }
        } else {
            ToolbarItem(placement: .principal) {
                titleTapTarget
            }
        }

        // Order: git actions sit closest to the title, the ellipsis thread-
        // actions menu trails after them.
        //
        // iOS 26: emit two adjacent ToolbarItems with no ToolbarSpacer so the
        // system merges them into a single shared glass capsule. Wrapping both
        // buttons inside ONE ToolbarItem (e.g. via TurnToolbarActionCluster)
        // breaks the inner UIKit ellipsis button — iOS 26 treats the HStack
        // as a single control and the UIButton's menu/hit-testing regresses.
        //
        // iOS < 26: the system does not auto-merge adjacent ToolbarItems, so
        // TurnToolbarActionCluster renders both buttons inside a single shared
        // material capsule.
        if showsGitActions, showsThreadActions {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    TurnGitActionsToolbarButton(
                        isEnabled: isGitActionEnabled,
                        disabledActions: disabledGitActions,
                        isRunningAction: isRunningGitAction,
                        loadingTitle: gitActionLoadingTitle,
                        showsDiscardRuntimeChangesAndSync: showsDiscardRuntimeChangesAndSync,
                        gitSyncState: gitSyncState,
                        repoDiffTotals: repoDiffTotals,
                        isLoadingRepoDiff: isLoadingRepoDiff,
                        onTapRepoDiff: onTapRepoDiff,
                        onSelect: onGitAction
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TurnThreadActionsMenuButton(
                        isLoading: isThreadActionLoading,
                        actions: threadActions
                    )
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    TurnToolbarActionCluster(
                        isEnabled: isGitActionEnabled,
                        disabledActions: disabledGitActions,
                        isRunningAction: isRunningGitAction,
                        loadingTitle: gitActionLoadingTitle,
                        showsDiscardRuntimeChangesAndSync: showsDiscardRuntimeChangesAndSync,
                        gitSyncState: gitSyncState,
                        repoDiffTotals: repoDiffTotals,
                        isLoadingRepoDiff: isLoadingRepoDiff,
                        onTapRepoDiff: onTapRepoDiff,
                        onGitAction: onGitAction,
                        isThreadActionLoading: isThreadActionLoading,
                        threadActions: threadActions
                    )
                }
            }
        } else if showsGitActions {
            ToolbarItem(placement: .topBarTrailing) {
                TurnGitActionsToolbarButton(
                    isEnabled: isGitActionEnabled,
                    disabledActions: disabledGitActions,
                    isRunningAction: isRunningGitAction,
                    loadingTitle: gitActionLoadingTitle,
                    showsDiscardRuntimeChangesAndSync: showsDiscardRuntimeChangesAndSync,
                    gitSyncState: gitSyncState,
                    repoDiffTotals: repoDiffTotals,
                    isLoadingRepoDiff: isLoadingRepoDiff,
                    onTapRepoDiff: onTapRepoDiff,
                    onSelect: onGitAction
                )
            }
        } else if showsThreadActions {
            ToolbarItem(placement: .topBarTrailing) {
                TurnThreadActionsMenuButton(
                    isLoading: isThreadActionLoading,
                    actions: threadActions
                )
            }
        }
    }

    // Hides worktree-only actions for rootless Quick Chat, where there is no real branch context.
    private func threadActionItems(
        canTapMacHandoff: Bool,
        canTapWorktreeHandoff: Bool,
        canTapNewChat: Bool,
        canTapTerminal: Bool
    ) -> [TurnThreadActionMenuItem] {
        var actions: [TurnThreadActionMenuItem] = [
            TurnThreadActionMenuItem(
                title: "Hand off to Desktop",
                icon: .system("arrow.left.arrow.right"),
                isEnabled: canTapMacHandoff
            ) {
                onTapMacHandoff?()
            },
        ]

        if onTapWorktreeHandoff != nil {
            actions.append(
                TurnThreadActionMenuItem(
                    title: isCreatingGitWorktree ? "Preparing worktree..." : worktreeHandoffTitle,
                    icon: .worktree,
                    isEnabled: canTapWorktreeHandoff
                ) {
                    onTapWorktreeHandoff?()
                }
            )
        }

        actions.append(contentsOf: [
            TurnThreadActionMenuItem(
                title: "New chat",
                icon: .system("square.and.pencil"),
                isEnabled: canTapNewChat
            ) {
                onTapNewChat?()
            },
            TurnThreadActionMenuItem(
                title: "Open Terminal Here",
                icon: .system("terminal"),
                isEnabled: canTapTerminal
            ) {
                onTapTerminal?()
            },
        ])

        return actions
    }

    @ViewBuilder
    private var titleTapTarget: some View {
        TurnChatToolbarTitleLabel(
            title: displayTitle,
            subtitle: navigationContext?.subtitle,
            onTap: navigationContext == nil ? nil : { isShowingPathSheet = true },
            accessibilityHint: navigationContext == nil ? nil : "Opens thread location"
        )
    }
}

struct TurnToolbarActionCluster: View {
    let isEnabled: Bool
    let disabledActions: Set<TurnGitActionKind>
    let isRunningAction: Bool
    let loadingTitle: String?
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    let repoDiffTotals: GitDiffTotals?
    let isLoadingRepoDiff: Bool
    let onTapRepoDiff: (() -> Void)?
    let onGitAction: (TurnGitActionKind) -> Void
    let isThreadActionLoading: Bool
    let threadActions: [TurnThreadActionMenuItem]

    var body: some View {
        HStack(spacing: Self.iconGap) {
            TurnGitActionsToolbarButton(
                isEnabled: isEnabled,
                disabledActions: disabledActions,
                isRunningAction: isRunningAction,
                loadingTitle: loadingTitle,
                showsDiscardRuntimeChangesAndSync: showsDiscardRuntimeChangesAndSync,
                gitSyncState: gitSyncState,
                repoDiffTotals: repoDiffTotals,
                isLoadingRepoDiff: isLoadingRepoDiff,
                onTapRepoDiff: onTapRepoDiff,
                onSelect: onGitAction,
                usesToolbarChrome: false
            )

            TurnThreadActionsMenuButton(
                isLoading: isThreadActionLoading,
                actions: threadActions,
                usesToolbarChrome: false
            )
        }
        .padding(.horizontal, Self.horizontalInset)
        .frame(minHeight: Self.minHeight)
        .contentShape(Capsule())
        .adaptiveToolbarItem(in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private static let iconGap: CGFloat = 28
    private static let horizontalInset: CGFloat = 12
    private static let minHeight: CGFloat = 36
}

struct TurnMacHandoffToolbarLabel: View {
    let isLoading: Bool
    var usesToolbarChrome: Bool = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                // Let the system toolbar render the ellipsis at its native
                // size; force-fitting the wide SF `ellipsis` glyph into a
                // square frame crushes the dots.
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
            }
        }
        .contentShape(Circle())
        .adaptiveToolbarItem(if: usesToolbarChrome, in: Circle())
    }
}

struct TurnThreadActionsMenuButton: View {
    let isLoading: Bool
    var isEnabled: Bool = true
    let actions: [TurnThreadActionMenuItem]
    var usesToolbarChrome: Bool = true

    var body: some View {
        Group {
            if isLoading {
                TurnMacHandoffToolbarLabel(isLoading: true, usesToolbarChrome: usesToolbarChrome)
            } else {
                UIKitThreadActionsToolbarButton(
                    isEnabled: isEnabled,
                    actions: actions,
                    triggerImage: Self.triggerImage
                )
                .frame(width: Self.triggerIconSize, height: Self.triggerIconSize)
                .padding(.vertical, 4)
                .frame(minWidth: Self.minToolbarButtonSize, minHeight: Self.minToolbarButtonSize)
                .contentShape(Circle())
                .adaptiveToolbarItem(if: usesToolbarChrome, in: Circle())
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .accessibilityLabel("Thread actions")
    }

    private static let triggerIconSize: CGFloat = 24
    private static let minToolbarButtonSize: CGFloat = 28

    private static var triggerImage: UIImage {
        UIImage(systemName: "ellipsis") ?? UIImage()
    }
}

struct TurnThreadActionMenuItem {
    enum Icon {
        case system(String)
        case worktree

        var uiImage: UIImage? {
            switch self {
            case .system(let systemName):
                RemodexIcon.menuUIImage(systemName: systemName)
            case .worktree:
                CodexWorktreeIcon.toolbarMenuUIImage()
            }
        }
    }

    let title: String
    let icon: Icon
    var isEnabled: Bool = true
    let handler: () -> Void

    func uiAction() -> UIAction {
        let attributes: UIMenuElement.Attributes = isEnabled ? [] : .disabled
        return UIAction(
            title: title,
            image: icon.uiImage,
            attributes: attributes
        ) { _ in
            guard isEnabled else { return }
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            handler()
        }
    }
}

private struct UIKitThreadActionsToolbarButton: UIViewRepresentable {
    let isEnabled: Bool
    let actions: [TurnThreadActionMenuItem]
    let triggerImage: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeUIView(context: Context) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = .label
        button.accessibilityLabel = "Thread actions"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)

        let coordinator = context.coordinator
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak coordinator] completion in
                completion(coordinator?.makeMenu().children ?? [])
            },
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = triggerImage.withRenderingMode(.alwaysTemplate)
        button.configuration = config
        button.isEnabled = isEnabled
        button.accessibilityLabel = "Thread actions"
        context.coordinator.actions = actions
    }

    final class Coordinator {
        var actions: [TurnThreadActionMenuItem]

        init(actions: [TurnThreadActionMenuItem]) {
            self.actions = actions
        }

        // Builds fresh rows at presentation time so disabled/loading state stays current.
        func makeMenu() -> UIMenu {
            UIMenu(
                title: "",
                options: [.displayInline],
                children: actions.map { $0.uiAction() }
            )
        }
    }
}

struct TurnThreadPathSheet: View {
    let context: TurnThreadNavigationContext
    let threadTitle: String
    var onRenameThread: ((String) -> Void)? = nil

    @State private var renamePrompt = ThreadRenamePromptState()
    @State private var didCopyPath = false

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
                                    RemodexIcon.image(systemName: "pencil")
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
                        HStack(spacing: 8) {
                            Text("Path")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(.secondary)

                            Button {
                                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                copyPathToPasteboard()
                            } label: {
                                Group {
                                    if didCopyPath {
                                        RemodexIcon.image(systemName: "checkmark")
                                            .font(AppFont.system(size: 12, weight: .semibold))
                                    } else {
                                        Image("copy")
                                            .renderingMode(.template)
                                            .resizable()
                                            .scaledToFit()
                                    }
                                }
                                .frame(width: 16, height: 16)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(didCopyPath ? "Path copied" : "Copy path")
                        }

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

    // Copies the full local project path while keeping the sheet visible.
    private func copyPathToPasteboard() {
        UIPasteboard.general.string = context.fullPath
        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyPath = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyPath = false
            }
        }
    }
}
