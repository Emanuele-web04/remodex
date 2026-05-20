// FILE: TurnMentionChips.swift
// Purpose: Single source of truth for mention/action chip UI (composer + timeline).
// Layer: View Component
//
// Modify chip appearance in one place:
//   - `TurnMentionChipTokens`
//   - `TurnMentionChipStyle`
//   - `TurnMentionChip`
//
// Row presets:
//   - `TurnMentionChipRow.composer(...)` — removable composer strip
//   - `TurnMentionChipRow.bubble(...)` / `UserMentionChipStrip` — read-only bubble strip
//   - `TurnComposerMentionChipSections` — all composer mention rows
//
// Exports: TurnMentionChipRef, TurnMentionChip, TurnMentionChipRow, UserMentionChipStrip,
//          TurnComposerMentionChipSections, TurnMentionChipCatalog, SkillDisplayNameFormatter
// Depends on: SwiftUI, TurnComposerCommandState

import SwiftUI

// MARK: - Tokens

enum TurnMentionChipTokens {
    static let iconFont = AppFont.system(size: 12, weight: .semibold)
    static let labelFont = AppFont.subheadline(weight: .medium)
    static let removeFont = AppFont.system(size: 8, weight: .bold)
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 20
    static let removeButtonSize: CGFloat = 14
    static let contentSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 6
    static let fillOpacity: CGFloat = 0.05
    static let removeFillOpacity: CGFloat = 0.14
    static let composerHorizontalPadding: CGFloat = 16
    static let composerFilesTopPadding: CGFloat = 10
    static let composerAccessoryTopPadding: CGFloat = 8
    static let bubbleRowSpacing: CGFloat = 6
}

struct TurnMentionChipStyle: Equatable {
    let symbolName: String
    let tintColor: Color

    static let file = TurnMentionChipStyle(
        symbolName: "chevron.left.forwardslash.chevron.right",
        tintColor: .blue
    )

    static let skill = TurnMentionChipStyle(
        symbolName: "square.stack.3d.up",
        tintColor: .indigo
    )

    static let plugin = TurnMentionChipStyle(
        symbolName: "circle.grid.2x2",
        tintColor: .blue
    )

    static let review = TurnMentionChipStyle(
        symbolName: "checklist",
        tintColor: .teal
    )

    static let subagents = TurnMentionChipStyle(
        symbolName: "point.3.connected.trianglepath.dotted",
        tintColor: .teal
    )

    static let planMode = TurnMentionChipStyle(
        symbolName: "remodex.plan-mode",
        tintColor: Color(.plan)
    )

    static func slashCommand(_ command: TurnComposerSlashCommand) -> TurnMentionChipStyle {
        TurnMentionChipStyle(
            symbolName: command.symbolName,
            tintColor: slashCommandTint(for: command)
        )
    }

    private static func slashCommandTint(for command: TurnComposerSlashCommand) -> Color {
        switch command {
        case .codeReview, .subagents:
            return .teal
        case .compact:
            return .purple
        case .feedback:
            return .pink
        case .fork:
            return .blue
        case .status:
            return .secondary
        }
    }
}

// MARK: - Semantic ref

struct TurnMentionChipRef: Identifiable, Equatable {
    enum Kind: Equatable {
        case file
        case skill
        case plugin
        case slashCommand(TurnComposerSlashCommand)
        case review(TurnComposerReviewTarget)
        case subagents
        case planMode
        case action(TurnMentionChipStyle)
    }

    let kind: Kind
    let label: String
    let identity: String

    var id: String {
        switch kind {
        case .slashCommand(let command):
            return "slash:\(command.rawValue):\(identity)"
        case .review(let target):
            return "review:\(target.rawValue):\(identity)"
        case .action:
            return "action:\(identity)"
        default:
            return "\(kindKey):\(identity)"
        }
    }

    private var kindKey: String {
        switch kind {
        case .file: return "file"
        case .skill: return "skill"
        case .plugin: return "plugin"
        case .slashCommand: return "slash"
        case .review: return "review"
        case .subagents: return "subagents"
        case .planMode: return "plan"
        case .action: return "action"
        }
    }

    var style: TurnMentionChipStyle {
        switch kind {
        case .file:
            return .file
        case .skill:
            return .skill
        case .plugin:
            return .plugin
        case .slashCommand(let command):
            return .slashCommand(command)
        case .review:
            return .review
        case .subagents:
            return .subagents
        case .planMode:
            return .planMode
        case .action(let style):
            return style
        }
    }

