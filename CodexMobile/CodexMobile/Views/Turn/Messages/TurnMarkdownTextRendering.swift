// FILE: TurnMarkdownTextRendering.swift
// Purpose: Core markdown rendering for turn timeline rows (parsers + MarkdownTextView).
// Layer: Turn UI rendering
// Exports: MarkdownTextView, PreparsedMarkdown, UncachedMarkdownParser, MarkdownParseCacheReset
// Depends on: Foundation, SwiftUI, RemodexTextKit, TurnMessageCaches, TurnMessageRegexCache

import Foundation
import RemodexTextKit
import SwiftUI

/// Resets the in-memory AttributedString cache that backs ``MarkdownTextView``.
/// Kept for explicit memory recovery without forcing cold parses on every thread switch.
@MainActor
enum MarkdownParseCacheReset {
    static func reset() { CachingMarkdownParser.reset() }
}

// Wraps the default RemodexTextKit markdown parser with a bounded AttributedString
// cache so Foundation's markdown parser is not re-run during timeline redraws
// or when a future lazy container recycles a row on upward scroll.
@MainActor
private struct CachingMarkdownParser: MarkupParser {
    static let shared = CachingMarkdownParser()
    private static let cache = BoundedCache<String, AttributedString>(maxEntries: 128)
    private let inner: AttributedStringMarkdownParser = .markdown()

    func attributedString(for input: String) throws -> AttributedString {
        let key = TurnTextCacheKey.stableKey(namespace: "markdown-parser", text: input)
        if let cached = Self.cache.get(key) {
            return cached
        }
        let result = try inner.attributedString(for: input)
        Self.cache.set(key, value: result)
        return result
    }

    static func reset() {
        cache.removeAll()
    }
}

// Cache-free parser for one-shot inputs (streaming deltas), whose keys never repeat and
// would otherwise flood the shared bounded cache above.
@MainActor
struct UncachedMarkdownParser: MarkupParser {
    static let shared = UncachedMarkdownParser()
    private let inner: AttributedStringMarkdownParser = .markdown()

    func attributedString(for input: String) throws -> AttributedString {
        try inner.attributedString(for: input)
    }
}

// Hands an already-parsed AttributedString straight back to RemodexTextKit so a
// streaming reveal can render a *slice* of a value parsed once per delta, instead
// of re-parsing a String prefix on every animation frame.
@MainActor
private struct IdentityMarkupParser: MarkupParser {
    let value: AttributedString
    func attributedString(for input: String) throws -> AttributedString { value }
}

/// A markdown value parsed once upstream. `revision` must change whenever `value`
/// changes so `StructuredText`'s `onChange(of:)` re-reads it.
struct PreparsedMarkdown {
    let value: AttributedString
    let revision: String
}

struct MarkdownTextView: View {
    var text: String = ""
    // When set, renders this pre-parsed AttributedString instead of parsing `text`.
    var preparsed: PreparsedMarkdown? = nil
    let profile: MarkdownRenderProfile
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false
    var usesCaches: Bool = true
    var usesScrollableCodeBlocks: Bool = false
    // Overrides the accent-derived link color, e.g. inside tinted user bubbles
    // where the accent palette can match the bubble background.
    var linkColor: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey)
    private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    var body: some View {
        let resolved: (markup: String, parser: any MarkupParser) = {
            if let preparsed {
                return (preparsed.revision, IdentityMarkupParser(value: preparsed.value))
            }
            let markup = MarkdownTextFormatter.renderableText(
                from: text,
                profile: profile,
                usesCache: usesCaches
            )
            let parser: any MarkupParser = usesCaches
                ? CachingMarkdownParser.shared
                : UncachedMarkdownParser.shared
            return (markup, parser)
        }()
        // Keep prose on the app font, but let RemodexTextKit own markdown/code layout to avoid block sizing regressions.
        // RemodexTextKit exposes its SwiftUI modifiers under the `.remodex` namespace.
        // Default code-block overflow to wrap so horizontal ScrollViews
        // inside the timeline do not compete with the sidebar swipe gesture or let
        // the chat feel like a pannable canvas. Modal detail views can opt into scroll.
        let baseView = StructuredText(resolved.markup, parser: resolved.parser)
            .font(AppFont.body())
            .remodex.codeBlockStyle(
                .default(
                    actionIcons: .init(
                        copy: .custom {
                            Image("copy", bundle: .main)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                        },
                        copied: .custom {
                            RemodexIcon.image(systemName: "checkmark")
                        }
                    )
                )
            )
            .remodex.inlineStyle(markdownInlineStyle)
            .remodex.structuredTextStyle(.default)
            .remodex.overflowMode(usesScrollableCodeBlocks ? .scroll : .wrap)

        let renderedContent = Group {
            if enablesSelection {
                baseView
                    .remodex.textSelection(.enabled)
            } else {
                baseView
            }
        }

        if constrainsToAvailableWidth {
            // No .clipped() here: UIKit selection handles (the round grabbers) paint a few
            // points outside the text bounds and would get cut. Width containment is already
            // enforced by the frame + fixedSize pair and by the timeline-level clip.
            renderedContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            renderedContent
        }
    }

    // Match markdown links to the app-wide accent palette the user picks for primary actions.
    private var markdownInlineStyle: InlineStyle {
        .default.link(
            .foregroundColor(markdownLinkColor),
            .underlineStyle(.init(pattern: .dot))
        )
    }

    private var markdownLinkColor: Color {
        if let linkColor {
            return linkColor
        }
        let palette = (UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default).ctaPalette
        return palette.bubbleBackground(for: colorScheme)
    }
}
