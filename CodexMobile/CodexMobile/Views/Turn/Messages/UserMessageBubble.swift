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
    private static let darkColoredBubbleOpacity = 0.7

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
                    .font(AppFont.caption2())
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
    }

    private var selectedUserBubbleColor: UserBubbleColor {
        UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
    }

    // Softens saturated palettes in dark mode without muting the neutral/default choices.
    private func userBubbleBackground(for bubbleColor: UserBubbleColor) -> Color {
        guard colorScheme == .dark else {
            return bubbleColor.bubbleBackground(for: colorScheme)
        }

        switch bubbleColor {
        case .default, .black:
            return bubbleColor.bubbleBackground(for: colorScheme)
        default:
            return Color(uiColor: bubbleColor.uiColor).opacity(Self.darkColoredBubbleOpacity)
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
            userBubbleText(renderModel.text, bubbleColor: bubbleColor)
        } else {
            UserBubbleTextBlock(
                contentIdentity: message.id,
                rawText: renderModel.text,
                contentResetKey: renderModel.textFingerprint
            ) {
                userBubbleText(renderModel.text, bubbleColor: bubbleColor)
            }
        }
    }

    private func userBubbleText(_ rawText: String, bubbleColor: UserBubbleColor) -> some View {
        UserBubbleInlineMarkdownText(
            rawText,
            foreground: bubbleColor.bubbleForeground(for: colorScheme)
        )
            .font(AppFont.body())
    }
}

private struct UserBubbleRenderModel: Equatable {
    let text: String
    let textFingerprint: String
    let chips: [TurnMentionChipRef]
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
        var replacements: [Replacement] = []
        var replacedChipIDs: Set<String> = []

        if normalizedText.contains("@") || normalizedText.contains("$"),
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
                replacements.append(Replacement(range: match.range, text: chip.displayLabel + parsed.trailingPunctuation))
                replacedChipIDs.insert(chip.id)
            }
        }

        // Chips render in their own strip; keep the bubble text to the user's prose only.
        let displayText = cleanedText(
            replacing: replacements,
            in: normalizedText
        )
        return UserBubbleRenderModel(
            text: displayText,
            textFingerprint: TurnTextCacheKey.stableFingerprint(for: displayText),
            chips: chips
        )
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
        let triggerRange = match.range(at: 1)
        let tokenRange = match.range(at: 2)
        guard triggerRange.location != NSNotFound,
              tokenRange.location != NSNotFound else {
            return nil
        }

        let trigger = nsText.substring(with: triggerRange)
        let rawToken = nsText.substring(with: tokenRange)
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
                previewSection("Skill chip + text") {
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

#Preview("User Bubble — Mention Chips") {
    UserBubblePreviewCatalog()
}
