// FILE: TurnMarkdownTextRendering.swift
// Purpose: Renders and formats markdown text used by turn timeline rows.
// Layer: Turn UI rendering
// Exports: MarkdownTextView, StreamingAssistantMarkdownTextView, MarkdownTextFormatter
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

@MainActor
private struct UncachedMarkdownParser: MarkupParser {
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
        // RemodexTextKit intentionally keeps the `.textual` namespace for its SwiftUI modifiers.
        // Default code-block overflow to wrap so horizontal ScrollViews
        // inside the timeline do not compete with the sidebar swipe gesture or let
        // the chat feel like a pannable canvas. Modal detail views can opt into scroll.
        let baseView = StructuredText(resolved.markup, parser: resolved.parser)
            .font(AppFont.body())
            .textual.codeBlockStyle(
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
            .textual.inlineStyle(markdownInlineStyle)
            .textual.structuredTextStyle(.default)
            .textual.overflowMode(usesScrollableCodeBlocks ? .scroll : .wrap)

        let renderedContent = Group {
            if enablesSelection {
                baseView
                    .textual.textSelection(.enabled)
            } else {
                baseView
            }
        }

        if constrainsToAvailableWidth {
            renderedContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
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
        let palette = (UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default).ctaPalette
        return palette.bubbleBackground(for: colorScheme)
    }
}

struct StreamingAssistantMarkdownTextView: View {
    let text: String
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false
    // Lets the parent disable the reveal when the row isn't the active follow-bottom
    // row (off-screen / older streaming messages snap to their full text instead).
    var animatesReveal: Bool = true
    var protectsPendingIndicatorAnchor: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Mirrors the styling inputs MarkdownTextView reads, so the Equatable settled view restyles
    // when the user flips theme or accent mid-stream (otherwise equality would suppress it).
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey)
    private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue
    // Tracks Dynamic Type so the reproduced inter-block seam spacing scales with the body font.
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 15

    // The message is split into a stable "settled" prefix (every closed block) and the
    // single "active" trailing block that is still streaming. Settled is rendered once and
    // memoized via `Equatable`, so incoming deltas never re-parse or re-measure the history;
    // only the small active block churns. The active block reveals with a per-character
    // opacity ramp on its streaming frontier so new words materialize in place. The seam
    // between the two views reproduces RemodexTextKit's inter-block spacing, which its own
    // BlockVStack drops at container edges.
    @State private var settledText: String = ""
    @State private var activeText: String = ""
    @State private var activeAttributed: AttributedString
    @State private var activeParsedCount: Int
    @State private var activeRevision: Int = 0
    // Full text that drives append/snap decisions and the settled/active split.
    @State private var fullText: String
    // Number of characters revealed within the active block; drives the per-character fade.
    @State private var revealFrontier: Int
    @State private var revealTask: Task<Void, Never>?
    @State private var textAdoptionTask: Task<Void, Never>?
    // Memoizes the last faded value so incidental redraws (scroll-follow, neighbour-row
    // updates, environment changes) at an unchanged frontier reuse it instead of rebuilding.
    @State private var fadeCache = FrontierFadeCache()
    // Seam spacing is derived from the adjacent block kinds, which only change when the
    // active/settled split changes - not on every frontier tick. Cache the multipliers so
    // `body` (re-run per revealed character) stays O(1) instead of re-scanning the settled text.
    @State private var seamTopMultiplier: CGFloat
    @State private var seamBottomMultiplier: CGFloat

