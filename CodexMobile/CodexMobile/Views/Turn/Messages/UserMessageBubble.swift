// FILE: UserMessageBubble.swift
// Purpose: Renders user prompt bubbles, attachment previews, mention chips, and retry/copy actions.
// Layer: View Component
// Exports: UserMessageBubble
// Depends on: SwiftUI, UIKit, UserAttachmentViews, UserBubbleLayout, UserBubbleTextBlock, UserBubbleInlineMarkdownText

import SwiftUI
import UIKit

struct UserMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue
    private static let bubbleCornerRadius: CGFloat = 22
    private static let darkColoredBubbleOpacity = 0.4
    private static let lightColoredBubbleOpacity = 0.1

    let message: CodexMessage
    let text: String
    let actionText: String
    var isProgressiveTextWindow: Bool = false
    let isRetryAvailable: Bool
    let onRetryUserMessage: (String) -> Void

    @State private var previewImage: PreviewImagePayload?

    var body: some View {
        let bubbleColor = selectedUserBubbleColor
        let renderModel = UserBubbleRenderModelCache.model(for: message, text: text)
        UserBubbleTrailingColumn {
            if !message.attachments.isEmpty {
                UserAttachmentStrip(attachments: message.attachments) { tappedAttachment in
                    if let image = AttachmentPreviewImageResolver.resolve(tappedAttachment) {
                        previewImage = PreviewImagePayload(image: image)
                    }
                }
            }

            if !renderModel.chips.isEmpty {
                UserMentionChipStrip(chips: renderModel.chips)
            }

            if !renderModel.text.isEmpty {
                userBubbleTextContent(renderModel, bubbleColor: bubbleColor)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background {
                        RoundedRectangle(cornerRadius: Self.bubbleCornerRadius, style: .continuous)
                            .fill(userBubbleBackground(for: bubbleColor))
                    }
            }

            if let statusText = deliveryStatusText {
                Text(statusText)
                    .font(AppFont.caption())
                    .foregroundStyle(message.deliveryState == .failed ? .red : .secondary)
            }
        }
        .contextMenu {
            if !actionText.isEmpty {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    UIPasteboard.general.string = actionText
                } label: {
                    RemodexIcon.menuLabel("Copy", systemName: "doc.on.doc")
                }
            }
            if isRetryAvailable, !actionText.isEmpty {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onRetryUserMessage(actionText)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
        .fullScreenCover(item: $previewImage) { payload in
            ZoomableImagePreviewScreen(
                payload: payload,
                onDismiss: { previewImage = nil }
            )
        }
        .modifier(UserBubbleSendAppearance(isEnabled: isFreshLocalSend))
    }

    // Only a just-sent optimistic row animates in. History rows arrive confirmed
    // (or old enough), so thread opens and scroll-backs never replay the effect.
    private var isFreshLocalSend: Bool {
        message.deliveryState == .pending
            && Date().timeIntervalSince(message.createdAt) < 3
    }

    private var selectedUserBubbleColor: UserBubbleColor {
        UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
    }

    // Softens saturated palettes into a tint without muting the neutral/default choices.
    private func userBubbleBackground(for bubbleColor: UserBubbleColor) -> Color {
        switch bubbleColor {
        case .default, .black:
            return bubbleColor.bubbleBackground(for: colorScheme)
        default:
            let opacity = colorScheme == .dark ? Self.darkColoredBubbleOpacity : Self.lightColoredBubbleOpacity
            return Color(uiColor: bubbleColor.uiColor).opacity(opacity)
        }
    }

    // In light mode the colored bubbles are a soft tint, so the text takes the full saturated color for contrast.
    private func userBubbleForeground(for bubbleColor: UserBubbleColor) -> Color {
        switch bubbleColor {
        case .default, .black:
            return bubbleColor.bubbleForeground(for: colorScheme)
        default:
            return colorScheme == .dark
                ? bubbleColor.bubbleForeground(for: colorScheme)
                : Color(uiColor: bubbleColor.uiColor)
        }
    }

    private var deliveryStatusText: String? {
        switch message.deliveryState {
        case .pending:
            return "sending..."
        case .failed:
            return "Failed"
        case .confirmed:
            return message.formattedTimelineTime()
        }
    }

    @ViewBuilder
    private func userBubbleTextContent(_ renderModel: UserBubbleRenderModel, bubbleColor: UserBubbleColor) -> some View {
        if isProgressiveTextWindow {
            userBubbleText(renderModel, bubbleColor: bubbleColor, isCollapsed: false)
        } else {
            UserBubbleTextBlock(
                contentIdentity: message.id,
                rawText: renderModel.text,
                contentResetKey: renderModel.textFingerprint,
                collapsesWithLineLimit: !renderModel.usesBlockMarkdown
            ) { isCollapsed in
                userBubbleText(renderModel, bubbleColor: bubbleColor, isCollapsed: isCollapsed)
            }
        }
    }

    // Simple prompts keep the lightweight inline renderer; block-level markdown
    // (fences, headings, lists, quotes, tables) takes the assistant pipeline.
    @ViewBuilder
    private func userBubbleText(
        _ renderModel: UserBubbleRenderModel,
        bubbleColor: UserBubbleColor,
        isCollapsed: Bool
    ) -> some View {
        let foreground = userBubbleForeground(for: bubbleColor)
        if renderModel.usesBlockMarkdown {
            // While collapsed, lay out only a bounded preview instead of the full
            // message clipped to bubble height; expanding renders the full text.
            MarkdownTextView(
                text: isCollapsed
                    ? UserBubbleCollapsedMarkdownPreview.previewText(for: renderModel.text)
                    : renderModel.text,
                profile: .userProse,
                constrainsToAvailableWidth: true,
                linkColor: foreground
            )
            .foregroundStyle(foreground)
            .tint(foreground)
        } else {
            if renderModel.segments.isEmpty {
                UserBubbleInlineMarkdownText(renderModel.text, foreground: foreground)
                    .font(AppFont.body())
            } else {
                UserBubbleInlineSkillText(
                    renderModel.segments,
                    foreground: foreground,
                    skillForeground: bubbleColor == .default ? .blue : foreground
                )
                    .font(AppFont.body())
            }
        }
    }
}