    var removeAccessibilityLabel: String {
        switch kind {
        case .file:
            return "Remove file mention"
        case .skill:
            return "Remove skill mention"
        case .plugin:
            return "Remove plugin mention"
        case .slashCommand(let command):
            return "Remove \(command.title)"
        case .review:
            return "Remove code review"
        case .subagents:
            return "Remove subagents"
        case .planMode:
            return "Disable Plan Mode"
        case .action:
            return "Remove action"
        }
    }

    var displayLabel: String {
        switch kind {
        case .skill, .plugin:
            return SkillDisplayNameFormatter.displayName(for: label)
        default:
            return label
        }
    }

    static func file(_ path: String, label: String? = nil) -> TurnMentionChipRef {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = label ?? trimmed.pathDisplayName
        let identity = TurnMessageRegexCache.removingTrailingLineColumnSuffix(from: trimmed).lowercased()
        return TurnMentionChipRef(kind: .file, label: displayLabel, identity: identity)
    }

    static func skill(_ name: String) -> TurnMentionChipRef {
        TurnMentionChipRef(
            kind: .skill,
            label: name,
            identity: name.lowercased()
        )
    }

    static func plugin(_ name: String, label: String? = nil) -> TurnMentionChipRef {
        TurnMentionChipRef(
            kind: .plugin,
            label: label ?? name,
            identity: name.lowercased()
        )
    }

    static func slashCommand(_ command: TurnComposerSlashCommand) -> TurnMentionChipRef {
        TurnMentionChipRef(
            kind: .slashCommand(command),
            label: command.title,
            identity: command.rawValue
        )
    }

    static func review(_ target: TurnComposerReviewTarget) -> TurnMentionChipRef {
        TurnMentionChipRef(
            kind: .review(target),
            label: "Code Review: \(target.title)",
            identity: target.rawValue
        )
    }

    static var subagents: TurnMentionChipRef {
        TurnMentionChipRef(kind: .subagents, label: "Subagents", identity: "subagents")
    }

    static var planMode: TurnMentionChipRef {
        TurnMentionChipRef(kind: .planMode, label: "Plan", identity: "plan")
    }

    static func action(
        title: String,
        symbolName: String,
        tintColor: Color,
        identity: String? = nil
    ) -> TurnMentionChipRef {
        TurnMentionChipRef(
            kind: .action(TurnMentionChipStyle(symbolName: symbolName, tintColor: tintColor)),
            label: title,
            identity: identity ?? title
        )
    }
}

// MARK: - Composer ref mapping

extension Array where Element == TurnComposerMentionedFile {
    var mentionChipRefs: [TurnMentionChipRef] {
        map { TurnMentionChipRef.file($0.path, label: $0.fileName) }
    }

    func mentionID(matching ref: TurnMentionChipRef) -> String? {
        first(where: { TurnMentionChipRef.file($0.path, label: $0.fileName) == ref })?.id
    }
}

extension Array where Element == TurnComposerMentionedSkill {
    var mentionChipRefs: [TurnMentionChipRef] {
        map { TurnMentionChipRef.skill($0.name) }
    }

    func mentionID(matching ref: TurnMentionChipRef) -> String? {
        first(where: { TurnMentionChipRef.skill($0.name) == ref })?.id
    }
}

extension Array where Element == TurnComposerMentionedPlugin {
    var mentionChipRefs: [TurnMentionChipRef] {
        map { TurnMentionChipRef.plugin($0.name, label: $0.displayName) }
    }

    func mentionID(matching ref: TurnMentionChipRef) -> String? {
        first(where: { TurnMentionChipRef.plugin($0.name, label: $0.displayName) == ref })?.id
    }
}

// MARK: - Chip

struct TurnMentionChip: View {
    let ref: TurnMentionChipRef
    var removeAccessibilityLabelOverride: String? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        let style = ref.style
        HStack(spacing: TurnMentionChipTokens.contentSpacing) {
            RemodexIcon.image(systemName: style.symbolName)
                .font(TurnMentionChipTokens.iconFont)
                .foregroundStyle(style.tintColor)

            Text(displayLabel)
                .font(TurnMentionChipTokens.labelFont)
                .foregroundStyle(style.tintColor)
                .lineLimit(1)

            if let onRemove {
                removeButton(tintColor: style.tintColor, action: onRemove)
            }
        }
        .padding(.horizontal, TurnMentionChipTokens.horizontalPadding)
        .padding(.vertical, TurnMentionChipTokens.verticalPadding)
        .background(
            style.tintColor.opacity(TurnMentionChipTokens.fillOpacity),
            in: RoundedRectangle(cornerRadius: TurnMentionChipTokens.cornerRadius)
        )
    }

    private var displayLabel: String {
        ref.displayLabel
    }

    private func removeButton(tintColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RemodexIcon.image(systemName: "xmark")
                .font(TurnMentionChipTokens.removeFont)
                .foregroundStyle(tintColor)
                .frame(width: TurnMentionChipTokens.removeButtonSize, height: TurnMentionChipTokens.removeButtonSize)
                .background(
                    tintColor.opacity(TurnMentionChipTokens.removeFillOpacity),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(removeAccessibilityLabelOverride ?? ref.removeAccessibilityLabel)
    }
}

