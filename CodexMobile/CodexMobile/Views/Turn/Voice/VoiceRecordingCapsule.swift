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
        // Keeps the recording UI in the same accessory family as the pinned plan card.
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color.clear)
                .adaptiveGlass(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                )
        )
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
        GeometryReader { geometry in
            let renderedLevels = displayedLevels(for: geometry.size.width)
            let barWidth = renderedBarWidth(for: geometry.size.width, slotCount: renderedLevels.count)

            Canvas { context, size in
                let midY = size.height / 2
                for (index, level) in renderedLevels.enumerated() {
                    let h = barHeight(for: level)
                    let x = CGFloat(index) * (barWidth + barSpacing)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(.primary.opacity(0.15 + level * 0.65))
                    )
                }
            }
        }
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
            Image(systemName: "xmark")
                .font(AppFont.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel voice recording")
    }

    // MARK: - Helpers

    private func barHeight(for level: CGFloat) -> CGFloat {
        barMinHeight + (barMaxHeight - barMinHeight) * level
    }

    // Resamples the rolling meter history to the number of bars that fit on screen.
    // When the clip is still short, leading slots stay quiet so the capsule width is still occupied.
    private func displayedLevels(for availableWidth: CGFloat) -> [CGFloat] {
        let slotCount = max(1, Int((max(availableWidth, 0) + barSpacing) / (idealBarWidth + barSpacing)))
        guard !audioLevels.isEmpty else { return Array(repeating: 0, count: slotCount) }

        let tail = Array(audioLevels.suffix(slotCount * 3))
        if tail.count <= slotCount {
            return Array(repeating: 0, count: slotCount - tail.count) + tail
        }

        return (0..<slotCount).map { index in
            let start = Int((Double(index) / Double(slotCount)) * Double(tail.count))
            let end = max(start + 1, Int((Double(index + 1) / Double(slotCount)) * Double(tail.count)))
            let bucket = tail[start..<min(end, tail.count)]
            return bucket.max() ?? 0
        }
    }

    // Uses the full waveform lane width instead of letting the bars stop at their intrinsic content size.
    private func renderedBarWidth(for availableWidth: CGFloat, slotCount: Int) -> CGFloat {
        guard slotCount > 0 else { return idealBarWidth }
        let totalSpacing = CGFloat(slotCount - 1) * barSpacing
        return max(1, (max(availableWidth, 0) - totalSpacing) / CGFloat(slotCount))
    }

    private var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
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

            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FileMentionChip(fileName: "TurnView.swift")
                        SkillMentionChip(skillName: "refactor-code")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Text("Ask anything... @plugins, $skills, /commands")
                    .font(AppFont.body())
                    .foregroundStyle(Color(.placeholderText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                HStack(spacing: 12) {
                    Image(systemName: "plus")
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
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 32, height: 32)
                            .background(
                                isRecording ? Color(.systemRed) : Color(.label),
                                in: Circle()
                            )
                    }

                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color(.label), in: Circle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.top, 10)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0, alignment: .topLeading)
                    .overlay(alignment: .bottomLeading) {
                        if isRecording {
                            VoiceRecordingCapsule(
                                audioLevels: levels,
                                duration: elapsed,
                                onCancel: { isRecording = false; levels = []; elapsed = 0 }
                            )
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .offset(y: -8)
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

#Preview("Voice Capsule — In Composer") {
    VoiceRecordingCapsulePreview()
}
