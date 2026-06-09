// FILE: OpenCodeAllModelsSheet.swift
// Purpose: Uncapped OpenCode model browser via model/list params.full=true (D15).
// Layer: View
// Exports: OpenCodeAllModelsSheet
// Depends on: SwiftUI, CodexService

import SwiftUI

struct OpenCodeAllModelsSheet: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss

    let threadId: String?
    let onSelect: (CodexModelOption) -> Void

    @State private var models: [CodexModelOption] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading all models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn't load models",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if models.isEmpty {
                    ContentUnavailableView(
                        "No models found",
                        systemImage: "cpu",
                        description: Text("Connect OpenCode providers on your Mac and try again.")
                    )
                } else {
                    List(models, id: \.selectionKey) { model in
                        Button {
                            onSelect(model)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(TurnComposerMetaMapper.modelTitle(for: model))
                                    .font(.body)
                                if let provider = model.upstreamProviderDisplayName, !provider.isEmpty {
                                    Text(provider)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("All Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await loadModels()
            }
        }
    }

    private func loadModels() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            models = try await codex.fetchFullOpenCodeModelList(threadId: threadId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}