// FILE: ComposerBottomBar.swift
// Purpose: Bottom bar with attachment/runtime/access menus, queue controls, and send button.
//          The runtime pill only renders the label and reports taps; the
//          slider overlay and all-models sheet are hosted by TurnComposerView
//          so their presentations survive the composer collapsing.
// Layer: View Component
// Exports: ComposerBottomBar
// Depends on: SwiftUI, TurnComposerRuntimeLabelParts, TurnComposerRuntimeState

import SwiftUI

struct ComposerBottomBar: View {
    @Environment(\.colorScheme) private var colorScheme

    // Data
    let runtimeLabelParts: TurnComposerRuntimeLabelParts
    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    let remainingAttachmentSlots: Int
    let isComposerInteractionLocked: Bool
    let isSendDisabled: Bool
    let isSending: Bool
    let isPlanModeArmed: Bool
    let queuedCount: Int
    let isQueuePaused: Bool
    let activeTurnID: String?
    let isThreadRunning: Bool
    let showsSendButton: Bool
    let voiceButtonPresentation: TurnComposerVoiceButtonPresentation
    let selectedAccessMode: CodexAccessMode
    let contextWindowUsage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let shouldAutoRefreshUsageStatus: Bool
    let onRefreshUsageStatus: () async -> Void
    let onSelectAccessMode: (CodexAccessMode) -> Void
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
    let onTapVoice: () -> Void
    let onSetPlanModeArmed: (Bool) -> Void
    let onResumeQueue: () -> Void
    let onStopTurn: (String?) -> Void
    let onTapRuntimePill: () -> Void
    let onSend: () -> Void

    // MARK: - Constants

    private let composerCircleDiameter: CGFloat = 32
    private let composerActionIconSize: CGFloat = 14
    // Send stays the primary CTA, so give it a slightly larger tap target than
    // the neutral composer chrome.
    // Keep the send circle two points larger than its previous 32pt size.
    private let sendButtonDiameter: CGFloat = 34

    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    private var selectedUserBubbleColor: UserBubbleColor {
        UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
    }

    private var sendButtonPaletteColor: UserBubbleColor {
        selectedUserBubbleColor.ctaPalette
    }

    private var sendButtonIconColor: Color {
        if isSendDisabled { return Color(.systemGray2) }
        return sendButtonPaletteColor.bubbleForeground(for: colorScheme)
    }

    private var sendButtonBackgroundColor: Color {
        if isSendDisabled { return Color(.systemGray5) }
        return sendButtonPaletteColor.bubbleBackground(for: colorScheme)
    }

    private var showsStopButton: Bool {
        isThreadRunning && !showsSendButton
    }

    // MARK: - Body

