// FILE: CapabilityGreyOutModifier.swift
// Purpose: ViewModifier implementing the ADR-002 tri-state capability model
//          (enabled / greyed / hidden) for composer controls.
// Layer: View Helper
// Exports: CapabilityGreyOutModifier, View.capabilityGreyOut(isEnabled:reason:)
// Depends on: SwiftUI, ComposerDisabledAppearance, AppFont

import SwiftUI

struct CapabilityGreyOutModifier: ViewModifier {
    let isEnabled: Bool
    let reason: String?
    var showsCaption: Bool = true

    func body(content: Content) -> some View {
        Group {
            if showsCaption {
                VStack(alignment: .leading, spacing: 4) {
                    styledContent(content)
                    if let reason, !isEnabled {
                        Text(reason)
                            .font(ComposerDisabledAppearance.captionFont)
                            .foregroundStyle(ComposerDisabledAppearance.captionColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                styledContent(content)
            }
        }
    }

    private func styledContent(_ content: Content) -> some View {
        content
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1.0 : ComposerDisabledAppearance.controlOpacity)
            .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        guard !isEnabled, let reason, !reason.isEmpty else { return "" }
        return reason
    }
}

extension View {
    func capabilityGreyOut(
        isEnabled: Bool,
        reason: String? = nil,
        showsCaption: Bool = true
    ) -> some View {
        modifier(
            CapabilityGreyOutModifier(
                isEnabled: isEnabled,
                reason: reason,
                showsCaption: showsCaption
            )
        )
    }
}

#if DEBUG
#Preview("Capability grey-out") {
    VStack(alignment: .leading, spacing: 16) {
        Button("Voice") {}
            .capabilityGreyOut(isEnabled: true, reason: nil)

        Button("Voice") {}
            .capabilityGreyOut(
                isEnabled: false,
                reason: ComposerCapabilityCopy.capabilityReason(for: .voice)
            )
    }
    .padding()
    .background(Color.black)
}
#endif
