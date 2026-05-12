// FILE: ThinkingSystemBlock.swift
// Purpose: Renders compact assistant reasoning rows and disclosure sections.
// Layer: View Component
// Exports: ThinkingSystemBlock
// Depends on: SwiftUI, ThinkingDisclosureParser

import SwiftUI

// Centralizes the inline reasoning row so thinking-specific spacing, fonts, and
// disclosure behavior are easy to tune without touching MessageRow.
struct ThinkingSystemBlock: View {
    let messageID: String
    let isStreaming: Bool
    let thinkingText: String
    let thinkingContent: ThinkingDisclosureContent
    let activityPreview: String?

    init(
        messageID: String,
        isStreaming: Bool,
        thinkingText: String,
        thinkingContent: ThinkingDisclosureContent,
        activityPreview: String? = nil
    ) {
        self.messageID = messageID
        self.isStreaming = isStreaming
        self.thinkingText = thinkingText
        self.thinkingContent = thinkingContent
        self.activityPreview = activityPreview
    }

    var body: some View {
        Group {
            // Keep completed reasoning visible too; older builds showed thinking blocks
            // even after stream completion whenever content was present.
            if isStreaming || !thinkingText.isEmpty {
                if let activityPreview {
                    activityPreviewText(activityPreview)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if thinkingText.isEmpty {
                    EmptyView()
                } else {
                    ThinkingDisclosureView(
                        messageID: messageID,
                        content: thinkingContent
                    )
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func activityPreviewText(_ preview: String) -> Text {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Text("") }

        let splitIndex = trimmed.firstIndex(of: " ")
        let leading: String
        let remainder: String

        if let splitIndex {
            leading = String(trimmed[..<splitIndex])
            remainder = String(trimmed[splitIndex...])
        } else {
            leading = trimmed
            remainder = ""
        }

        let capitalised = leading.prefix(1).uppercased() + leading.dropFirst()

        return Text(capitalised)
            .font(AppFont.caption(weight: .medium))
            .foregroundStyle(.secondary)
        +
        Text(remainder)
            .font(AppFont.caption())
            .foregroundStyle(.tertiary)
    }
}

// Owns disclosure state for compact reasoning summaries without invalidating MessageRow.
private struct ThinkingDisclosureView: View {
    let messageID: String
    let content: ThinkingDisclosureContent

    @State private var expandedSectionIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if content.showsDisclosure {
                ForEach(content.sections) { section in
                    sectionDisclosure(section)
                }
            } else if !content.fallbackText.isEmpty {
                detailText(content.fallbackText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: messageID) { _, _ in
            expandedSectionIDs.removeAll()
        }
    }

    private func sectionDisclosure(_ section: ThinkingDisclosureSection) -> some View {
        let isExpanded = expandedSectionIDs.contains(section.id)
        let hasDetail = !section.detail.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasDetail else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedSectionIDs.remove(section.id)
                    } else {
                        expandedSectionIDs.insert(section.id)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(AppFont.system(size: 10, weight: .semibold))
                        .foregroundStyle(hasDetail ? .secondary : .tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)

                    Text(section.title)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, hasDetail {
                detailText(section.detail)
                    .padding(.leading, 18)
                    .transition(.opacity.combined(with: .scale(scale: 1, anchor: .top)))
                    .clipped()
            }
        }
    }

    private func detailText(_ value: String) -> some View {
        Text(runtimeMarkdownText(value))
            .font(AppFont.caption())
            .lineSpacing(2)
            .fontWeight(.regular)
            .foregroundStyle(.secondary.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Parse folded reasoning as inline markdown without routing through LocalizedStringKey interpolation.
    private func runtimeMarkdownText(_ value: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
    }
}

struct TimelineSystemBlockPreviewSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(.systemBackground))
    }
}

@MainActor
private struct ThinkingSystemBlockCompactPreviewHost: View {
    var body: some View {
        TimelineSystemBlockPreviewSurface {
            ThinkingSystemBlock(
                messageID: "preview-thinking-compact",
                isStreaming: true,
                thinkingText: "running rg -n \"Thinking\" CodexMobile/CodexMobile/Views/Turn",
                thinkingContent: ThinkingDisclosureContent(sections: [], fallbackText: "")
            )
        }
    }
}

@MainActor
private struct ThinkingSystemBlockDisclosurePreviewHost: View {
    var body: some View {
        TimelineSystemBlockPreviewSurface {
            ThinkingSystemBlock(
                messageID: "preview-thinking-disclosure",
                isStreaming: false,
                thinkingText: """
                **Tracing timeline rendering**
                The thinking row now lives in its own dedicated view so typography and spacing changes stay local.

                **Checking disclosure typography**
                The selected prose font should be used for the thinking label and section titles instead of monospace.
                """,
                thinkingContent: ThinkingDisclosureContent(
                    sections: [
                        ThinkingDisclosureSection(
                            id: "trace",
                            title: "Tracing timeline rendering",
                            detail: "The thinking row now lives in its own dedicated view so typography and spacing changes stay local."
                        ),
                        ThinkingDisclosureSection(
                            id: "type",
                            title: "Checking disclosure typography",
                            detail: "The selected prose font should be used for the thinking label and section titles instead of monospace."
                        ),
                    ],
                    fallbackText: ""
                )
            )
        }
    }
}

@MainActor
private struct ThinkingSystemBlockRealResponsePreviewHost: View {
    private let rawThinkingText = """
    **Explored 1 file**
    Found the compact thinking block and isolated it into a dedicated view so the UI can be tuned in one place.

    **Checking typography**
    Removed italics and aligned the label with the selected prose font instead of monospace styling.

    **Polishing compact activity state**
    running rg -n "Thinking" CodexMobile/CodexMobile/Views/Turn
    """

    var body: some View {
        let parsed = ThinkingDisclosureParser.parse(from: rawThinkingText)

        return TimelineSystemBlockPreviewSurface {
            ThinkingSystemBlock(
                messageID: "preview-thinking-real-response",
                isStreaming: false,
                thinkingText: ThinkingDisclosureParser.normalizedThinkingContent(from: rawThinkingText),
                thinkingContent: parsed
            )
        }
    }
}

#Preview("Thinking Block - Compact") {
    ThinkingSystemBlockCompactPreviewHost()
}

#Preview("Thinking Block - Disclosure") {
    ThinkingSystemBlockDisclosurePreviewHost()
}

#Preview("Thinking Block - Real Response") {
    ThinkingSystemBlockRealResponsePreviewHost()
}
