// FILE: PetCompanionOverlay.swift
// Purpose: Draws and animates a draggable Codex companion pet above the app shell.
// Layer: View
// Exports: PetCompanionOverlay, PetCompanionStatusSyncView
// Depends on: SwiftUI, UIKit, PetCompanionStore, CodexService

import SwiftUI
import UIKit

struct PetCompanionOverlay: View {
    @Environment(CodexService.self) private var codex
    @Environment(PetCompanionStore.self) private var petStore
    @Environment(PetCompanionStatusStore.self) private var petStatusStore

    let isInteractionEnabled: Bool
    let bottomExclusionHeight: CGFloat

    @State private var dragStartPoint: CGPoint?
    @State private var dragPoint: CGPoint?
    @State private var isDragging = false
    @State private var dragPhase: PetCompanionPhase = .runningRight
    @State private var transientPhase: PetCompanionPhase?
    @State private var transientPhaseTask: Task<Void, Never>?

    private let spriteSize = CGSize(width: 92, height: 100)
    private let companionSize = CGSize(width: 176, height: 150)
    private let sidebarGestureExclusionWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            if petStore.isEnabled, let pet = petStore.renderedPet {
                let containerSize = proxy.size
                let resolvedPoint = resolvedPetPoint(in: containerSize)
                let status = currentStatus
                let phase = status.phase

                petBody(pet: pet, status: status)
                    .frame(width: companionSize.width, height: companionSize.height)
                    .position(resolvedPoint)
                    .gesture(dragGesture(containerSize: containerSize, currentPoint: resolvedPoint))
                    .simultaneousGesture(tapGesture)
                    .allowsHitTesting(isInteractionEnabled)
                    .animation(.spring(response: 0.28, dampingFraction: 0.78), value: resolvedPoint)
                    .animation(.easeInOut(duration: 0.18), value: phase)
            }
        }
        .task(id: codex.isConnected) {
            guard codex.isConnected, petStore.isEnabled else {
                return
            }
            await petStore.loadPetsIfNeeded(codex: codex)
            await petStore.loadSelectedPet(codex: codex)
        }
        .task(id: petStore.selectedPetID) {
            guard codex.isConnected, petStore.isEnabled else {
                return
            }
            await petStore.loadSelectedPet(codex: codex)
        }
        .onChange(of: petStore.isEnabled) { _, isEnabled in
            guard isEnabled else {
                transientPhaseTask?.cancel()
                transientPhaseTask = nil
                return
            }
            Task {
                await petStore.loadPetsIfNeeded(codex: codex)
                await petStore.loadSelectedPet(codex: codex)
            }
        }
    }

    private var currentStatus: PetCompanionStatusSnapshot {
        if isDragging {
            return PetCompanionStatusSnapshot(phase: dragPhase)
        }
        if let transientPhase {
            return PetCompanionStatusSnapshot(phase: transientPhase)
        }
        return petStatusStore.snapshot
    }

    @ViewBuilder
    private func petBody(pet: PetCompanion, status: PetCompanionStatusSnapshot) -> some View {
        VStack(spacing: 4) {
            PetSpriteView(pet: pet, phase: status.phase)
                .frame(width: spriteSize.width, height: spriteSize.height)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            if status.showsLabel {
                VStack(spacing: 1) {
                    Text(status.title ?? "")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.primary)
                    if let detail = status.detail, !detail.isEmpty {
                        Text(detail)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 168)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                )
            }
        }
        .frame(width: companionSize.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pet.displayName) companion pet")
    }

    private func resolvedPetPoint(in containerSize: CGSize) -> CGPoint {
        if let dragPoint {
            return PetCompanionLayout.clampedPoint(
                dragPoint,
                in: containerSize,
                petSize: companionSize,
                leftExclusionWidth: sidebarGestureExclusionWidth,
                bottomExclusionHeight: bottomExclusionHeight
            )
        }

        return PetCompanionLayout.point(
            for: petStore.position,
            in: containerSize,
            petSize: companionSize,
            leftExclusionWidth: sidebarGestureExclusionWidth,
            bottomExclusionHeight: bottomExclusionHeight
        )
    }

    private func dragGesture(containerSize: CGSize, currentPoint: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let startPoint = dragStartPoint ?? currentPoint
                dragStartPoint = startPoint
                isDragging = true
                if abs(value.translation.width) >= 4 {
                    dragPhase = value.translation.width >= 0 ? .runningRight : .runningLeft
                }
                dragPoint = PetCompanionLayout.clampedPoint(
                    CGPoint(
                        x: startPoint.x + value.translation.width,
                        y: startPoint.y + value.translation.height
                    ),
                    in: containerSize,
                    petSize: companionSize,
                    leftExclusionWidth: sidebarGestureExclusionWidth,
                    bottomExclusionHeight: bottomExclusionHeight
                )
            }
            .onEnded { _ in
                if let dragPoint {
                    let nextPosition = PetCompanionLayout.normalizedPosition(
                        for: dragPoint,
                        in: containerSize,
                        petSize: companionSize,
                        leftExclusionWidth: sidebarGestureExclusionWidth,
                        bottomExclusionHeight: bottomExclusionHeight
                    )
                    petStore.updatePosition(nextPosition)
                }
                dragStartPoint = nil
                dragPoint = nil
                isDragging = false
            }
    }

    private var tapGesture: some Gesture {
        TapGesture()
            .onEnded {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                playTransientPhase(.jumping, durationNanoseconds: 850_000_000)
            }
    }

    private func playTransientPhase(_ phase: PetCompanionPhase, durationNanoseconds: UInt64) {
        transientPhaseTask?.cancel()
        transientPhase = phase
        transientPhaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            if !Task.isCancelled {
                transientPhase = nil
            }
        }
    }

}

