// FILE: ComposerRuntimeSliderOverlay.swift
// Purpose: Runtime picker popped over the chat from the composer's model pill.
//          The app blurs behind it (material backdrop) while the keyboard stays
//          up, and a screen-centered block shows: the fast-mode bolt toggle
//          (Central zap outline = off, solid = on), the model + effort label that
//          opens the model menu, and a fill slider that sweeps the selected
//          model's reasoning efforts from the first to the last. Tapping the
//          blurred backdrop dismisses.
// Layer: View Component
// Exports: ComposerRuntimeSliderOverlay
// Depends on: SwiftUI, UIKit, RemodexIcon, AppFont, UIKitMenuButton,
//             AllModelsSheet, TurnComposerRuntimeState,
//             TurnComposerRuntimeActions, TurnComposerRuntimeUIKitMenuBuilder,
//             UserBubbleColor, HapticFeedback
//
// Design notes
// ------------
// * Installed with `fullScreenOverlay`, so this view owns its own backdrop
//   instead of a `presentationBackground` material, and the composer (plus its
//   keyboard) stays alive and focused underneath.
// * That modifier adds and removes this view without a transition, so the
//   animation lives here: everything fades/rises in on appear, and dismissal
//   animates out first and only then reports back through `onDismiss`.
// * The all-models sheet is presented from inside this overlay: the composer
//   underneath would otherwise have to interleave the sheet with tearing this
//   view down.

import SwiftUI
import UIKit

struct ComposerRuntimeSliderOverlay: View {
    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    let modelDisplayTitle: String
    let effortDisplayTitle: String?
    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let isLoadingModels: Bool
    let onDismiss: () -> Void

    // Drives the whole in/out animation: the backdrop fades while the content
    // pops in place — a centered scale-up, not a slide from anywhere.
    @State private var isVisible = false
    @State private var showsAllModelsSheet = false

