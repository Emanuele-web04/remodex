// FILE: TurnWorktreeHandoffOverlay.swift
// Purpose: Presents the shared managed-worktree dialog used by handoff and fork flows.
// Layer: View Component
// Exports: TurnWorktreeHandoffOverlay
// Depends on: SwiftUI, CodexWorktreeIcon

import SwiftUI

enum TurnWorktreeOverlayMode {
    case handoff
    case fork

    var title: String {
        switch self {
        case .handoff:
            return "Hand off thread to worktree"
        case .fork:
            return "Fork thread into worktree"
        }
    }

    var message: String {
        switch self {
        case .handoff:
            return "Create a managed detached worktree from a base branch, then move this same chat there. If this base branch matches your current branch, local changes move with it; ignored files stay in Local. You can create a branch later inside the worktree."
        case .fork:
            return "Create a managed detached worktree from a base branch, then clone this conversation into it as a new chat. No local files move during a fork, so the new worktree starts clean. You can create a branch later inside the worktree."
        }
    }

    var submitLabel: String {
        switch self {
        case .handoff:
            return "Hand off"
        case .fork:
            return "Fork"
        }
    }
}

struct TurnWorktreeHandoffOverlay: View {
    let mode: TurnWorktreeOverlayMode
    let preferredBaseBranch: String
    let isHandoffAvailable: Bool
    let isSubmitting: Bool
    let onClose: () -> Void
    let onSubmit: (String) -> Void

    @State private var baseBranch = ""
    @FocusState private var isBaseBranchFocused: Bool

    private var trimmedBaseBranch: String {
        baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 24) {
                header
                content
                submitButton
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 30, y: 12)
            .padding(.horizontal, 20)
        }
        .task {
            if baseBranch.isEmpty {
                baseBranch = preferredBaseBranch
            }
            guard !isSubmitting else { return }
            isBaseBranchFocused = true
        }
        .onChange(of: preferredBaseBranch) { _, newValue in
            if trimmedBaseBranch.isEmpty {
                baseBranch = newValue
            }
        }
        .onChange(of: isHandoffAvailable) { _, newValue in
            // If a run starts while the dialog is open, close it instead of leaving a dead-end submit affordance onscreen.
            guard !newValue, !isSubmitting else { return }
            onClose()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 56, height: 56)

                CodexWorktreeIcon(pointSize: 20, weight: .semibold)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 16)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(AppFont.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode.title)
                    .font(AppFont.title2(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(mode.message)
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Base branch")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)

                TextField("main", text: $baseBranch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isBaseBranchFocused)
                    .font(AppFont.body(weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                Text("Managed worktrees start detached from this branch; create a feature branch later if you want one.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var submitButton: some View {
        Button {
            guard !trimmedBaseBranch.isEmpty else { return }
            onSubmit(trimmedBaseBranch)
        } label: {
            ZStack {
                if isSubmitting {
                    ProgressView()
                        .tint(.black)
                } else {
                    Text(mode.submitLabel)
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isHandoffAvailable || isSubmitting || trimmedBaseBranch.isEmpty)
        .opacity(!isHandoffAvailable || isSubmitting || trimmedBaseBranch.isEmpty ? 0.6 : 1)
    }
}
