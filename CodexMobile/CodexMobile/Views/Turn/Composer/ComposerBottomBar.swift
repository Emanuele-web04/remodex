// FILE: ComposerBottomBar.swift
// Purpose: Bottom bar with attachment/runtime/access menus, queue controls, and send button.
// Layer: View Component
// Exports: ComposerBottomBar
// Depends on: SwiftUI, TurnComposerMetaMapper, UIKitMenuButton, TurnComposerRuntimeUIKitMenuBuilder

import SwiftUI

struct ComposerBottomBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue
    @State private var showsAllModelsSheet = false

    // Data
    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool
    let isRuntimeSelectionLoading: Bool
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
    let onSend: () -> Void

    // MARK: - Constants

    private let metaLabelColor = Color(.secondaryLabel)
    private var metaTextFont: Font { AppFont.subheadline() }
    private let composerCircleDiameter: CGFloat = 30
    private let composerActionIconSize: CGFloat = 14
    private let inlineAccessControlSize: CGFloat = 32
    private let inlineAccessControlIconSize: CGFloat = 20
    // Send stays the primary CTA, so give it a slightly larger tap target than
    // the neutral composer chrome.
    private let sendButtonDiameter: CGFloat = 32

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
        // 8pt base spacing + each control's own edge padding lands every
        // visual gap (ring/pill, pill/mic, mic/stop-send) at ~11-12pt.
        HStack(spacing: 8) {
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
            inlineAccessMenuLabel
            Spacer(minLength: 0)

            // Ring + runtime pill travel together on the trailing side; the
            // tight inner spacing keeps the ring visually attached to the
            // model/effort block instead of floating in the Spacer gap.
            HStack(spacing: 2) {
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
                .padding(.leading, 3)
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
                .padding(.leading, 3)
                .disabled(isSendDisabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .padding(.top, 0)
        .sheet(isPresented: $showsAllModelsSheet) {
            AllModelsSheet(
                models: orderedModelOptions,
                selectedModelID: selectedModelID,
                isLoadingModels: isLoadingModels,
                modelSupportsFastMode: modelSupportsFastMode,
                onSelect: { modelID in
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    runtimeActions.selectModel(modelID)
                    showsAllModelsSheet = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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

    // MARK: - Menus

    // Access and usage stay inline with the bottom composer controls for every
    // thread type so rootless and project-backed chats share the same layout.
    private var inlineAccessMenuLabel: some View {
        Menu {
            ForEach(CodexAccessMode.allCases, id: \.rawValue) { mode in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onSelectAccessMode(mode)
                } label: {
                    if selectedAccessMode == mode {
                        Label(mode.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(mode.menuTitle)
                    }
                }
            }
        } label: {
            RemodexIcon.image(
                systemName: selectedAccessMode == .fullAccess ? "hand.thumbsup" : "hand.raised",
                size: inlineAccessControlIconSize
            )
            .frame(width: inlineAccessControlSize, height: inlineAccessControlSize)
            .foregroundStyle(selectedAccessMode == .fullAccess ? .orange : metaLabelColor)
            .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .tint(metaLabelColor)
        .disabled(isComposerInteractionLocked)
    }

    private var runtimeMenuControl: some View {
        ComposerRuntimeMenuControl(
            orderedModelOptions: orderedModelOptions,
            selectedModelID: selectedModelID,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: isLoadingModels,
            isRuntimeSelectionLoading: isRuntimeSelectionLoading,
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            showsAllModelsSheet: $showsAllModelsSheet
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

    // Mirrors the bridge-provided runtime capability instead of guessing from the model name.
    private func modelSupportsFastMode(_ model: CodexModelOption) -> Bool {
        return model.supportsServiceTier(.fast)
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

// Keeps the SwiftUI Menu from rebuilding during unrelated thread-sync updates.
private struct ComposerRuntimeMenuControl: View, Equatable {
    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool
    let isRuntimeSelectionLoading: Bool
    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    @Binding var showsAllModelsSheet: Bool

    private let metaLabelColor = Color(.secondaryLabel)
    private var metaTextFont: Font { AppFont.callout() }
    private var effortTextFont: Font { AppFont.subheadline() }
    private var leadingIconFont: Font { AppFont.callout() }

    static func == (lhs: ComposerRuntimeMenuControl, rhs: ComposerRuntimeMenuControl) -> Bool {
        lhs.orderedModelOptions == rhs.orderedModelOptions
            && lhs.selectedModelID == rhs.selectedModelID
            && lhs.selectedModelTitle == rhs.selectedModelTitle
            && lhs.isLoadingModels == rhs.isLoadingModels
            && lhs.isRuntimeSelectionLoading == rhs.isRuntimeSelectionLoading
            && lhs.runtimeState == rhs.runtimeState
    }

    // Renders one consolidated runtime pill backed by a real UIKit UIMenu so we
    // can use hierarchical Model / Intelligence / Speed rows with subtitles
    // without hitting SwiftUI nested-Menu glitches.
    var body: some View {
        UIKitMenuButton {
            composerMenuLabel(
                modelPart: modelLabelPart,
                effortPart: effortLabelPart,
                leadingImageName: runtimeState.showsSpeedBadgeInModelMenu ? "bolt.fill" : nil
            )
        } menu: {
            TurnComposerRuntimeUIKitMenuBuilder.makeMenu(
                .init(
                    runtimeState: runtimeState,
                    runtimeActions: runtimeActions,
                    orderedModelOptions: orderedModelOptions,
                    selectedModelID: selectedModelID,
                    selectedModelTitle: selectedModelTitle,
                    isLoadingModels: isLoadingModels,
                    isRuntimeSelectionLoading: isRuntimeSelectionLoading,
                    featuredModelIdentifiers: Self.featuredModelIdentifiers,
                    onRequestAllModelsSheet: {
                        // Defer to the next runloop so the menu dismissal
                        // animation isn't fighting the sheet presentation.
                        DispatchQueue.main.async {
                            showsAllModelsSheet = true
                        }
                    }
                )
            )
        }
        // Let the pill hug its content; the Spacer in the bottom bar absorbs
        // leftover width, and layoutPriority(-1) makes the effort label the
        // first thing to truncate when the bar runs out of room.
        .layoutPriority(-1)
        .tint(metaLabelColor)
        .accessibilityLabel(runtimeAccessibilityLabel)
    }

    // Split label parts so the model name and effort can carry different foreground styles.
    private var modelLabelPart: String {
        if selectedModelID == nil {
            return isRuntimeSelectionLoading ? "Loading…" : "Select model"
        }
        return compactModelTitle
    }

    private var effortLabelPart: String? {
        guard selectedModelID != nil else { return nil }
        let trimmed = runtimeState.selectedReasoningTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Select reasoning" else { return nil }
        return trimmed
    }

    private var compactModelTitle: String {
        let normalized = selectedModelTitle
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(String.init)

        let words = normalized.filter { word in
            let lowercased = word.lowercased()
            return lowercased != "gpt" && lowercased != "codex"
        }
        let compact = words.isEmpty ? selectedModelTitle : words.joined(separator: " ")
        return compact
    }

    private var runtimeAccessibilityLabel: String {
        if selectedModelID == nil {
            return modelLabelPart
        }
        let effort = runtimeState.selectedReasoningTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty {
            return "\(selectedModelTitle), \(effort)"
        }
        return selectedModelTitle
    }

    // Identifiers pinned to the top of the model submenu; the rest are reachable
    // via "Other models…" so the menu stays glanceable as the list grows.
    private static let featuredModelIdentifiers: Set<String> = [
        "gpt-5.5",
        "gpt-5.4",
    ]

    private func composerMenuLabel(
        modelPart: String,
        effortPart: String?,
        leadingImageName: String?
    ) -> some View {
        HStack(spacing: 6) {
            if let leadingImageName {
                RemodexIcon.image(systemName: leadingImageName)
                    .font(leadingIconFont)
                    .foregroundStyle(Color.primary)
            }

            HStack(spacing: 4) {
                Text(modelPart)
                    .font(metaTextFont)
                    .fontWeight(.regular)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                if let effortPart, !effortPart.isEmpty {
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
}

// Full-list model picker shown when the user taps "See all models…" inside the
// runtime menu. Lives in a sheet so it sidesteps the SwiftUI nested-Menu bug
// while still keeping the runtime pill compact.
private struct AllModelsSheet: View {
    let models: [CodexModelOption]
    let selectedModelID: String?
    let isLoadingModels: Bool
    let modelSupportsFastMode: (CodexModelOption) -> Bool
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let fastModeIconSide: CGFloat = 16

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingModels {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if models.isEmpty {
                    ContentUnavailableView {
                        RemodexIcon.label("No models available", systemName: "square.stack.3d.up.slash")
                    } description: {
                        Text("Reconnect to your local Codex bridge to refresh the model list.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(models, id: \.id) { model in
                                Button {
                                    onSelect(model.id)
                                } label: {
                                    modelRow(for: model)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Choose model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(for model: CodexModelOption) -> some View {
        let title = TurnComposerMetaMapper.modelTitle(for: model)
        HStack(alignment: .top, spacing: 12) {
            RemodexIcon.image(systemName: model.id == selectedModelID ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(model.id == selectedModelID ? Color.accentColor : Color(.tertiaryLabel))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(Color(.label))
                    if modelSupportsFastMode(model) {
                        RemodexIcon.image(systemName: CodexServiceTier.fast.iconName, size: fastModeIconSide)
                            .frame(width: fastModeIconSide, height: fastModeIconSide)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                }
                if !model.description.isEmpty {
                    Text(model.description)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
