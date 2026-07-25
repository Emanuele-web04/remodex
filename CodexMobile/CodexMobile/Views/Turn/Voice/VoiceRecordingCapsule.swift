// FILE: VoiceRecordingCapsule.swift
// Purpose: Live waveform panel shown above the composer during voice recording.
// Layer: View Component
// Exports: VoiceRecordingCapsule
// Depends on: SwiftUI

import Combine
import SwiftUI

struct VoiceRecordingCapsule: View {
    let audioLevels: [CGFloat]
    let duration: TimeInterval
    let onCancel: () -> Void

    private let cardCornerRadius: CGFloat = 20
    private let idealBarWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1.5
    private let barMinHeight: CGFloat = 2
    private let barMaxHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            pulsingDot

            waveformView
                .frame(height: barMaxHeight)
                .clipped()

            durationLabel

            cancelButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // Glass lives on a background layer so waveform/text stay above the
        // material while the per-frame TimelineView canvas and pulsing dot do
        // not invalidate the glass node itself ("glassEffect() tried to update
        // multiple times per frame").
        .background {
            Color.clear
                .adaptiveGlass(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Subviews

    private var pulsingDot: some View {
        Circle()
            .fill(Color(.label))
            .frame(width: 6, height: 6)
            .modifier(PulsingOpacity())
    }

    private var waveformView: some View {
        ScrollingWaveformLane(
            levels: audioLevels,
            barWidth: idealBarWidth,
            barSpacing: barSpacing,
            minHeight: barMinHeight,
            maxHeight: barMaxHeight
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var durationLabel: some View {
        Text(formattedDuration)
            .font(AppFont.footnote(weight: .medium))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            RemodexCircleBadge(
                systemName: "xmark",
                foreground: Color.secondary,
                background: Color.primary.opacity(0.08),
                diameter: 22,
                iconSize: 10
            )
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel voice recording")
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Scrolling waveform lane

// Treadmill-style waveform: every meter sample becomes one bar whose height is
// frozen at append time. The whole strip glides left continuously so new bars
// slide in from the right edge, instead of re-bucketing history on every sample
// (which made existing bars jump around).
//
// Levels are produced on a fixed audio-time grid but reach the main thread in
// irregular lumps (buffer boundaries, runloop coalescing can deliver two at
// once). Scrolling therefore never keys off arrival timestamps: a free-running
// clock advances at the nominal rate and is softly servo-corrected toward the
// true sample count, so delivery jitter is absorbed instead of shown as a snap.
private struct ScrollingWaveformLane: View {
    let levels: [CGFloat]
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    // Levels are emitted at a fixed cadence (one per meter window), so the
    // strip scrolls at a constant, known speed.
    private let sampleInterval: TimeInterval = GPTVoiceTranscriptionManager.meterWindowSeconds

    // Reference type on purpose: it mutates every frame inside the Canvas
    // renderer, where @State writes are not allowed (and no invalidation is
    // needed — TimelineView already redraws continuously).
    @State private var clock = WaveformScrollClock()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    draw(in: context, size: size, now: timeline.date)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        // Observes the array (not just its count): once the rolling buffer is
        // full, appends keep the count constant while contents shift.
        .onChange(of: levels) { oldLevels, newLevels in
            clock.register(oldLevels: oldLevels, newLevels: newLevels)
        }
        .onAppear {
            clock.attach(levelCount: levels.count)
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize, now: Date) {
        guard size.width > 0 else { return }
        let head = clock.currentHead(now: now, interval: sampleInterval)
        let slotWidth = barWidth + barSpacing
        let midY = size.height / 2

        // Absolute sample index of levels[0]; older samples were trimmed.
        let baseIndex = clock.totalAppended - levels.count

        // Newest sample first, marching left until off screen. Indices outside
        // the available history render as quiet baseline bars.
        var index = clock.totalAppended - 1
        while true {
            let distance = head - Double(index)
            let minX = size.width - CGFloat(distance) * slotWidth
            if minX + barWidth <= 0 { break }
            defer { index -= 1 }
            guard minX < size.width else { continue }

            let arrayIndex = index - baseIndex
            let level = (0..<levels.count).contains(arrayIndex) ? levels[arrayIndex] : 0
            let height = minHeight + (maxHeight - minHeight) * level
            let rect = CGRect(x: minX, y: midY - height / 2, width: barWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .color(.primary.opacity(0.15 + level * 0.65))
            )
        }
    }
}

// Free-running scroll clock with a soft servo toward the real sample count.
// `displayedHead` is the fractional absolute sample index currently anchored
// at the lane's right edge; it advances one slot per meter window.
private final class WaveformScrollClock {
    private(set) var totalAppended = 0
    private var displayedHead: Double = 0
    private var lastFrameTime: Date?

    // How much of the remaining drift is corrected per second. Low enough to
    // spread a lumpy two-sample delivery over ~a third of a second.
    private static let correctionRate: Double = 3
    // Steady-state cushion (in slots) behind the newest sample, so ordinary
    // arrival jitter never forces the head to stall against the data edge.
    private static let cushion: Double = 0.5

    func attach(levelCount: Int) {
        guard totalAppended == 0 else { return }
        totalAppended = levelCount
        displayedHead = Double(levelCount) - Self.cushion
        lastFrameTime = nil
    }

    func register(oldLevels: [CGFloat], newLevels: [CGFloat]) {
        if newLevels.isEmpty {
            totalAppended = 0
            displayedHead = 0
            lastFrameTime = nil
            return
        }
        totalAppended += Self.appendedCount(oldLevels: oldLevels, newLevels: newLevels)
    }

    func currentHead(now: Date, interval: TimeInterval) -> Double {
        guard totalAppended > 0 else {
            lastFrameTime = now
            return 0
        }

        let dt = lastFrameTime.map { max(0, min(now.timeIntervalSince($0), 0.1)) } ?? 0
        lastFrameTime = now

        // Nominal advance keeps pace with the audio clock; the servo trims the
        // residual drift toward the cushion point without visible jumps.
        displayedHead += dt / interval
        let target = Double(totalAppended) - Self.cushion
        displayedHead += (target - displayedHead) * min(1, dt * Self.correctionRate)

        // Hard bounds: never scroll past real data, never fall far behind.
        displayedHead = min(displayedHead, Double(totalAppended))
        displayedHead = max(displayedHead, Double(totalAppended) - 3)
        return displayedHead
    }

    // The rolling buffer keeps a constant count once full, so growth alone
    // can't measure appends; align the shifted contents to count them exactly.
    private static func appendedCount(oldLevels: [CGFloat], newLevels: [CGFloat]) -> Int {
        if newLevels.count > oldLevels.count {
            return newLevels.count - oldLevels.count
        }
        guard newLevels.count == oldLevels.count, !newLevels.isEmpty else { return 0 }
        for shift in 1...min(8, newLevels.count) where
            oldLevels.dropFirst(shift).elementsEqual(newLevels.dropLast(shift)) {
            return shift
        }
        return 1
    }
}

// MARK: - Pulsing animation modifier

private struct PulsingOpacity: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Preview

private struct VoiceRecordingCapsulePreview: View {
    @State private var levels: [CGFloat] = []
    @State private var elapsed: TimeInterval = 0
    @State private var isRecording = false
    private let timer = Timer.publish(
        every: GPTVoiceTranscriptionManager.meterWindowSeconds,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 8) {
                if isRecording {
                    VoiceRecordingCapsule(
                        audioLevels: levels,
                        duration: elapsed,
                        onCancel: { isRecording = false; levels = []; elapsed = 0 }
                    )
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                VStack(spacing: 0) {
                    TurnMentionChipRow.composer(
                        chips: [
                            .file("TurnView.swift"),
                            .skill("refactor-code"),
                        ],
                        topPadding: 14,
                        onRemove: { _ in }
                    )

                    Text("Ask anything... @plugins, $skills, /commands")
                        .font(AppFont.body())
                        .foregroundStyle(Color(.placeholderText))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    HStack(spacing: 12) {
                        RemodexIcon.image(systemName: "plus")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)

                        Text("GPT-5.3-Codex")
                            .font(AppFont.subheadline())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            if isRecording {
                                isRecording = false; levels = []; elapsed = 0
                            } else {
                                isRecording = true
                            }
                        } label: {
                            RemodexCircleBadge(
                                systemName: isRecording ? "stop.fill" : "mic.fill",
                                foreground: Color(.systemBackground),
                                background: isRecording ? Color(.systemRed) : Color(.label)
                            )
                        }

                        RemodexCircleBadge(
                            systemName: "arrow.up",
                            foreground: Color(.systemBackground),
                            background: Color(.label)
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .padding(.top, 10)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        .onReceive(timer) { _ in
            guard isRecording else { return }
            elapsed += GPTVoiceTranscriptionManager.meterWindowSeconds
            let base: CGFloat = 0.15
            let voiceBurst = CGFloat.random(in: 0...1) > 0.7 ? CGFloat.random(in: 0.4...0.95) : 0
            let level = min(1, base + CGFloat.random(in: 0...0.3) + voiceBurst)
            levels.append(level)
            if levels.count > 200 { levels.removeFirst(levels.count - 200) }
        }
    }
}

#Preview("Voice Capsule — Above Composer") {
    VoiceRecordingCapsulePreview()
}