// iMessage-style send reveal: fade + slight rise + scale from the composer corner.
// Render-only (opacity/scaleEffect/offset), so the row claims its full height on
// insertion and the timeline's scroll anchoring and caches see zero layout churn.
private struct UserBubbleSendAppearance: ViewModifier {
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasRevealed = false

    private var isConcealed: Bool {
        isEnabled && !hasRevealed
    }

    func body(content: Content) -> some View {
        content
            .opacity(isConcealed ? 0 : 1)
            .scaleEffect(
                isConcealed && !reduceMotion ? 0.9 : 1,
                anchor: .bottomTrailing
            )
            .offset(y: isConcealed && !reduceMotion ? 10 : 0)
            .onAppear {
                guard isEnabled, !hasRevealed else { return }
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.34, dampingFraction: 0.82)
                withAnimation(animation) {
                    hasRevealed = true
                }
            }
    }
}

enum UserBubbleInlineSegment: Equatable {
    case text(String)
    case skillMention(name: String, displayLabel: String)
}

private struct UserBubbleRenderModel: Equatable {
    let text: String
    let textFingerprint: String
    let chips: [TurnMentionChipRef]
    let usesBlockMarkdown: Bool
    let segments: [UserBubbleInlineSegment]
}

enum UserBubbleRenderModelCache {
    private static let cache = BoundedCache<String, UserBubbleRenderModel>(maxEntries: 512)

