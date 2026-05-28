// FILE: TurnGitActionsToolbar.swift
// Purpose: Encapsulates Git actions toolbar UI for bridge-triggered git operations.
// Layer: View Component
// Exports: TurnGitActionsToolbarButton
// Depends on: SwiftUI, UIKit, GitActionModels

import SwiftUI
import UIKit

extension TurnGitActionKind {
    func menuIcon(pointSize: CGFloat = 20) -> UIImage {
        let cgSize = CGSize(width: pointSize, height: pointSize)
        switch self {
        case .initialize:
            return Self.resizedSymbol(named: "plus.circle", size: cgSize)
        case .syncNow:
            return Self.resizedSymbol(named: "arrow.trianglehead.2.clockwise.rotate.90", size: cgSize)
        case .commit:
            return Self.resizedAsset(named: "git-commit", size: cgSize)
        case .push:
            return Self.resizedSymbol(named: "arrow.up.circle", size: cgSize)
        case .commitAndPush:
            return Self.resizedAsset(named: "cloud-upload", size: cgSize)
        case .commitPushCreatePR:
            return Self.resizedAsset(named: "GitHub_Invertocat_Black", size: cgSize)
        case .createPR:
            return Self.resizedAsset(named: "GitHub_Invertocat_Black", size: cgSize)
        case .discardRuntimeChangesAndSync:
            return Self.resizedSymbol(named: "trash.circle", size: cgSize)
        }
    }

    private static func resizedAsset(named name: String, size: CGSize) -> UIImage {
        guard let original = UIImage(named: name)?.withRenderingMode(.alwaysTemplate) else {
            return UIImage()
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }

    private static func resizedSymbol(named name: String, size: CGSize) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size.height, weight: .regular)
        guard let symbol = RemodexIcon.uiImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate) else {
            return UIImage()
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let scale = min(size.width / symbol.size.width, size.height / symbol.size.height)
        let scaled = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let origin = CGPoint(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
        return renderer.image { _ in
            symbol.draw(in: CGRect(origin: origin, size: scaled))
        }.withRenderingMode(.alwaysTemplate)
    }
}

struct TurnGitActionsToolbarButton: View {
    let isEnabled: Bool
    let disabledActions: Set<TurnGitActionKind>
    let isRunningAction: Bool
    let loadingTitle: String?
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    let repoDiffTotals: GitDiffTotals?
    let isLoadingRepoDiff: Bool
    let onTapRepoDiff: (() -> Void)?
    let onSelect: (TurnGitActionKind) -> Void
    var usesToolbarChrome: Bool = true

    private let minToolbarButtonSize: CGFloat = 28

    private var syncStatusColor: Color? {
        switch gitSyncState {
        case "not_initialized":
            return Color(.systemOrange)
        case "behind_only", "diverged", "dirty_and_behind":
            return Color(.systemGray2)
        default:
            return nil
        }
    }

    private var syncStatusAccessibilityValue: String? {
        switch gitSyncState {
        case "not_initialized":
            return "Git is not initialized"
        case "up_to_date":
            return "Repository up to date"
        case "ahead_only":
            return "Local branch ahead of remote"
        case "behind_only":
            return "Remote branch ahead of local branch"
        case "diverged":
            return "Local and remote branches diverged"
        case "dirty":
            return "Local repository has uncommitted changes"
        case "dirty_and_behind":
            return "Local changes exist and remote branch moved ahead"
        case "no_upstream":
            return "Branch not published yet"
        case "detached_head":
            return "Current branch unavailable"
        default:
            return nil
        }
    }

    var body: some View {
        UIKitGitActionsMenuButton(
            isEnabled: isEnabled,
            disabledActions: disabledActions,
            gitSyncState: gitSyncState,
            repoDiffTotals: repoDiffTotals,
            isLoadingRepoDiff: isLoadingRepoDiff,
            triggerImage: triggerUIImage,
            onTapRepoDiff: onTapRepoDiff,
            onSelect: onSelect
        )
        .frame(width: triggerIconSize, height: triggerIconSize)
        .overlay(alignment: .topTrailing) {
            // Skip the dot while a git action runs; the in-app toast already shows live progress.
            if !isRunningAction, let syncStatusColor {
                Circle()
                    .fill(syncStatusColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 1.5)
                    }
                    .offset(x: 2, y: -2)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: minToolbarButtonSize, minHeight: minToolbarButtonSize)
        .contentShape(Circle())
        .adaptiveToolbarItem(if: usesToolbarChrome, in: Circle())
        .accessibilityLabel("Git actions")
        .accessibilityValue(loadingTitle ?? syncStatusAccessibilityValue ?? "Repository status unavailable")
    }

    private let triggerIconSize: CGFloat = 24