    init(
        text: String,
        enablesSelection: Bool = false,
        constrainsToAvailableWidth: Bool = false,
        animatesReveal: Bool = true,
        protectsPendingIndicatorAnchor: Bool = false
    ) {
        self.text = text
        self.enablesSelection = enablesSelection
        self.constrainsToAvailableWidth = constrainsToAvailableWidth
        self.animatesReveal = animatesReveal
        self.protectsPendingIndicatorAnchor = protectsPendingIndicatorAnchor

        let split = StreamingAssistantMarkdownTextView.splitSettledActive(text)
        let activeAttr = StreamingAssistantMarkdownTextView.parse(split.active)
        let activeCount = activeAttr.characters.count
        _fullText = State(initialValue: text)
        _settledText = State(initialValue: split.settled)
        _activeText = State(initialValue: split.active)
        _activeAttributed = State(initialValue: activeAttr)
        _activeParsedCount = State(initialValue: activeCount)
        // Text already present at mount is shown fully (no reveal on first paint).
        _revealFrontier = State(initialValue: activeCount)
        _seamTopMultiplier = State(
            initialValue: StreamingAssistantMarkdownTextView.topSpacingMultiplier(forBlockStarting: split.active)
        )
        _seamBottomMultiplier = State(
            initialValue: StreamingAssistantMarkdownTextView.bottomSpacingMultiplier(forLastBlockOf: split.settled)
        )
    }

    var body: some View {
        let resolved = resolvedReveal()
        let layout = VStack(alignment: .leading, spacing: settledText.isEmpty ? 0 : seamSpacing) {
            if !settledText.isEmpty {
                SettledAssistantMarkdownText(
                    text: settledText,
                    enablesSelection: enablesSelection,
                    constrainsToAvailableWidth: constrainsToAvailableWidth,
                    colorScheme: colorScheme,
                    userBubbleColorRawValue: userBubbleColorRawValue
                )
                .equatable()
            }
            if !activeText.isEmpty {
                MarkdownTextView(
                    preparsed: PreparsedMarkdown(value: resolved.attributed, revision: resolved.revision),
                    profile: .assistantProse,
                    enablesSelection: enablesSelection,
                    constrainsToAvailableWidth: constrainsToAvailableWidth
                )
            }
        }

        Group {
            if constrainsToAvailableWidth {
                layout.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                layout
            }
        }
        .onAppear {
            adoptText(text, animated: false)
        }
        .onChange(of: text) { _, nextText in
            scheduleTextAdoption(
                nextText,
                animated: animatesReveal && !reduceMotion
            )
        }
        .onChange(of: animatesReveal) { _, isAnimating in
            if !isAnimating {
                snapToActive()
            }
        }
        .onDisappear {
            textAdoptionTask?.cancel()
            textAdoptionTask = nil
            cancelReveal()
        }
    }

    // Reproduces the gap BlockVStack would place between the last settled block and the first
    // active block (max of the adjacent edges), since each StructuredText drops edge spacing.
    // Reads cached multipliers, so this stays O(1) on the per-character render path.
    private var seamSpacing: CGFloat {
        max(seamTopMultiplier, seamBottomMultiplier) * bodyFontSize
    }

    // Picks between the fully-styled active value and a frontier-faded copy. The revision keys
    // the rendered value so RemodexTextKit re-reads only when the revealed text changes.
    private func resolvedReveal() -> (attributed: AttributedString, revision: String) {
        guard animatesReveal, !reduceMotion, revealFrontier < activeParsedCount else {
            return (activeAttributed, "full-\(activeRevision)")
        }
        let revision = "rev-\(activeRevision)-\(revealFrontier)"
        if let cached = fadeCache.value(forRevision: activeRevision, frontier: revealFrontier) {
            return (cached, revision)
        }
        let faded = Self.applyFrontierFade(to: activeAttributed, frontier: revealFrontier)
        fadeCache.store(faded, revision: activeRevision, frontier: revealFrontier)
        return (faded, revision)
    }

