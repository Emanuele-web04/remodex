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
        // Apply glass to the capsule surface itself so waveform/text stay above
        // the material instead of being composited behind a separate glass layer.
        .adaptiveGlass(
            .regular,
            in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        )
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
private struct ScrollingWaveformLane: View {
    let levels: [CGFloat]
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var lastAppendDate: Date = .distantPast
    // Smoothed seconds between meter samples; drives the scroll speed so the
    // strip advances exactly one slot per sample regardless of device buffer size.
    @State private var sampleInterval: TimeInterval = 0.09

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
            registerAppend(oldLevels: oldLevels, newLevels: newLevels)
        }
    }

    private func registerAppend(oldLevels: [CGFloat], newLevels: [CGFloat]) {
        guard !newLevels.isEmpty, newLevels.count >= oldLevels.count else {
            lastAppendDate = .distantPast
            return
        }
        let now = Date()
        if lastAppendDate != .distantPast {
            let measured = now.timeIntervalSince(lastAppendDate)
            if (0.02...0.5).contains(measured) {
                sampleInterval = sampleInterval * 0.8 + measured * 0.2
            }
        }
        lastAppendDate = now
    }

    private func draw(in context: GraphicsContext, size: CGSize, now: Date) {
        let slotWidth = barWidth + barSpacing
        let midY = size.height / 2

        // 0 → newest bar fully offscreen right, 1 → settled one slot in.
        let elapsed = now.timeIntervalSince(lastAppendDate)
        let phase = lastAppendDate == .distantPast
            ? 1.0
            : min(1.0, max(0.0, elapsed / sampleInterval))

        let slotCount = Int(ceil(size.width / slotWidth)) + 2
        for slot in 0..<slotCount {
            // slot 0 is the newest sample; older samples march left.
            let level = slot < levels.count ? levels[levels.count - 1 - slot] : 0
            let minX = size.width - (CGFloat(slot) + CGFloat(phase)) * slotWidth
            guard minX + barWidth > 0 else { break }

            let height = minHeight + (maxHeight - minHeight) * level
            let rect = CGRect(x: minX, y: midY - height / 2, width: barWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .color(.primary.opacity(0.15 + level * 0.65))
            )
        }
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
    private let timer = Timer.publish(every: 0.09, on: .main, in: .common).autoconnect()

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
                            .font(.subheadline)
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
            elapsed += 0.09
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
