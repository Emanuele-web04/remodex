// FILE: SettingsSupportCards.swift
// Purpose: Settings cards for about/support links and paired-computer presentation.
// Layer: Settings UI components
// Exports: SettingsAboutCard, SettingsTrustedComputerCard, SettingsComputerNameSheet
// Depends on: SwiftUI, UIKit, AppEnvironment, CodexTrustedPairPresentation

import SwiftUI
import UIKit

struct SettingsAboutCard: View {
    let onShowHowItWorks: () -> Void

    var body: some View {
        SettingsCard(
            title: "About",
            footer: "Chats are end-to-end encrypted between your iPhone and paired device."
        ) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onShowHowItWorks()
            } label: {
                SettingsLinkRow(title: "How Remodex Works") {
                    RemodexIcon.image(systemName: "info.circle")
                }
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                if let url = URL(string: "https://x.com/emanueledpt") {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingsLinkRow(title: "Chat & Support") {
                    Image("x-icon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                UIApplication.shared.open(AppEnvironment.privacyPolicyURL)
            } label: {
                SettingsLinkRow(title: "Privacy Policy") {
                    RemodexIcon.image(systemName: "hand.raised")
                }
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                UIApplication.shared.open(AppEnvironment.termsOfUseURL)
            } label: {
                SettingsLinkRow(title: "Terms of Use") {
                    RemodexIcon.image(systemName: "doc.text")
                }
            }
        }
    }
}

struct SettingsTrustedComputerCard: View {
    let presentation: CodexTrustedPairPresentation
    let connectionStatusLabel: String
    let onEditName: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RemodexIcon.image(systemName: "laptopcomputer", size: 18, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.name)
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let systemName = presentation.systemName, !systemName.isEmpty {
                        Text(systemName)
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(action: onEditName) {
                    RemodexIcon.image(systemName: "pencil")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit device name")
            }

            HStack(spacing: 8) {
                SettingsStatusPill(
                    label: connectionStatusLabel,
                    tint: connectionStatusLabel == "Connected" ? .green : .secondary
                )

                if let title = compactTitle {
                    SettingsStatusPill(label: title)
                }
            }

            if let detail = presentation.detail, !detail.isEmpty {
                Text(detail)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var compactTitle: String? {
        let trimmed = presentation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SettingsComputerNameSheet: View {
    @Binding var nickname: String
    let currentName: String
    let systemName: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftNickname = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Device name")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(currentName)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }

                TextField(systemName, text: $draftNickname)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .font(AppFont.subheadline())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemFill))
                    )

                Text("This nickname stays on this iPhone and appears anywhere this device is shown.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    Button {
                        nickname = ""
                        dismiss()
                    } label: {
                        Text("Use Default")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(canResetToDefault ? 1 : 0.5)
                    .disabled(!canResetToDefault)

                    Button {
                        nickname = draftNickname
                        dismiss()
                    } label: {
                        Text("Save")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .opacity(canSave ? 1 : 0.5)
                    .disabled(!canSave)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .navigationTitle("Edit Device Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftNickname = nickname
            }
        }
    }

    private var canSave: Bool {
        draftNickname != nickname
    }

    private var canResetToDefault: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