    private func scheduleTextAdoption(_ nextText: String, animated: Bool) {
        textAdoptionTask?.cancel()
        // Streaming text can change repeatedly in one SwiftUI frame. Coalescing the
        // local @State writes keeps reveal state current without tripping onChange's
        // per-frame mutation guard.
        textAdoptionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            adoptText(nextText, animated: animated)
            textAdoptionTask = nil
        }
    }

    private func adoptText(_ nextText: String, animated: Bool) {
        let previousFull = fullText
        let settledDidChange = setFullText(nextText)

        if nextText.isEmpty {
            cancelReveal()
            revealFrontier = 0
            return
        }

        // Snap for the initial mount, reduced motion, and any non-append change
        // (replay / reconciliation) so the transcript stays exact.
        let isAppend = nextText.hasPrefix(previousFull)
        guard animated, isAppend else {
            snapToActive()
            return
        }

        // A newly closed block restarts the active region; fade the new block from the start.
        if settledDidChange {
            revealFrontier = 0
        }
        guard revealFrontier < activeParsedCount else { return }
        startRevealIfNeeded()
    }

    // Updates the split state; returns whether the settled prefix changed (a block closed).
    @discardableResult
    private func setFullText(_ nextText: String) -> Bool {
        guard fullText != nextText else { return false }
        fullText = nextText

        let split = Self.splitSettledActive(nextText)
        let settledDidChange = split.settled != settledText
        if settledDidChange {
            settledText = split.settled
            // Last settled block kind drives the seam's bottom edge; recompute only on close.
            seamBottomMultiplier = Self.bottomSpacingMultiplier(forLastBlockOf: split.settled)
        }
        if split.active != activeText {
            activeText = split.active
            activeAttributed = Self.parse(split.active)
            activeParsedCount = activeAttributed.characters.count
            activeRevision &+= 1
            // First active block kind drives the seam's top edge; cheap (first line only).
            seamTopMultiplier = Self.topSpacingMultiplier(forBlockStarting: split.active)
            if revealFrontier > activeParsedCount {
                revealFrontier = activeParsedCount
            }
        }
        return settledDidChange
    }

    private func snapToActive() {
        cancelReveal()
        revealFrontier = activeParsedCount
    }

    private func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
    }

    private func startRevealIfNeeded() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            await runReveal()
            revealTask = nil
        }
    }

    // Drains the already-arrived active buffer toward the frontier at a steady, adaptive
    // velocity. This mirrors Synara's smooth-stream hook: small backlogs trickle, large flushes
    // catch up quickly, and the loop sleeps completely once caught up. Accumulator + velocity
    // stay local so per-frame work does not invalidate the view; only whole-character advances
    // of `revealFrontier` trigger a re-render.
    private func runReveal() async {
        var revealed = Double(revealFrontier)
        var velocity = 0.0
        var lastFrameTime: TimeInterval?

        while !Task.isCancelled {
            let count = activeParsedCount
            if revealed > Double(count) {
                revealed = Double(count)
            }

            let backlog = Double(count) - revealed
            if backlog <= 0 {
                if revealFrontier != count {
                    revealFrontier = count
                }
                return
            }

            let now = Date.timeIntervalSinceReferenceDate
            let deltaSeconds = lastFrameTime.map {
                min(now - $0, StreamingMarkdownRevealPolicy.maximumFrameSeconds)
            } ?? 0
            lastFrameTime = now

            let targetVelocity = min(
                StreamingMarkdownRevealPolicy.maximumCharactersPerSecond,
                backlog / StreamingMarkdownRevealPolicy.drainWindowSeconds
            )
            velocity += (targetVelocity - velocity) * StreamingMarkdownRevealPolicy.velocityLerp
            revealed = min(Double(count), revealed + velocity * deltaSeconds)

            // Never let more than a short tail stay hidden: on big flushes, pull the frontier up
            // so the newest visible line stays at the pinned bottom instead of a blank reserve.
            let minRevealed = Double(max(0, count - StreamingMarkdownRevealPolicy.maxHiddenTailCharacters))
            if revealed < minRevealed {
                revealed = minRevealed
            }

            let nextFrontier = Int(revealed.rounded(.down))
            if nextFrontier != revealFrontier {
                revealFrontier = nextFrontier
            }

            if Double(count) - revealed <= 0 {
                if revealFrontier != count {
                    revealFrontier = count
                }
                return
            }

            try? await Task.sleep(nanoseconds: StreamingMarkdownRevealPolicy.frameIntervalNanoseconds)
        }
    }

    @MainActor
    private static func parse(_ text: String) -> AttributedString {
        let transformed = MarkdownTextFormatter.renderableText(
            from: text,
            profile: .assistantProse,
            usesCache: true
        )
        return (try? CachingMarkdownParser.shared.attributedString(for: transformed))
            ?? AttributedString(text)
    }

    // Returns a copy of the parsed value where text past `frontier` is hidden and the
    // trailing window fades from faint (newest) to opaque, so words materialize in place.
    // Only the suffix is mutated; the opaque prefix keeps its original markdown styling.
    private static func applyFrontierFade(to attributed: AttributedString, frontier: Int) -> AttributedString {
        let total = attributed.characters.count
        let clampedFrontier = min(max(frontier, 0), total)
        guard clampedFrontier < total else { return attributed }

        var copy = attributed

        let hiddenStart = copy.index(copy.startIndex, offsetByCharacters: clampedFrontier)

        // Resolve the window start once by walking back from the frontier (O(window)), then
        // advance one character at a time. This avoids re-resolving each window character index
        // from startIndex, which would be O(window * frontier) per revealed character. All edits
        // are length-preserving foreground-color changes, so the indices stay valid as we go.
        let window = StreamingMarkdownRevealPolicy.fadeWindowCharacters
        let windowLength = min(window, clampedFrontier)
        var charStart = copy.index(hiddenStart, offsetByCharacters: -windowLength)

        // Hide everything past the frontier in a single attribute run.
        copy[hiddenStart..<copy.endIndex].foregroundColor = Color.primary.opacity(0)

        // Fade the trailing window: the closer to the frontier, the fainter.
        var offset = clampedFrontier - windowLength
        while offset < clampedFrontier {
            let charEnd = copy.index(charStart, offsetByCharacters: 1)
            let distanceFromFrontier = Double(clampedFrontier - offset)
            let alpha = min(1.0, distanceFromFrontier / Double(window))
            let existing = copy[charStart..<charEnd].foregroundColor ?? Color.primary
            copy[charStart..<charEnd].foregroundColor = existing.opacity(alpha)
            charStart = charEnd
            offset += 1
        }

        return copy
    }

    // Splits the text into the settled prefix (all closed top-level blocks) and the active
    // trailing block. A blank line outside a code fence ends a block; an open fence keeps its
    // content in the active block so a still-typing fence never reflows the settled history.
    static func splitSettledActive(_ text: String) -> (settled: String, active: String) {
        guard !text.isEmpty else { return ("", "") }

        let lines = text.components(separatedBy: "\n")
        var insideFence = false
        var pendingBoundary = false
        var sawContent = false
        var lastBlockStartLine = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFenceMarker = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            if isFenceMarker {
                if pendingBoundary { lastBlockStartLine = index; pendingBoundary = false }
                sawContent = true
                insideFence.toggle()
                continue
            }

            if insideFence {
                if pendingBoundary { lastBlockStartLine = index; pendingBoundary = false }
                sawContent = true
                continue
            }

            if trimmed.isEmpty {
                if sawContent { pendingBoundary = true }
            } else {
                if pendingBoundary { lastBlockStartLine = index; pendingBoundary = false }
                sawContent = true
            }
        }

        guard lastBlockStartLine > 0 else { return ("", text) }

        let settled = lines[0..<lastBlockStartLine].joined(separator: "\n")
        let active = lines[lastBlockStartLine...].joined(separator: "\n")
        return (settled, active)
    }

    private enum BlockKind {
        case paragraph, heading, code, table, thematicBreak, blockquote, list

        // Font-relative `blockSpacing` from RemodexTextKit's default styles. Single source of
        // truth for the settled<->active seam, mirroring (grep these if the library changes):
        //   DefaultParagraphStyle      .blockSpacing(.fontScaled(top: 0.8))
        //   DefaultHeadingStyle        .blockSpacing(.fontScaled(top: 1.6, bottom: 0.8))
        //   DefaultCodeBlockStyle      .blockSpacing(.fontScaled(top: 0.88, bottom: 0))
        //   DefaultTableStyle          .blockSpacing(.fontScaled(top: 1.6, bottom: 1.6))
        //   DividerThematicBreakStyle  .blockSpacing(.fontScaled(top: 1.6, bottom: 1.6))
        // Blockquote and list leave `blockSpacing` unset (resolved by surrounding styles), so
        // their values here are a paragraph-like approximation of the resolved gap.
        var topMultiplier: CGFloat {
            switch self {
            case .paragraph: return 0.8
            case .heading: return 1.6
            case .code: return 0.88
            case .table, .thematicBreak: return 1.6
            case .blockquote, .list: return 0.8
            }
        }

        var bottomMultiplier: CGFloat {
            switch self {
            case .paragraph, .code, .blockquote, .list: return 0
            case .heading: return 0.8
            case .table, .thematicBreak: return 1.6
            }
        }
    }

    private static func topSpacingMultiplier(forBlockStarting active: String) -> CGFloat {
        guard let line = firstNonBlankLine(of: active) else { return 0 }
        return classify(line).topMultiplier
    }

    private static func bottomSpacingMultiplier(forLastBlockOf settled: String) -> CGFloat {
        // The last settled block's kind is set by its first line, so reuse the splitter.
        let lastBlock = splitSettledActive(settled).active
        guard let line = firstNonBlankLine(of: lastBlock) else { return 0 }
        return classify(line).bottomMultiplier
    }

    private static func firstNonBlankLine(of text: String) -> String? {
        // Scan line by line and stop at the first non-blank one, so a long active block
        // never materializes its whole line array just to read its leading line.
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return nil
    }

    private static func classify(_ trimmedLine: String) -> BlockKind {
        if trimmedLine.hasPrefix("#") { return .heading }
        if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") { return .code }
        if trimmedLine.hasPrefix(">") { return .blockquote }
        if trimmedLine.hasPrefix("|") { return .table }
        if isThematicBreak(trimmedLine) { return .thematicBreak }
        if isListMarker(trimmedLine) { return .list }
        return .paragraph
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func isListMarker(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        // Ordered list: digits followed by "." or ")" and a space.
        var sawDigit = false
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            sawDigit = true
            index = line.index(after: index)
        }
        guard sawDigit, index < line.endIndex else { return false }
        let marker = line[index]
        guard marker == "." || marker == ")" else { return false }
        let afterMarker = line.index(after: index)
        return afterMarker < line.endIndex && line[afterMarker] == " "
    }
}

