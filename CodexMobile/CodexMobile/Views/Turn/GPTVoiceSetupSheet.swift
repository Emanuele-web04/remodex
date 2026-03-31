// FILE: GPTVoiceSetupSheet.swift
// Purpose: Explains the Mac-side ChatGPT steps needed before Remodex voice mode can work.
// Layer: View
// Exports: GPTVoiceSetupSheet
// Depends on: SwiftUI, AppFont

import SwiftUI

struct GPTVoiceSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ChatGPT voice is checked on your Mac")
                            .font(AppFont.subheadline(weight: .semibold))
                        Text("Remodex reads the ChatGPT session from your paired Mac bridge.")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    setupStep(
                        number: "1",
                        title: "Open ChatGPT on your Mac",
                        detail: "Use the same Mac that is paired with this iPhone."
                    )
                    setupStep(
                        number: "2",
                        title: "Sign in there",
                        detail: "Make sure the ChatGPT account you want for voice is active on the Mac."
                    )
                    setupStep(
                        number: "3",
                        title: "Come back to Remodex",
                        detail: "Keep the bridge connected, then try voice mode again after the status refreshes."
                    )
                }

                Text("You do not need to start ChatGPT login from this iPhone.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                SettingsButton("Close") {
                    dismiss()
                }
            }
            .padding(20)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .navigationTitle("Use ChatGPT on Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    // Keeps the setup instructions scannable in a compact sheet.
    private func setupStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
