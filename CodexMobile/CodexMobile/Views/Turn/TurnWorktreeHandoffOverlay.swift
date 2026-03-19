// FILE: TurnWorktreeHandoffOverlay.swift
// Purpose: Presents the Codex-style worktree handoff dialog from both the toolbar and composer.
// Layer: View Component
// Exports: TurnWorktreeHandoffOverlay
// Depends on: SwiftUI, CodexWorktreeIcon

import SwiftUI

struct TurnWorktreeHandoffOverlay: View {
    let preferredBaseBranch: String
    let isHandoffAvailable: Bool
    let isSubmitting: Bool
    let onClose: () -> Void
    let onSubmit: (String, String) -> Void

    @State private var branchName = ""
    @FocusState private var isBranchNameFocused: Bool

    private var normalizedBranchName: String {
        remodexNormalizedCreatedBranchName(branchName)
    }

    private var trimmedBaseBranch: String {
        preferredBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard !isSubmitting else { return }
            isBranchNameFocused = true
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
                Text("Hand off thread to worktree")
                    .font(AppFont.title2(weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Create and check out a branch in a new worktree to continue working in parallel. Tracked local changes move there too, while ignored files stay in Local.")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Branch name")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)

                TextField("feature-name", text: $branchName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isBranchNameFocused)
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

                if !normalizedBranchName.isEmpty {
                    Text(normalizedBranchName)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }
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
                    Text("Hand off")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isHandoffAvailable || isSubmitting || normalizedBranchName.isEmpty || trimmedBaseBranch.isEmpty)
        .opacity(!isHandoffAvailable || isSubmitting || normalizedBranchName.isEmpty || trimmedBaseBranch.isEmpty ? 0.6 : 1)
    }
}
