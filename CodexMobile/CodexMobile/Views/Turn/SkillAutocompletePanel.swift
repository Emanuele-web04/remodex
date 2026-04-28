// FILE: SkillAutocompletePanel.swift
// Purpose: Autocomplete dropdown for $-skill mentions.
// Layer: View Component
// Exports: SkillAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle, SkillDisplayNameFormatter

import SwiftUI

struct SkillAutocompletePanel: View {
    let items: [CodexSkillMetadata]
    let isLoading: Bool
    let query: String
    let onSelect: (CodexSkillMetadata) -> Void

    private static let rowHeight: CGFloat = 50
    private static let maxVisibleRows = 6

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
            } else if items.isEmpty {
                Text("No skills for $\(query)")
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
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text("$\(skill.name)")
                                            .font(AppFont.subheadline(weight: .semibold))
                                            .foregroundStyle(Color.indigo)
                                            .lineLimit(1)

                                        Spacer(minLength: 8)

                                        Text(SkillDisplayNameFormatter.displayName(for: skill.name))
                                            .font(AppFont.footnote())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    if let description = Self.descriptionLabel(from: skill.description) {
                                        Text(description)
                                            .font(AppFont.caption2())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
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

    static func descriptionLabel(from rawDescription: String?) -> String? {
        guard let rawDescription else { return nil }
        let normalized = rawDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
