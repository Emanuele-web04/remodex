// FILE: TurnWorktreeHandoffOverlay.swift
// Purpose: Presents the shared worktree-creation dialog used by handoff and fork flows.
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
            return "Fork thread into new worktree"
        }
    }

    var message: String {
        switch self {
        case .handoff:
            return "Create and check out a branch in a new worktree to continue in parallel. The branch is normalized with the remodex/ prefix."
        case .fork:
            return "Create and check out a branch in a new worktree, then fork this conversation into that checkout as a new chat."
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
    let onSubmit: (String, String) -> Void

    @State private var branchName = ""
    @State private var baseBranch = ""
    @FocusState private var isBranchNameFocused: Bool

    private var normalizedBranchName: String {
        remodexNormalizedCreatedBranchName(branchName)
    }

    private var trimmedBaseBranch: String {
        baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 16) {
                header
                content
                submitButton
            }
            .padding(20)
            .frame(maxWidth: 400)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 30, y: 12)
            .padding(.horizontal, 24)
        }
        .task {
            if baseBranch.isEmpty {
                baseBranch = preferredBaseBranch
            }
            guard !isSubmitting else { return }
            isBranchNameFocused = true
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 40, height: 40)

                CodexWorktreeIcon(pointSize: 16, weight: .semibold)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 12)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(AppFont.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title)
                .font(AppFont.headline())
                .foregroundStyle(.primary)

            Text(mode.message)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch name")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                TextField("feature-name", text: $branchName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isBranchNameFocused)
                    .font(AppFont.body(weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                if !normalizedBranchName.isEmpty {
                    Text(normalizedBranchName)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base branch")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                TextField("main", text: $baseBranch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(AppFont.body(weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                Text("Starts from this base branch.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var submitButton: some View {
        Button {
            guard !normalizedBranchName.isEmpty, !trimmedBaseBranch.isEmpty else { return }
            onSubmit(normalizedBranchName, trimmedBaseBranch)
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
            .frame(height: 46)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isHandoffAvailable || isSubmitting || normalizedBranchName.isEmpty || trimmedBaseBranch.isEmpty)
        .opacity(!isHandoffAvailable || isSubmitting || normalizedBranchName.isEmpty || trimmedBaseBranch.isEmpty ? 0.6 : 1)
    }
}
