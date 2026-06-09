// FILE: SkillAutocompletePanel.swift
// Purpose: Autocomplete dropdown for $- and /-skill mentions (V2: sectioned by scope, provider badges, count header, See all).
// Layer: View Component
// Exports: SkillAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle, SkillDisplayNameFormatter, RuntimeProviderLogoView, ComposerAutocompletePanelHeight

import SwiftUI

struct SkillAutocompletePanel: View {
    let items: [CodexSkillMetadata]
    let totalCount: Int
    let isLoading: Bool
    let query: String
    let trigger: String
    let onSelect: (CodexSkillMetadata) -> Void
    var onSeeAll: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var sectionHeaderHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var countHeaderHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var seeAllRowHeight: CGFloat = 32

    private var groupedByScope: [(scopeKey: String, skills: [CodexSkillMetadata])] {
        Self.groupedByScope(items)
    }

    static func groupedByScope(_ items: [CodexSkillMetadata]) -> [(scopeKey: String, skills: [CodexSkillMetadata])] {
        let grouped = Dictionary(grouping: items) { $0.scope ?? "global" }
        let preferredOrder = ["project", "global"]
        var result: [(String, [CodexSkillMetadata])] = []
        for key in preferredOrder {
            if let sks = grouped[key], !sks.isEmpty {
                result.append((key, sks.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
            }
        }
        let remainingKeys = grouped.keys.filter { !preferredOrder.contains($0) }.sorted()
        for key in remainingKeys {
            if let sks = grouped[key], !sks.isEmpty {
                result.append((key, sks.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
            }
        }
        return result
    }

    static func scopeTitle(for key: String) -> String {
        switch key {
        case "project": return "Project"
        case "global": return "Global"
        default: return key.capitalized
        }
    }

    var body: some View {
        panelContent(screenHeight: ComposerAutocompletePanelHeight.screenHeightForCap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func panelContent(screenHeight: CGFloat) -> some View {
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
                if !items.isEmpty {
                    HStack(spacing: 6) {
                        Text("Skills")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("(\(totalCount))")
                            .font(AppFont.subheadline(weight: .regular))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: countHeaderHeight, alignment: .center)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedByScope, id: \.scopeKey) { group in
                            sectionHeader(scopeTitle(for: group.scopeKey))
                            ForEach(group.skills) { skill in
                                skillRow(skill)
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: inlineListHeight(screenHeight: screenHeight))
                .clipped()

                if !items.isEmpty {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onSeeAll?()
                    } label: {
                        HStack(spacing: 6) {
                            Text("See all")
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(Color.indigo)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: seeAllRowHeight, alignment: .center)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AutocompleteRowButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineListHeight(screenHeight: CGFloat) -> CGFloat {
        let sectionAllowance = ComposerAutocompletePanelHeight.sectionHeaderAllowance(
            sectionCount: groupedByScope.count,
            sectionHeaderHeight: sectionHeaderHeight
        )
        return ComposerAutocompletePanelHeight.cappedListHeight(
            rowHeight: rowHeight,
            headerHeights: sectionAllowance,
            rowCount: items.count,
            screenHeight: screenHeight
        )
    }

    private func skillRow(_ skill: CodexSkillMetadata) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onSelect(skill)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(skill.providerIds, id: \.self) { providerID in
                            RuntimeProviderLogoView(provider: providerID, size: 14)
                        }
                    }

                    Text(SkillDisplayNameFormatter.displayName(for: skill.name))
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.indigo)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(skill.name)
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
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AutocompleteRowButtonStyle())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: sectionHeaderHeight, alignment: .bottomLeading)
    }

    private func scopeTitle(for key: String) -> String {
        Self.scopeTitle(for: key)
    }

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

#if DEBUG
#Preview("V2 sections + badges + count + See all (project/global, mixed providers)") {
    VStack(spacing: 16) {
        SkillAutocompletePanel(
            items: [
                CodexSkillMetadata(
                    name: "review",
                    description: "Review recent diffs and suggest improvements",
                    path: "/repo/.agents/skills/review/SKILL.md",
                    scope: "project",
                    provider: "codex",
                    providers: ["codex", "opencode"],
                    enabled: true
                ),
                CodexSkillMetadata(
                    name: "check-code",
                    description: "Static analysis for security and style",
                    path: "/repo/.agents/skills/check-code/SKILL.md",
                    scope: "project",
                    provider: "codex",
                    enabled: true
                ),
                CodexSkillMetadata(
                    name: "lint-global",
                    description: nil,
                    path: "/Users/me/.codex/skills/lint/SKILL.md",
                    scope: "global",
                    provider: "opencode",
                    enabled: true
                ),
            ],
            totalCount: 3,
            isLoading: false,
            query: "",
            trigger: "$",
            onSelect: { _ in }
        )
        .frame(width: 320)

        SkillAutocompletePanel(
            items: [],
            totalCount: 0,
            isLoading: false,
            query: "foo",
            trigger: "$",
            onSelect: { _ in }
        )
        .frame(width: 320)
    }
    .padding()
    .previewLayout(.sizeThatFits)
}

#Preview("V2 loading state") {
    SkillAutocompletePanel(
        items: [],
        totalCount: 0,
        isLoading: true,
        query: "re",
        trigger: "$",
        onSelect: { _ in }
    )
    .frame(width: 320)
    .padding()
    .previewLayout(.sizeThatFits)
}
#endif