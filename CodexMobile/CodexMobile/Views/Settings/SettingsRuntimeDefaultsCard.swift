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

            if showsOpenCodeAgentPicker {
                SettingsMenuPickerRow(
                    title: "OpenCode Agent",
                    value: defaultOpenCodeAgentTitle,
                    options: openCodeAgentPickerOptions,
                    selection: defaultOpenCodeAgentSelection
                )

                Toggle("Discover Mac sessions", isOn: openCodeExternalDiscoveryBinding)

                Text("Show OpenCode sessions started on your Mac in the sidebar.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

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

            if let opencodeRuntime = codex.availableRuntimes.first(where: {
                CodexModelOption.normalizedProvider($0.id) == "opencode"
            }) {
                Text(openCodeRuntimeFootnote(opencodeRuntime))
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                Text("Configure MCP in OpenCode on your Mac — not from Remodex.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard codex.isConnected, codex.isInitialized else { return }
            await codex.refreshRuntimeMetadataSequential()
        }
    }

    private var defaultOpenCodeAgentTitle: String {
        TurnComposerMetaMapper.agentTitle(
            for: codex.defaultOpenCodeAgentId
                ?? codex.availableAgents.first?.id
                ?? "build"
        )
    }

    private var openCodeAgentPickerOptions: [SettingsMenuPickerOption<String>] {
        codex.availableAgents.map {
            SettingsMenuPickerOption(value: $0.id, title: TurnComposerMetaMapper.agentTitle(for: $0.id))
        }
    }

    private func openCodeRuntimeFootnote(_ runtime: RuntimeInfo) -> String {
        let details = runtime.opencode
        let discoveryReason = codex.openCodeProviderDiscoveryReasonCode
            ?? details?.providerDiscoveryReasonCode

        if discoveryReason == "no_connected_providers" {
            return "Connect providers in OpenCode on your Mac."
        }

        if discoveryReason == "unknown" {
            return "OpenCode provider status is unknown. Tap Retry in Settings or the model menu."
        }

        if discoveryReason == "provider_list_failed" {
            return runtime.unavailableReason ?? "OpenCode provider list is unavailable on this Mac."
        }

        if runtime.enabled {
            var summary = ComposerCapabilityCopy.openCodeStatusSummary(
                version: details?.version,
                minVersion: details?.minVersion,
                handoffEnvEnabled: details?.handoffEnvEnabled ?? false
            )
            if discoveryReason == "ok",
               let connected = details?.connectedProviders,
               !connected.isEmpty {
                let names = connected.map(\.displayName).joined(separator: ", ")
                summary += " · Connected on Mac: \(names)"
            } else if let auth = details?.authConfigured {
                summary += auth ? " · Providers connected on Mac" : " · No providers connected on Mac"
            } else {
                summary += " · Provider status unknown"
            }
            if details?.versionBelowMinimum == true {
                summary += " · Upgrade OpenCode on your Mac"
            }
            return summary
        }
        return runtime.unavailableReason ?? "OpenCode is not available on this Mac bridge."
    }

    private var showsOpenCodeAgentPicker: Bool {
        guard let opencodeRuntime = codex.availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        }) else {
            return false
        }
        return opencodeRuntime.enabled && !codex.availableAgents.isEmpty
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
                SettingsMenuPickerOption(value: $0.selectionKey, title: TurnComposerMetaMapper.settingsModelLabel(for: $0))
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
            SettingsMenuPickerOption(value: $0.selectionKey, title: TurnComposerMetaMapper.modelTitle(for: $0))
        }
    }

    private var runtimeModelTitle: String {
        guard let selectedKey = codex.selectedModelOption()?.selectionKey,
              let model = runtimeModelOptions.first(where: { $0.selectionKey == selectedKey }) else {
            return "Auto"
        }
        return TurnComposerMetaMapper.settingsModelLabel(for: model)
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
            get: { codex.selectedModelOption()?.selectionKey ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedModelId(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    private var defaultOpenCodeAgentSelection: Binding<String> {
        Binding(
            get: {
                codex.defaultOpenCodeAgentId
                    ?? codex.availableAgents.first?.id
                    ?? "build"
            },
            set: { codex.setDefaultOpenCodeAgent($0) }
        )
    }

    private var openCodeExternalDiscoveryBinding: Binding<Bool> {
        Binding(
            get: { codex.openCodeExternalDiscoveryEnabled },
            set: { codex.setOpenCodeExternalDiscoveryEnabled($0) }
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
        let codexOnly = codex.availableModels.filter {
            CodexModelOption.normalizedProvider($0.modelProvider) == "codex"
        }
        return TurnComposerMetaMapper.orderedModels(from: codexOnly)
    }

    private var isGitWriterModelPickerEnabled: Bool {
        !gitWriterModelOptions.isEmpty
    }

    private var gitWriterModelSelection: Binding<String> {
        Binding(
            get: { codex.selectedGitWriterModelOption()?.selectionKey ?? gitWriterModelOptions.first?.selectionKey ?? "" },
            set: { codex.setSelectedGitWriterModelId($0.isEmpty ? nil : $0) }
        )
    }
}