    fileprivate static func model(for message: CodexMessage, text: String) -> UserBubbleRenderModel {
        let displayFingerprint = TurnTextCacheKey.stableFingerprint(for: text)
        let fileMentionsKey = message.fileMentions
            .map { TurnTextCacheKey.stableFingerprint(for: $0) }
            .joined(separator: ",")
        let skillMentionsKey = message.skillMentions
            .map { TurnTextCacheKey.stableFingerprint(for: $0) }
            .joined(separator: ",")
        let pluginMentionsKey = message.pluginMentions
            .map { TurnTextCacheKey.stableFingerprint(for: $0) }
            .joined(separator: ",")
        let key = [
            message.id,
            "\(message.textRenderSignature.byteCount):\(message.textRenderSignature.revision)",
            displayFingerprint,
            fileMentionsKey,
            skillMentionsKey,
            pluginMentionsKey,
        ].joined(separator: "|")

        return cache.getOrSet(key) {
            UserBubbleMentionExtractor.renderModel(
                text: text,
                displayFingerprint: displayFingerprint,
                fileMentions: message.fileMentions,
                skillMentions: message.skillMentions,
                pluginMentions: message.pluginMentions
            )
        }
    }

    static func reset() {
        cache.removeAll()
    }
}

private enum UserBubbleMentionExtractor {
    private struct Replacement {
        let range: NSRange
        let text: String
    }

    private static let repeatedHorizontalWhitespace = try? NSRegularExpression(pattern: #"[ \t]{2,}"#)

    static func renderModel(
        text rawText: String,
        displayFingerprint: String,
        fileMentions: [String],
        skillMentions: [String] = [],
        pluginMentions: [String] = []
    ) -> UserBubbleRenderModel {
        var chips: [TurnMentionChipRef] = []
        var seenChipIDs: Set<String> = []
        var selectedChipsByToken: [String: TurnMentionChipRef] = [:]

        for mention in fileMentions {
            let trimmed = mention.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let chip = TurnMentionChipRef.file(trimmed)
            appendChip(chip, to: &chips, seenChipIDs: &seenChipIDs)
            selectedChipsByToken[mentionLookupKey(trigger: "@", token: trimmed)] = chip
            selectedChipsByToken[mentionLookupKey(trigger: "@", token: chip.displayLabel)] = chip
        }

        for mention in skillMentions {
            let trimmed = mention.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let chip = TurnMentionChipRef.skill(trimmed)
            appendChip(chip, to: &chips, seenChipIDs: &seenChipIDs)
            selectedChipsByToken[mentionLookupKey(trigger: "$", token: trimmed)] = chip
            selectedChipsByToken[mentionLookupKey(trigger: "/", token: trimmed)] = chip
        }

        for mention in pluginMentions {
            let trimmed = mention.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let chip = TurnMentionChipRef.plugin(trimmed)
            appendChip(chip, to: &chips, seenChipIDs: &seenChipIDs)
            selectedChipsByToken[mentionLookupKey(trigger: "@", token: trimmed)] = chip
        }

        let normalizedText = SkillReferenceFormatter.replacingSkillReferences(
            in: rawText,
            style: .mentionToken
        )
        var nonSkillReplacements: [Replacement] = []

        if normalizedText.contains("@") || normalizedText.contains("$") || normalizedText.contains("/"),
           let mentionRegex = TurnMessageRegexCache.userMentionToken {
            let nsText = normalizedText as NSString
            let matches = mentionRegex.matches(
                in: normalizedText,
                range: NSRange(location: 0, length: nsText.length)
            )

            for match in matches {
                guard let parsed = parsedMention(match: match, in: nsText) else {
                    continue
                }
                let lookupKey = mentionLookupKey(trigger: parsed.trigger, token: parsed.token)
                guard let chip = selectedChipsByToken[lookupKey] else { continue }
                guard chip.kind != .skill else { continue }
                nonSkillReplacements.append(
                    Replacement(range: match.range, text: chip.displayLabel + parsed.trailingPunctuation)
                )
            }
        }

        let intermediateText = cleanedText(
            replacing: nonSkillReplacements,
            in: normalizedText
        )
        let usesBlockMarkdown = UserBubbleBlockMarkdownDetector.containsBlockMarkdown(intermediateText)
        let inlineResult = skillInlineResult(
            in: intermediateText,
            selectedChipsByToken: selectedChipsByToken,
            createsSegments: !usesBlockMarkdown
        )
        return UserBubbleRenderModel(
            text: inlineResult.displayText,
            textFingerprint: TurnTextCacheKey.stableFingerprint(for: inlineResult.displayText),
            chips: chips.filter { !inlineResult.inlineSkillChipIDs.contains($0.id) },
            usesBlockMarkdown: usesBlockMarkdown,
            segments: inlineResult.segments
        )
    }

    private static func skillInlineResult(
        in text: String,
        selectedChipsByToken: [String: TurnMentionChipRef],
        createsSegments: Bool
    ) -> (displayText: String, segments: [UserBubbleInlineSegment], inlineSkillChipIDs: Set<String>) {
        guard let regex = TurnMessageRegexCache.userMentionToken else {
            return (text, [], [])
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var replacements: [Replacement] = []
        var segments: [UserBubbleInlineSegment] = []
        var inlineSkillChipIDs: Set<String> = []
        var cursor = 0

        for match in matches {
            guard let parsed = parsedMention(match: match, in: nsText),
                  parsed.trigger == "$" || parsed.trigger == "/",
                  let chip = selectedChipsByToken[
                    mentionLookupKey(trigger: parsed.trigger, token: parsed.token)
                  ],
                  chip.kind == .skill else {
                continue
            }
            replacements.append(
                Replacement(range: match.range, text: chip.displayLabel + parsed.trailingPunctuation)
            )
            guard createsSegments else { continue }

            if match.range.location > cursor {
                segments.append(.text(nsText.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))))
            }
            segments.append(.skillMention(name: parsed.token, displayLabel: chip.displayLabel))
            if !parsed.trailingPunctuation.isEmpty {
                segments.append(.text(parsed.trailingPunctuation))
            }
            cursor = NSMaxRange(match.range)
            inlineSkillChipIDs.insert(chip.id)
        }

        if createsSegments, !inlineSkillChipIDs.isEmpty, cursor < nsText.length {
            segments.append(.text(nsText.substring(from: cursor)))
        }
        let displayText = cleanedText(replacing: replacements, in: text)
        return (displayText, inlineSkillChipIDs.isEmpty ? [] : segments, inlineSkillChipIDs)
    }