// MARK: - Row

struct TurnMentionChipRow: View {
    enum Layout {
        /// Wrapping trailing row for the user-bubble column.
        case compact
        /// Horizontally scrolling row for the composer accessory area.
        case scrollLeading
    }

    let chips: [TurnMentionChipRef]
    var layout: Layout = .scrollLeading
    var horizontalPadding: CGFloat = 0
    var topPadding: CGFloat = 0
    var onRemove: ((TurnMentionChipRef) -> Void)? = nil

    var body: some View {
        chipStack
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
    }

    static func composer(
        chips: [TurnMentionChipRef],
        topPadding: CGFloat,
        onRemove: @escaping (TurnMentionChipRef) -> Void
    ) -> TurnMentionChipRow {
        TurnMentionChipRow(
            chips: chips,
            layout: .scrollLeading,
            horizontalPadding: TurnMentionChipTokens.composerHorizontalPadding,
            topPadding: topPadding,
            onRemove: onRemove
        )
    }

    static func bubble(chips: [TurnMentionChipRef]) -> TurnMentionChipRow {
        TurnMentionChipRow(chips: chips, layout: .compact)
    }

    @ViewBuilder
    private var chipStack: some View {
        switch layout {
        case .compact:
            TurnMentionChipFlowLayout(
                horizontalSpacing: TurnMentionChipTokens.rowSpacing,
                verticalSpacing: TurnMentionChipTokens.bubbleRowSpacing
            ) {
                chipViews
            }

        case .scrollLeading:
            ScrollView(.horizontal, showsIndicators: false) {
                chipHStack
            }
            .defaultScrollAnchor(.leading, for: .initialOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chipHStack: some View {
        HStack(spacing: TurnMentionChipTokens.rowSpacing) {
            chipViews
        }
    }

    private var chipViews: some View {
        ForEach(chips) { chip in
            TurnMentionChip(
                ref: chip,
                onRemove: onRemove.map { callback in
                    { callback(chip) }
                }
            )
        }
    }
}

private struct TurnMentionChipFlowLayout: Layout {
    struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = proposal.width ?? contentWidth
        let height = rows.enumerated().reduce(CGFloat(0)) { total, pair in
            total + pair.element.height + (pair.offset > 0 ? verticalSpacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.maxX - row.width
            for item in row.items {
                let origin = CGPoint(x: x, y: y + (row.height - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    // Packs chip-sized subviews into right-aligned rows instead of shrinking labels.
    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width

            if !current.items.isEmpty, proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }

            current.items.append((index, size))
            current.width = current.width == 0 ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }

        return rows
    }
}

// MARK: - Timeline strip

/// Read-only mention chips shown above a sent user bubble.
struct UserMentionChipStrip: View {
    let chips: [TurnMentionChipRef]

    var body: some View {
        TurnMentionChipRow.bubble(chips: chips)
    }
}

// MARK: - Composer sections

struct TurnComposerMentionChipSections: View {
    let state: TurnComposerAccessoryState
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedSkill: (String) -> Void
    let onRemoveMentionedPlugin: (String) -> Void
    let onRemoveComposerReviewSelection: () -> Void
    let onRemoveComposerSubagentsSelection: () -> Void
    let onRemoveComposerPlanModeSelection: () -> Void

    var body: some View {
        Group {
            if state.showsMentionedFiles {
                TurnMentionChipRow.composer(
                    chips: state.composerMentionedFiles.mentionChipRefs,
                    topPadding: TurnMentionChipTokens.composerFilesTopPadding
                ) { ref in
                    guard let fileID = state.composerMentionedFiles.mentionID(matching: ref) else { return }
                    onRemoveMentionedFile(fileID)
                }
            }

            if state.showsMentionedSkills {
                TurnMentionChipRow.composer(
                    chips: state.composerMentionedSkills.mentionChipRefs,
                    topPadding: TurnMentionChipTokens.composerAccessoryTopPadding
                ) { ref in
                    guard let skillID = state.composerMentionedSkills.mentionID(matching: ref) else { return }
                    onRemoveMentionedSkill(skillID)
                }
            }

            if state.showsMentionedPlugins {
                TurnMentionChipRow.composer(
                    chips: state.composerMentionedPlugins.mentionChipRefs,
                    topPadding: TurnMentionChipTokens.composerAccessoryTopPadding
                ) { ref in
                    guard let pluginID = state.composerMentionedPlugins.mentionID(matching: ref) else { return }
                    onRemoveMentionedPlugin(pluginID)
                }
            }

            if state.showsSubagentsSelection {
                TurnMentionChipRow.composer(
                    chips: [.subagents],
                    topPadding: TurnMentionChipTokens.composerAccessoryTopPadding
                ) { _ in
                    onRemoveComposerSubagentsSelection()
                }
            }

            if state.showsPlanModeSelection {
                TurnMentionChipRow.composer(
                    chips: [.planMode],
                    topPadding: TurnMentionChipTokens.composerAccessoryTopPadding
                ) { _ in
                    onRemoveComposerPlanModeSelection()
                }
            }

            if state.showsReviewSelection, let reviewTarget = state.reviewTarget {
                TurnMentionChipRow.composer(
                    chips: [.review(reviewTarget)],
                    topPadding: TurnMentionChipTokens.composerAccessoryTopPadding
                ) { _ in
                    onRemoveComposerReviewSelection()
                }
            }
        }
    }
}

// MARK: - Display names

enum SkillDisplayNameFormatter {
    // Converts slug names like "skill-builder" to "Skill Builder".
    static func displayName(for rawName: String) -> String {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return rawName
        }

        let parts = normalized
            .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "-" || $0 == "_" })
            .map { part in
                let token = String(part)
                return token.prefix(1).uppercased() + token.dropFirst().lowercased()
            }

        guard !parts.isEmpty else {
            return normalized
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Preview catalog

struct TurnMentionChipCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                catalogSection("Files") {
                    chipWrap {
                        TurnMentionChip(ref: .file("src/Views/SidebarView.swift"))
                        TurnMentionChip(ref: .file("src/index.ts"))
                        TurnMentionChip(ref: .file("config.json"))
                    }
                }

                catalogSection("Skills") {
                    chipWrap {
                        TurnMentionChip(ref: .skill("skill-builder"))
                        TurnMentionChip(ref: .skill("check-code"))
                        TurnMentionChip(ref: .skill("frontend-design"))
                    }
                }

                catalogSection("Plugins") {
                    chipWrap {
                        TurnMentionChip(ref: .plugin("linear"))
                        TurnMentionChip(ref: .plugin("github"))
                        TurnMentionChip(ref: .plugin("playwright"))
                    }
                }

                catalogSection("Slash Commands") {
                    chipWrap {
                        ForEach(TurnComposerSlashCommand.allCommands) { command in
                            TurnMentionChip(ref: .slashCommand(command))
                        }
                    }
                }

                catalogSection("Composer Actions") {
                    chipWrap {
                        TurnMentionChip(ref: .subagents)
                        TurnMentionChip(ref: .review(.uncommittedChanges))
                        TurnMentionChip(ref: .review(.baseBranch))
                    }
                }

                catalogSection("Removable") {
                    chipWrap {
                        TurnMentionChip(ref: .file("TurnView.swift")) {}
                        TurnMentionChip(ref: .skill("refactor-code")) {}
                        TurnMentionChip(ref: .plugin("linear")) {}
                        TurnMentionChip(ref: .slashCommand(.codeReview)) {}
                        TurnMentionChip(ref: .review(.uncommittedChanges)) {}
                        TurnMentionChip(ref: .subagents) {}
                    }
                }

                catalogSection("Composer Row") {
                    TurnMentionChipRow.composer(
                        chips: [
                            .file("UserMessageBubble.swift"),
                            .skill("ui-component-extractor"),
                            .plugin("linear"),
                            .subagents,
                        ],
                        topPadding: TurnMentionChipTokens.composerFilesTopPadding,
                        onRemove: { _ in }
                    )
                }

                catalogSection("Bubble Row") {
                    UserBubbleTrailingColumn {
                        UserMentionChipStrip(
                            chips: [
                                .file("TurnMentionChips.swift"),
                                .skill("check-code"),
                                .slashCommand(.compact),
                            ]
                        )
                        Text("can you")
                            .font(AppFont.body())
                            .foregroundStyle(.primary)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TurnMentionChipTokens.composerHorizontalPadding)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func catalogSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.secondary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipWrap<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TurnMentionChipTokens.rowSpacing) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Mention Chips — Catalog") {
    TurnMentionChipCatalog()
}
