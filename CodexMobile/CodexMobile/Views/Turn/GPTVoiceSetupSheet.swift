// FILE: GPTVoiceSetupSheet.swift
// Purpose: Shows a compact info sheet that explains how Remodex voice uses the paired computer's ChatGPT session.
// Layer: View
// Exports: GPTVoiceSetupSheet
// Depends on: SwiftUI, AppFont

import SwiftUI

struct GPTVoiceSetupSheet: View {
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
                        Text("GPT voice uses the ChatGPT session on your computer")
                            .font(AppFont.subheadline(weight: .semibold))
                        Text("Remodex does not keep a separate GPT voice login on the iPhone. It uses the ChatGPT session already active on your paired computer.")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    infoStep(
                        number: "1",
                        title: "You speak on the iPhone",
                        detail: "Remodex records the voice clip locally on the phone when you hold to talk."
                    )
                    infoStep(
                        number: "2",
                        title: "The phone checks your paired computer",
                        detail: "Remodex asks the paired computer bridge for the active ChatGPT session that is already connected there."
                    )
                    infoStep(
                        number: "3",
                        title: "GPT transcribes the clip",
                        detail: "The voice clip is sent with that computer-backed GPT session so GPT can turn it into text."
                    )
                    infoStep(
                        number: "4",
                        title: "The text comes back to Remodex",
                        detail: "The transcript returns to the app and gets dropped into your message composer."
                    )
                }

                Text("In short: iPhone voice in, computer ChatGPT session for auth, GPT transcript back to the iPhone.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(20)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .navigationTitle("How GPT Voice Works")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // Keeps the voice flow easy to scan in a compact informational sheet.
    private func infoStep(number: String, title: String, detail: String) -> some View {
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