    var body: some View {
        // 10pt base spacing + each control's own edge padding lands every
        // visual gap (ring/pill, pill/mic, mic/stop-send) at ~14pt.
        HStack(spacing: 10) {
            ComposerAttachmentMenu(
                isPlanModeArmed: isPlanModeArmed,
                runtimeState: runtimeState,
                runtimeActions: runtimeActions,
                remainingAttachmentSlots: remainingAttachmentSlots,
                isInteractionLocked: isComposerInteractionLocked,
                onSetPlanModeArmed: onSetPlanModeArmed,
                onTapAddImage: onTapAddImage,
                onTapTakePhoto: onTapTakePhoto
            )
            .padding(.leading, 6)
            ComposerAccessModeControl(
                selectedAccessMode: selectedAccessMode,
                isInteractionLocked: isComposerInteractionLocked,
                onSelect: onSelectAccessMode
            )
            Spacer(minLength: 0)

            // Ring + runtime pill travel together on the trailing side; the
            // tight inner spacing keeps the ring visually attached to the
            // model/effort block instead of floating in the Spacer gap.
            HStack(spacing: 4) {
                inlineStatusControl
                runtimeMenuControl
            }

            if isQueuePaused && queuedCount > 0 {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onResumeQueue()
                } label: {
                    RemodexCircleBadge(
                        systemName: "arrow.clockwise",
                        foreground: Color(.systemBackground),
                        background: Color(.systemGray2),
                        diameter: 28
                    )
                }
                .accessibilityLabel("Resume queued messages")
            }

            ComposerVoiceButton(
                presentation: voiceButtonPresentation,
                onTap: onTapVoice
            )

            if showsStopButton {
                ComposerStopControl(
                    activeTurnID: activeTurnID,
                    isSending: isSending,
                    onStopTurn: onStopTurn,
                    diameter: composerCircleDiameter,
                    iconSize: composerActionIconSize
                )
                // Match the send button's extra leading air so the mic never
                // sits flush against the filled stop circle.
                .padding(.leading, 4)
            }

            if showsSendButton {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onSend()
                } label: {
                    sendButtonLabel
                }
                .overlay(alignment: .topTrailing) {
                    if queuedCount > 0 {
                        queueBadge
                            .offset(x: 8, y: -8)
                    }
                }
                .padding(.leading, 4)
                .disabled(isSendDisabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .padding(.top, 0)
    }

    // Single SF `arrow.up.circle.fill` glyph (palette-rendered) so the arrow and
    // its circle are one coherent icon in both the disabled and active states,
    // instead of an arrow layered over a separately-filled circle badge.
    private var sendButtonLabel: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: sendButtonDiameter, weight: .regular))
            .symbolRenderingMode(.palette)
            .foregroundStyle(sendButtonIconColor, sendButtonBackgroundColor)
            .frame(width: sendButtonDiameter, height: sendButtonDiameter)
            .contentShape(Circle())
    }

    // MARK: - Runtime pill

    private var runtimeMenuControl: some View {
        ComposerRuntimePill(
            labelParts: runtimeLabelParts,
            showsFastModeBadge: runtimeState.showsFastModeBadgeOnPill,
            onTap: onTapRuntimePill
        )
        .equatable()
    }

    private var inlineStatusControl: some View {
        ContextWindowProgressRing(
            usage: contextWindowUsage,
            rateLimitBuckets: rateLimitBuckets,
            isLoadingRateLimits: isLoadingRateLimits,
            rateLimitsErrorMessage: rateLimitsErrorMessage,
            shouldAutoRefreshStatus: shouldAutoRefreshUsageStatus,
            showsGlassBackground: false,
            progressColorOverride: .primary,
            // Slimmer tap target than the standalone default so the ring's
            // internal air matches the ~12pt visual rhythm of the bar.
            tapTargetSize: 28,
            onRefreshStatus: onRefreshUsageStatus
        )
    }

    private var queueBadge: some View {
        HStack(spacing: 3) {
            if isQueuePaused {
                RemodexIcon.image(systemName: "pause.fill")
                    .font(AppFont.system(size: 8, weight: .bold))
            }
            Text("\(queuedCount)")
                .font(AppFont.caption2(weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isQueuePaused ? Color(.systemGray3) : Color(.systemGray4))
        )
    }
}

// Keeps the runtime pill from rebuilding during unrelated thread-sync updates:
// it renders precomputed label parts and reports taps, while the slider
// overlay and all-models sheet are presented by TurnComposerView.
private struct ComposerRuntimePill: View, Equatable {
    let labelParts: TurnComposerRuntimeLabelParts
    let showsFastModeBadge: Bool
    let onTap: () -> Void

    private let metaLabelColor = Color(.secondaryLabel)
    private var metaTextFont: Font { AppFont.callout() }
    private var effortTextFont: Font { AppFont.subheadline() }
    private var leadingIconFont: Font { AppFont.callout() }

    static func == (lhs: ComposerRuntimePill, rhs: ComposerRuntimePill) -> Bool {
        lhs.labelParts == rhs.labelParts
            && lhs.showsFastModeBadge == rhs.showsFastModeBadge
    }

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTap()
        } label: {
            pillLabel
        }
        .buttonStyle(.plain)
        // Let the pill hug its content; the Spacer in the bottom bar absorbs
        // leftover width, and layoutPriority(-1) makes the effort label the
        // first thing to truncate when the bar runs out of room.
        .layoutPriority(-1)
        .tint(metaLabelColor)
        .accessibilityLabel(accessibilityLabel)
    }

    private var pillLabel: some View {
        HStack(spacing: 6) {
            if showsFastModeBadge {
                RemodexIcon.image(systemName: "bolt.fill")
                    .font(leadingIconFont)
                    .foregroundStyle(Color.primary)
            }

            HStack(spacing: 4) {
                Text(labelParts.modelPart)
                    .font(metaTextFont)
                    .fontWeight(.regular)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                if let effortPart = labelParts.effortPart, !effortPart.isEmpty {
                    Text(effortPart)
                        .font(effortTextFont)
                        .fontWeight(.regular)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        if let effortPart = labelParts.effortPart, !effortPart.isEmpty {
            return "\(labelParts.modelPart), \(effortPart)"
        }
        return labelParts.modelPart
    }
}

// Keeps the mic button state and styling decisions outside the layout code.
struct TurnComposerVoiceButtonPresentation {
    let systemImageName: String
    let foregroundColor: Color
    let backgroundColor: Color
    let accessibilityLabel: String
    let isDisabled: Bool
    let showsProgress: Bool
    let hasCircleBackground: Bool
}
