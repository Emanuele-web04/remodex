// FILE: StreamingAssistantMarkdownTextView.swift
// Purpose: Streams assistant markdown as a settled prefix plus a frontier-faded active block.
// Layer: Turn UI rendering
// Exports: StreamingAssistantMarkdownTextView
// Depends on: Foundation, SwiftUI, MarkdownTextView, StreamingMarkdownBlockSplitter,
//   StreamingMarkdownReveal, StreamingInlineMarkupAutoCloser, MarkdownTextFormatter

import Foundation
import SwiftUI

struct StreamingAssistantMarkdownTextView: View {
    let text: String
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false
    // Lets the parent disable the reveal when the row isn't the active follow-bottom
    // row (off-screen / older streaming messages snap to their full text instead).
    var animatesReveal: Bool = true

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
    // opacity ramp whose frontier is advanced on the display refresh (see
    // `StreamingRevealController`), so new words materialize continuously instead of stepping
    // on whole-character crossings. The seam between the two views reproduces RemodexTextKit's
    // inter-block spacing, which its own BlockVStack drops at container edges.
    // All state starts empty and is populated by the first adoptText (onAppear). SwiftUI
    // re-runs this struct's init on every parent re-render (once per streaming delta) and
    // discards the State initial values for already-mounted views, so any eager split/parse
    // here would be paid per delta just to be thrown away. Until adoption, `body` renders the
    // full text through the plain cached path (visually identical output).
    @State private var settledText: String = ""
    @State private var activeText: String = ""
    @State private var activeAttributed = AttributedString()
    @State private var activeParsedCount = 0
    @State private var activeRevision: Int = 0
    // Full text that drives append/snap decisions and the settled/active split.
    @State private var fullText: String = ""
    // Advances the fractional reveal frontier on the display refresh (CADisplayLink), so the
    // fade is vsync-locked and continuous rather than stepping on integer character crossings.
    @State private var reveal = StreamingRevealController()
    @State private var textAdoptionTask: Task<Void, Never>?
    // Memoizes the last faded value so incidental redraws (scroll-follow, neighbour-row
    // updates, environment changes) at an unchanged frontier bucket reuse it instead of rebuilding.
    @State private var fadeCache = FrontierFadeCache()
    // Seam spacing is derived from the adjacent block kinds, which only change when the
    // active/settled split changes - not on every frontier tick. Cache the multipliers so
    // `body` (re-run per revealed character) stays O(1) instead of re-scanning the settled text.
    @State private var seamTopMultiplier: CGFloat = 0
    @State private var seamBottomMultiplier: CGFloat = 0

