// FILE: CopyBlockButton.swift
// Purpose: End-of-block accessory that swaps between a running terminal loader and copy action.
// Layer: View Component
// Exports: CopyBlockButton

import SwiftUI
import UIKit

struct CopyBlockButton: View {
    let text: String?
    var isRunning: Bool = false
    @State private var showCopiedFeedback = false
    @State private var cursorOpacity: Double = 1

    var body: some View {
        Group {
            if isRunning {
                runningIndicator
            } else if let text {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    UIPasteboard.general.string = text
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showCopiedFeedback = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showCopiedFeedback = false
                        }
                    }
                } label: {
                    copyLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy response")
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRunning)
    }

    // Mirrors the terminal glyph while the latest assistant block is still running.
    private var runningIndicator: some View {
        HStack(alignment: .bottom, spacing: 1) {
            Text(">")
                .font(AppFont.mono(.caption))
                .fontWeight(.semibold)
                .baselineOffset(-0.5)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.secondary)
                .frame(width: 6, height: 1.5)
                .padding(.bottom, 2)
                .opacity(cursorOpacity)
        }
        .foregroundStyle(.secondary)
        .frame(width: 15, height: 15)
        .padding(6)
        .background(
            Circle()
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .contentShape(Circle())
        .onAppear {
            startCursorAnimationIfNeeded()
        }
        .onChange(of: isRunning) { _, newValue in
            if newValue {
                startCursorAnimationIfNeeded()
            } else {
                cursorOpacity = 1
            }
        }
        .accessibilityLabel("Response running")
    }

    // Keeps the compact copy affordance consistent with the rest of the timeline chrome.
    private var copyLabel: some View {
        HStack(spacing: 4) {
            Group {
                if showCopiedFeedback {
                    Image(systemName: "checkmark")
                        .font(AppFont.system(size: 11, weight: .medium))
                } else {
                    Image("copy")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 15, height: 15)
            if showCopiedFeedback {
                Text("Copied")
                    .font(AppFont.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    // Restarts the blinking underscore whenever a fresh run takes ownership of the accessory.
    private func startCursorAnimationIfNeeded() {
        guard isRunning else { return }
        cursorOpacity = 1
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            cursorOpacity = 0.18
        }
    }
}

#Preview("Default") {
    VStack(alignment: .leading, spacing: 16) {
        Text("This is a sample assistant response with some content that the user might want to copy.")
            .font(AppFont.body())
            .padding(.horizontal, 16)

        CopyBlockButton(text: "This is a sample assistant response with some content that the user might want to copy.")
            .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 20)
}

#Preview("Long block") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Here is the first paragraph of the response.\n\nAnd here is a second paragraph with more detail about the topic at hand.")
            .font(AppFont.body())
            .padding(.horizontal, 16)

        CopyBlockButton(text: "Here is the first paragraph of the response.\n\nAnd here is a second paragraph with more detail about the topic at hand.")
            .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 20)
}

#Preview("Running") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Running a response right now.")
            .font(AppFont.body())
            .padding(.horizontal, 16)

        CopyBlockButton(text: nil, isRunning: true)
            .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 20)
}