    private let appearAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)
    private let dismissAnimation = Animation.easeIn(duration: 0.18)

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(isVisible ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            // Centered by the ZStack: the picker always lands mid-screen, no
            // matter where it was opened from or whether the keyboard is up.
            VStack(spacing: 18) {
                modelRow

                if !ascendingEffortOptions.isEmpty {
                    ComposerEffortSlider(
                        options: ascendingEffortOptions,
                        selectedEffort: runtimeState.selectedReasoningEffort
                            ?? runtimeState.effectiveReasoningEffort,
                        isDisabled: runtimeState.reasoningMenuDisabled,
                        onSelect: runtimeActions.selectReasoning
                    )
                } else {
                    // No resolved model yet (bootstrap model/list failed or is
                    // still in flight): say so instead of showing a bare row.
                    // Opening the picker retries the fetch, and the slider pops
                    // in live once options land.
                    HStack(spacing: 8) {
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isLoadingModels ? "Loading model options…" : "Model options unavailable. Check the Mac connection.")
                            .font(AppFont.subheadline())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .opacity(isVisible ? 1 : 0)
            // Scaled on the controls block alone so the picker expands from
            // its own center and reads as popping into place.
            .scaleEffect(isVisible ? 1 : 0.85)
        }
        .onAppear {
            withAnimation(appearAnimation) { isVisible = true }
        }
        .sheet(isPresented: $showsAllModelsSheet) {
            allModelsSheet
        }
    }

    // Fades out in place before the host removes this view, so dismissal is not
    // an instant cut.
    private func dismiss() {
        guard isVisible else { return }
        withAnimation(dismissAnimation) {
            isVisible = false
        } completion: {
            onDismiss()
        }
    }

    // Bolt toggle + "Model Effort >" menu anchor, centered like the pill label.
    private var modelRow: some View {
        HStack(spacing: 14) {
            if runtimeState.supportsFastMode {
                fastModeToggle
            }

            UIKitMenuButton {
                HStack(spacing: 6) {
                    Text(modelDisplayTitle)
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let effortDisplayTitle {
                        Text(effortDisplayTitle)
                            .font(AppFont.title3(weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    RemodexIcon.image(systemName: "chevron.right", size: 14, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            } menu: {
                modelMenu()
            }
            .accessibilityLabel(modelMenuAccessibilityLabel)
        }
        .frame(maxWidth: .infinity)
    }

    // One-tap fast-mode switch: outline zap = normal speed, solid zap = fast.
    private var fastModeToggle: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            runtimeActions.selectServiceTier(isFastModeOn ? nil : .fast)
        } label: {
            RemodexIcon.image(
                systemName: isFastModeOn ? "bolt.fill" : "bolt",
                size: 21
            )
            .foregroundStyle(isFastModeOn ? Color.primary : Color.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .accessibilityLabel("Fast mode")
        .accessibilityValue(isFastModeOn ? "On" : "Off")
        .accessibilityAddTraits(isFastModeOn ? .isSelected : [])
    }

    private var isFastModeOn: Bool {
        runtimeState.isSelectedServiceTier(.fast)
    }

    private func modelMenu() -> UIMenu {
        TurnComposerRuntimeUIKitMenuBuilder.makeModelMenu(
            .init(
                runtimeActions: runtimeActions,
                orderedModelOptions: orderedModelOptions,
                selectedModelID: selectedModelID,
                isLoadingModels: isLoadingModels,
                onRequestAllModelsSheet: {
                    // Let the UIKit menu finish dismissing before this hosting
                    // controller starts presenting the sheet.
                    DispatchQueue.main.async { showsAllModelsSheet = true }
                }
            )
        )
    }

    private var allModelsSheet: some View {
        AllModelsSheet(
            models: orderedModelOptions,
            selectedModelID: selectedModelID,
            isLoadingModels: isLoadingModels,
            onSelect: { modelID in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                runtimeActions.selectModel(modelID)
                showsAllModelsSheet = false
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // `reasoningDisplayOptions` arrives sorted for the (bottom-anchored,
    // visually reversed) UIKit menus, i.e. highest effort first. The slider
    // reads left -> right, so re-sort ascending: first effort on the left,
    // strongest on the right.
    private var ascendingEffortOptions: [TurnComposerReasoningDisplayOption] {
        runtimeState.reasoningDisplayOptions.sorted { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.title < rhs.title
            }
            return lhs.rank < rhs.rank
        }
    }

    private var modelMenuAccessibilityLabel: String {
        if let effortDisplayTitle {
            return "Model: \(modelDisplayTitle), \(effortDisplayTitle)"
        }
        return "Model: \(modelDisplayTitle)"
    }
}

// MARK: - Effort slider

// Fill slider: a soft capsule track with one dot per reasoning effort and an
// accent fill that grows from the leading edge to the thumb, so the selected
// effort reads as "how far along" rather than just a knob position. Selection
// commits live while the thumb crosses dots, so the label above tracks the drag
// in real time.
struct ComposerEffortSlider: View {
    let options: [TurnComposerReasoningDisplayOption]
    let selectedEffort: String?
    let isDisabled: Bool
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey)
    private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    // Live finger x while dragging; nil when the thumb rests on the selection.
    @State private var dragLocationX: CGFloat?

    private let trackHeight: CGFloat = 60
    // Air between the track edge and the fill, matching a switch's inner gap.
    private let fillInset: CGFloat = 6
    // Air between the fill edge and the thumb.
    private let thumbInset: CGFloat = 4
    private let dotDiameter: CGFloat = 8

    private var fillHeight: CGFloat { trackHeight - fillInset * 2 }
    private var thumbDiameter: CGFloat { fillHeight - thumbInset * 2 }

    var body: some View {
        GeometryReader { proxy in
            slider(width: proxy.size.width)
        }
        .frame(height: trackHeight)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityElement()
        .accessibilityLabel("Intelligence")
        .accessibilityValue(options.isEmpty ? "" : options[selectedIndex].title)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                accessibilitySelect(selectedIndex + 1)
            case .decrement:
                accessibilitySelect(selectedIndex - 1)
            @unknown default:
                break
            }
        }
    }

    // Below one track height there is no room for the thumb at all; skip drawing
    // rather than overflow during transient zero-width layout passes.
    @ViewBuilder
    private func slider(width: CGFloat) -> some View {
        if width >= trackHeight {
            track(width: width)
        }
    }

    private func track(width: CGFloat) -> some View {
        let centers = dotCenters(width: width)
        let thumbX = thumbCenterX(centers: centers)
        return ZStack {
            fill(trailingX: thumbX + fillHeight / 2)

            // Dots stay on top of the fill (dimmed once passed) so the scale
            // remains readable at every position; the one under the thumb is
            // covered by it.
            ForEach(Array(options.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(centers[index] <= thumbX ? passedDotColor : pendingDotColor)
                    .frame(width: dotDiameter, height: dotDiameter)
                    .position(x: centers[index], y: trackHeight / 2)
            }

            thumb
                .position(x: thumbX, y: trackHeight / 2)
        }
        .frame(width: width, height: trackHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        )
        .contentShape(Capsule(style: .continuous))
        .animation(
            dragLocationX == nil ? .spring(response: 0.3, dampingFraction: 0.8) : nil,
            value: thumbX
        )
        .gesture(isDisabled ? nil : dragGesture(centers: centers))
    }

    // Accent capsule from the leading inset to the thumb's trailing edge: at the
    // first effort it is just a ring around the thumb, at the last it fills the
    // whole track.
    private func fill(trailingX: CGFloat) -> some View {
        let width = max(trailingX - fillInset, fillHeight)
        return Capsule(style: .continuous)
            .fill(ctaPalette.bubbleBackground(for: colorScheme))
            .frame(width: width, height: fillHeight)
            .position(x: fillInset + width / 2, y: trackHeight / 2)
    }

    private var thumb: some View {
        Circle()
            .fill(ctaPalette.bubbleForeground(for: colorScheme))
            .frame(width: thumbDiameter, height: thumbDiameter)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }

    // MARK: - Geometry

    private var selectedIndex: Int {
        options.firstIndex(where: { $0.effort == selectedEffort }) ?? 0
    }

    private func dotCenters(width: CGFloat) -> [CGFloat] {
        // Keep the thumb (and therefore the fill) inside the track at both ends.
        let inset = fillInset + fillHeight / 2
        guard options.count > 1 else { return [inset] }
        let usable = max(width - inset * 2, 0)
        let step = usable / CGFloat(options.count - 1)
        return options.indices.map { inset + CGFloat($0) * step }
    }

    private func thumbCenterX(centers: [CGFloat]) -> CGFloat {
        guard let first = centers.first, let last = centers.last else { return 0 }
        if let dragLocationX {
            return min(max(dragLocationX, first), last)
        }
        return centers[min(selectedIndex, centers.count - 1)]
    }

    private func nearestIndex(to x: CGFloat, centers: [CGFloat]) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(center - x)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Colors

    private var passedDotColor: Color {
        ctaPalette.bubbleForeground(for: colorScheme).opacity(0.35)
    }

    private var pendingDotColor: Color {
        Color(.systemGray3)
    }

    // MARK: - Interaction

    private func dragGesture(centers: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragLocationX = value.location.x
                commitIfNeeded(nearestIndex(to: value.location.x, centers: centers))
            }
            .onEnded { value in
                let index = nearestIndex(to: value.location.x, centers: centers)
                dragLocationX = nil
                commitIfNeeded(index)
            }
    }

    private func commitIfNeeded(_ index: Int) {
        guard options.indices.contains(index) else { return }
        let effort = options[index].effort
        guard effort != selectedEffort else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        onSelect(effort)
    }

    private func accessibilitySelect(_ index: Int) {
        guard !isDisabled else { return }
        commitIfNeeded(min(max(index, 0), options.count - 1))
    }

    private var ctaPalette: UserBubbleColor {
        (UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default).ctaPalette
    }
}

#if DEBUG
#Preview("Effort slider") {
    VStack(spacing: 24) {
        ComposerEffortSlider(
            options: [
                .init(effort: "minimal", title: "Minimal"),
                .init(effort: "low", title: "Low"),
                .init(effort: "medium", title: "Medium"),
                .init(effort: "high", title: "High"),
                .init(effort: "xhigh", title: "Extra High"),
            ],
            selectedEffort: "minimal",
            isDisabled: false,
            onSelect: { _ in }
        )

        ComposerEffortSlider(
            options: [
                .init(effort: "minimal", title: "Minimal"),
                .init(effort: "low", title: "Low"),
                .init(effort: "medium", title: "Medium"),
                .init(effort: "high", title: "High"),
                .init(effort: "xhigh", title: "Extra High"),
            ],
            selectedEffort: "high",
            isDisabled: false,
            onSelect: { _ in }
        )
    }
    .padding(28)
}
#endif
