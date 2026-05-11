// FILE: UserBubbleTextBlock.swift
// Purpose: Collapses long user messages without making MessageRow own the state.
// Layer: View Component
// Exports: UserBubbleTextBlock
// Depends on: SwiftUI

import SwiftUI

struct UserBubbleTextBlock<Content: View>: View {
    private static var collapseLineLimit: Int { 10 }
    private static var collapseCharacterThreshold: Int { 360 }
    private static var collapseNewlineThreshold: Int { 8 }

    let contentIdentity: String
    let rawText: String
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = false

    private var canCollapse: Bool {
        if rawText.count > Self.collapseCharacterThreshold {
            return true
        }

        var newlineCount = 0
        for character in rawText where character == "\n" {
            newlineCount += 1
            if newlineCount >= Self.collapseNewlineThreshold {
                return true
            }
        }
        return false
    }

    private var collapseResetKey: Int {
        var hasher = Hasher()
        hasher.combine(contentIdentity)
        hasher.combine(rawText)
        return hasher.finalize()
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            content()
                .lineLimit(canCollapse ? (isExpanded ? nil : Self.collapseLineLimit) : nil)

            if canCollapse {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: collapseResetKey) { _, _ in
            isExpanded = false
        }
    }
}
