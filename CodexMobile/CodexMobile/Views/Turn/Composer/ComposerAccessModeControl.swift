// FILE: ComposerAccessModeControl.swift
// Purpose: Presents the composer access-mode control and its selection popover.
// Layer: View Component
// Exports: ComposerAccessModeControl
// Depends on: SwiftUI, CodexAccessMode, RemodexIcon

import SwiftUI

struct ComposerAccessModeControl: View {
    let selectedAccessMode: CodexAccessMode
    let isInteractionLocked: Bool
    let onSelect: (CodexAccessMode) -> Void

    private let controlSize: CGFloat = 32
    private let iconSize: CGFloat = 20
    private let labelColor = Color(.secondaryLabel)

    @State private var showsPopover = false

    var body: some View {
        Button(action: showPopover) {
            RemodexIcon.image(
                systemName: selectedAccessMode.composerIconSystemName,
                size: iconSize
            )
            .frame(width: controlSize, height: controlSize)
            .foregroundStyle(selectedAccessMode.composerTint)
            .contentShape(Circle())
        }
        .tint(labelColor)
        .disabled(isInteractionLocked)
        .accessibilityLabel(selectedAccessMode.pickerTitle)
        .accessibilityHint("Changes how Codex requests permission")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            ComposerAccessModePopover(
                selectedAccessMode: selectedAccessMode,
                onSelect: select
            )
        }
    }

    private func showPopover() {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        showsPopover = true
    }

    private func select(_ mode: CodexAccessMode) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        showsPopover = false
        onSelect(mode)
    }
}

private struct ComposerAccessModePopover: View {
    let selectedAccessMode: CodexAccessMode
    let onSelect: (CodexAccessMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CodexAccessMode.allCases, id: \.rawValue) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    ComposerAccessModeRow(
                        mode: mode,
                        isSelected: selectedAccessMode == mode
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.pickerTitle)
                .accessibilityHint(mode.pickerSubtitle)
                .accessibilityAddTraits(selectedAccessMode == mode ? .isSelected : [])
            }
        }
        .padding(.vertical, 10)
        .frame(width: 312)
        .presentationCompactAdaptation(.popover)
    }
}

private struct ComposerAccessModeRow: View {
    let mode: CodexAccessMode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            RemodexIcon.image(systemName: mode.composerIconSystemName, size: 22)
                .frame(width: 28, height: 28)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.pickerTitle)
                    .font(AppFont.body())
                    .foregroundStyle(.primary)
                Text(mode.pickerSubtitle)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private extension CodexAccessMode {
    var composerIconSystemName: String {
        switch self {
        case .onRequest:
            "hand.raised"
        case .autoReview:
            "remodex.auto-review"
        case .fullAccess:
            "hand.thumbsup"
        }
    }

    var composerTint: Color {
        switch self {
        case .onRequest:
            Color(.secondaryLabel)
        case .autoReview:
            Color(.systemBlue)
        case .fullAccess:
            .orange
        }
    }
}
