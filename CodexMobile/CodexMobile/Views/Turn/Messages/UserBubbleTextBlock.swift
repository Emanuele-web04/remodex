// FILE: UserBubbleTextBlock.swift
// Purpose: Collapses long user messages without making MessageRow own the state.
// Layer: View Component
// Exports: UserBubbleTextBlock
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

struct UserBubbleTextBlock<Content: View>: View {
    private static var collapseLineLimit: Int { 10 }
    private static var collapseCharacterThreshold: Int { 360 }
    private static var collapseNewlineThreshold: Int { 8 }

    let contentIdentity: String
    let rawText: String
    var contentResetKey: String? = nil
    // Block markdown renders through StructuredText, which opts out of lineLimit;
    // those bubbles collapse by capping the rendered height instead.
    var collapsesWithLineLimit: Bool = true
    // Receives the collapsed state so callers can render a cheaper preview while collapsed.
    @ViewBuilder let content: (_ isCollapsed: Bool) -> Content

    @State private var isExpanded = false

    private var canCollapse: Bool {
        var characterCount = 0
        var newlineCount = 0
        for character in rawText {
            characterCount += 1
            if characterCount > Self.collapseCharacterThreshold {
                return true
            }
            if character == "\n" {
                newlineCount += 1
                if newlineCount >= Self.collapseNewlineThreshold {
                    return true
                }
            }
        }
        return false
    }

    private var collapseResetKey: String {
        "\(contentIdentity)|\(contentResetKey ?? TurnTextCacheKey.stableFingerprint(for: rawText))"
    }

    // Follows Dynamic Type so the height-capped collapse shows roughly the same
    // amount of content as the lineLimit-based one.
    private static var collapsedContentMaxHeight: CGFloat {
        AppFont.bodyUIFont().lineHeight * CGFloat(collapseLineLimit)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            collapsibleContent

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

    @ViewBuilder
    private var collapsibleContent: some View {
        let isCollapsed = canCollapse && !isExpanded
        if collapsesWithLineLimit {
            content(isCollapsed)
                .lineLimit(isCollapsed ? Self.collapseLineLimit : nil)
        } else {
            content(isCollapsed)
                .frame(maxHeight: isCollapsed ? Self.collapsedContentMaxHeight : nil, alignment: .top)
                .clipped()
                // Clipped overflow still hit-tests; disable taps until expanded.
                .allowsHitTesting(!isCollapsed)
        }
    }
}