    init(
        text: String,
        enablesSelection: Bool = false,
        constrainsToAvailableWidth: Bool = false,
        animatesReveal: Bool = true
    ) {
        self.text = text
        self.enablesSelection = enablesSelection
        self.constrainsToAvailableWidth = constrainsToAvailableWidth
        self.animatesReveal = animatesReveal
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
            if fullText.isEmpty, !text.isEmpty {
                // Pre-adoption frame (first mount, before onAppear runs adoptText): render the
                // full text through the plain cached path. Fully revealed, one StructuredText,
                // so the handoff to the split layout below is pixel-stable by construction.
                MarkdownTextView(
                    text: text,
                    profile: .assistantProse,
                    enablesSelection: enablesSelection,
                    constrainsToAvailableWidth: constrainsToAvailableWidth
                )
            } else if constrainsToAvailableWidth {
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
        // Accessibility: if Reduce Motion turns on mid-stream, stop the reveal immediately
        // instead of letting the in-flight animation drain on its own.
        .onChange(of: reduceMotion) { _, reducesMotion in
            if reducesMotion {
                snapToActive()
            }
        }
        .onDisappear {
            textAdoptionTask?.cancel()
            textAdoptionTask = nil
            reveal.stop()
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
        // The quantized bucket is the sole observable dependency of the reveal; the raw
        // position/velocity reads below are untracked snapshots taken when the bucket moves.
        let bucket = reveal.bucket
        let count = activeParsedCount
        let fullBucket = Int((Double(count) * StreamingMarkdownRevealPolicy.positionQuantization).rounded())
        guard animatesReveal, !reduceMotion, bucket < fullBucket else {
            return (activeAttributed, "full-\(activeRevision)")
        }
        // The window is quantized to whole characters and folded into the key/revision, so the
        // cache and RemodexTextKit always re-read exactly the value that was rendered.
        let window = Int(StreamingMarkdownRevealPolicy.fadeWindow(forVelocity: reveal.velocity).rounded())
        let revision = "rev-\(activeRevision)-\(bucket)-\(window)"
        if let cached = fadeCache.value(forRevision: activeRevision, bucket: bucket, window: window) {
            return (cached, revision)
        }
        let position = Double(bucket) / StreamingMarkdownRevealPolicy.positionQuantization
        let faded = Self.applyFrontierFade(
            to: activeAttributed,
            totalCharacters: count,
            position: position,
            window: Double(window)
        )
        fadeCache.store(faded, revision: activeRevision, bucket: bucket, window: window)
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
        // Computed before the split state mutates; also gates the incremental split fast path.
        let isAppend = nextText.hasPrefix(fullText)
        let settledDidChange = setFullText(nextText, isAppend: isAppend)

        if nextText.isEmpty {
            reveal.reset(to: 0)
            return
        }

        // Snap for the initial mount, reduced motion, and any non-append change
        // (replay / reconciliation) so the transcript stays exact.
        guard animated, isAppend else {
            snapToActive()
            return
        }

        // A newly closed block restarts the active region; fade the new block from the start.
        if settledDidChange {
            reveal.rewindToStart()
        }
        reveal.start(targetCount: activeParsedCount)
    }

    // Updates the split state; returns whether the settled prefix changed (a block closed).
    // `isAppend` enables the incremental fast path: in an append the settled boundary can only
    // advance, so only the previous active block plus the new delta needs rescanning -
    // O(active block) per delta instead of O(entire message). Correctness relies on split
    // invariants: the boundary line is non-blank and never inside a fence, so rescanning the
    // tail from a fresh scan state matches the full scan (see the parity notes on each edge).
    @discardableResult
    private func setFullText(_ nextText: String, isAppend: Bool) -> Bool {
        guard fullText != nextText else { return false }
        fullText = nextText

        // Incremental path: the previous full text was settled + "\n" + active, so the new
        // tail (active + delta) starts right past the settled prefix and its joining newline.
        if isAppend, !settledText.isEmpty {
            let utf8 = nextText.utf8
            if let tailStart = utf8.index(
                utf8.startIndex,
                offsetBy: settledText.utf8.count + 1,
                limitedBy: utf8.endIndex
            ) {
                let split = StreamingMarkdownBlockSplitter.split(String(nextText[tailStart...]))
                let settledDidChange = !split.settled.isEmpty
                if settledDidChange {
                    settledText += "\n" + split.settled
                    // The tail's settled suffix ends with the same block as the full settled
                    // text, so the seam's bottom edge derives from the suffix alone.
                    seamBottomMultiplier = StreamingMarkdownBlockSplitter.bottomSpacingMultiplier(
                        forLastBlockOf: split.settled
                    )
                }
                applyActiveBlock(split.active)
                return settledDidChange
            }
        }

        let split = StreamingMarkdownBlockSplitter.split(nextText)
        let settledDidChange = split.settled != settledText
        if settledDidChange {
            settledText = split.settled
            // Last settled block kind drives the seam's bottom edge; recompute only on close.
            seamBottomMultiplier = StreamingMarkdownBlockSplitter.bottomSpacingMultiplier(
                forLastBlockOf: split.settled
            )
        }
        applyActiveBlock(split.active)
        return settledDidChange
    }

    // Adopts a new active block value: one parse per delta, skipped when unchanged.
    // The parsed copy virtually closes unterminated inline spans (`code`, **bold**) so
    // they render styled from the first character instead of flashing raw markers that
    // collapse into styling when the real closer streams in.
    private func applyActiveBlock(_ active: String) {
        guard active != activeText else { return }
        activeText = active
        activeAttributed = Self.parse(StreamingInlineMarkupAutoCloser.autoClosed(active))
        activeParsedCount = activeAttributed.characters.count
        activeRevision &+= 1
        // First active block kind drives the seam's top edge; cheap (first line only).
        seamTopMultiplier = StreamingMarkdownBlockSplitter.topSpacingMultiplier(forBlockStarting: active)
        reveal.clampTarget(to: activeParsedCount)
    }

    private func snapToActive() {
        reveal.reset(to: activeParsedCount)
    }

    // Streaming-delta parse, deliberately outside the shared bounded caches: the active block
    // grows on every delta, so its keys never repeat - caching them would only flood the shared
    // caches and evict entries other rows still need, without ever producing a hit. Each delta
    // is parsed exactly once here (the pre-adoption fallback uses the cached path instead).
    @MainActor
    private static func parse(_ text: String) -> AttributedString {
        let transformed = MarkdownTextFormatter.renderableText(
            from: text,
            profile: .assistantProse,
            usesCache: false
        )
        return (try? UncachedMarkdownParser.shared.attributedString(for: transformed))
            ?? AttributedString(text)
    }

    // Returns a copy of the parsed value where text past the fractional `position` is hidden and
    // the trailing `window` fades from faint (newest) to opaque, so words materialize in place.
    // `position` is fractional and advances every display frame, so a character's alpha rises
    // smoothly over `window / velocity` seconds (a fixed fade time) instead of snapping on whole
    // crossings. Only the suffix is mutated; the opaque prefix keeps its original markdown styling.
    // `totalCharacters` is the caller's cached count for `attributed` (an AttributedString
    // character count is an O(n) walk, too costly to redo on every frontier step).
    private static func applyFrontierFade(
        to attributed: AttributedString,
        totalCharacters: Int,
        position: Double,
        window: Double
    ) -> AttributedString {
        let total = totalCharacters
        let clamped = min(max(position, 0), Double(total))
        guard clamped < Double(total) else { return attributed }

        var copy = attributed

        // A character at integer index `i` is at least partially revealed while `i < position`,
        // so the first fully-hidden index is ceil(position).
        let hiddenIndex = min(total, Int(clamped.rounded(.up)))
        let hiddenStart = copy.index(copy.startIndex, offsetByCharacters: hiddenIndex)

        // Hide everything past the frontier in a single attribute run.
        copy[hiddenStart..<copy.endIndex].foregroundColor = Color.primary.opacity(0)

        // Resolve the window start once by walking back from the frontier (O(window)), then
        // advance one character at a time. This avoids re-resolving each window character index
        // from startIndex, which would be O(window * position) per frame. All edits are
        // length-preserving foreground-color changes, so the indices stay valid as we go.
        let safeWindow = max(window, 1)
        let windowLength = min(Int(safeWindow.rounded(.up)), hiddenIndex)
        var charStart = copy.index(hiddenStart, offsetByCharacters: -windowLength)

        // Fade the trailing window: alpha rises with distance behind the fractional frontier,
        // so the newest character (distance ~0) is faintest and materializes as `position` moves.
        var index = hiddenIndex - windowLength
        while index < hiddenIndex {
            let charEnd = copy.index(charStart, offsetByCharacters: 1)
            let distance = clamped - Double(index)
            let alpha = min(1.0, max(0.0, distance / safeWindow))
            let existing = copy[charStart..<charEnd].foregroundColor ?? Color.primary
            copy[charStart..<charEnd].foregroundColor = existing.opacity(alpha)
            charStart = charEnd
            index += 1
        }

        return copy
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
    private var cachedBucket = Int.min
    private var cachedWindow = -1
    private var cachedValue = AttributedString()

    func value(forRevision revision: Int, bucket: Int, window: Int) -> AttributedString? {
        guard cachedRevision == revision, cachedBucket == bucket, cachedWindow == window else { return nil }
        return cachedValue
    }

    func store(_ value: AttributedString, revision: Int, bucket: Int, window: Int) {
        cachedRevision = revision
        cachedBucket = bucket
        cachedWindow = window
        cachedValue = value
    }
}