    private static func appendChip(
        _ chip: TurnMentionChipRef,
        to chips: inout [TurnMentionChipRef],
        seenChipIDs: inout Set<String>
    ) {
        guard seenChipIDs.insert(chip.id).inserted else { return }
        chips.append(chip)
    }

    private static func parsedMention(
        match: NSTextCheckingResult,
        in nsText: NSString
    ) -> (trigger: String, token: String, trailingPunctuation: String)? {
        let capturePair = [(1, 2), (3, 4)].first { pair in
            pair.0 < match.numberOfRanges
                && pair.1 < match.numberOfRanges
                && match.range(at: pair.0).location != NSNotFound
                && match.range(at: pair.1).location != NSNotFound
        }
        guard let capturePair else {
            return nil
        }

        let trigger = nsText.substring(with: match.range(at: capturePair.0))
        let rawToken = nsText.substring(with: match.range(at: capturePair.1))
        let normalized = normalizedMentionToken(rawToken)
        guard !normalized.token.isEmpty else {
            return nil
        }

        return (trigger, normalized.token, normalized.trailingPunctuation)
    }

    private static func normalizedMentionToken(_ token: String) -> (token: String, trailingPunctuation: String) {
        let punctuationSet = CharacterSet(charactersIn: ".,;:!?)]}")
        let scalars = Array(token.unicodeScalars)

        var splitIndex = scalars.count
        while splitIndex > 0, punctuationSet.contains(scalars[splitIndex - 1]) {
            splitIndex -= 1
        }

        let pathScalars = scalars.prefix(splitIndex)
        let trailingScalars = scalars.suffix(scalars.count - splitIndex)
        let path = String(String.UnicodeScalarView(pathScalars))
        let trailing = String(String.UnicodeScalarView(trailingScalars))
        return (path, trailing)
    }

