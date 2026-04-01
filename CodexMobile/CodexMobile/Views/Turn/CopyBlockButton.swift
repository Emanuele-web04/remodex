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

    private var runningIndicator: some View {
        TerminalRunningIndicator()
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
