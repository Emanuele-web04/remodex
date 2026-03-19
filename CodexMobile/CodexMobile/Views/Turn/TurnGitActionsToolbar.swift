// FILE: TurnGitActionsToolbar.swift
// Purpose: Encapsulates Git actions toolbar UI for bridge-triggered git operations.
// Layer: View Component
// Exports: TurnGitActionsToolbarButton
// Depends on: SwiftUI, GitActionModels

import SwiftUI

extension TurnGitActionKind {
    func menuIcon(pointSize: CGFloat = 20) -> UIImage {
        let cgSize = CGSize(width: pointSize, height: pointSize)
        switch self {
        case .syncNow:
            return Self.resizedSymbol(named: "arrow.trianglehead.2.clockwise.rotate.90", size: cgSize)
        case .commit:
            return Self.resizedAsset(named: "git-commit", size: cgSize)
        case .push:
            return Self.resizedSymbol(named: "arrow.up.circle", size: cgSize)
        case .commitAndPush:
            return Self.resizedAsset(named: "cloud-upload", size: cgSize)
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
        guard let symbol = UIImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate) else {
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
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    let onSelect: (TurnGitActionKind) -> Void

    private let minToolbarButtonSize: CGFloat = 28

    private var syncStatusColor: Color? {
        switch gitSyncState {
        case "behind_only", "diverged", "dirty_and_behind":
            return Color.orange
        default:
            return nil
        }
    }

    private var syncStatusAccessibilityValue: String? {
        switch gitSyncState {
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
        Menu {
            Section("Update") {
                actionButton(for: .syncNow)
            }

            Section("Write") {
                ForEach([TurnGitActionKind.commit, .push, .commitAndPush, .createPR], id: \.self) { action in
                    actionButton(for: action)
                }
            }

            if !recoveryActions.isEmpty {
                Section("Recovery") {
                    ForEach(recoveryActions, id: \.self) { action in
                        actionButton(for: action)
                    }
                }
            }
        } label: {
            if isRunningAction {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                toolbarIcon(for: .commit, size: 24)
                    .overlay(alignment: .topTrailing) {
                        if let syncStatusColor {
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
            }
        }
        .controlSize(.small)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.vertical, 4)
        .frame(minWidth: minToolbarButtonSize, minHeight: minToolbarButtonSize)
        .contentShape(Circle())
        .adaptiveToolbarItem(in: Circle())
        .accessibilityLabel("Git actions")
        .accessibilityValue(syncStatusAccessibilityValue ?? "Repository status unavailable")
    }

    private var recoveryActions: [TurnGitActionKind] {
        showsDiscardRuntimeChangesAndSync ? [.discardRuntimeChangesAndSync] : []
    }

    private func actionButton(for action: TurnGitActionKind) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            onSelect(action)
        } label: {
            Label {
                Text(action.title)
            } icon: {
                Image(uiImage: action.menuIcon())
            }
        }
        .disabled(!isEnabled || disabledActions.contains(action))
    }

    @ViewBuilder
    private func toolbarIcon(for action: TurnGitActionKind, size: CGFloat) -> some View {
        Image(uiImage: action.menuIcon(pointSize: size))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
    }
}
