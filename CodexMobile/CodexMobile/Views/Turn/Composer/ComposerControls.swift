// FILE: ComposerControls.swift
// Purpose: Shared composer chrome (the "+" attachment menu, the mic button,
//          and the Stop control) used by both the expanded composer bottom bar
//          and the collapsed resting row inside TurnComposerView.
// Layer: View Component
// Exports: ComposerAttachmentMenu, ComposerVoiceButton, ComposerStopControl
// Depends on: SwiftUI, RemodexIcon, CircularIconBadge, TurnComposerRuntimeState

import SwiftUI
import UIKit

// MARK: - Attachment ("+") menu

// The composer "+" affordance: attachments plus the plan/fast-mode toggles.
// Shared so the collapsed capsule opens the exact same menu as the full bar.
struct ComposerAttachmentMenu: View {
    let isPlanModeArmed: Bool
    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    let remainingAttachmentSlots: Int
    let isInteractionLocked: Bool
    let onSetPlanModeArmed: (Bool) -> Void
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
    var iconSide: CGFloat = 24
    // When set, the "+" gets a larger square hit area (matching the send
    // button) so it's as easy to tap as the primary CTA in the collapsed row.
    var tapTargetSide: CGFloat?

    private let metaLabelColor = Color(.secondaryLabel)

    var body: some View {
        UIKitMenuButton {
            RemodexIcon.image(systemName: "plus")
                .font(AppFont.title3(weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: tapTargetSide ?? iconSide, height: tapTargetSide ?? iconSide)
                .contentShape(Circle())
        } menu: {
            attachmentMenu()
        }
        .tint(metaLabelColor)
        .disabled(isInteractionLocked)
        .accessibilityLabel("Composer options")
    }

    private func attachmentMenu() -> UIMenu {
        var modeActions: [UIMenuElement] = [
            UIAction(
                title: "Plan mode",
                image: RemodexIcon.menuUIImage(systemName: "remodex.plan-mode"),
                state: isPlanModeArmed ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onSetPlanModeArmed(!isPlanModeArmed)
            },
        ]

        if runtimeState.supportsFastMode {
            modeActions.append(
                UIAction(
                    title: "Fast Mode",
                    image: RemodexIcon.menuUIImage(systemName: fastModePlusMenuIconName),
                    state: runtimeState.isSelectedServiceTier(.fast) ? .on : .off
                ) { _ in
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    toggleFastMode()
                }
            )
        }

        let attachmentActions: [UIMenuElement] = [
            UIAction(
                title: "Photo library",
                image: RemodexIcon.menuUIImage(systemName: "photo"),
                attributes: remainingAttachmentSlots == 0 ? .disabled : []
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback()
                onTapAddImage()
            },
            UIAction(
                title: "Take a photo",
                image: RemodexIcon.menuUIImage(systemName: "camera.fill"),
                attributes: remainingAttachmentSlots == 0 ? .disabled : []
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback()
                onTapTakePhoto()
            },
        ]

        return UIMenu(children: [
            UIMenu(options: [.displayInline], children: modeActions),
            UIMenu(options: [.displayInline], children: attachmentActions),
        ])
    }

    // Toggling Fast Mode from the plus menu mirrors the runtime speed menu without adding another visible pill.
    private func toggleFastMode() {
        runtimeActions.selectServiceTier(runtimeState.isSelectedServiceTier(.fast) ? nil : .fast)
    }

    private var fastModePlusMenuIconName: String {
        runtimeState.isSelectedServiceTier(.fast) ? "bolt.fill" : "bolt"
    }
}

// MARK: - Mic button

// The composer mic. Routes every voice state (idle glyph, circular background,
// progress spinner) through the same icon pipeline as the rest of the chrome.
struct ComposerVoiceButton: View {
    let presentation: TurnComposerVoiceButtonPresentation
    let onTap: () -> Void
    var circleDiameter: CGFloat = 32
    var iconSide: CGFloat = 21
    // When set, the whole button gets a larger square hit area (matching the
    // send button) so the mic is as easy to tap as the primary CTA.
    var tapTargetSide: CGFloat?

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            onTap()
        } label: {
            if let tapTargetSide {
                label
                    .frame(width: tapTargetSide, height: tapTargetSide)
                    .contentShape(Circle())
            } else {
                label
            }
        }
        .disabled(presentation.isDisabled)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var label: some View {
        if presentation.showsProgress {
            CircularIconBadge(
                foreground: presentation.foregroundColor,
                background: presentation.backgroundColor,
                diameter: circleDiameter
            ) {
                RunningThreadSpinner(
                    size: 16,
                    color: presentation.foregroundColor
                )
            }
        } else if presentation.hasCircleBackground {
            // Keep circular voice states on the same icon pipeline as the
            // rest of the composer chrome.
            RemodexCircleBadge(
                systemName: presentation.systemImageName,
                foreground: presentation.foregroundColor,
                background: presentation.backgroundColor,
                diameter: circleDiameter
            )
        } else {
            // Use explicit size so the Central mic artwork compensates for
            // its internal padding (glyph fills ~77% of the SVG viewBox)
            // and renders at the same visual size as the SF `plus` glyph.
            RemodexIcon.image(
                systemName: presentation.systemImageName,
                size: iconSide
            )
            .foregroundStyle(presentation.foregroundColor)
            .frame(width: iconSide, height: iconSide)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Stop control

// Stop affordance for a running turn: a short spinner while the run is still
// being created (no turn id yet), then the palette-colored stop badge. Shared
// so the collapsed capsule keeps Stop reachable exactly like the full bar.
struct ComposerStopControl: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    let activeTurnID: String?
    let isSending: Bool
    let onStopTurn: (String?) -> Void
    var diameter: CGFloat = 32
    var iconSize: CGFloat = 14

    private var palette: UserBubbleColor {
        (UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default).ctaPalette
    }

    var body: some View {
        if isSending && activeTurnID == nil {
            ProgressView()
                .tint(Color(.label))
                .frame(width: diameter, height: diameter)
                .accessibilityLabel("Starting run")
        } else {
            Button {
                HapticFeedback.shared.triggerImpactFeedback()
                onStopTurn(activeTurnID)
            } label: {
                RemodexCircleBadge(
                    systemName: "stop.fill",
                    foreground: palette.bubbleForeground(for: colorScheme),
                    background: palette.bubbleBackground(for: colorScheme),
                    diameter: diameter,
                    iconSize: iconSize
                )
            }
            .accessibilityLabel("Stop current run")
        }
    }
}
