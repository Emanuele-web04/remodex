// FILE: SettingsRuntimeDefaultsCard.swift
// Purpose: Presents default model, reasoning, speed, access, and git-writer settings.
// Layer: Settings UI component
// Exports: SettingsRuntimeDefaultsCard
// Depends on: SwiftUI, CodexService runtime configuration, TurnComposerMetaMapper

import SwiftUI

struct SettingsRuntimeDefaultsCard: View {
    @Environment(CodexService.self) private var codex

    private let runtimeAutoValue = "__AUTO__"
    private let runtimeNormalValue = "__NORMAL__"

    var body: some View {
        SettingsCard(
            title: "Composer Defaults",
            footer: "Used for new chats. Git writer model applies to commit messages and PR drafts."
        ) {
            SettingsMenuPickerRow(
                title: "Model",
                value: runtimeModelTitle,
                options: runtimeModelPickerOptions,
                selection: runtimeModelSelection
            )

            SettingsMenuPickerRow(
                title: "Reasoning",
                value: runtimeReasoningTitle,
                options: runtimeReasoningPickerOptions,
                selection: runtimeReasoningSelection,
                isDisabled: runtimeReasoningOptions.isEmpty
            )

            if codex.selectedModelSupportsServiceTier(.fast) {
                SettingsMenuPickerRow(
                    title: "Speed",
                    value: runtimeServiceTierTitle,
                    options: runtimeServiceTierPickerOptions,
                    selection: runtimeServiceTierSelection
                )
            }

            SettingsMenuPickerRow(
                title: "Access",
                value: runtimeAccessTitle,
                options: runtimeAccessPickerOptions,
                selection: runtimeAccessSelection
            )

            SettingsMenuPickerRow(
                title: "Git Writer",
                value: gitWriterModelTitle,
                options: gitWriterModelPickerOptions,
                selection: gitWriterModelSelection,
                isDisabled: gitWriterModelOptions.isEmpty
            )
        }
    }

    private var runtimeModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    private var runtimeReasoningOptions: [TurnComposerReasoningDisplayOption] {
        TurnComposerMetaMapper.reasoningDisplayOptions(
            from: codex.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
    }

    private var runtimeModelPickerOptions: [SettingsMenuPickerOption<String>] {
        [SettingsMenuPickerOption(value: runtimeAutoValue, title: "Auto")]
            + runtimeModelOptions.map {
                SettingsMenuPickerOption(value: $0.id, title: TurnComposerMetaMapper.modelTitle(for: $0))
            }
    }

    private var runtimeReasoningPickerOptions: [SettingsMenuPickerOption<String>] {
        [SettingsMenuPickerOption(value: runtimeAutoValue, title: "Auto")]
            + runtimeReasoningOptions.map {
                SettingsMenuPickerOption(value: $0.effort, title: $0.title)
            }
    }

    private var runtimeServiceTierPickerOptions: [SettingsMenuPickerOption<String>] {
        [SettingsMenuPickerOption(value: runtimeNormalValue, title: "Normal")]
            + CodexServiceTier.allCases.map {
                SettingsMenuPickerOption(value: $0.rawValue, title: $0.displayName)
            }
    }

    private var runtimeAccessPickerOptions: [SettingsMenuPickerOption<CodexAccessMode>] {
        CodexAccessMode.allCases.map {
            SettingsMenuPickerOption(value: $0, title: $0.displayName)
        }
    }

    private var gitWriterModelPickerOptions: [SettingsMenuPickerOption<String>] {
        gitWriterModelOptions.map {
            SettingsMenuPickerOption(value: $0.id, title: TurnComposerMetaMapper.modelTitle(for: $0))
        }
    }

    private var runtimeModelTitle: String {
        guard let selectedModelId = codex.selectedModelOption()?.id,
              let model = runtimeModelOptions.first(where: { $0.id == selectedModelId }) else {
            return "Auto"
        }
        return TurnComposerMetaMapper.modelTitle(for: model)
    }

    private var runtimeReasoningTitle: String {
        guard let selectedReasoning = codex.selectedReasoningEffort,
              let option = runtimeReasoningOptions.first(where: { $0.effort == selectedReasoning }) else {
            return "Auto"
        }
        return option.title
    }

    private var runtimeServiceTierTitle: String {
        guard let selectedServiceTier = codex.selectedServiceTier else {
            return "Normal"
        }
        return selectedServiceTier.displayName
    }

    private var runtimeAccessTitle: String {
        codex.selectedAccessMode.displayName
    }

    private var gitWriterModelTitle: String {
        guard let selectedModel = codex.selectedGitWriterModelOption()
            ?? gitWriterModelOptions.first else {
            return "Unavailable"
        }
        return TurnComposerMetaMapper.modelTitle(for: selectedModel)
    }

    private var runtimeModelSelection: Binding<String> {
        Binding(
            get: { codex.selectedModelOption()?.id ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedModelId(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    private var runtimeReasoningSelection: Binding<String> {
        Binding(
            get: { codex.selectedReasoningEffort ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedReasoningEffort(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    private var runtimeAccessSelection: Binding<CodexAccessMode> {
        Binding(
            get: { codex.selectedAccessMode },
            set: { codex.setSelectedAccessMode($0) }
        )
    }

    private var runtimeServiceTierSelection: Binding<String> {
        Binding(
            get: { codex.selectedServiceTier?.rawValue ?? runtimeNormalValue },
            set: { selection in
                codex.setSelectedServiceTier(
                    selection == runtimeNormalValue ? nil : CodexServiceTier(rawValue: selection)
                )
            }
        )
    }

    private var gitWriterModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    private var gitWriterModelSelection: Binding<String> {
        Binding(
            get: { codex.selectedGitWriterModelOption()?.id ?? gitWriterModelOptions.first?.id ?? "" },
            set: { codex.setSelectedGitWriterModelId($0.isEmpty ? nil : $0) }
        )
    }
}
