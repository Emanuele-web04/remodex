// FILE: TurnMessageComponents.swift
// Purpose: SwiftUI views for rendering turn messages: MessageRow, ApprovalBanner, and subviews.
// Layer: View Components
// Exports: MessageRow, ApprovalBanner
// Depends on: SwiftUI, Textual, TurnMessageRegexCache, SkillReferenceFormatter,
//   ThinkingDisclosureParser, CodeCommentDirectiveParser, TurnFileChangeSummaryParser,
//   TurnMessageCaches, TurnMarkdownModels, TurnDiffRenderer, CommandExecutionViews

import ImageIO
import SwiftUI
import Textual
import UIKit

// Keep Textual selection out of the scrolling timeline. This is shared by both
// plain markdown rows and Mermaid-interleaved markdown segments.
let enablesInlineMarkdownSelectionInTimeline = false

// Normalizes streaming placeholders once so assistant rows do not render transient status text
// as if it were final message content.
func timelineDisplayText(for message: CodexMessage) -> String {
    let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.isStreaming {
        let placeholderTexts: Set<String> = [
            "...",
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

/// Resets the in-memory AttributedString cache that backs ``MarkdownTextView``.
/// Kept for explicit memory recovery without forcing cold parses on every thread switch.
@MainActor
enum MarkdownParseCacheReset {
    static func reset() { CachingMarkdownParser.reset() }
}

// Wraps the default Textual markdown parser with a bounded AttributedString
// cache so Foundation's markdown parser is not re-run when LazyVStack
// recycles a cell on upward scroll.
@MainActor
private struct CachingMarkdownParser: MarkupParser {
    static let shared = CachingMarkdownParser()
    private static let cache = BoundedCache<String, AttributedString>(maxEntries: 128)
    private let inner: AttributedStringMarkdownParser = .markdown()

    func attributedString(for input: String) throws -> AttributedString {
        let key = TurnTextCacheKey.stableKey(namespace: "markdown-parser", text: input)
        if let cached = Self.cache.get(key) {
            return cached
        }
        let result = try inner.attributedString(for: input)
        Self.cache.set(key, value: result)
        return result
    }

    static func reset() {
        cache.removeAll()
    }
}

struct MarkdownTextView: View {
    let text: String
    let profile: MarkdownRenderProfile
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false

    var body: some View {
        let transformed = MarkdownTextFormatter.renderableText(from: text, profile: profile)
        // Keep prose on the app font, but let Textual own markdown/code layout to avoid block sizing regressions.
        // Force code-block overflow to wrap instead of scroll so horizontal ScrollViews
        // inside the timeline do not compete with the sidebar swipe gesture or let
        // the chat feel like a pannable canvas.
        let baseView = StructuredText(transformed, parser: CachingMarkdownParser.shared)
            .font(AppFont.body())
            .textual.structuredTextStyle(.gitHub)
            .textual.overflowMode(.wrap)

        let renderedContent = Group {
            if enablesSelection {
                baseView
                    .textual.textSelection(.enabled)
            } else {
                baseView
            }
        }

        if constrainsToAvailableWidth {
            renderedContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        } else {
            renderedContent
        }
    }
}

private struct StreamingAssistantMarkdownTextView: View {
    let text: String
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false

    @State private var displayedText = ""

    var body: some View {
        let effectiveText = displayedText.isEmpty ? text : displayedText
        let rendered = Text(effectiveText)
            .font(AppFont.body())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)

        let selectable = Group {
            if enablesSelection {
                rendered.textSelection(.enabled)
            } else {
                rendered
            }
        }

        Group {
            if constrainsToAvailableWidth {
                selectable
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                selectable
            }
        }
        .onAppear {
            reconcileDisplayedText(with: text)
        }
        .onChange(of: text) { _, nextText in
            reconcileDisplayedText(with: nextText)
        }
    }

    // Keep the streaming row append-oriented; the finalized row returns to Textual markdown.
    private func reconcileDisplayedText(with nextText: String) {
        guard !nextText.isEmpty else {
            displayedText = ""
            return
        }
        if nextText.hasPrefix(displayedText) {
            displayedText.append(String(nextText.dropFirst(displayedText.count)))
        } else {
            displayedText = nextText
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
        return scalar == UnicodeScalar(".")
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

private struct AssistantMarkdownImagePreviewButton: View {
    let reference: AssistantMarkdownImageReference
    let currentWorkingDirectory: String?

    @Environment(CodexService.self) private var codex
    @State private var isLoading = false
    @State private var previewImage: PreviewImagePayload?
    @State private var previewError: String?

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            loadPreview()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                            .font(AppFont.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.displayTitle)
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(reference.fileName)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(AppFont.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator).opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .fullScreenCover(item: $previewImage) { payload in
            ZoomableImagePreviewScreen(
                payload: payload,
                onDismiss: { previewImage = nil }
            )
        }
        .alert("Image Preview", isPresented: previewErrorIsPresented, actions: {
            Button("OK", role: .cancel) {
                previewError = nil
            }
        }, message: {
            Text(previewError ?? "")
        })
    }

    private func loadPreview() {
        guard !isLoading else { return }
        isLoading = true

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let cachedPreview = await WorkspaceImagePreviewCache.shared.cachedPreview(forPath: reference.path)
                let result = try await codex.readWorkspaceImage(
                    path: reference.path,
                    cwd: currentWorkingDirectory,
                    cachedMetadata: cachedPreview?.metadata
                )
                if result.isNotModified, let cachedPreview {
                    previewImage = PreviewImagePayload(
                        image: cachedPreview.payload.image,
                        title: cachedPreview.metadata.fileName.isEmpty ? reference.fileName : cachedPreview.metadata.fileName
                    )
                    return
                }

                let decodedImage = try await WorkspaceImagePreviewCache.shared.preview(for: result)
                previewImage = PreviewImagePayload(
                    image: decodedImage.image,
                    title: result.fileName.isEmpty ? reference.fileName : result.fileName
                )
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    private var previewErrorIsPresented: Binding<Bool> {
        Binding(
            get: { previewError != nil },
            set: { isPresented in
                if !isPresented {
                    previewError = nil
                }
            }
        )
    }
}

// ─── Message row ────────────────────────────────────────────────────

private struct UserBubbleTextBlock<Content: View>: View {
    private static var collapseLineLimit: Int { 10 }
    private static var collapseCharacterThreshold: Int { 360 }
    private static var collapseNewlineThreshold: Int { 8 }

    let contentIdentity: String
    let rawText: String
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = false

    private var canCollapse: Bool {
        let newlineCount = rawText.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        return rawText.count > Self.collapseCharacterThreshold
            || newlineCount >= Self.collapseNewlineThreshold
    }

    private var collapseResetKey: Int {
        var hasher = Hasher()
        hasher.combine(contentIdentity)
        hasher.combine(rawText)
        return hasher.finalize()
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            content()
                .lineLimit(canCollapse ? (isExpanded ? nil : Self.collapseLineLimit) : nil)

            if canCollapse {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: collapseResetKey) { _, _ in
            isExpanded = false
        }
    }
}

struct MessageRow: View, Equatable {

    let message: CodexMessage
    let isRetryAvailable: Bool
    let onRetryUserMessage: (String) -> Void
    // Keeps the end-of-block accessory aligned with the active assistant turn.
    var assistantBlockAccessoryState: AssistantBlockAccessoryState? = nil
    var planSessionSource: CodexPlanSessionSource? = nil
    var allowsAssistantPlanFallbackRecovery: Bool = false
    var assistantTurnCompleted: Bool = false
    var threadMessagesForPlanMatching: [CodexMessage] = []
    var currentWorkingDirectory: String? = nil
    // Narrow token for inferred-plan fallback invalidation; this changes only when the
    // relevant native structured prompts change, not on every unrelated service mutation.
    var planMatchingFingerprint: Int = 0
    // Disables timer-driven adornments while the user reads older content.
    var showsStreamingAnimations: Bool = true
    // Passed as init params instead of @Environment so .equatable() can short-circuit
    // without environment rebinding forcing a body re-evaluation on scroll-up cell reuse.
    var assistantRevertAction: ((CodexMessage) -> Void)? = nil
    var subagentOpenAction: ((CodexSubagentThreadPresentation) -> Void)? = nil
    @State private var previewImage: PreviewImagePayload?
    @State private var selectableTextSheet: SelectableMessageTextSheetState?
    @State private var throttledAssistantDisplayText: String?
    @State private var pendingAssistantDisplayText: String?
    @State private var assistantDisplayUpdateTask: Task<Void, Never>?

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isRetryAvailable == rhs.isRetryAvailable
            && lhs.assistantBlockAccessoryState == rhs.assistantBlockAccessoryState
            && lhs.planSessionSource == rhs.planSessionSource
            && lhs.allowsAssistantPlanFallbackRecovery == rhs.allowsAssistantPlanFallbackRecovery
            && lhs.assistantTurnCompleted == rhs.assistantTurnCompleted
            && lhs.currentWorkingDirectory == rhs.currentWorkingDirectory
            && lhs.planMatchingFingerprint == rhs.planMatchingFingerprint
            && lhs.showsStreamingAnimations == rhs.showsStreamingAnimations
    }

    // Computed once per body evaluation and reused by all sub-views.
    private var displayText: String {
        if message.role == .assistant,
           message.isStreaming,
           let throttledAssistantDisplayText {
            return throttledAssistantDisplayText
        }

        return timelineDisplayText(for: message)
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
                    if hasTurnEndActions {
                        turnEndActionButtons
                    }
                    if let assistantBlockAccessoryState {
                        CopyBlockButton(
                            text: assistantBlockAccessoryState.copyText,
                            isRunning: assistantBlockAccessoryState.showsRunningIndicator
                        )
                    }
                }
                // Keep block-end actions pinned left when a system row is the last item in a turn.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $selectableTextSheet) { sheet in
            SelectableMessageTextSheet(state: sheet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear {
            synchronizeAssistantDisplayText(immediate: true)
        }
        .onChange(of: message.text) { _, _ in
            synchronizeAssistantDisplayText(immediate: !message.isStreaming)
        }
        .onChange(of: message.isStreaming) { _, isStreaming in
            synchronizeAssistantDisplayText(immediate: !isStreaming)
        }
        .onDisappear {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
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
                    UserBubbleTextBlock(
                        contentIdentity: message.id,
                        rawText: text
                    ) {
                        userBubbleText(text)
                            .font(AppFont.body())
                    }
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

    // Renders inline @file/plugin and $skill mentions inside one AttributedString so large
    // messages do not build an arbitrarily deep SwiftUI Text concatenation chain.
    private func userBubbleText(_ rawText: String) -> Text {
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
                confirmedFileMentions: confirmedFileMentions
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
        confirmedFileMentions: Set<String>
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
                    color = .blue
                } else if trigger == "@" {
                    displayName = SkillDisplayNameFormatter.displayName(for: normalizedToken)
                    color = .blue
                } else {
                    displayName = SkillDisplayNameFormatter.displayName(for: normalizedToken)
                    color = .indigo
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

    private func assistantView(text: String, renderModel: MessageRowRenderModel) -> some View {
        let commentContent = renderModel.codeCommentContent
        let bodyText = commentContent?.fallbackText ?? text
        let mermaidContent = renderModel.mermaidContent
        let shouldParseStructuredAssistantContent = !message.isStreaming
        let assistantProposedPlanCandidate = shouldParseStructuredAssistantContent
            && commentContent == nil && mermaidContent == nil
            ? (message.proposedPlan ?? CodexProposedPlanParser.parse(from: bodyText))
            : nil
        let currentPlanSessionSource = planSessionSource
        let isNativePlanSession = currentPlanSessionSource != nil && currentPlanSessionSource != .compatibilityFallback
        let proposedPlan = !isNativePlanSession
            ? (assistantProposedPlanCandidate
                ?? (
                    commentContent == nil
                        && mermaidContent == nil
                        && currentPlanSessionSource == .compatibilityFallback
                        && InferredPlanQuestionnaireParser.parseAssistantMessage(bodyText) == nil
                    ? CodexProposedPlanParser.parseAssistantFallback(from: bodyText)
                            : nil
                ))
            : nil
        let renderedPlanText = assistantProposedPlanCandidate == nil
            ? bodyText
            : (
                CodexProposedPlanParser.containsEnvelope(in: bodyText)
                    ? (CodexProposedPlanParser.removingEnvelope(from: bodyText) ?? "")
                    : ""
            )
        let inferredQuestionnaire = shouldParseStructuredAssistantContent && commentContent == nil
            ? resolvedInferredPlanQuestionnaire(
                bodyText: bodyText,
                message: message,
                threadMessages: threadMessagesForPlanMatching,
                shouldRecoverFallback: allowsAssistantPlanFallbackRecovery,
                parse: InferredPlanQuestionnaireParser.parseAssistantMessage
            )
            : nil
        let visibleAssistantText = renderedPlanText
        let suppressNativeProposedPlanShell = isNativePlanSession
            && assistantProposedPlanCandidate != nil
            && visibleAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inferredQuestionnaire == nil
            && mermaidContent == nil
        // Prefer copying the exact assistant block the user can see instead of the
        // whole non-user turn aggregate assembled by the timeline footer cache.
        let assistantCopyText: String? = {
            let trimmedVisibleText = visibleAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedVisibleText.isEmpty {
                return trimmedVisibleText
            }
            return assistantBlockAccessoryState?.copyText
        }()
        let usesCachedAssistantImageContent = !message.isStreaming && visibleAssistantText == bodyText
        let assistantImageReferences = usesCachedAssistantImageContent
            ? renderModel.assistantImageReferences
            : []
        let visibleAssistantTextWithoutImageSyntax = assistantImageReferences.isEmpty
            ? visibleAssistantText
            : (renderModel.assistantTextWithoutImageSyntax ?? visibleAssistantText)
        let hasRenderableAssistantContent = !visibleAssistantTextWithoutImageSyntax.isEmpty
            || proposedPlan != nil
            || !assistantImageReferences.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let commentContent, commentContent.hasFindings {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(commentContent.findings) { finding in
                        CodeCommentFindingCard(finding: finding)
                    }
                }
            }

            if hasRenderableAssistantContent {
                if let mermaidContent {
                    MermaidMarkdownContentView(content: mermaidContent)
                } else if let inferredQuestionnaire {
                    if let introText = inferredQuestionnaire.introText {
                        MarkdownTextView(
                            text: introText,
                            profile: .assistantProse,
                            enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                            constrainsToAvailableWidth: true
                        )
                    }

                    InferredPlanQuestionnaireCard(
                        message: message,
                        questionnaire: inferredQuestionnaire
                    )

                    if let outroText = inferredQuestionnaire.outroText {
                        Text(outroText)
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let proposedPlan {
                    // Compatibility-mode proposed plans still render inline from assistant text.
                    if !renderedPlanText.isEmpty {
                        MarkdownTextView(
                            text: renderedPlanText,
                            profile: .assistantProse,
                            enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                            constrainsToAvailableWidth: true
                        )
                    }

                    ProposedPlanResultCard(
                        threadId: message.threadId,
                        proposedPlan: proposedPlan,
                        isStreaming: message.isStreaming,
                        canImplement: assistantTurnCompleted
                    )
                } else if message.isStreaming {
                    StreamingAssistantMarkdownTextView(
                        text: visibleAssistantTextWithoutImageSyntax,
                        enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                        constrainsToAvailableWidth: true
                    )
                } else {
                    MarkdownTextView(
                        text: visibleAssistantTextWithoutImageSyntax,
                        profile: .assistantProse,
                        enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                        constrainsToAvailableWidth: true
                    )
                }

                if !assistantImageReferences.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(assistantImageReferences) { reference in
                            AssistantMarkdownImagePreviewButton(
                                reference: reference,
                                currentWorkingDirectory: currentWorkingDirectory
                            )
                        }
                    }
                }
            }

            if !suppressNativeProposedPlanShell && message.isStreaming && showsStreamingAnimations {
                TypingIndicator()
            }

            if !suppressNativeProposedPlanShell && hasTurnEndActions {
                turnEndActionButtons
            }

            if !suppressNativeProposedPlanShell, let assistantBlockAccessoryState {
                CopyBlockButton(
                    text: assistantCopyText,
                    isRunning: assistantBlockAccessoryState.showsRunningIndicator
                )
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
        case .toolActivity:
            toolActivitySystemView(text: text)
        case .fileChange:
            fileChangeSystemView(text: text, renderModel: renderModel)
        case .commandExecution:
            commandExecutionSystemView(text: text, renderModel: renderModel)
        case .subagentAction:
            subagentActionSystemView(text: text)
        case .plan:
            if message.resolvedPlanPresentation?.isInlineResultVisible == true,
               let proposedPlan = message.proposedPlan {
                ProposedPlanResultCard(
                    threadId: message.threadId,
                    proposedPlan: proposedPlan,
                    isStreaming: message.isStreaming,
                    canImplement: message.resolvedPlanPresentation == .resultReady
                )
            } else {
                PlanSystemCard(message: message)
            }
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
        ThinkingSystemBlock(
            messageID: message.id,
            isStreaming: message.isStreaming,
            thinkingText: renderModel.thinkingText ?? "",
            thinkingContent: renderModel.thinkingContent ?? ThinkingDisclosureContent(sections: [], fallbackText: ""),
            activityPreview: renderModel.thinkingActivityPreview
        )
    }

    private func toolActivitySystemView(text: String) -> some View {
        let joined = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 4) {
            if !joined.isEmpty {
                Text(joined)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if message.isStreaming && showsStreamingAnimations {
                TypingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            selectableTextActions(text: text, usesMarkdownSelection: false)
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
            .padding(.vertical, 2)
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

    @Environment(\.inlineCommitAndPushAction) private var inlineCommitAction
    @Environment(\.inlineCommitAndPushPhase) private var inlineCommitAndPushPhase
    @State private var isShowingBlockDiffSheet = false

    private var hasTurnEndActions: Bool {
        AssistantTurnEndActionVisibility.shouldShow(
            accessoryState: assistantBlockAccessoryState
        )
    }

    private var isInlineCommitAndPushRunning: Bool {
        inlineCommitAndPushPhase != nil
    }

    private var inlineCommitAndPushTitle: String {
        inlineCommitAndPushPhase?.title ?? "Commit & Push"
    }

    @ViewBuilder
    private var turnEndActionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let revert = assistantBlockAccessoryState?.blockRevertPresentation {
                assistantRevertButton(presentation: revert)
            }

            if let accessory = assistantBlockAccessoryState {
                HStack(spacing: 10) {
                    if let entries = accessory.blockDiffEntries, !entries.isEmpty {
                        let totalAdditions = entries.reduce(0) { $0 + $1.additions }
                        let totalDeletions = entries.reduce(0) { $0 + $1.deletions }

                        Button {
                            isShowingBlockDiffSheet = true
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
                        .sheet(isPresented: $isShowingBlockDiffSheet) {
                            TurnDiffSheet(
                                title: "Changes",
                                entries: entries,
                                bodyText: accessory.blockDiffText ?? "",
                                messageID: message.id
                            )
                        }
                    }

                    if let action = inlineCommitAction {
                        Button {
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            action()
                        } label: {
                            HStack(spacing: 4) {
                                // Mirror the top-bar git feedback so the inline CTA feels responsive too.
                                Group {
                                    if isInlineCommitAndPushRunning {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image("cloud-upload")
                                            .renderingMode(.template)
                                            .resizable()
                                            .scaledToFit()
                                    }
                                }
                                    .frame(width: 18, height: 18)
                                Text(inlineCommitAndPushTitle)
                            }
                            .font(AppFont.mono(.body))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isInlineCommitAndPushRunning)
                    }
                }
            }
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

    // Throttles only the assistant row's visible text during streaming so markdown/layout
    // work stays local to that cell instead of firing on every token delta.
    private func synchronizeAssistantDisplayText(immediate: Bool) {
        guard message.role == .assistant else {
            throttledAssistantDisplayText = nil
            pendingAssistantDisplayText = nil
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
            return
        }

        let nextText = timelineDisplayText(for: message)
        pendingAssistantDisplayText = nextText

        guard message.isStreaming else {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
            throttledAssistantDisplayText = nextText
            return
        }

        if immediate {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
            throttledAssistantDisplayText = nextText
            return
        }

        if assistantDisplayUpdateTask != nil {
            return
        }

        assistantDisplayUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            throttledAssistantDisplayText = pendingAssistantDisplayText ?? nextText
            assistantDisplayUpdateTask = nil
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

// ─── Thinking UI ────────────────────────────────────────────────────

// Centralizes the inline reasoning row so thinking-specific spacing, fonts, and
// disclosure behavior are easy to tweak without hunting through MessageRow.
// Kept as one flat struct (no sub-view nesting) to minimise per-cell view-tree
// depth inside the LazyVStack — extra struct layers cost allocation + diffing on
// every scroll frame.
private struct ThinkingSystemBlock: View {
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

// A single-pass gradient sweep that slides across the text it overlays.
private struct ShimmerMask: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.45), location: 0.4),
                    .init(color: .white.opacity(0.45), location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: w * 0.6)
            .offset(x: phase * w)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
        }
        .allowsHitTesting(false)
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
        Text(.init(value))
            .font(AppFont.caption())
            .lineSpacing(2)
            .fontWeight(.regular)
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
    @State private var isLoadingImagePreview = false
    @State private var imagePreviewError: String?
    @State private var previewImage: PreviewImagePayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if let imageReference {
                commandImagePreviewButton(for: imageReference)
            }
        }
            .sheet(isPresented: $isShowingDetailSheet) {
                CommandExecutionDetailSheet(status: status, details: detailModel)
                    .presentationDetents([.fraction(0.35), .medium])
            }
            .fullScreenCover(item: $previewImage) { payload in
                ZoomableImagePreviewScreen(
                    payload: payload,
                    onDismiss: { previewImage = nil }
                )
            }
            .alert("Image Preview", isPresented: imagePreviewErrorIsPresented, actions: {
                Button("OK", role: .cancel) {
                    imagePreviewError = nil
                }
            }, message: {
                Text(imagePreviewError ?? "")
            })
    }

    private var detailModel: CommandExecutionDetails? {
        guard let itemId else { return nil }
        return codex.commandExecutionDetailsByItemID[itemId]
    }

    private var imageReference: CommandOutputImageReference? {
        guard let details = detailModel else {
            return nil
        }
        return CommandOutputImageReferenceParser.firstReference(
            command: details.fullCommand,
            outputTail: details.outputTail,
            cwd: details.cwd
        )
    }

    private func commandImagePreviewButton(for reference: CommandOutputImageReference) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            loadImagePreview(reference)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                    if isLoadingImagePreview {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                            .font(AppFont.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Image")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(reference.fileName)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(AppFont.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator).opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoadingImagePreview)
    }

    private func loadImagePreview(_ reference: CommandOutputImageReference) {
        guard !isLoadingImagePreview else { return }
        isLoadingImagePreview = true

        Task { @MainActor in
            defer { isLoadingImagePreview = false }
            do {
                let cachedPreview = await WorkspaceImagePreviewCache.shared.cachedPreview(forPath: reference.path)
                let result = try await codex.readWorkspaceImage(
                    path: reference.path,
                    cwd: detailModel?.cwd,
                    cachedMetadata: cachedPreview?.metadata
                )
                if result.isNotModified, let cachedPreview {
                    previewImage = PreviewImagePayload(
                        image: cachedPreview.payload.image,
                        title: cachedPreview.metadata.fileName.isEmpty ? reference.fileName : cachedPreview.metadata.fileName
                    )
                    return
                }

                let decodedImage = try await WorkspaceImagePreviewCache.shared.preview(for: result)
                previewImage = PreviewImagePayload(
                    image: decodedImage.image,
                    title: result.fileName.isEmpty ? reference.fileName : result.fileName
                )
            } catch {
                imagePreviewError = error.localizedDescription
            }
        }
    }

    private var imagePreviewErrorIsPresented: Binding<Bool> {
        Binding(
            get: { imagePreviewError != nil },
            set: { isPresented in
                if !isPresented {
                    imagePreviewError = nil
                }
            }
        )
    }
}

private struct CachedWorkspaceImagePreview: Sendable {
    let metadata: WorkspaceImageMetadata
    let payload: CommandImagePreviewPayload
}

private final class CommandImagePreviewPayload: @unchecked Sendable {
    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    var estimatedMemoryCost: Int {
        guard let cgImage = image.cgImage else {
            return 1
        }
        return max(cgImage.bytesPerRow * cgImage.height, 1)
    }
}

private actor WorkspaceImagePreviewCache {
    static let shared = WorkspaceImagePreviewCache()

    private let cache = NSCache<NSString, CommandImagePreviewPayload>()
    private var inFlightPreviews: [String: Task<CommandImagePreviewPayload, Error>] = [:]
    private var latestMetadataByPath: [String: WorkspaceImageMetadata] = [:]
    private var latestMetadataAccessOrder: [String] = []

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func cachedPreview(forPath path: String) -> CachedWorkspaceImagePreview? {
        guard let metadata = latestMetadataByPath[path],
              let payload = cache.object(forKey: cacheKey(for: metadata) as NSString) else {
            return nil
        }
        latestMetadataAccessOrder.removeAll { $0 == path }
        latestMetadataAccessOrder.append(path)
        return CachedWorkspaceImagePreview(metadata: metadata, payload: payload)
    }

    func preview(for result: WorkspaceImageReadResult) async throws -> CommandImagePreviewPayload {
        let key = cacheKey(for: result.metadata)
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) {
            return cached
        }
        if let task = inFlightPreviews[key] {
            return try await task.value
        }

        guard let data = result.data else {
            throw CodexServiceError.invalidResponse("Cached image preview was unavailable.")
        }
        let task = Task(priority: .userInitiated) {
            try await CommandImagePreviewDecoder.decode(data)
        }
        inFlightPreviews[key] = task
        defer { inFlightPreviews[key] = nil }

        let decodedImage = try await task.value
        cache.setObject(decodedImage, forKey: nsKey, cost: decodedImage.estimatedMemoryCost)
        rememberMetadata(result.metadata)
        return decodedImage
    }

    private func cacheKey(for metadata: WorkspaceImageMetadata) -> String {
        let mtimeMs = metadata.mtimeMs.map { Int64($0.rounded()) } ?? -1
        return "\(metadata.path)|\(metadata.byteLength)|\(mtimeMs)"
    }

    private func rememberMetadata(_ metadata: WorkspaceImageMetadata) {
        latestMetadataByPath[metadata.path] = metadata
        latestMetadataAccessOrder.removeAll { $0 == metadata.path }
        latestMetadataAccessOrder.append(metadata.path)

        while latestMetadataAccessOrder.count > 64, let evictedPath = latestMetadataAccessOrder.first {
            latestMetadataAccessOrder.removeFirst()
            latestMetadataByPath[evictedPath] = nil
        }
    }
}

private enum CommandImagePreviewDecoder {
    private static let maxPreviewPixelDimension = 2_400

    // Downsamples and prepares the preview off the main actor before presenting it.
    static func decode(_ data: Data) async throws -> CommandImagePreviewPayload {
        try await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw CodexServiceError.invalidResponse("The file is not a readable image.")
            }

            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPreviewPixelDimension,
            ] as CFDictionary

            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
                return CommandImagePreviewPayload(image: UIImage(cgImage: cgImage))
            }

            guard let image = UIImage(data: data) else {
                throw CodexServiceError.invalidResponse("The file is not a readable image.")
            }
            return CommandImagePreviewPayload(image: image.preparingForDisplay() ?? image)
        }.value
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

// ─── Focused Previews ───────────────────────────────────────────────

private struct TimelineSystemBlockPreviewSurface<Content: View>: View {
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
struct ThinkingSystemBlockCompactPreviewHost: View {
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
struct ThinkingSystemBlockDisclosurePreviewHost: View {
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
struct ThinkingSystemBlockRealResponsePreviewHost: View {
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

@MainActor
struct ToolCallSystemBlockPreviewHost: View {
    var body: some View {
        TimelineSystemBlockPreviewSurface {
            CommandExecutionStatusCard(
                status: CommandExecutionStatusModel(
                    command: "npm run lint -- --fix",
                    statusLabel: "completed",
                    accent: .completed
                ),
                itemId: "preview-tool-call"
            )
        }
        .environment(CodexService())
    }
}

enum AssistantTurnEndActionVisibility {
    // Ties Diff/Revert to the block's own streaming state so interrupted and
    // turn-less recovered rows keep their end-of-turn controls once settled.
    static func shouldShow(accessoryState: AssistantBlockAccessoryState?) -> Bool {
        guard let accessoryState, !accessoryState.showsRunningIndicator else { return false }
        return accessoryState.blockRevertPresentation != nil
            || accessoryState.blockDiffEntries != nil
    }
}

#Preview("Thinking Block — Compact") {
    ThinkingSystemBlockCompactPreviewHost()
}

#Preview("Thinking Block — Disclosure") {
    ThinkingSystemBlockDisclosurePreviewHost()
}

#Preview("Thinking Block — Real Response") {
    ThinkingSystemBlockRealResponsePreviewHost()
}

#Preview("Tool Call Block") {
    ToolCallSystemBlockPreviewHost()
}
