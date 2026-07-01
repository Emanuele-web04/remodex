// FILE: StreamingMarkdownReveal.swift
// Purpose: Vsync-locked reveal engine for streaming assistant markdown (rate smoothing + frontier).
// Layer: Turn UI rendering support
// Exports: StreamingMarkdownRevealPolicy, StreamingRevealController
// Depends on: Foundation, Observation, QuartzCore

import Foundation
import Observation
import QuartzCore

enum StreamingMarkdownRevealPolicy {
    // Rate-smoothing constants ported from Synara's smooth-stream hook: small backlogs trickle,
    // large flushes catch up quickly. The frontier is advanced on the display refresh
    // (CADisplayLink) instead of a fixed Task.sleep, so the reveal is phase-locked to vsync.
    static let drainWindowSeconds = 0.16
    static let maximumCharactersPerSecond = 2_000.0
    static let velocityLerp = 0.15
    static let maximumFrameSeconds: TimeInterval = 0.05
    // Sub-character resolution for the frontier bucket (quarter-character steps), fine enough
    // to read as continuous at the display rate while deduping sub-bucket ticks and redraws.
    static let positionQuantization = 4.0
    // How long, in seconds, a single glyph takes to fade from faint to opaque. The fade window is
    // scaled to the current velocity (window ≈ velocity × this) so the fade time stays fixed at
    // any stream speed instead of collapsing to sub-frame at high speed (which reads as a "pop").
    static let fadeDurationSeconds = 0.32
    // Bounds on the fade window so it stays a subtle band and the per-frame color-run count is
    // small. The lower bound keeps a soft edge at slow speeds; the upper bound caps fast streams.
    static let minimumFadeWindowCharacters = 10.0
    static let maximumFadeWindowCharacters = 30.0
    // Upper bound on how many characters may stay hidden past the frontier. Unrevealed text
    // still reserves layout height (it is only alpha-hidden), so an unbounded backlog would
    // leave a blank sliver pinned at the bottom during large bursts. Small streaming deltas stay
    // under this bound and reveal normally; only big flushes are pulled up to keep the newest
    // visible line near the pinned bottom.
    static let maxHiddenTailCharacters = 24

    // Scales the fade window to the reveal velocity so each glyph takes a fixed time to
    // materialize regardless of stream speed (window ≈ velocity × fade duration). Bounded so the
    // fade stays a subtle band at any speed and the per-frame color-run count stays small.
    static func fadeWindow(forVelocity velocity: Double) -> Double {
        let raw = velocity * fadeDurationSeconds
        return min(maximumFadeWindowCharacters, max(minimumFadeWindowCharacters, raw))
    }
}

// Advances a streaming reveal's fractional frontier on the display refresh so the fade is
// vsync-locked (the native equivalent of Synara's requestAnimationFrame reveal) rather than
// stepping off a Task.sleep that drifts in and out of phase with the screen. Only `bucket`
// (the quantized frontier) is observable, and it is written only when the rendered frontier
// actually moves - so the row invalidates once per visible change, not once per display tick.
// The CADisplayLink is only alive while there is backlog to drain, and invalidates itself the
// moment the frontier catches up (or the controller is deallocated).
@MainActor
@Observable
final class StreamingRevealController {
    // Quantized frontier (quarter-character steps); the view's sole observable dependency.
    private(set) var bucket = 0

    // Raw integration state. Not observed: `body` reads these as snapshots when `bucket` moves.
    @ObservationIgnored private(set) var revealedPosition: Double = 0
    @ObservationIgnored private(set) var velocity: Double = 0
    @ObservationIgnored private var targetCount = 0
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    // CADisplayLink needs an ObjC target/selector; a small proxy keeps this class free of
    // NSObject so the @Observable machinery stays straightforward.
    @ObservationIgnored private let proxy = DisplayLinkProxy()

    init() {
        proxy.onFrame = { [weak self] link in
            // The run loop retains the link and the link retains the proxy, so if the
            // controller is gone (view state discarded without onDisappear) nothing else
            // would ever stop the tick - invalidate from inside so the link self-heals.
            guard let self else {
                link.invalidate()
                return
            }
            self.handleFrame(link)
        }
    }

    // Snap fully-revealed (mount, snap, reduced motion, empty text). Stops any running reveal.
    func reset(to count: Int) {
        stop()
        targetCount = count
        velocity = 0
        revealedPosition = Double(count)
        publishBucket()
    }

    // Restart the active region's reveal from the start (a block just closed / rolled over).
    func rewindToStart() {
        revealedPosition = 0
        velocity = 0
        publishBucket()
    }

    // Keep the frontier in range when the active block is re-parsed shorter than before.
    func clampTarget(to count: Int) {
        targetCount = count
        if revealedPosition > Double(count) {
            revealedPosition = Double(count)
            publishBucket()
        }
    }

    // Begin (or continue) revealing toward `count` on the display refresh.
    func start(targetCount count: Int) {
        targetCount = count
        guard revealedPosition < Double(count) else {
            reset(to: count)
            return
        }
        guard displayLink == nil else { return }
        lastTimestamp = nil
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        // An in-place opacity ramp does not need ProMotion's 120Hz; letting the system settle
        // around 60-80 halves the per-frame text rebuild cost with no visible difference.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 80)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private func handleFrame(_ link: CADisplayLink) {
        let count = Double(targetCount)
        if revealedPosition >= count {
            revealedPosition = count
            publishBucket()
            stop()
            return
        }

        let now = link.timestamp
        let delta = lastTimestamp.map {
            min(now - $0, StreamingMarkdownRevealPolicy.maximumFrameSeconds)
        } ?? 0
        lastTimestamp = now

        let backlog = count - revealedPosition
        let targetVelocity = min(
            StreamingMarkdownRevealPolicy.maximumCharactersPerSecond,
            backlog / StreamingMarkdownRevealPolicy.drainWindowSeconds
        )
        velocity += (targetVelocity - velocity) * StreamingMarkdownRevealPolicy.velocityLerp

        var next = min(count, revealedPosition + velocity * delta)
        // Never leave more than a short tail hidden: on big flushes pull the frontier up so the
        // newest visible line stays at the pinned bottom instead of a blank reserved gap.
        let minReveal = max(0, count - Double(StreamingMarkdownRevealPolicy.maxHiddenTailCharacters))
        if next < minReveal { next = minReveal }
        revealedPosition = next

        if next >= count {
            revealedPosition = count
            stop()
        }
        publishBucket()
    }

    // Writes the observable bucket only on a real quarter-character crossing, so sub-bucket
    // ticks (slow reveals) do not invalidate the view at the display rate for nothing.
    private func publishBucket() {
        let next = Int((revealedPosition * StreamingMarkdownRevealPolicy.positionQuantization).rounded())
        if next != bucket {
            bucket = next
        }
    }
}

// ObjC target for CADisplayLink. Forwards each vsync tick to the (main-actor) controller; the
// link is scheduled on the main run loop, so the tick already lands on the main thread.
private final class DisplayLinkProxy: NSObject {
    var onFrame: (@MainActor (CADisplayLink) -> Void)?

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated { onFrame?(link) }
    }
}