struct PetCompanionStatusSyncView: View {
    @Environment(CodexService.self) private var codex
    @Environment(PetCompanionStore.self) private var petStore
    @Environment(PetCompanionStatusStore.self) private var petStatusStore

    var body: some View {
        Group {
            if petStore.isEnabled {
                let signature = codex.petCompanionStatusSignature()

                syncSurface
                    .task(id: signature) {
                        await refreshStatusLoop(for: signature)
                    }
            } else {
                syncSurface
                    .task {
                        petStatusStore.reset()
                    }
            }
        }
        .onChange(of: petStore.isEnabled) { _, isEnabled in
            if isEnabled {
                petStatusStore.update(codex.petCompanionStatusSnapshot())
            } else {
                petStatusStore.reset()
            }
        }
    }

    private var syncSurface: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    private func refreshStatusLoop(for signature: PetCompanionStatusSignature) async {
        guard petStore.isEnabled, signature.isConnected else {
            petStatusStore.reset()
            return
        }

        petStatusStore.update(codex.petCompanionStatusSnapshot())
        guard signature.hasRunningWork else {
            return
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, petStore.isEnabled else {
                return
            }
            petStatusStore.update(codex.petCompanionStatusSnapshot())
        }
    }
}

private struct PetSpriteView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pet: PetCompanion
    let phase: PetCompanionPhase

    @State private var atlas: PetSpriteAtlas?
    @State private var displayedPhase: PetCompanionPhase = .idle
    @State private var frameIndex = 0

    var body: some View {
        Group {
            if let frame = currentFrame {
                Image(uiImage: frame)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: pet.spritesheetDataURL ?? pet.id) {
            let nextAtlas = PetSpriteDecoder.decodeAtlas(from: pet.spritesheetDataURL)
            nextAtlas?.prewarmSequence(for: phase)
            atlas = nextAtlas
        }
        .task(id: "\(phase.rawValue)-\(reduceMotion)") {
            atlas?.prewarmSequence(for: phase)
            await runAnimationLoop()
        }
        .onChange(of: phase) { _, _ in
            displayedPhase = phase
            frameIndex = 0
        }
    }

    private var currentFrame: UIImage? {
        atlas?.cachedFrame(for: displayedPhase, index: frameIndex)
            ?? atlas?.cachedFrame(for: .idle, index: 0)
    }

    private func runAnimationLoop() async {
        displayedPhase = phase
        frameIndex = 0
        if reduceMotion {
            return
        }

        if phase != .idle {
            for _ in 0..<3 {
                await playPhaseOnce(phase, durations: phase.frameDurationsMilliseconds)
                guard !Task.isCancelled else {
                    return
                }
            }
            displayedPhase = .idle
            frameIndex = 0
        }

        while !Task.isCancelled {
            await playPhaseOnce(.idle, durations: PetCompanionPhase.idle.slowFrameDurationsMilliseconds)
        }
    }

    private func playPhaseOnce(_ phase: PetCompanionPhase, durations: [UInt64]) async {
        displayedPhase = phase
        for index in 0..<phase.frameCount {
            frameIndex = index
            let delay = durations[index % durations.count]
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard !Task.isCancelled else {
                return
            }
        }
    }
}

private enum PetSpriteDecoder {
    static func decodeAtlas(from dataURL: String?) -> PetSpriteAtlas? {
        guard let image = image(from: dataURL),
              let cgImage = image.cgImage else {
            return nil
        }

        return PetSpriteAtlas(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func image(from dataURL: String?) -> UIImage? {
        guard let dataURL else {
            return nil
        }
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let base64 = dataURL[dataURL.index(after: commaIndex)...]
        guard let data = Data(base64Encoded: String(base64)) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private final class PetSpriteAtlas {
    private let cgImage: CGImage
    private let scale: CGFloat
    private let orientation: UIImage.Orientation
    private var frameCache: [String: UIImage] = [:]

    init(cgImage: CGImage, scale: CGFloat, orientation: UIImage.Orientation) {
        self.cgImage = cgImage
        self.scale = scale
        self.orientation = orientation
    }

    // Prepares only the frames the current animation can show; body rendering stays a pure lookup.
    func prewarmSequence(for phase: PetCompanionPhase) {
        prewarm(phase)
        if phase != .idle {
            prewarm(.idle)
        }
    }

    func cachedFrame(for phase: PetCompanionPhase, index: Int) -> UIImage? {
        let normalizedIndex = index % max(phase.frameCount, 1)
        return frameCache[cacheKey(for: phase, index: normalizedIndex)]
    }

    private func prewarm(_ phase: PetCompanionPhase) {
        for index in 0..<phase.frameCount {
            let key = cacheKey(for: phase, index: index)
            guard frameCache[key] == nil,
                  let frame = makeFrame(for: phase, index: index) else {
                continue
            }
            frameCache[key] = frame
        }
    }

    private func makeFrame(for phase: PetCompanionPhase, index: Int) -> UIImage? {
        let normalizedIndex = index % max(phase.frameCount, 1)
        let cropRect = CGRect(
            x: CGFloat(normalizedIndex) * PetCompanionPhase.cellSize.width,
            y: CGFloat(phase.rowIndex) * PetCompanionPhase.cellSize.height,
            width: PetCompanionPhase.cellSize.width,
            height: PetCompanionPhase.cellSize.height
        )
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: scale, orientation: orientation)
    }

    private func cacheKey(for phase: PetCompanionPhase, index: Int) -> String {
        "\(phase.rawValue):\(index)"
    }
}