    private var triggerUIImage: UIImage {
        let kind: TurnGitActionKind = gitSyncState == "not_initialized" ? .initialize : .commit
        return kind.menuIcon(pointSize: triggerIconSize)
    }
}

// MARK: - UIKit-backed menu button

// Wraps a UIButton with showsMenuAsPrimaryAction to get the native UIMenu chrome
// (same snappiness as iOS context menus). The Changes row uses UIAction's
// `attributedTitle` (KVC) so the +/- counts render in green/red at body-size
// inside the row's title slot. Public-API alternatives don't deliver the same
// visual: UIMenu's image slot is icon-sized (~22pt square) which shrinks wide
// colored text to unreadable, and subtitle/title strip foreground colors.
//
// Risk profile (target iOS 26.2): the `responds(to:)` guard prevents
// NSUnknownKeyException if a future iOS removes the private property, and the
// plain `title` stays as the textual/voice-over fallback. App Review risk is
// the only remaining theoretical concern (accepted trade-off).
//
// State flow: a Coordinator holds the latest snapshot. The outer button.menu is
// a single UIDeferredMenuElement.uncached that rebuilds on each open from the
// coordinator's snapshot. While the bridge's git sync state hasn't landed yet
// (gitSyncState == nil), the Changes row is itself a nested
// UIDeferredMenuElement.uncached — iOS renders its native spinner inside the
// row, and the coordinator fires the stored completion as soon as gitSyncState
// arrives (so the row swaps in-place without closing the menu). The separate
// `isLoadingRepoDiff` flag means "diff sheet is currently being prepared after
// a tap" and only drives the row's disabled state, never the spinner.
private struct UIKitGitActionsMenuButton: UIViewRepresentable {
    let isEnabled: Bool
    let disabledActions: Set<TurnGitActionKind>
    let gitSyncState: String?
    let repoDiffTotals: GitDiffTotals?
    let isLoadingRepoDiff: Bool
    let triggerImage: UIImage
    let onTapRepoDiff: (() -> Void)?
    let onSelect: (TurnGitActionKind) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = .label
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)

        let coordinator = context.coordinator
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak coordinator] completion in
                guard let coordinator else {
                    completion([])
                    return
                }
                completion(coordinator.buildMenu().children)
            },
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = triggerImage.withRenderingMode(.alwaysTemplate)
        button.configuration = config

        context.coordinator.update(snapshot: GitMenuSnapshot(
            isEnabled: isEnabled,
            disabledActions: disabledActions,
            gitSyncState: gitSyncState,
            repoDiffTotals: repoDiffTotals,
            isLoadingRepoDiff: isLoadingRepoDiff,
            onTapRepoDiff: onTapRepoDiff,
            onSelect: onSelect
        ))
    }

    // Immutable per-update snapshot consumed by the Coordinator. Bundles the
    // full input set so diffing/logging future tweaks stay focused on a single
    // value, and avoids drift between caller-side parameter order and stored
    // state.
    struct GitMenuSnapshot {
        var isEnabled: Bool = true
        var disabledActions: Set<TurnGitActionKind> = []
        var gitSyncState: String?
        var repoDiffTotals: GitDiffTotals?
        var isLoadingRepoDiff: Bool = false
        var onTapRepoDiff: (() -> Void)?
        var onSelect: (TurnGitActionKind) -> Void = { _ in }
    }

    final class Coordinator {
        private var snapshot = GitMenuSnapshot()

        // Stored deferred-element completion for the Changes row; fired from
        // update(...) as soon as gitSyncState lands (the bridge has answered).
        // Single-shot per open. NOTE: isLoadingRepoDiff is NOT the right signal
        // — that flag is owned by the diff-sheet loader in TurnView (post-tap),
        // not by the initial sync of totals from the bridge.
        private var pendingChangesCompletion: (([UIMenuElement]) -> Void)?

        func update(snapshot: GitMenuSnapshot) {
            self.snapshot = snapshot

            // Sync has landed (any state, with or without diff) → fulfil the
            // pending spinner with the resolved row. resolvedChangesElements()
            // returns "Changes unavailable" if the bridge omitted the diff
            // section, so iOS never keeps the spinner indefinitely once the
            // sync state itself is known.
            if snapshot.gitSyncState != nil, let completion = pendingChangesCompletion {
                pendingChangesCompletion = nil
                completion(resolvedChangesElements())
            }
        }

        func buildMenu() -> UIMenu {
            if snapshot.gitSyncState == "not_initialized" {
                let setup = UIMenu(title: "Setup", options: .displayInline, children: [
                    makeAction(for: .initialize),
                ])
                return UIMenu(title: "", children: [setup])
            }

            var sections: [UIMenuElement] = []

            // Always include the Changes section when a tap handler is available
            // so the spinner has a home and the section doesn't pop in late.
            if snapshot.onTapRepoDiff != nil {
                sections.append(
                    UIMenu(title: "Changes", options: .displayInline, children: [
                        changesElement(),
                    ])
                )
            }

            sections.append(
                UIMenu(title: "Write", options: .displayInline, children: [
                    makeAction(for: .commit),
                    makeAction(for: .push),
                    makeAction(for: .commitAndPush),
                    makeAction(for: .commitPushCreatePR),
                    makeAction(for: .createPR),
                ])
            )

            sections.append(
                UIMenu(title: "Update", options: .displayInline, children: [
                    makeAction(for: .syncNow),
                ])
            )

            return UIMenu(title: "", children: sections)
        }

        private func changesElement() -> UIMenuElement {
            if snapshot.gitSyncState != nil {
                // Synchronous path: the bridge has already answered for this
                // repo (state present), emit the resolved row immediately —
                // never park a spinner when we already know the answer.
                return resolvedChangesElements().first
                    ?? makePlaceholderChangesRow(title: "Changes unavailable", systemImage: "exclamationmark.circle")
            }

            // Deferred path: gitSyncState == nil means we're still waiting for
            // the bridge's first git status push. iOS shows its native spinner
            // inside the row until we fire `completion`. update(...) holds the
            // latest closure and calls it as soon as gitSyncState lands.
            return UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }
                if self.snapshot.gitSyncState != nil {
                    completion(self.resolvedChangesElements())
                } else {
                    self.pendingChangesCompletion = completion
                }
            }
        }

        // Resolves the final state of the Changes row once loading is done.
        // Always returns at least one row so the section never disappears and
        // the deferred-element spinner is never left hanging.
        private func resolvedChangesElements() -> [UIMenuElement] {
            guard let totals = snapshot.repoDiffTotals else {
                return [makePlaceholderChangesRow(title: "Changes unavailable", systemImage: "exclamationmark.circle")]
            }
            if totals.additions == 0, totals.deletions == 0, totals.binaryFiles == 0 {
                return [makePlaceholderChangesRow(title: "No changes", systemImage: "checkmark.circle")]
            }
            return [makeChangesAction(totals: totals)]
        }

        private func makePlaceholderChangesRow(title: String, systemImage: String) -> UIAction {
            return UIAction(
                title: title,
                image: RemodexIcon.menuUIImage(systemName: systemImage),
                attributes: .disabled,
                handler: { _ in }
            )
        }

        private func makeChangesAction(totals: GitDiffTotals) -> UIAction {
            let onTap = snapshot.onTapRepoDiff
            // isLoadingRepoDiff means "the diff sheet is loading after a previous
            // tap" — disable the row in that window to prevent duplicate sheet
            // presentation. NOT related to totals loading.
            let action = UIAction(
                title: plainChangesTitle(totals: totals),
                image: RemodexIcon.menuUIImage(systemName: "remodex.changes"),
                attributes: snapshot.isLoadingRepoDiff ? .disabled : []
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onTap?()
            }
            // Private-API path guarded by runtime selector check: skips the
            // setter (rather than crashing with NSUnknownKeyException) if a
            // future iOS renames/removes the underlying property. Plain
            // `title` above stays as the visible/voice-over fallback in that case.
            if #available(iOS 16.0, *),
               action.responds(to: NSSelectorFromString("setAttributedTitle:")) {
                action.setValue(coloredChangesTitle(totals: totals), forKey: "attributedTitle")
            }
            return action
        }

        private func makeAction(for kind: TurnGitActionKind) -> UIAction {
            let disabled = !snapshot.isEnabled || snapshot.disabledActions.contains(kind)
            let select = snapshot.onSelect
            return UIAction(
                title: kind.title,
                image: kind.menuIcon().withRenderingMode(.alwaysTemplate),
                attributes: disabled ? .disabled : []
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback()
                select(kind)
            }
        }

        private func coloredChangesTitle(totals: GitDiffTotals) -> NSAttributedString {
            let font = UIFont.preferredFont(forTextStyle: .body)
            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(
                string: "+\(totals.additions)",
                attributes: [.foregroundColor: UIColor.systemGreen, .font: font]
            ))
            attributed.append(NSAttributedString(
                string: "  -\(totals.deletions)",
                attributes: [.foregroundColor: UIColor.systemRed, .font: font]
            ))
            if totals.binaryFiles > 0 {
                attributed.append(NSAttributedString(
                    string: "  B\(totals.binaryFiles)",
                    attributes: [.foregroundColor: UIColor.secondaryLabel, .font: font]
                ))
            }
            return attributed
        }

        private func plainChangesTitle(totals: GitDiffTotals) -> String {
            var parts = ["+\(totals.additions)", "-\(totals.deletions)"]
            if totals.binaryFiles > 0 { parts.append("B\(totals.binaryFiles)") }
            return parts.joined(separator: "  ")
        }
    }
}
