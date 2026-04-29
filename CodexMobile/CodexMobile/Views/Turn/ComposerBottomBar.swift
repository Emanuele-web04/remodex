// FILE: ComposerBottomBar.swift
// Purpose: Bottom bar with attachment/runtime/access menus, queue controls, and send button.
// Layer: View Component
// Exports: ComposerBottomBar
// Depends on: SwiftUI, TurnComposerMetaMapper

import SwiftUI

struct ComposerBottomBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsAllModelsSheet = false

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
            runtimeMenu
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
        .padding(.bottom, 4)
        .padding(.top, 2)
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

            if runtimeState.supportsFastMode {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    toggleFastMode()
                } label: {
                    Label("Fast Mode", systemImage: fastModePlusMenuIconName)
                }
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
        .accessibilityLabel("Composer options")
    }

    // One consolidated runtime pill: Effort + featured models + Speed as flat sections.
    // The full model list opens in a sheet so we avoid nested SwiftUI Menus, which
    // can self-dismiss when their label is tapped from inside the parent menu.
    private var runtimeMenu: some View {
        Menu {
            Section("Effort") {
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

            Section("Change model") {
                if isLoadingModels {
                    Text("Loading models...")
                } else if orderedModelOptions.isEmpty {
                    Text("No models available")
                } else {
                    ForEach(featuredModelOptions, id: \.id) { model in
                        Button {
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            runtimeActions.selectModel(model.id)
                        } label: {
                            modelMenuRow(for: model)
                        }
                    }

                    if hasNonFeaturedModels {
                        Button("Other models") {
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            DispatchQueue.main.async {
                                showsAllModelsSheet = true
                            }
                        }
                    }
                }
            }

            if runtimeState.supportsFastMode {
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
            }
        } label: {
            composerMenuLabel(
                title: compactRuntimeTitle,
                leadingImageName: runtimeState.showsSpeedBadgeInModelMenu ? "bolt.fill" : nil,
                leadingImageIsSystem: true
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
        .foregroundStyle(Color(.plan))
    }

    private var compactRuntimeTitle: String {
        "\(compactModelTitle) \(runtimeState.selectedReasoningTitle)"
    }

    // Strips the GPT- prefix and converts remaining dashes to spaces so the
    // pill keeps the family suffix (Codex, Spark, mini, ...) instead of erasing it.
    private var compactModelTitle: String {
        let stripped: String
        if selectedModelTitle.lowercased().hasPrefix("gpt-") {
            stripped = String(selectedModelTitle.dropFirst("GPT-".count))
        } else {
            stripped = selectedModelTitle
        }
        return stripped.replacingOccurrences(of: "-", with: " ")
    }

    // Toggling Fast Mode from the plus menu mirrors the runtime speed menu without adding another visible pill.
    private func toggleFastMode() {
        runtimeActions.selectServiceTier(runtimeState.isSelectedServiceTier(.fast) ? nil : .fast)
    }

    private var fastModePlusMenuIconName: String {
        runtimeState.isSelectedServiceTier(.fast) ? "bolt.fill" : "bolt"
    }

    @ViewBuilder
    private func modelMenuRow(for model: CodexModelOption) -> some View {
        modelMenuRow(
            title: TurnComposerMetaMapper.modelTitle(for: model),
            isSelected: selectedModelID == model.id,
            supportsFastMode: modelSupportsFastMode(model)
        )
    }

    @ViewBuilder
    private func modelMenuRow(
        title: String,
        isSelected: Bool,
        supportsFastMode: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            if supportsFastMode {
                Image(systemName: CodexServiceTier.fast.iconName)
            }
            Text(title)
        }
    }

    // Mirrors the bridge-provided runtime capability instead of guessing from the model name.
    private func modelSupportsFastMode(_ model: CodexModelOption) -> Bool {
        return model.supportsServiceTier(.fast)
    }

    // The runtime menu inlines only a few "headline" models to stay compact; the
    // rest live behind the "See all models…" sheet. The currently selected model
    // is always pinned so the user never loses sight of it.
    private static let featuredModelIdentifiers: Set<String> = [
        "gpt-5.5",
        "gpt-5.4",
    ]

    private var featuredModelOptions: [CodexModelOption] {
        var seenIDs = Set<String>()
        var result: [CodexModelOption] = []

        func append(_ model: CodexModelOption) {
            guard seenIDs.insert(model.id).inserted else { return }
            result.append(model)
        }

        for model in orderedModelOptions where Self.matchesFeaturedIdentifier(model) {
            append(model)
        }
        if let selected = orderedModelOptions.first(where: { $0.id == selectedModelID }) {
            append(selected)
        }
        return result
    }

    private var hasNonFeaturedModels: Bool {
        orderedModelOptions.contains { model in
            !featuredModelOptions.contains(where: { $0.id == model.id })
        }
    }

    private static func matchesFeaturedIdentifier(_ model: CodexModelOption) -> Bool {
        let normalizedID = model.id.lowercased()
        let normalizedModel = model.model.lowercased()
        return featuredModelIdentifiers.contains(normalizedID)
            || featuredModelIdentifiers.contains(normalizedModel)
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

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingModels {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if models.isEmpty {
                    ContentUnavailableView(
                        "No models available",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Reconnect to your local Codex bridge to refresh the model list.")
                    )
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
            Image(systemName: model.id == selectedModelID ? "checkmark.circle.fill" : "circle")
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
                            .font(AppFont.system(size: 11, weight: .regular))
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