    // Only selected metadata is allowed to rewrite visible text; raw `$foo`/`@foo` stays literal.
    private static func mentionLookupKey(trigger: String, token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if trigger == "@" {
            normalized = TurnMessageRegexCache.removingTrailingLineColumnSuffix(from: trimmed)
        } else {
            normalized = trimmed
        }
        return "\(trigger):\(normalized.lowercased())"
    }

    private static func cleanedText(replacing replacements: [Replacement], in text: String) -> String {
        guard !replacements.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let mutableText = NSMutableString(string: text)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            mutableText.replaceCharacters(in: replacement.range, with: replacement.text)
        }

        let collapsed = TurnMessageRegexCache.replaceMatches(
            in: String(mutableText),
            regex: repeatedHorizontalWhitespace,
            template: " "
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Previews

private struct UserBubblePreviewCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                previewSection("Inline skill + text") {
                    bubblePreview(
                        text: "can you $check-code",
                        skillMentions: ["check-code"],
                        actionText: "can you $check-code",
                        bubbleColor: .purple
                    )
                }

                previewSection("Skill + file + plugin") {
                    bubblePreview(
                        text: "review this module @TurnView.swift $check-code @linear",
                        fileMentions: ["TurnView.swift"],
                        skillMentions: ["check-code"],
                        pluginMentions: ["linear"],
                        actionText: "review this module @TurnView.swift $check-code @linear",
                        bubbleColor: .indigo
                    )
                }

                previewSection("Long text wraps") {
                    bubblePreview(
                        text: "can you review this module and explain the risky parts before I merge these local changes? @TurnView.swift $check-code",
                        fileMentions: ["TurnView.swift"],
                        skillMentions: ["check-code"],
                        actionText: "can you review this module and explain the risky parts before I merge these local changes? @TurnView.swift $check-code",
                        bubbleColor: .indigo
                    )
                }

                previewSection("Text only") {
                    bubblePreview(
                        text: "can you help me refactor this?",
                        actionText: "can you help me refactor this?"
                    )
                }

                previewSection("Slash command + skill") {
                    bubblePreview(
                        text: "/review run on local changes $frontend-design",
                        skillMentions: ["frontend-design"],
                        actionText: "/review run on local changes $frontend-design",
                        bubbleColor: .blue
                    )
                }

                previewSection("Block markdown") {
                    bubblePreview(
                        text: """
                        Fix this snippet:

                        ```swift
                        // TODO: guard against nil
                        let value = cache[key]!
                        ```

                        Then check:
                        - the reconnect path
                        - the pairing flow
                        """,
                        actionText: "Fix this snippet",
                        bubbleColor: .green
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func previewSection<Content: View>(
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

    private func bubblePreview(
        text: String,
        fileMentions: [String] = [],
        skillMentions: [String] = [],
        pluginMentions: [String] = [],
        actionText: String,
        bubbleColor: UserBubbleColor = .default
    ) -> some View {
        UserMessageBubble(
            message: CodexMessage(
                id: "preview-\(titleFingerprint(text, skillMentions, pluginMentions))",
                threadId: "preview-thread",
                role: .user,
                text: text,
                fileMentions: fileMentions,
                skillMentions: skillMentions,
                pluginMentions: pluginMentions,
                deliveryState: .confirmed
            ),
            text: text,
            actionText: actionText,
            isRetryAvailable: false,
            onRetryUserMessage: { _ in }
        )
        .defaultAppStorage(previewDefaults(for: bubbleColor))
    }

    private func previewDefaults(for color: UserBubbleColor) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "user-bubble-preview-\(color.rawValue)") ?? .standard
        defaults.set(color.rawValue, forKey: UserBubbleColor.storageKey)
        return defaults
    }

    private func titleFingerprint(
        _ text: String,
        _ skills: [String],
        _ plugins: [String]
    ) -> String {
        ([text] + skills + plugins).joined(separator: "-")
    }
}

#Preview("User Bubble — Inline Skills") {
    UserBubblePreviewCatalog()
}
