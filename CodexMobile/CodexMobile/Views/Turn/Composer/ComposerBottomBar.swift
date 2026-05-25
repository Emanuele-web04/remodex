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
    @State private var bottomBarWidth: CGFloat = 0

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
    private let composerIconSide: CGFloat = 22
    private let inlineAccessControlSize: CGFloat = 32
    private let inlineAccessControlIconSize: CGFloat = 20

    private var selectedUserBubbleColor: UserBubbleColor {
        UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
    }

    // The send button is a CTA: treat the neutral "Default" palette the same
    // as the "Primary" (.black) palette so it stays a bold label-colored circle
    // regardless of which neutral the user picked.
    private var sendButtonPaletteColor: UserBubbleColor {
        selectedUserBubbleColor == .default ? .black : selectedUserBubbleColor
    }

    private var sendButtonIconColor: Color {
        if isSendDisabled { return Color(.systemGray2) }
        return sendButtonPaletteColor.bubbleForeground(for: colorScheme)
    }

    private var sendButtonBackgroundColor: Color {
        if isSendDisabled { return Color(.systemGray5) }
        return sendButtonPaletteColor.bubbleBackground(for: colorScheme)
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            attachmentMenu
                .padding(.leading, 8)
            inlineAccessMenuLabel
            agentRuntimeMenuControl
            if runtimeState.selectedAgentRuntimeID == "opencode", runtimeState.openCodeAgentOptions.count > 1 {
                openCodeBuildAgentMenuControl
            }
            if runtimeState.selectedAgentRuntimeID == "opencode", runtimeState.agentRuntimeCapabilities.planMode {
                openCodePlanAgentMenuControl
            }
            Spacer(minLength: 0)

            inlineStatusControl
            runtimeMenuControl

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

            // Voice -> Stop/loading -> Send. New sends can look running before the turn id is interruptible.
            Button {
                HapticFeedback.shared.triggerImpactFeedback()
                onTapVoice()
            } label: {
                voiceButtonLabel
            }
            .disabled(voiceButtonPresentation.isDisabled)
            .accessibilityLabel(voiceButtonPresentation.accessibilityLabel)

            if isThreadRunning && isSending && activeTurnID == nil {
                ProgressView()
                    .tint(Color(.label))
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Starting run")
            } else if isThreadRunning {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onStopTurn(activeTurnID)
                } label: {
                    RemodexCircleBadge(
                        systemName: "stop.fill",
                        foreground: sendButtonPaletteColor.bubbleForeground(for: colorScheme),
                        background: sendButtonPaletteColor.bubbleBackground(for: colorScheme)
                    )
                }
                .accessibilityLabel("Stop current run")
            }

            if showsSendButton {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onSend()
                } label: {
                    RemodexCircleBadge(
                        systemName: "arrow.up",
                        foreground: sendButtonIconColor,
                        background: sendButtonBackgroundColor
                    )
                }
                .overlay(alignment: .topTrailing) {
                    if queuedCount > 0 {
                        queueBadge
                            .offset(x: 8, y: -8)
                    }
                }
                .disabled(isSendDisabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 2)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ComposerBottomBarWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(ComposerBottomBarWidthPreferenceKey.self) { width in
            let roundedWidth = width.rounded()
            if abs(bottomBarWidth - roundedWidth) > 0.5 {
                bottomBarWidth = roundedWidth
            }
        }
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

    private var voiceButtonLabel: some View {
        Group {
            if voiceButtonPresentation.showsProgress {
                CircularIconBadge(
                    foreground: voiceButtonPresentation.foregroundColor,
                    background: voiceButtonPresentation.backgroundColor
                ) {
                    ProgressView()
                }
            } else if voiceButtonPresentation.hasCircleBackground {
                // Keep circular voice states on the same icon pipeline as the
                // rest of the composer chrome.
                RemodexCircleBadge(
                    systemName: voiceButtonPresentation.systemImageName,
                    foreground: voiceButtonPresentation.foregroundColor,
                    background: voiceButtonPresentation.backgroundColor
                )
            } else {
                // Use explicit size so the Central mic artwork compensates for
                // its internal padding (glyph fills ~77% of the SVG viewBox)
                // and renders at the same visual size as the SF `plus` glyph.
                RemodexIcon.image(
                    systemName: voiceButtonPresentation.systemImageName,
                    size: composerIconSide
                )
                .foregroundStyle(metaLabelColor)
                .frame(width: composerIconSide, height: composerIconSide)
                .contentShape(Rectangle())
            }
        }
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
            availableBottomBarWidth: bottomBarWidth,
            showsAllModelsSheet: $showsAllModelsSheet
        )
        .equatable()
    }

    private var openCodeBuildAgentMenuControl: some View {
        Menu {
            ForEach(runtimeState.openCodeAgentOptions) { agent in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    runtimeActions.selectOpenCodeBuildAgent(agent.id)
                } label: {
                    if runtimeState.selectedOpenCodeBuildAgentID == agent.id {
                        Label(agent.displayName, systemImage: "checkmark")
                    } else {
                        Text(agent.displayName)
                    }
                }
                .disabled(runtimeState.isAgentRuntimeLocked)
            }
        } label: {
            HStack(spacing: 4) {
                RemodexIcon.image(systemName: "person.crop.circle", size: 14)
                Text(runtimeState.selectedOpenCodeBuildAgentTitle)
                    .font(AppFont.caption(weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(runtimeState.isAgentRuntimeLocked ? Color(.secondaryLabel) : Color(.label))
            .padding(.horizontal, 9)
            .frame(maxWidth: 140)
            .frame(height: 30)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .disabled(runtimeState.isAgentRuntimeLocked)
        .accessibilityLabel("OpenCode build agent")
    }

    private var openCodePlanAgentMenuControl: some View {
        Menu {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                runtimeActions.selectOpenCodePlanAgent(runtimeState.selectedOpenCodePlanAgentID)
            } label: {
                Label(runtimeState.selectedOpenCodePlanAgentTitle, systemImage: "checkmark")
            }
            .disabled(runtimeState.isAgentRuntimeLocked)
        } label: {
            HStack(spacing: 4) {
                RemodexIcon.image(systemName: "list.bullet.clipboard", size: 14)
                Text(runtimeState.selectedOpenCodePlanAgentTitle)
                    .font(AppFont.caption(weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(runtimeState.isAgentRuntimeLocked ? Color(.secondaryLabel) : Color(.label))
            .padding(.horizontal, 9)
            .frame(maxWidth: 96)
            .frame(height: 30)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .disabled(runtimeState.isAgentRuntimeLocked)
        .accessibilityLabel("OpenCode plan agent")
    }

    private var agentRuntimeMenuControl: some View {
        Menu {
            ForEach(runtimeState.agentRuntimeOptions) { runtime in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    runtimeActions.selectAgentRuntime(runtime.id)
                } label: {
                    if runtimeState.selectedAgentRuntimeID == runtime.id {
                        Label(runtime.displayName, systemImage: "checkmark")
                    } else if runtime.isReady {
                        Text(runtime.displayName)
                    } else if runtime.showsRuntimeStatusWarning,
                              let statusMessage = runtime.statusMessage,
                              !statusMessage.isEmpty {
                        Label("\(runtime.displayName) — \(statusMessage)", systemImage: "exclamationmark.triangle")
                    } else {
                        Label(runtime.displayName, systemImage: "exclamationmark.triangle")
                    }
                }
                .disabled(runtimeState.isAgentRuntimeLocked || !runtime.isReady)
            }
        } label: {
            HStack(spacing: 4) {
                RemodexIcon.image(systemName: "cpu", size: 14)
                Text(runtimeState.selectedAgentRuntimeTitle)
                    .font(AppFont.caption(weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(runtimeState.isAgentRuntimeLocked ? Color(.secondaryLabel) : Color(.label))
            .padding(.horizontal, 9)
            .frame(maxWidth: 96)
            .frame(height: 30)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .disabled(runtimeState.isAgentRuntimeLocked)
        .accessibilityLabel("Agent")
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
            onRefreshStatus: onRefreshUsageStatus
        )
    }

    private var attachmentMenu: some View {
        Menu {
            // `RemodexIcon.menuLabel` keeps Central artwork in SwiftUI Menus
            // by routing through `Label(_, image:)` for mapped assets and
            // falling back to `Label(_, systemImage:)` for plain SF Symbols.
            if runtimeState.agentRuntimeCapabilities.planMode {
                Toggle(isOn: Binding(
                    get: { isPlanModeArmed },
                    set: { newValue in
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onSetPlanModeArmed(newValue)
                    }
                )) {
                    RemodexIcon.menuLabel("Plan mode", systemName: "remodex.plan-mode")
                }
            }

            if runtimeState.supportsFastMode {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    toggleFastMode()
                } label: {
                    // Native SF bolt on purpose so the menu item matches the
                    // speed badge / Speed submenu icon used elsewhere.
                    Label("Fast Mode", systemImage: fastModePlusMenuIconName)
                }
            }

            if runtimeState.agentRuntimeCapabilities.photos {
                Section {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback()
                        onTapAddImage()
                    } label: {
                        RemodexIcon.menuLabel("Photo library", systemName: "photo")
                    }
                    .disabled(remainingAttachmentSlots == 0)

                    Button {
                        HapticFeedback.shared.triggerImpactFeedback()
                        onTapTakePhoto()
                    } label: {
                        RemodexIcon.menuLabel("Take a photo", systemName: "camera.fill")
                    }
                    .disabled(remainingAttachmentSlots == 0)
                }
            }
        } label: {
            RemodexIcon.image(systemName: "plus")
                .font(AppFont.title3(weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: composerIconSide, height: composerIconSide)
                .contentShape(Capsule())
        }
        .tint(metaLabelColor)
        .disabled(isComposerInteractionLocked)
        .accessibilityLabel("Composer options")
    }

    // Toggling Fast Mode from the plus menu mirrors the runtime speed menu without adding another visible pill.
    private func toggleFastMode() {
        runtimeActions.selectServiceTier(runtimeState.isSelectedServiceTier(.fast) ? nil : .fast)
    }

    private var fastModePlusMenuIconName: String {
        runtimeState.isSelectedServiceTier(.fast) ? "bolt.fill" : "bolt"
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
    let availableBottomBarWidth: CGFloat
    @Binding var showsAllModelsSheet: Bool

    private let metaLabelColor = Color(.secondaryLabel)
    private var metaTextFont: Font { AppFont.callout() }
    private var leadingIconFont: Font { AppFont.subheadline() }
    private let minInlineRuntimeLabelWidth: CGFloat = 88
    private let maxInlineRuntimeLabelWidth: CGFloat = 200

    private var inlineRuntimeLabelMaxWidth: CGFloat {
        guard availableBottomBarWidth > 0 else {
            return maxInlineRuntimeLabelWidth
        }
        let budget = availableBottomBarWidth * 0.22
        return min(max(budget, minInlineRuntimeLabelWidth), maxInlineRuntimeLabelWidth)
    }

    static func == (lhs: ComposerRuntimeMenuControl, rhs: ComposerRuntimeMenuControl) -> Bool {
        lhs.orderedModelOptions == rhs.orderedModelOptions
            && lhs.selectedModelID == rhs.selectedModelID
            && lhs.selectedModelTitle == rhs.selectedModelTitle
            && lhs.isLoadingModels == rhs.isLoadingModels
            && lhs.isRuntimeSelectionLoading == rhs.isRuntimeSelectionLoading
            && lhs.runtimeState == rhs.runtimeState
            && lhs.availableBottomBarWidth == rhs.availableBottomBarWidth
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
        .layoutPriority(1)
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

    // Keeps inline runtime metadata short so stop + send controls do not move the composer.
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
                // Native SF Symbol on purpose: the Central lightning artwork
                // reads as a different glyph from the system bolt that the
                // user expects in the speed badge.
                Image(systemName: leadingImageName)
                    .font(leadingIconFont)
                    .foregroundStyle(Color.primary)
            }

            titleText(modelPart: modelPart, effortPart: effortPart)
                .font(metaTextFont)
                .fontWeight(.regular)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.tail)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: inlineRuntimeLabelMaxWidth, alignment: .leading)
        .contentShape(Rectangle())
    }

    // Concatenated Text lets each segment carry its own foreground style.
    private func titleText(modelPart: String, effortPart: String?) -> Text {
        let model = Text(modelPart).foregroundStyle(Color.primary)
        guard let effortPart, !effortPart.isEmpty else { return model }
        return model
            + Text(" ")
            + Text(effortPart).foregroundStyle(.tertiary)
    }
}

private struct ComposerBottomBarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
                        Image(systemName: CodexServiceTier.fast.iconName)
                            .font(.system(size: fastModeIconSide, weight: .regular))
                            .frame(width: fastModeIconSide, height: fastModeIconSide)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                }
                if !model.description.isEmpty {
                    Text(model.description)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color(.secondaryLabel))
                }
                if let providerName = model.providerDisplayName, !providerName.isEmpty {
                    Text(providerName)
                        .font(AppFont.caption())
                        .foregroundStyle(Color(.tertiaryLabel))
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
