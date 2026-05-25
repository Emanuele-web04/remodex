// FILE: SkillAutocompletePanel.swift
// Purpose: Autocomplete dropdown for $- and /-skill mentions.
// Layer: View Component
// Exports: SkillAutocompletePanel
// Depends on: SwiftUI, RemodexIcon, AutocompleteRowButtonStyle, SkillDisplayNameFormatter

import SwiftUI

struct SkillAutocompletePanel: View {
    let items: [CodexSkillMetadata]
    let isLoading: Bool
    let query: String
    let trigger: String
    let onSelect: (CodexSkillMetadata) -> Void

    private static let rowHeight: CGFloat = 50
    // Keep the floating composer menu compact above the iOS keyboard.
    private static let maxVisibleRows = 4

    private static func visibleListHeight(for count: Int) -> CGFloat {
        rowHeight * CGFloat(min(count, maxVisibleRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching skills...")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if items.isEmpty, !query.isEmpty {
                Text("No skills for \(trigger)\(query)")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { skill in
                            Button {
                                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                onSelect(skill)
                            } label: {
                                HStack(spacing: 10) {
                                    skillIcon

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(SkillDisplayNameFormatter.displayName(for: skill.name))
                                            .font(AppFont.subheadline(weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if let description = Self.descriptionLabel(from: skill.description) {
                                            Text(description)
                                                .font(AppFont.caption2())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                    }

                                    Spacer(minLength: 8)

                                    Text(skill.name)
                                        .font(AppFont.footnote())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Self.rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(AutocompleteRowButtonStyle())
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: Self.visibleListHeight(for: items.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(4)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 4)
    }

    // MARK: - Private

    private var skillIcon: some View {
        RemodexIcon.image(systemName: "remodex.skill")
            .font(AppFont.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 22)
    }

    static func descriptionLabel(from rawDescription: String?) -> String? {
        guard let rawDescription else { return nil }
        let normalized = rawDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
