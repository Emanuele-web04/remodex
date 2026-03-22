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

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1.5
    private let barMinHeight: CGFloat = 2
    private let barMaxHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            pulsingDot

            waveformView
                .frame(height: barMaxHeight)
                .clipped()

            durationLabel

            cancelButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(4)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(Array(audioLevels.enumerated()), id: \.offset) { index, level in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.45))
                            .frame(
                                width: barWidth,
                                height: barHeight(for: level)
                            )
                            .id(index)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .scrollDisabled(true)
            .onChange(of: audioLevels.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation(.linear(duration: 0.06)) {
                    proxy.scrollTo(newCount - 1, anchor: .trailing)
                }
            }
        }
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

                Text("Ask anything... @files, $skills, /commands")
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