// The settled prefix. `Equatable` on its content so streaming deltas to the active block do
// not re-evaluate (and therefore do not re-parse or re-measure) the message history. Styling
// inputs that `MarkdownTextView` reads for assistant prose (color scheme + accent that drive
// the markdown link color) are part of the identity, so a theme/accent change mid-stream still
// restyles the settled text instead of being suppressed by equality.
private struct SettledAssistantMarkdownText: View, Equatable {
    let text: String
    let enablesSelection: Bool
    let constrainsToAvailableWidth: Bool
    let colorScheme: ColorScheme
    let userBubbleColorRawValue: String

    var body: some View {
        MarkdownTextView(
            text: text,
            profile: .assistantProse,
            enablesSelection: enablesSelection,
            constrainsToAvailableWidth: constrainsToAvailableWidth
        )
    }

    static func == (lhs: SettledAssistantMarkdownText, rhs: SettledAssistantMarkdownText) -> Bool {
        lhs.text == rhs.text
            && lhs.enablesSelection == rhs.enablesSelection
            && lhs.constrainsToAvailableWidth == rhs.constrainsToAvailableWidth
            && lhs.colorScheme == rhs.colorScheme
            && lhs.userBubbleColorRawValue == rhs.userBubbleColorRawValue
    }
}

// Single-slot memo for the most recently produced frontier fade. A reference type so it can
// be updated from within `body` without invalidating SwiftUI state; the reveal is monotonic
// during streaming, so one slot is enough to absorb the incidental redraws between advances.
private final class FrontierFadeCache {
    private var cachedRevision = -1
    private var cachedFrontier = -1
    private var cachedValue = AttributedString()

