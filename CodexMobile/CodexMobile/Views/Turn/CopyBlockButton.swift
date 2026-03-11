// FILE: CopyBlockButton.swift
// Purpose: Small copy button shown at the end of each assistant response block.
// Layer: View Component
// Exports: CopyBlockButton

import SwiftUI
import UIKit

struct CopyBlockButton: View {
    let text: String
    @State private var showCopiedFeedback = false

    var body: some View {
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
        .buttonStyle(.plain)
        .accessibilityLabel("Copy response")
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
