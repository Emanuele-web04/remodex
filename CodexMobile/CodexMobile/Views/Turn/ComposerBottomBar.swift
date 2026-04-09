// FILE: ComposerBottomBar.swift
// Purpose: Bottom bar with attachment/model/reasoning/access menus, queue controls, and send button.
// Layer: View Component
// Exports: ComposerBottomBar
// Depends on: SwiftUI, TurnComposerMetaMapper

import SwiftUI

struct ComposerBottomBar: View {
    @Environment(\.colorScheme) private var colorScheme

    // Data
    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool
    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    let remainingAttachmentSlots: Int
    let isComposerInteractionLocked: Bool
    let isSendDisabled: Bool
    let isPlanModeArmed: Bool
    let queuedCount: Int
    let isQueuePaused: Bool
    let activeTurnID: String?
    let isThreadRunning: Bool
    let voiceButtonPresentation: TurnComposerVoiceButtonPresentation
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
    let onTapVoice: () -> Void
    let onSetPlanModeArmed: (Bool) -> Void
    let onResumeQueue: () -> Void
    let onStopTurn: (String?) -> Void
    let onSend: () -> Void

    // MARK: - Constants

    private let metaLabelColor = Color(.secondaryLabel)
    private var metaTextFont: Font { AppFont.subheadline() }
    private var metaSymbolFont: Font { AppFont.system(size: 11, weight: .regular) }
    private let metaSymbolSize: CGFloat = 12
    private let brainSymbolSize: CGFloat = 8
    private let reasoningSymbolName = "brain"
    private let reasoningSymbolIsAsset = true
    private var metaChevronFont: Font { AppFont.system(size: 9, weight: .regular) }
    private let metaVerticalPadding: CGFloat = 6
    private let plusTapTargetSide: CGFloat = 22

    private var sendButtonIconColor: Color {
        if isSendDisabled { return Color(.systemGray2) }
        return Color(.systemBackground)
    }