    func value(forRevision revision: Int, frontier: Int) -> AttributedString? {
        guard cachedRevision == revision, cachedFrontier == frontier else { return nil }
        return cachedValue
    }

    func store(_ value: AttributedString, revision: Int, frontier: Int) {
        cachedRevision = revision
        cachedFrontier = frontier
        cachedValue = value
    }
}

private enum StreamingMarkdownRevealPolicy {
    static let frameIntervalNanoseconds: UInt64 = 16_000_000
    static let drainWindowSeconds = 0.16
    static let maximumCharactersPerSecond = 2_000.0
    static let velocityLerp = 0.15
    static let maximumFrameSeconds: TimeInterval = 0.05
    // How many characters the soft fade-in trailing edge spans.
    static let fadeWindowCharacters = 18
    // Upper bound on how many characters may stay hidden past the frontier. Unrevealed text
    // still reserves layout height (it is only alpha-hidden), so an unbounded backlog would
    // leave a blank sliver pinned at the bottom during large bursts. Small streaming deltas stay
    // under this bound and reveal normally; only big flushes are pulled up to keep the newest
    // visible line near the pinned bottom.
    static let maxHiddenTailCharacters = 24
}

enum MarkdownTextFormatter {
    // Applies lightweight markdown cleanup and turns file paths into link-styled labels.
    static func renderableText(
        from raw: String,
        profile: MarkdownRenderProfile,
        usesCache: Bool = true
    ) -> String {
        let build = {
            renderableTextUncached(from: raw, profile: profile)
        }

        if usesCache {
            return MarkdownRenderableTextCache.rendered(raw: raw, profile: profile, builder: build)
        }

        return build()
    }

