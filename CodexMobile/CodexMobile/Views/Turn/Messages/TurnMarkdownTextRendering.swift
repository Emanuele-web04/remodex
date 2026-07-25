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

// RemodexTextKit derives its code font from the ambient prose font with SwiftUI's
// `.monospaced()`, which only swaps in a fixed-width face when the base family has one.
// SF Pro Rounded and Geist do not, so a selected rounded/serif app font leaked into code
// blocks. Publishing the app mono face into the block's environment keeps code monospaced
// in every app-font mode while the default style still owns layout, scaling and actions.
private struct MonospacedCodeBlockStyle: StructuredText.CodeBlockStyle {
    let base: StructuredText.DefaultCodeBlockStyle

    func makeBody(configuration: Configuration) -> some View {
        base.makeBody(configuration: configuration)
            .font(AppFont.mono(.body))
    }
}

// The app mono face is pinned explicitly (see `MonospacedCodeBlockStyle`), which
// makes the code font absolute. Headings render by scaling the ambient font, and
// the framework's derived code font followed that scale for free, so keep the
// pinned face in sync by re-publishing it at the heading's own scale.
private enum MarkdownCodeInlineStyle {
    static func applying(codeFont: Font, to style: InlineStyle) -> InlineStyle {
        style.code(
            .font(codeFont),
            .fontScale(0.94),
            .tracking(-0.2),
            .foregroundColor(Color.secondary)
        )
    }
}

private struct ScaledCodeHeadingStyle: StructuredText.HeadingStyle {
    // Mirrors StructuredText.DefaultHeadingStyle's per-level font scales.
    private static let fontScales: [CGFloat] = [2.353, 1.882, 1.647, 1.412, 1.294, 1]

    let base: StructuredText.DefaultHeadingStyle
    let inlineStyle: InlineStyle

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), Self.fontScales.count)
        let codeFont = AppFont.mono(size: AppFont.bodyPointSize * Self.fontScales[level - 1])
        base.makeBody(configuration: configuration)
            .remodex.inlineStyle(MarkdownCodeInlineStyle.applying(codeFont: codeFont, to: inlineStyle))
    }
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
                MonospacedCodeBlockStyle(
                    base: StructuredText.DefaultCodeBlockStyle(
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
            )
            .remodex.inlineStyle(markdownInlineStyle)
            .remodex.headingStyle(
                ScaledCodeHeadingStyle(base: .default, inlineStyle: markdownBaseInlineStyle)
            )
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
    // Inline code keeps RemodexTextKit's default metrics but takes the app mono face explicitly
    // (see `MonospacedCodeBlockStyle` for why the derived `.monospaced()` font is not enough).
    private var markdownInlineStyle: InlineStyle {
        MarkdownCodeInlineStyle.applying(codeFont: AppFont.mono(.body), to: markdownBaseInlineStyle)
    }

    // Everything except the code font, so headings can restate it at their own scale.
    private var markdownBaseInlineStyle: InlineStyle {
        .default
            .link(
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
