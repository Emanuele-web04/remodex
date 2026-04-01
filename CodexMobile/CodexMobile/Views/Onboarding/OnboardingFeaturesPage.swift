// FILE: OnboardingFeaturesPage.swift
// Purpose: Compact feature highlights page shown after the welcome splash.
// Layer: View
// Exports: OnboardingFeaturesPage
// Depends on: SwiftUI, AppFont

import SwiftUI

struct OnboardingFeaturesPage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 40) {
                VStack(spacing: 10) {
                    Text("What you get")
                        .font(AppFont.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Everything runs on your Mac.\nYour phone is the remote.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                VStack(spacing: 16) {
                    featureRow(
                        icon: "hare.fill",
                        color: .yellow,
                        title: "Fast mode",
                        subtitle: "Lower-latency turns for quick interactions"
                    )
                    featureRow(
                        icon: "arrow.triangle.branch",
                        color: .green,
                        title: "Git from your phone",
                        subtitle: "Commit, push, pull, and switch branches"
                    )
                    featureRow(
                        icon: "lock.shield.fill",
                        color: .cyan,
                        title: "End-to-end encrypted",
                        subtitle: "The relay never sees your prompts or code"
                    )
                    featureRow(
                        icon: "waveform",
                        color: .purple,
                        title: "Voice mode",
                        subtitle: "Talk to Codex with speech-to-text"
                    )
                    featureRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        color: .orange,
                        title: "Subagents, skills and /commands",
                        subtitle: "Spawn and monitor parallel agents from your phone"
                    )
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    @ViewBuilder
    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingFeaturesPage()
    }
    .preferredColorScheme(.dark)
}