    private var sendButtonBackgroundColor: Color {
        if isSendDisabled { return Color(.systemGray5) }
        return Color(.label)
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            attachmentMenu
            modelMenu
            reasoningMenu
            if isPlanModeArmed {
                Divider()
                    .frame(height: 16)
                planModeIndicator
            }
            Spacer(minLength: 0)

            if isQueuePaused && queuedCount > 0 {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onResumeQueue()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppFont.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 28, height: 28)
                        .background(Color(.systemGray2), in: Circle())
                }
                .accessibilityLabel("Resume queued messages")
            }

            // Voice → Stop → Send
            Button {
                HapticFeedback.shared.triggerImpactFeedback()
                onTapVoice()
            } label: {
                voiceButtonLabel
            }
            .disabled(voiceButtonPresentation.isDisabled)
            .accessibilityLabel(voiceButtonPresentation.accessibilityLabel)

            if isThreadRunning {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onStopTurn(activeTurnID)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(AppFont.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color(.label), in: Circle())
                }
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(AppFont.system(size: 12, weight: .bold))
                    .foregroundStyle(sendButtonIconColor)
                    .frame(width: 32, height: 32)
                    .background(sendButtonBackgroundColor, in: Circle())
            }
            .overlay(alignment: .topTrailing) {
                if queuedCount > 0 {
                    queueBadge
                        .offset(x: 8, y: -8)
                }
            }
            .disabled(isSendDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .padding(.top, 6)
    }

    private var voiceButtonLabel: some View {
        Group {
            if voiceButtonPresentation.showsProgress {
                ProgressView()
                    .tint(voiceButtonPresentation.foregroundColor)
                    .frame(width: 32, height: 32)
                    .background(voiceButtonPresentation.backgroundColor, in: Circle())
            } else if voiceButtonPresentation.hasCircleBackground {
                Image(systemName: voiceButtonPresentation.systemImageName)
                    .font(AppFont.system(size: 12, weight: .bold))
                    .foregroundStyle(voiceButtonPresentation.foregroundColor)
                    .frame(width: 32, height: 32)
                    .background(voiceButtonPresentation.backgroundColor, in: Circle())
            } else {
                Image(systemName: voiceButtonPresentation.systemImageName)
                    .font(metaTextFont)
                    .foregroundStyle(metaLabelColor)
                    .frame(width: plusTapTargetSide, height: plusTapTargetSide)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Menus

    private var attachmentMenu: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { isPlanModeArmed },
                set: { newValue in
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onSetPlanModeArmed(newValue)
                }
            )) {
                Label("Plan mode", systemImage: "checklist")
            }

            Section {
                Button("Photo library") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onTapAddImage()
                }
                .disabled(remainingAttachmentSlots == 0)

                Button("Take a photo") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onTapTakePhoto()
                }
                .disabled(remainingAttachmentSlots == 0)
            }
        } label: {
            Image(systemName: "plus")
                .font(metaTextFont)
                .fontWeight(.regular)
                .frame(width: plusTapTargetSide, height: plusTapTargetSide)
                .contentShape(Capsule())
        }
        .tint(metaLabelColor)
        .disabled(isComposerInteractionLocked)
        .accessibilityLabel("Attachment and plan options")
    }

    private var modelMenu: some View {
        Menu {
            Text("Select model")
            if isLoadingModels {
                Text("Loading models...")
            } else if orderedModelOptions.isEmpty {
                Text("No models available")
            } else {
                ForEach(orderedModelOptions, id: \.id) { model in
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        runtimeActions.selectModel(model.id)
                    } label: {
                        if selectedModelID == model.id {
                            Label(TurnComposerMetaMapper.modelTitle(for: model), systemImage: "checkmark")
                        } else {
                            Text(TurnComposerMetaMapper.modelTitle(for: model))
                        }
                    }
                }
            }
        } label: {
            composerMenuLabel(
                title: selectedModelTitle,
                leadingImageName: runtimeState.showsSpeedBadgeInModelMenu ? "bolt.fill" : nil,
                leadingImageIsSystem: true
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .tint(metaLabelColor)
    }

    private var reasoningMenu: some View {
        Menu {
            Section("Reasoning") {
                if runtimeState.reasoningDisplayOptions.isEmpty {
                    Text("No reasoning options")
                } else {
                    ForEach(runtimeState.reasoningDisplayOptions, id: \.id) { option in
                        Button {
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            runtimeActions.selectReasoning(option.effort)
                        } label: {
                            if runtimeState.isSelectedReasoning(option.effort) {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                        .disabled(runtimeState.reasoningMenuDisabled)
                    }
                }
            }

            Section("Speed") {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    runtimeActions.selectServiceTier(nil)
                } label: {
                    if runtimeState.isSelectedServiceTier(nil) {
                        Label("Normal", systemImage: "checkmark")
                    } else {
                        Text("Normal")
                    }
                }

                ForEach(CodexServiceTier.allCases, id: \.rawValue) { tier in
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        runtimeActions.selectServiceTier(tier)
                    } label: {
                        if runtimeState.isSelectedServiceTier(tier) {
                            Label(tier.displayName, systemImage: "checkmark")
                        } else {
                            Text(tier.displayName)
                        }
                    }
                }
            }
        } label: {
            composerMenuLabel(
                title: runtimeState.selectedReasoningTitle,
                leadingImageName: reasoningSymbolName,
                leadingImageIsSystem: false
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .tint(metaLabelColor)
    }

    private var planModeIndicator: some View {
        HStack(spacing: 5) {
            Image(systemName: "checklist")
                .font(metaSymbolFont)
            Text("Plan")
                .font(metaTextFont)
                .fontWeight(.regular)
                .lineLimit(1)
        }
        .padding(.vertical, metaVerticalPadding)
        .padding(.horizontal, 4)
        .foregroundStyle(.secondary)
    }


    private var queueBadge: some View {
        HStack(spacing: 3) {
            if isQueuePaused {
                Image(systemName: "pause.fill")
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

    // MARK: - Shared Label

    private func composerMenuLabel(
        title: String,
        leadingImageName: String? = nil,
        leadingImageIsSystem: Bool = true
    ) -> some View {
        HStack(spacing: 6) {
            if let leadingImageName {
                Group {
                    if leadingImageIsSystem {
                        Image(systemName: leadingImageName)
                            .font(metaSymbolFont)
                    } else {
                        Image(leadingImageName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: metaSymbolSize, height: metaSymbolSize)
                    }
                }
            }

            Text(title)
                .font(metaTextFont)
                .fontWeight(.regular)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(metaChevronFont)
        }
        .padding(.vertical, metaVerticalPadding)
        .padding(.horizontal, 4)
        .foregroundStyle(metaLabelColor)
        // Keep adjacent menus from borrowing each other's touch region when the
        // phone composer gets tight while the keyboard is up.
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
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
