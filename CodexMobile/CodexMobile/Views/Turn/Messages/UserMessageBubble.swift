// FILE: UserMessageBubble.swift
// Purpose: Renders user prompt bubbles, attachment previews, mention highlighting, and retry/copy actions.
// Layer: View Component
// Exports: UserMessageBubble
// Depends on: SwiftUI, UIKit, UserAttachmentViews, UserBubbleTextBlock

import SwiftUI
import UIKit

struct UserMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    let message: CodexMessage
    let text: String
    let isRetryAvailable: Bool
    let onRetryUserMessage: (String) -> Void

    @State private var previewImage: PreviewImagePayload?

    var body: some View {
        let bubbleColor = selectedUserBubbleColor
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if !message.attachments.isEmpty {
                    UserAttachmentStrip(attachments: message.attachments) { tappedAttachment in
                        if let image = AttachmentPreviewImageResolver.resolve(tappedAttachment) {
                            previewImage = PreviewImagePayload(image: image)
                        }
                    }
                }

                if !text.isEmpty {
                    UserBubbleTextBlock(
                        contentIdentity: message.id,
                        rawText: text
                    ) {
                        userBubbleText(text, bubbleColor: bubbleColor)
                            .font(AppFont.body())
                            .foregroundStyle(bubbleColor.bubbleForeground(for: colorScheme))
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(bubbleColor.bubbleBackground(for: colorScheme))
                    }
                }

                if let statusText = deliveryStatusText {
                    Text(statusText)
                        .font(AppFont.caption2())
                        .foregroundStyle(message.deliveryState == .failed ? .red : .secondary)
                }
            }
            .contextMenu {
                if !text.isEmpty {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                if isRetryAvailable, !text.isEmpty {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onRetryUserMessage(text)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
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

    private var deliveryStatusText: String? {
        switch message.deliveryState {
        case .pending:
            return "sending..."
        case .failed:
            return "send failed"
        case .confirmed:
            return message.createdAt.formatted(date: .omitted, time: .shortened)
        }
    }

    // Renders inline @file/plugin and $skill mentions inside one AttributedString so large
    // messages do not build an arbitrarily deep SwiftUI Text concatenation chain.
    private func userBubbleText(_ rawText: String, bubbleColor: UserBubbleColor) -> Text {
        let normalizedRawText = SkillReferenceFormatter.replacingSkillReferences(
            in: rawText,
            style: .mentionToken
        )
        let confirmedFileMentions = Set(
            message.fileMentions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map(TurnMessageRegexCache.removingTrailingLineColumnSuffix)
                .filter { !$0.isEmpty }
        )

        guard normalizedRawText.contains("@") || normalizedRawText.contains("$") else {
            return Text(normalizedRawText)
        }

        guard let mentionRegex = TurnMessageRegexCache.userMentionToken else {
            return Text(normalizedRawText)
        }

        let nsText = normalizedRawText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = mentionRegex.matches(in: normalizedRawText, range: fullRange)
        guard !matches.isEmpty else {
            return Text(normalizedRawText)
        }

        return Text(
            userBubbleAttributedText(
                from: normalizedRawText,
                matches: matches,
                nsText: nsText,
                confirmedFileMentions: confirmedFileMentions,
                bubbleColor: bubbleColor
            )
        )
    }

    private func normalizedMentionToken(_ token: String) -> (token: String, trailingPunctuation: String) {
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

    // Keeps long mention-heavy prompts renderable without hitting SwiftUI's recursive
    // ConcatenatedTextStorage resolution path.
    private func userBubbleAttributedText(
        from text: String,
        matches: [NSTextCheckingResult],
        nsText: NSString,
        confirmedFileMentions: Set<String>,
        bubbleColor: UserBubbleColor
    ) -> AttributedString {
        var attributed = AttributedString()
        var cursor = 0

        for match in matches {
            let matchRange = match.range
            let triggerRange = match.range(at: 1)
            let tokenRange = match.range(at: 2)
            guard triggerRange.location != NSNotFound,
                  tokenRange.location != NSNotFound else {
                continue
            }

            if matchRange.location > cursor {
                let plain = nsText.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
                if !plain.isEmpty {
                    attributed.append(AttributedString(plain))
                }
            }

            let trigger = nsText.substring(with: triggerRange)
            let rawToken = nsText.substring(with: tokenRange)
            let (normalizedToken, trailingPunctuation) = normalizedMentionToken(rawToken)
            let fullMatch = nsText.substring(with: matchRange)
            let normalizedConfirmedToken = TurnMessageRegexCache.removingTrailingLineColumnSuffix(from: normalizedToken)
            let isConfirmedFileMention = confirmedFileMentions.contains(normalizedConfirmedToken)
            let isPluginMention = trigger == "@" && isLikelyPluginMention(normalizedToken)
            if trigger == "@", !isConfirmedFileMention, !isPluginMention {
                attributed.append(AttributedString(fullMatch))
                cursor = matchRange.location + matchRange.length
                continue
            }

            if !normalizedToken.isEmpty {
                let displayName: String
                let color: Color

                if trigger == "@", isConfirmedFileMention {
                    let fileName = (normalizedToken as NSString).lastPathComponent
                    displayName = fileName.isEmpty ? normalizedToken : fileName
                    color = bubbleColor.mentionForeground(for: colorScheme, fallback: .blue)
                } else if trigger == "@" {
                    displayName = SkillDisplayNameFormatter.displayName(for: normalizedToken)
                    color = bubbleColor.mentionForeground(for: colorScheme, fallback: .blue)
                } else {
                    displayName = SkillDisplayNameFormatter.displayName(for: normalizedToken)
                    color = bubbleColor.mentionForeground(for: colorScheme, fallback: .indigo)
                }

                var highlightedSegment = AttributedString(displayName)
                highlightedSegment.foregroundColor = color
                attributed.append(highlightedSegment)
            }

            if !trailingPunctuation.isEmpty {
                attributed.append(AttributedString(trailingPunctuation))
            }

            cursor = matchRange.location + matchRange.length
        }

        if cursor < nsText.length {
            attributed.append(AttributedString(nsText.substring(from: cursor)))
        }

        if attributed.characters.isEmpty {
            return AttributedString(text)
        }

        return attributed
    }

    // Keeps plugin coloring to app-style slugs so Swift attributes and scoped build labels stay plain.
    private func isLikelyPluginMention(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = normalized.first,
              first.isLowercase || first.isNumber else {
            return false
        }

        return normalized.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
    }
}
