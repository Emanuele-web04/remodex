// FILE: BridgeSkillsFullListSheet.swift
// Purpose: Full skills picker sheet opened from SkillAutocompletePanel “See all” (PR6).
// Layer: View Component
// Exports: BridgeSkillsFullListSheet
// Depends on: SwiftUI, SkillAutocompletePanel, SkillDisplayNameFormatter, RuntimeProviderLogoView

import SwiftUI

struct BridgeSkillsFullListSheet: View {
    let items: [CodexSkillMetadata]
    let onSelect: (CodexSkillMetadata) -> Void
    let onDismiss: () -> Void

    private var groupedByScope: [(scopeKey: String, skills: [CodexSkillMetadata])] {
        SkillAutocompletePanel.groupedByScope(items)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No skills",
                        systemImage: "dollarsign.circle",
                        description: Text("No skills match this search.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groupedByScope, id: \.scopeKey) { group in
                                Text(SkillAutocompletePanel.scopeTitle(for: group.scopeKey))
                                    .font(AppFont.caption(weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)

                                ForEach(group.skills) { skill in
                                    Button {
                                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                        onSelect(skill)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 8) {
                                                HStack(spacing: 4) {
                                                    ForEach(skill.providerIds, id: \.self) { providerID in
                                                        RuntimeProviderLogoView(
                                                            provider: providerID,
                                                            size: 14
                                                        )
                                                    }
                                                }

                                                Text(SkillDisplayNameFormatter.displayName(for: skill.name))
                                                    .font(AppFont.subheadline(weight: .semibold))
                                                    .foregroundStyle(Color.indigo)

                                                Spacer(minLength: 8)

                                                Text(skill.name)
                                                    .font(AppFont.footnote())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }

                                            if let description = SkillAutocompletePanel.descriptionLabel(from: skill.description) {
                                                Text(description)
                                                    .font(AppFont.caption2())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}