    private static func renderableTextUncached(from raw: String, profile: MarkdownRenderProfile) -> String {
        let normalizedSkills = SkillReferenceFormatter.replacingSkillReferences(
            in: raw,
            style: .displayName
        )
        let headingNormalized = replaceMatches(
            in: normalizedSkills,
            regex: TurnMessageRegexCache.heading,
            template: "**$1**"
        )
        return linkifyFileReferenceLines(in: headingNormalized, profile: profile)
    }

    private static func linkifyFileReferenceLines(in text: String, profile: MarkdownRenderProfile) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var isInsideFence = false

        let transformed = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                isInsideFence.toggle()
                return line
            }

            guard !isInsideFence else {
                return line
            }

            return linkifyInlineFileReferences(in: line, profile: profile)
        }

        return transformed.joined(separator: "\n")
    }

    private static func linkifyInlineFileReferences(in line: String, profile: MarkdownRenderProfile) -> String {
        switch profile {
        case .assistantProse, .fileChangeSystem:
            break
        }

        var transformedLine = line

        if let fileLinked = linkifyFileReferenceLine(transformedLine), fileLinked != transformedLine {
            transformedLine = fileLinked
        }

        transformedLine = linkifyInlineCodeFileReferences(in: transformedLine)
        return linkifyGenericPathTokens(in: transformedLine)
    }

    private static func linkifyFileReferenceLine(_ line: String) -> String? {
        guard let markerRange = line.range(of: "File:") else {
            return nil
        }

        let prefix = String(line[..<markerRange.lowerBound])
        let rawReference = line[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawReference.isEmpty,
              !rawReference.contains("]("),
              let parsed = parseFileReference(rawReference) else {
            return nil
        }

        return "\(prefix)File: [\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
    }

    private static func linkifyGenericPathTokens(in line: String) -> String {
        guard let regex = TurnMessageRegexCache.genericPath else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let inlineCodeRanges = inlineCodeRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let matchRange = match.range
            guard !rangeOverlapsMarkdownLink(matchRange, linkRanges: linkRanges) else {
                continue
            }
            guard !rangeOverlapsMarkdownLink(matchRange, linkRanges: inlineCodeRanges) else {
                continue
            }
            guard isEligiblePathTokenRange(matchRange, in: nsLine) else {
                continue
            }

            let token = nsLine.substring(with: matchRange)
            guard let parsed = parseFileReference(token) else {
                continue
            }

            let replacement = "[\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
            mutableLine.replaceCharacters(in: matchRange, with: replacement)
        }

        return String(mutableLine)
    }

    // Converts inline-code file refs (`/path/File.swift:42`) into compact markdown links.
    private static func linkifyInlineCodeFileReferences(in line: String) -> String {
        guard let regex = TurnMessageRegexCache.inlineCodeContent else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let fullMatchRange = match.range
            guard !rangeOverlapsMarkdownLink(fullMatchRange, linkRanges: linkRanges) else {
                continue
            }
            guard match.numberOfRanges > 1 else {
                continue
            }

            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound, tokenRange.length > 0 else {
                continue
            }

            let token = nsLine.substring(with: tokenRange)
            guard isStandaloneInlineCodeFileReference(token) else {
                continue
            }
            guard let parsed = parseFileReference(token) else {
                continue
            }

            let replacement = "[\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
            mutableLine.replaceCharacters(in: fullMatchRange, with: replacement)
        }

        return String(mutableLine)
    }

    private static func isStandaloneInlineCodeFileReference(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == token else {
            return false
        }

        return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private static func markdownLinkRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.markdownLinkRanges(in: line)
    }

    private static func inlineCodeRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.inlineCodeRanges(in: line)
    }

    private static func isEligiblePathTokenRange(_ range: NSRange, in line: NSString) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else {
            return false
        }

        let token = line.substring(with: range)
        if token.hasPrefix("//") {
            return false
        }

        let contextStart = max(0, range.location - 3)
        let contextLength = range.location - contextStart
        let leadingContext = contextLength > 0
            ? line.substring(with: NSRange(location: contextStart, length: contextLength))
            : ""
        if leadingContext.hasSuffix("://") {
            return false
        }

        let previousChar: String = range.location > 0
            ? line.substring(with: NSRange(location: range.location - 1, length: 1))
            : ""
        if token.hasPrefix("/"), isLikelyDomainCharacter(previousChar) {
            return false
        }

        return true
    }

    private static func rangeOverlapsMarkdownLink(_ range: NSRange, linkRanges: [NSRange]) -> Bool {
        TurnMessageRegexCache.rangeOverlaps(range, protectedRanges: linkRanges)
    }

    private static func escapeMarkdownLinkDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func parseFileReference(_ rawReference: String) -> (label: String, destination: String)? {
        var candidate = rawReference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))

        while let last = candidate.last, ",.;)]}".contains(last) {
            candidate.removeLast()
        }

        if candidate.hasPrefix("(") {
            candidate.removeFirst()
        }

        guard candidate.hasPrefix("/") || candidate.contains("/") else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: (candidate as NSString).length)

        var path = candidate
        var lineNumber: String?

        if let lineRegex = TurnMessageRegexCache.filenameWithLine,
           let match = lineRegex.firstMatch(in: candidate, range: fullRange),
           match.numberOfRanges >= 3 {
            let nsCandidate = candidate as NSString
            path = nsCandidate.substring(with: match.range(at: 1))
            lineNumber = nsCandidate.substring(with: match.range(at: 2))
        }

        let basename = (path as NSString).lastPathComponent
        guard !basename.isEmpty else {
            return nil
        }
        guard basename.contains(".") || lineNumber != nil else {
            return nil
        }

        let label: String
        let destination: String
        if let lineNumber {
            label = "\(basename) (line \(lineNumber))"
            destination = "\(path):\(lineNumber)"
        } else {
            label = basename
            destination = path
        }

        return (label, destination)
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression?,
        template: String
    ) -> String {
        TurnMessageRegexCache.replaceMatches(in: text, regex: regex, template: template)
    }

    private static func isLikelyDomainCharacter(_ value: String) -> Bool {
        guard value.count == 1, let scalar = value.unicodeScalars.first else {
            return false
        }
        if CharacterSet.alphanumerics.contains(scalar) {
            return true
        }
        return scalar == UnicodeScalar(".")
    }
}
