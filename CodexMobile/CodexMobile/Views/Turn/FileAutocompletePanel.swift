// FILE: FileAutocompletePanel.swift
// Purpose: Autocomplete dropdown for @-file mentions.
// Layer: View Component
// Exports: FileAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle

import SwiftUI

struct FileAutocompletePanel: View {
    let items: [CodexFuzzyFileMatch]
    let isLoading: Bool
    let query: String
    let onSelect: (CodexFuzzyFileMatch) -> Void

    private static let rowHeight: CGFloat = 38
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
                    Text("Searching files...")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if items.isEmpty {
                Text("No files for @\(query)")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.fileName)
                                        .font(AppFont.subheadline(weight: .semibold))
                                        .lineLimit(1)

                                    Text(item.path)
                                        .font(AppFont.caption())
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
}
