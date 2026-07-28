// FILE: AllModelsSheet.swift
// Purpose: Full-list model picker sheet opened from "Other models…" in the
//          runtime slider overlay's model menu, and presented from inside that
//          overlay so it stacks on the picker instead of racing its dismissal.
// Layer: View Component
// Exports: AllModelsSheet
// Depends on: SwiftUI, RemodexIcon, AppFont, TurnComposerMetaMapper,
//             CodexModelOption, CodexServiceTier

import SwiftUI

struct AllModelsSheet: View {
    let models: [CodexModelOption]
    let selectedModelID: String?
    let isLoadingModels: Bool
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
                    if model.supportsServiceTier(.fast) {
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
