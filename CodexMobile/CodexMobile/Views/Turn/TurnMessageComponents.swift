// FILE: TurnMessageComponents.swift
// Purpose: SwiftUI views for rendering turn messages: MessageRow, ApprovalBanner, and subviews.
// Layer: View Components
// Exports: MessageRow, ApprovalBanner
// Depends on: SwiftUI, Textual, TurnMessageRegexCache, SkillReferenceFormatter,
//   ThinkingDisclosureParser, CodeCommentDirectiveParser, TurnFileChangeSummaryParser,
//   TurnMessageCaches, TurnMarkdownModels, TurnDiffRenderer, CommandExecutionViews

import SwiftUI
import Textual
import UIKit

// Keep Textual selection out of the scrolling timeline. This is shared by both
// plain markdown rows and Mermaid-interleaved markdown segments.
let enablesInlineMarkdownSelectionInTimeline = false

// ─── Message content views ──────────────────────────────────────────

// ─── File-Change Recap UI ─────────────────────────────────────

// MARK: - FileChangeInlineActionRow
// Compact row: small gray action label on top, filename (blue) + +/- counts below.
private struct FileChangeInlineActionRow: View {
    let entry: TurnFileChangeSummaryEntry
    var showActionLabel: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showActionLabel {
                Text(entry.action?.rawValue ?? "Edited")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            HStack(spacing: 6) {
                Text(entry.compactPath)
                    .foregroundStyle(Color.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)

                DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                    .font(AppFont.mono(.caption))
            }
            .font(AppFont.body())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ─── File-Change Action Buttons ─────────────────────────────────────

// MARK: - FileChangeActionButtons
// Pill button below file rows: "Diff +N -M" (opens sheet).
// Owns @State isShowingDiffSheet so MessageRow's Equatable short-circuit stays effective.
private struct FileChangeActionButtons: View {
    let entries: [TurnFileChangeSummaryEntry]
    let bodyText: String
    let messageID: String
    var showInlineCommit: Bool = false

    @Environment(\.inlineCommitAndPushAction) private var commitAction
    @State private var isShowingDiffSheet = false

    var body: some View {
        let totalAdditions = entries.reduce(0) { $0 + $1.additions }
        let totalDeletions = entries.reduce(0) { $0 + $1.deletions }

        HStack(spacing: 10) {
            if !bodyText.isEmpty {
                Button {
                    isShowingDiffSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(AppFont.system(size: 10, weight: .medium))
                        Text("Diff")
                        DiffCountsLabel(additions: totalAdditions, deletions: totalDeletions)
                    }
                    .font(AppFont.mono(.body))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if showInlineCommit, let action = commitAction {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    action()
                } label: {
                    HStack(spacing: 4) {
                        Image("cloud-upload")
                            .renderingMode(.template)
                            // Keep the inline commit CTA visually balanced with the Diff pill beside it.
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                        Text("Commit & Push")
                    }
                    .font(AppFont.mono(.body))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $isShowingDiffSheet) {
            TurnDiffSheet(
                title: "Changes",
                entries: entries,
                bodyText: bodyText,
                messageID: messageID
            )
        }
    }
}

struct MarkdownTextView: View {
    let text: String
    let profile: MarkdownRenderProfile
    var enablesSelection: Bool = false

    var body: some View {
        let transformed = MarkdownTextFormatter.renderableText(from: text, profile: profile)
        // Keep prose on the app font, but let Textual own markdown/code layout to avoid block sizing regressions.
        let baseView = StructuredText(markdown: transformed)
            .font(AppFont.body())
            .textual.structuredTextStyle(.gitHub)

        if enablesSelection {
            baseView
                .textual.textSelection(.enabled)
        } else {
            baseView
        }
    }
}

private struct CodeCommentFindingCard: View {
    let finding: CodeCommentDirectiveFinding

    private var priorityLevel: Int {
        min(max(finding.priority ?? 3, 0), 3)
    }

    private var priorityColor: Color {
        switch priorityLevel {
        case 0:
            return .red
        case 1:
            return .orange
        case 2:
            return .yellow
        default:
            return .blue
        }
    }

    private var fileName: String {
        let basename = (finding.file as NSString).lastPathComponent
        return basename.isEmpty ? finding.file : basename
    }

    private var lineLabel: String? {
        guard let startLine = finding.startLine else { return nil }
        if let endLine = finding.endLine, endLine != startLine {
            return "L\(startLine)-\(endLine)"
        }
        return "L\(startLine)"
    }

    private var confidenceLabel: String? {
        guard let confidence = finding.confidence else { return nil }
        let clamped = min(max(confidence, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("P\(priorityLevel)")
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(priorityColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(priorityColor.opacity(0.12), in: Capsule())

                Text(finding.title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            Text(finding.body)
                .font(AppFont.body())
                .foregroundStyle(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(fileName)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(1)

                if let lineLabel {
                    Text(lineLabel)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }

                if let confidenceLabel {
                    Text(confidenceLabel)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(priorityColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(priorityColor.opacity(0.28), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

enum MarkdownTextFormatter {
    // Applies lightweight markdown cleanup and turns file paths into link-styled labels.
    static func renderableText(from raw: String, profile: MarkdownRenderProfile) -> String {
        MarkdownRenderableTextCache.rendered(raw: raw, profile: profile) {
            let normalizedSkills = SkillReferenceFormatter.replacingSkillReferences(
                in: raw,
                style: .displayName
            )
            let headingNormalized = replaceMatches(
                in: normalizedSkills,
                regex: TurnMessageRegexCache.heading,
                template: "**$1**"
            )
            return linkifyFileReferenceLines(in: headingNormalized, profile: profile)
        }
    }

    private static func linkifyFileReferenceLines(in text: String, profile: MarkdownRenderProfile) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var isInsideFence = false

        let transformed = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                isInsideFence.toggle()
                return line
            }

            guard !isInsideFence else {
                return line
            }

            return linkifyInlineFileReferences(in: line, profile: profile)
        }

        return transformed.joined(separator: "\n")
    }

    private static func linkifyInlineFileReferences(in line: String, profile: MarkdownRenderProfile) -> String {
        switch profile {
        case .assistantProse, .fileChangeSystem:
            break
        }

        var transformedLine = line

        if let fileLinked = linkifyFileReferenceLine(transformedLine), fileLinked != transformedLine {
            transformedLine = fileLinked
        }

        transformedLine = linkifyInlineCodeFileReferences(in: transformedLine)
        return linkifyGenericPathTokens(in: transformedLine)
    }

    private static func linkifyFileReferenceLine(_ line: String) -> String? {
        guard let markerRange = line.range(of: "File:") else {
            return nil
        }

        let prefix = String(line[..<markerRange.lowerBound])
        let rawReference = line[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawReference.isEmpty,
              !rawReference.contains("]("),
              let parsed = parseFileReference(rawReference) else {
            return nil
        }

        return "\(prefix)File: [\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
    }

    private static func linkifyGenericPathTokens(in line: String) -> String {
        guard let regex = TurnMessageRegexCache.genericPath else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let inlineCodeRanges = inlineCodeRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let matchRange = match.range
            guard !rangeOverlapsMarkdownLink(matchRange, linkRanges: linkRanges) else {
                continue
            }
            guard !rangeOverlapsMarkdownLink(matchRange, linkRanges: inlineCodeRanges) else {
                continue
            }
            guard isEligiblePathTokenRange(matchRange, in: nsLine) else {
                continue
            }

            let token = nsLine.substring(with: matchRange)
            guard let parsed = parseFileReference(token) else {
                continue
            }

            let replacement = "[\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
            mutableLine.replaceCharacters(in: matchRange, with: replacement)
        }

        return String(mutableLine)
    }

    // Converts inline-code file refs (`/path/File.swift:42`) into compact markdown links.
    private static func linkifyInlineCodeFileReferences(in line: String) -> String {
        guard let regex = TurnMessageRegexCache.inlineCodeContent else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let fullMatchRange = match.range
            guard !rangeOverlapsMarkdownLink(fullMatchRange, linkRanges: linkRanges) else {
                continue
            }
            guard match.numberOfRanges > 1 else {
                continue
            }

            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound, tokenRange.length > 0 else {
                continue
            }

            let token = nsLine.substring(with: tokenRange)
            guard let parsed = parseFileReference(token) else {
                continue
            }

            let replacement = "[\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
            mutableLine.replaceCharacters(in: fullMatchRange, with: replacement)
        }

        return String(mutableLine)
    }

    private static func markdownLinkRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.markdownLinkRanges(in: line)
    }

    private static func inlineCodeRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.inlineCodeRanges(in: line)
    }

    private static func isEligiblePathTokenRange(_ range: NSRange, in line: NSString) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else {
            return false
        }

        let token = line.substring(with: range)
        if token.hasPrefix("//") {
            return false
        }

        let contextStart = max(0, range.location - 3)
        let contextLength = range.location - contextStart
        let leadingContext = contextLength > 0
            ? line.substring(with: NSRange(location: contextStart, length: contextLength))
            : ""
        if leadingContext.hasSuffix("://") {
            return false
        }

        let previousChar: String = range.location > 0
            ? line.substring(with: NSRange(location: range.location - 1, length: 1))
            : ""
        if token.hasPrefix("/"), isLikelyDomainCharacter(previousChar) {
            return false
        }

        return true
    }

    private static func rangeOverlapsMarkdownLink(_ range: NSRange, linkRanges: [NSRange]) -> Bool {
        TurnMessageRegexCache.rangeOverlaps(range, protectedRanges: linkRanges)
    }

    private static func escapeMarkdownLinkDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func parseFileReference(_ rawReference: String) -> (label: String, destination: String)? {
        var candidate = rawReference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))

        while let last = candidate.last, ",.;)]}".contains(last) {
            candidate.removeLast()
        }

        if candidate.hasPrefix("(") {
            candidate.removeFirst()
        }

        guard candidate.hasPrefix("/") || candidate.contains("/") else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: (candidate as NSString).length)

        var path = candidate
        var lineNumber: String?

        if let lineRegex = TurnMessageRegexCache.filenameWithLine,
           let match = lineRegex.firstMatch(in: candidate, range: fullRange),
           match.numberOfRanges >= 3 {
            let nsCandidate = candidate as NSString
            path = nsCandidate.substring(with: match.range(at: 1))
            lineNumber = nsCandidate.substring(with: match.range(at: 2))
        }

        let basename = (path as NSString).lastPathComponent
        guard !basename.isEmpty else {
            return nil
        }
        guard basename.contains(".") || lineNumber != nil else {
            return nil
        }

        let label: String
        let destination: String
        if let lineNumber {
            label = "\(basename) (line \(lineNumber))"
            destination = "\(path):\(lineNumber)"
        } else {
            label = basename
            destination = path
        }

        return (label, destination)
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression?,
        template: String
    ) -> String {
        TurnMessageRegexCache.replaceMatches(in: text, regex: regex, template: template)
    }

    private static func isLikelyDomainCharacter(_ value: String) -> Bool {
        guard value.count == 1, let scalar = value.unicodeScalars.first else {
            return false
        }
        if CharacterSet.alphanumerics.contains(scalar) {
            return true
        }
        return scalar == "."
    }
}

private struct UserAttachmentThumbnailView: View {
    let attachment: CodexImageAttachment
    private let side: CGFloat = 70
    private let cornerRadius: CGFloat = 12

    var body: some View {
        if let image = thumbnailUIImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .frame(width: side, height: side)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        }
    }

    private var thumbnailUIImage: UIImage? {
        guard !attachment.thumbnailBase64JPEG.isEmpty,
              let data = Data(base64Encoded: attachment.thumbnailBase64JPEG) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private struct UserAttachmentStrip: View {
    let attachments: [CodexImageAttachment]
    let onTap: (CodexImageAttachment) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(attachments) { attachment in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onTap(attachment)
                } label: {
                    UserAttachmentThumbnailView(attachment: attachment)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private enum AttachmentPreviewImageResolver {
    // Uses full payload data URL first, then falls back to thumbnail for resilience.
    static func resolve(_ attachment: CodexImageAttachment) -> UIImage? {
        if let payloadDataURL = attachment.payloadDataURL,
           let imageData = decodeImageDataFromDataURL(payloadDataURL),
           let image = UIImage(data: imageData) {
            return image
        }

        guard !attachment.thumbnailBase64JPEG.isEmpty,
              let thumbnailData = Data(base64Encoded: attachment.thumbnailBase64JPEG) else {
            return nil
        }
        return UIImage(data: thumbnailData)
    }

    private static func decodeImageDataFromDataURL(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let metadata = dataURL[..<commaIndex].lowercased()
        guard metadata.hasPrefix("data:image"),
              metadata.contains(";base64") else {
            return nil
        }

        let payloadStart = dataURL.index(after: commaIndex)
        return Data(base64Encoded: String(dataURL[payloadStart...]))
    }
}

// ─── Message row ────────────────────────────────────────────────────

struct MessageRow: View, Equatable {
    let message: CodexMessage
    let isRetryAvailable: Bool
    let onRetryUserMessage: (String) -> Void
    var assistantRevertPresentation: AssistantRevertPresentation? = nil
    /// When non-nil, this message is the last in an assistant block and
    /// a copy button should be shown. The string is the aggregated block text.
    var copyBlockText: String? = nil
    var showInlineCommit: Bool = false
    // Disables timer-driven adornments while the user reads older content.
    var showsStreamingAnimations: Bool = true
    @Environment(\.assistantRevertAction) private var assistantRevertAction
    @Environment(\.subagentOpenAction) private var subagentOpenAction
    @State private var previewImage: PreviewImagePayload?
    @State private var selectableTextSheet: SelectableMessageTextSheetState?

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isRetryAvailable == rhs.isRetryAvailable
            && lhs.assistantRevertPresentation == rhs.assistantRevertPresentation
            && lhs.copyBlockText == rhs.copyBlockText
            && lhs.showInlineCommit == rhs.showInlineCommit
            && lhs.showsStreamingAnimations == rhs.showsStreamingAnimations
    }

    // Computed once per body evaluation and reused by all sub-views.
    private var displayText: String {
        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isStreaming {
            let placeholderTexts: Set<String> = [
                "...",
                "Thinking...",
                "Applying file changes...",
                "Updating...",
                "Coordinating agents...",
                "Planning...",
                "Waiting for input...",
            ]
            if trimmedText.isEmpty || placeholderTexts.contains(trimmedText) {
                return ""
            }
        }
        return trimmedText
    }

    var body: some View {
        let text = displayText
        let renderModel = MessageRowRenderModelCache.model(for: message, displayText: text)
        Group {
            switch message.role {
            case .user:
                userBubble(text: text)
            case .assistant:
                assistantView(text: text, renderModel: renderModel)
            case .system:
                VStack(alignment: .leading, spacing: 8) {
                    systemView(text: text, renderModel: renderModel)
                    if let blockText = copyBlockText {
                        CopyBlockButton(text: blockText)
                    }
                }
            }
        }
        .sheet(item: $selectableTextSheet) { sheet in
            SelectableMessageTextSheet(state: sheet)
        }
    }

    private func userBubble(text: String) -> some View {
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
                    userBubbleText(text)
                        .font(AppFont.body())
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(.tertiarySystemFill).opacity(0.8))
                                .stroke(.secondary.opacity(0.08))
                        }
                }

                if let statusText = deliveryStatusText {
                    Text(statusText)
                        .font(AppFont.caption2())
                        .foregroundStyle(message.deliveryState == .failed ? .red : .secondary)
                }
            }
            .contextMenu {
                if message.role == .user, !text.isEmpty {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                if isRetryAvailable, message.role == .user, !text.isEmpty {
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

    // Renders inline @file and $skill mentions as highlighted tokens inside user bubbles.
    private func userBubbleText(_ rawText: String) -> Text {
        let normalizedRawText = SkillReferenceFormatter.replacingSkillReferences(
            in: rawText,
            style: .mentionToken
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

        var segments: [Text] = []
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
                    segments.append(Text(plain))
                }
            }

            let trigger = nsText.substring(with: triggerRange)
            let rawToken = nsText.substring(with: tokenRange)
            let (normalizedToken, trailingPunctuation) = normalizedMentionToken(rawToken)
            if !normalizedToken.isEmpty {
                if trigger == "@" {
                    let fileName = (normalizedToken as NSString).lastPathComponent
                    let displayName = fileName.isEmpty ? normalizedToken : fileName
                    segments.append(Text(displayName).foregroundColor(.blue))
                } else {
                    let displayName = SkillDisplayNameFormatter.displayName(for: normalizedToken)
                    segments.append(Text(displayName).foregroundColor(.indigo))
                }
            }

            if !trailingPunctuation.isEmpty {
                segments.append(Text(trailingPunctuation))
            }

            cursor = matchRange.location + matchRange.length
        }

        if cursor < nsText.length {
            segments.append(Text(nsText.substring(from: cursor)))
        }

        guard let first = segments.first else {
            return Text(normalizedRawText)
        }

        return segments.dropFirst().reduce(first) { $0 + $1 }
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

    private func assistantView(text: String, renderModel: MessageRowRenderModel) -> some View {
        let commentContent = renderModel.codeCommentContent
        let bodyText = commentContent?.fallbackText ?? text
        let mermaidContent = renderModel.mermaidContent

        return VStack(alignment: .leading, spacing: 8) {
            if let commentContent, commentContent.hasFindings {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(commentContent.findings) { finding in
                        CodeCommentFindingCard(finding: finding)
                    }
                }
            }

            if !bodyText.isEmpty {
                if let mermaidContent {
                    MermaidMarkdownContentView(content: mermaidContent)
                } else {
                    MarkdownTextView(
                        text: bodyText,
                        profile: .assistantProse,
                        enablesSelection: enablesInlineMarkdownSelectionInTimeline
                    )
                }
            }

            if message.isStreaming && showsStreamingAnimations {
                TypingIndicator()
            }

            if let assistantRevertPresentation {
                assistantRevertButton(presentation: assistantRevertPresentation)
            }

            if let blockText = copyBlockText {
                CopyBlockButton(text: blockText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            selectableTextActions(text: text, usesMarkdownSelection: true)
        }
    }

    @ViewBuilder
    private func systemView(text: String, renderModel: MessageRowRenderModel) -> some View {
        switch message.kind {
        case .thinking:
            thinkingSystemView(renderModel: renderModel)
        case .fileChange:
            fileChangeSystemView(text: text, renderModel: renderModel)
        case .commandExecution:
            commandExecutionSystemView(text: text, renderModel: renderModel)
        case .subagentAction:
            subagentActionSystemView(text: text)
        case .plan:
            PlanSystemCard(message: message)
        case .userInputPrompt:
            if let request = message.structuredUserInputRequest {
                StructuredUserInputCard(request: request)
                    .id(request.requestID)
            } else {
                defaultSystemView(text: text)
            }
        case .chat:
            defaultSystemView(text: text)
        }
    }

    @ViewBuilder
    private func thinkingSystemView(renderModel: MessageRowRenderModel) -> some View {
        let thinkingText = renderModel.thinkingText ?? ""
        let thinkingContent = renderModel.thinkingContent ?? ThinkingDisclosureContent(sections: [], fallbackText: "")
        let activityPreview = ThinkingDisclosureParser.compactActivityPreview(fromNormalizedText: thinkingText)
        Group {
            // Keep completed reasoning visible too; older builds showed thinking blocks
            // even after stream completion whenever content was present.
            if message.isStreaming || !thinkingText.isEmpty {
                if let activityPreview {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thinking...")
                            .font(AppFont.mono(.caption))
                            .fontWeight(.regular)
                            .italic()
                            .foregroundStyle(.secondary.opacity(0.9))

                        Text(activityPreview)
                            .font(AppFont.mono(.caption))
                            .fontWeight(.regular)
                            .italic()
                            .foregroundStyle(.secondary.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Thinking...")
                            .font(AppFont.mono(.caption))
                            .fontWeight(.regular)
                            .italic()
                            .foregroundStyle(.secondary.opacity(0.9))

                        if !thinkingText.isEmpty {
                            ThinkingDisclosureView(
                                messageID: message.id,
                                content: thinkingContent
                            )
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fileChangeSystemView(text: String, renderModel: MessageRowRenderModel) -> some View {
        let renderState = renderModel.fileChangeState ?? FileChangeRenderState(
            summary: nil,
            actionEntries: [],
            bodyText: text
        )
        let actionEntries = renderState.actionEntries
        let hasActionRows = !actionEntries.isEmpty
        let allEntries = hasActionRows ? actionEntries : (renderState.summary?.entries ?? [])
        let grouped = renderModel.fileChangeGroups

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(grouped, id: \.key) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.key)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary.opacity(0.6))

                    ForEach(group.entries) { entry in
                        FileChangeInlineActionRow(entry: entry, showActionLabel: false)
                    }
                }
            }

            // Buttons + sheet live in a child view so environment reads
            // don't invalidate the parent MessageRow's Equatable short-circuit.
            if !message.isStreaming, !allEntries.isEmpty {
                FileChangeActionButtons(
                    entries: allEntries,
                    bodyText: renderState.bodyText,
                    messageID: message.id,
                    showInlineCommit: showInlineCommit
                )
            }

            if message.isStreaming && showsStreamingAnimations {
                TypingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            selectableTextActions(text: text, usesMarkdownSelection: false)
        }
    }

    private func defaultSystemView(text: String) -> some View {
        Text(text)
            .font(AppFont.footnote())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contextMenu {
                selectableTextActions(text: text, usesMarkdownSelection: false)
            }
    }

    @ViewBuilder
    private func commandExecutionSystemView(text: String, renderModel: MessageRowRenderModel) -> some View {
        if message.role == .system,
           message.kind == .commandExecution,
           !text.isEmpty,
           let commandStatus = renderModel.commandStatus {
            CommandExecutionStatusCard(status: commandStatus, itemId: message.itemId)
        } else {
            defaultSystemView(text: text)
        }
    }

    @ViewBuilder
    private func subagentActionSystemView(text: String) -> some View {
        if let subagentAction = message.subagentAction {
            SubagentActionCard(
                parentThreadId: message.threadId,
                action: subagentAction,
                isStreaming: message.isStreaming && showsStreamingAnimations,
                onOpenSubagent: subagentOpenAction
            )
        } else {
            defaultSystemView(text: text)
        }
    }

    private var deliveryStatusText: String? {
        guard message.role == .user else { return nil }

        switch message.deliveryState {
        case .pending:
            return "sending..."
        case .failed:
            return "send failed"
        case .confirmed:
            return message.createdAt.formatted(date: .omitted, time: .shortened)
        }
    }

    private func assistantRevertButton(presentation: AssistantRevertPresentation) -> some View {
        let iconName: String = {
            switch presentation.riskLevel {
            case .safe:
                return "arrow.uturn.backward.circle"
            case .warning:
                return "exclamationmark.circle"
            case .blocked:
                return "exclamationmark.triangle"
            }
        }()
        let accentColor: Color = {
            switch presentation.riskLevel {
            case .safe:
                return .primary
            case .warning:
                return .orange
            case .blocked:
                return .secondary
            }
        }()

        return Button {
            guard presentation.isEnabled else { return }
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            assistantRevertAction?(message)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(AppFont.system(size: 10, weight: .medium))
                    .foregroundStyle(accentColor)
                Text(presentation.title)
                    .lineLimit(1)
            }
            .font(AppFont.mono(.body))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .accessibilityHint(presentation.warningText ?? presentation.helperText ?? "")
    }

    @ViewBuilder
    private func selectableTextActions(text: String, usesMarkdownSelection: Bool) -> some View {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                selectableTextSheet = SelectableMessageTextSheetState(
                    role: message.role,
                    text: trimmedText,
                    usesMarkdownSelection: usesMarkdownSelection
                )
            } label: {
                Label("Select Text", systemImage: "text.cursor")
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                UIPasteboard.general.string = trimmedText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct SelectableMessageTextSheetState: Identifiable {
    let id = UUID()
    let role: CodexMessageRole
    let text: String
    let usesMarkdownSelection: Bool

    var title: String {
        switch role {
        case .assistant:
            return "Assistant Message"
        case .system:
            return "System Message"
        case .user:
            return "Message"
        }
    }
}

private struct SelectableMessageTextSheet: View {
    let state: SelectableMessageTextSheetState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.usesMarkdownSelection {
                        MarkdownTextView(
                            text: state.text,
                            profile: .assistantProse,
                            enablesSelection: true
                        )
                    } else {
                        Text(state.text)
                            .font(AppFont.body())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// Owns disclosure state for compact reasoning summaries without invalidating MessageRow.
private struct ThinkingDisclosureView: View {
    let messageID: String
    let content: ThinkingDisclosureContent

    @State private var expandedSectionIDs: Set<String> = []

    var body: some View {
        return VStack(alignment: .leading, spacing: 8) {
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
                        .font(AppFont.mono(.caption))
                        .fontWeight(.bold)
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
        Text(.init(value))
            .font(AppFont.mono(.caption))
            .lineSpacing(2)
            .fontWeight(.regular)
            .italic()
            .foregroundStyle(.secondary.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandExecutionStatusCard: View {
    let status: CommandExecutionStatusModel
    let itemId: String?
    @Environment(CodexService.self) private var codex
    @State private var isShowingDetailSheet = false

    var body: some View {
        CommandExecutionCardBody(
            command: status.command,
            statusLabel: status.statusLabel,
            accent: status.accent
        )
            .contentShape(Rectangle())
            .onTapGesture {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                isShowingDetailSheet = true
            }
            .sheet(isPresented: $isShowingDetailSheet) {
                CommandExecutionDetailSheet(status: status, details: detailModel)
                    .presentationDetents([.fraction(0.35), .medium])
            }
    }

    private var detailModel: CommandExecutionDetails? {
        guard let itemId else { return nil }
        return codex.commandExecutionDetailsByItemID[itemId]
    }
}

// ─── Subagent UI — see SubagentViews.swift ──────────────────────

// ─── Shared diff counts ─────────────────────────────────────────────

/// Compact `+N -M` label in green/red. Caller applies `.font()`.
struct DiffCountsLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)")
                .foregroundStyle(Color.green)
            Text("-\(deletions)")
                .foregroundStyle(Color.red)
        }
    }
}

// ─── Typing indicator ───────────────────────────────────────────────

struct TypingIndicator: View {
    private let trackWidth: CGFloat = 26
    private let trackHeight: CGFloat = 6
    private let highlightWidth: CGFloat = 16
    private let duration: TimeInterval = 1.0
    @State private var shimmerOffset: CGFloat = -21

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: trackWidth, height: trackHeight)
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.secondary.opacity(0.04),
                                Color.secondary.opacity(0.42),
                                Color.secondary.opacity(0.04),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: highlightWidth, height: trackHeight)
                    .offset(x: shimmerOffset)
            }
            .clipShape(Capsule(style: .continuous))
        .onAppear {
            guard shimmerOffset < 0 else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                shimmerOffset = 21
            }
        }
        .accessibilityHidden(true)
    }
}

// ─── Approval banner ────────────────────────────────────────────────

struct ApprovalBanner: View {
    let request: CodexApprovalRequest
    let isLoading: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval request", systemImage: "checkmark.shield")
                .font(AppFont.subheadline())

            if let command = request.command, !command.isEmpty {
                Text(command)
                    .font(AppFont.mono(.callout))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(AppFont.callout())
            } else {
                Text(request.method)
                    .font(AppFont.callout())
            }

            HStack {
                Button("Approve", action: {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onApprove()
                })
                    .buttonStyle(.borderedProminent)

                Button("Deny", role: .destructive, action: {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onDecline()
                })
                    .buttonStyle(.bordered)
            }
            .disabled(isLoading)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
