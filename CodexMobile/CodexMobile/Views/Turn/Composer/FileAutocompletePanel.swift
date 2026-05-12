// FILE: FileAutocompletePanel.swift
// Purpose: Autocomplete dropdown for @-file and @-plugin mentions.
// Layer: View Component
// Exports: FileAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle

import SwiftUI

struct FileAutocompletePanel: View {
    let items: [CodexFuzzyFileMatch]
    var pluginItems: [CodexPluginMetadata] = []
    let isLoading: Bool
    var isLoadingPlugins: Bool = false
    let query: String
    var pluginQuery: String = ""
    let onSelect: (CodexFuzzyFileMatch) -> Void
    var onSelectPlugin: (CodexPluginMetadata) -> Void = { _ in }

    private static let rowHeight: CGFloat = 38
    private static let maxVisibleRows = 6
    private static let sectionHeaderHeight: CGFloat = 24

    private static func visibleListHeight(for count: Int) -> CGFloat {
        rowHeight * CGFloat(min(count, maxVisibleRows))
    }

    private var visibleRowCount: Int {
        var count = items.count + pluginItems.count
        if isLoading {
            count += 1
        }
        if isLoadingPlugins {
            count += 1
        }
        if !pluginItems.isEmpty {
            count += 1
        }
        if !items.isEmpty || isLoading {
            count += 1
        }
        return count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty && pluginItems.isEmpty && !isLoading && !isLoadingPlugins {
                let effectiveQuery = pluginQuery.isEmpty ? query : pluginQuery
                Text("No files or plugins for @\(effectiveQuery)")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isLoadingPlugins {
                            loadingRow("Loading plugins...")
                        }

                        if !pluginItems.isEmpty {
                            sectionHeader("Plugins")
                        }

                        ForEach(pluginItems) { item in
                            Button {
                                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                onSelectPlugin(item)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "circle.grid.2x2")
                                        .font(AppFont.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.displayTitle)
                                            .font(AppFont.subheadline(weight: .semibold))
                                            .lineLimit(1)

                                        Text(item.shortDescription ?? item.mentionPath)
                                            .font(AppFont.caption())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
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

                        if !items.isEmpty || isLoading {
                            sectionHeader("Files")
                        }

                        if isLoading {
                            loadingRow("Searching files...")
                        }

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
                .frame(height: Self.visibleListHeight(for: visibleRowCount))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(4)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Self.sectionHeaderHeight, alignment: .bottomLeading)
    }

    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight, alignment: .leading)
    }
}
