// FILE: OnboardingCommandCard.swift
// Purpose: Copy-able terminal command card for onboarding steps.
// Layer: View
// Exports: OnboardingCommandCard
// Depends on: SwiftUI, AppFont

import SwiftUI

struct OnboardingCommandCard: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            Text("$ ")
                .foregroundStyle(.white.opacity(0.3))

            Text(command)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIPasteboard.general.string = command
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Group {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Image("copy")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 15, height: 15)
                .foregroundStyle(copied ? .white : .white.opacity(0.35))
                .contentTransition(.symbolEffect(.replace))
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(AppFont.mono(.caption))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Previews

#Preview("Short") {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingCommandCard(command: "remodex up")
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Long") {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingCommandCard(command: "npm install -g @openai/codex@latest")
            .padding()
    }
    .preferredColorScheme(.dark)
}
