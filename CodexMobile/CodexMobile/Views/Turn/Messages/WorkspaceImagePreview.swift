// FILE: WorkspaceImagePreview.swift
// Purpose: Loads, caches, and presents workspace image/text previews from assistant links.
// Layer: Turn UI preview service
// Exports: AssistantWorkspaceImagePreviewScreen, WorkspaceLinkedFilePreviewScreen, WorkspaceImagePreviewCache
// Depends on: Foundation, ImageIO, Runestone, SwiftUI, UIKit, CodexService workspace preview APIs

import Foundation
import ImageIO
import Runestone
import SwiftUI
import TreeSitterBashRunestone
import TreeSitterCPPRunestone
import TreeSitterCRunestone
import TreeSitterCSSRunestone
import TreeSitterCSharpRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone
import UIKit
import WebKit

struct AssistantWorkspaceImagePreviewRequest: Identifiable {
    let id = UUID()
    let reference: AssistantMarkdownImageReference
    let currentWorkingDirectory: String?
    let initialPayload: PreviewImagePayload?
}

struct WorkspaceFilePreviewRequest: Identifiable, Equatable {
    let path: String
    let currentWorkingDirectory: String?

    var id: String {
        "\(currentWorkingDirectory ?? "")|\(path)"
    }
}

fileprivate enum WorkspaceLinkedFilePreviewKind {
    case imageFirst
    case textFirst
}

enum WorkspaceFileLinkResolver {
    private static let textFileExtensions: Set<String> = [
        "bash", "c", "cc", "cjs", "cpp", "cs", "css", "go", "h", "html", "java",
        "js", "json", "jsx", "kt", "m", "md", "mjs", "mm", "py", "rb", "rs",
        "scss", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml",
        "yml", "zsh"
    ]
    private static let imageFileExtensions: Set<String> = [
        "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "webp"
    ]
    private static let extensionlessFileNames: Set<String> = [
        "dockerfile", "gemfile", "makefile", "podfile"
    ]

    // Converts markdown link destinations into local paths the paired Mac can read.
    static func localPath(from url: URL) -> String? {
        if url.isFileURL {
            return normalizedPath(url.path)
        }

        guard url.scheme == nil else {
            return nil
        }

        let rawValue = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return normalizedPath(rawValue)
    }

    fileprivate static func preferredPreviewKind(for path: String) -> WorkspaceLinkedFilePreviewKind {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return textFileExtensions.contains(fileExtension) ? .textFirst : .imageFirst
    }

    private static func normalizedPath(_ value: String) -> String? {
        let trimmed = stripLineSuffix(from: stripFragmentAndQuery(from: value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            return nil
        }
        guard isLocalPathCandidate(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func isLocalPathCandidate(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") {
            return true
        }
        guard !looksLikeSchemeLessWebURL(value) else {
            return false
        }

        let fileName = (value as NSString).lastPathComponent.lowercased()
        let fileExtension = (value as NSString).pathExtension.lowercased()
        return extensionlessFileNames.contains(fileName)
            || textFileExtensions.contains(fileExtension)
            || imageFileExtensions.contains(fileExtension)
    }

    private static func looksLikeSchemeLessWebURL(_ value: String) -> Bool {
        guard value.contains("/") else {
            return false
        }
        guard let firstComponent = value.split(separator: "/", maxSplits: 1).first else {
            return false
        }
        return firstComponent.contains(".")
            && !firstComponent.hasPrefix(".")
            && !firstComponent.hasSuffix(".")
    }

    private static func stripFragmentAndQuery(from value: String) -> String {
        guard let boundary = value.firstIndex(where: { $0 == "#" || $0 == "?" }) else {
            return value
        }
        return String(value[..<boundary])
    }

    private static func stripLineSuffix(from value: String) -> String {
        var normalized = value
        if let range = normalized.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            normalized.removeSubrange(range)
        }
        return normalized
    }
}

private struct WorkspacePreviewChromeButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            RemodexIcon.image(systemName: systemName)
                .font(AppFont.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .adaptiveGlass(.regular, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WorkspacePreviewTitlePill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .adaptiveGlass(.regular, in: Capsule())
    }
}

private struct WorkspacePreviewRetryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(AppFont.subheadline(weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .adaptiveGlass(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AssistantMarkdownImagePreviewButton: View {
    let reference: AssistantMarkdownImageReference
    let currentWorkingDirectory: String?

    @Environment(CodexService.self) private var codex
    @State private var previewRequest: AssistantWorkspaceImagePreviewRequest?
    @State private var loadedPreview: PreviewImagePayload?
    @State private var isAutoLoadingPreview = false
    @State private var didAttemptAutoPreviewLoad = false

    private static let cornerRadius: CGFloat = 18
    private static let maxWidth: CGFloat = 200

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            openPreview()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .task(id: autoPreviewLoadKey) {
            await loadPreviewAfterChatSettlesIfNeeded()
        }
        .fullScreenCover(item: $previewRequest) { request in
            AssistantWorkspaceImagePreviewScreen(
                reference: request.reference,
                currentWorkingDirectory: request.currentWorkingDirectory,
                initialPayload: request.initialPayload,
                onDismiss: { previewRequest = nil }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadedPreview {
            loadedImage(loadedPreview)
        } else {
            metadataCard
        }
    }

    private func loadedImage(_ payload: PreviewImagePayload) -> some View {
        Image(uiImage: payload.image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var metadataCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                if isAutoLoadingPreview {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.accentColor)
                } else {
                    RemodexIcon.image(systemName: "photo")
                        .font(AppFont.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.fileName.isEmpty ? "Generated image" : reference.fileName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                Text(reference.path)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            RemodexIcon.image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(AppFont.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func openPreview() {
        previewRequest = AssistantWorkspaceImagePreviewRequest(
            reference: reference,
            currentWorkingDirectory: currentWorkingDirectory,
            initialPayload: loadedPreview
        )
    }

    private var autoPreviewLoadKey: String {
        "\(reference.id)|\(codex.connectionPhase)"
    }

    private var canAutoLoadPreview: Bool {
        codex.connectionPhase == .connected
    }

    @MainActor
    private func loadPreviewAfterChatSettlesIfNeeded() async {
        guard canAutoLoadPreview,
              loadedPreview == nil,
              !isAutoLoadingPreview,
              !didAttemptAutoPreviewLoad else {
            return
        }

        do {
            // Give post-connect UI reconciliation a beat before starting image reads.
            try await Task.sleep(nanoseconds: 300_000_000)
            guard canAutoLoadPreview, loadedPreview == nil else { return }
            didAttemptAutoPreviewLoad = true
            isAutoLoadingPreview = true
            defer { isAutoLoadingPreview = false }
            loadedPreview = try await AssistantWorkspaceImagePreviewLoader.load(
                reference: reference,
                currentWorkingDirectory: currentWorkingDirectory,
                codex: codex
            )
        } catch {
            // Inline auto-load stays silent; the fullscreen sheet owns visible errors and retry.
        }
    }
}

private enum WorkspaceLinkedFilePreviewPayload {
    case image(PreviewImagePayload)
    case svg(WorkspaceSVGFilePreviewPayload)
    case text(WorkspaceTextFileReadResult)
}

struct WorkspaceLinkedFilePreviewScreen: View {
    let request: WorkspaceFilePreviewRequest
    let onDismiss: () -> Void

    @Environment(CodexService.self) private var codex
    @State private var isLoading = false
    @State private var payload: WorkspaceLinkedFilePreviewPayload?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            switch payload {
            case .image(let imagePayload):
                ZoomableImagePreviewScreen(payload: imagePayload, onDismiss: onDismiss)
            case .svg(let svgPayload):
                WorkspaceSVGFilePreviewScreen(payload: svgPayload, onDismiss: onDismiss, onReload: {
                    Task { await loadPreview(force: true) }
                })
            case .text(let file):
                WorkspaceTextFileViewerScreen(file: file, onDismiss: onDismiss, onReload: {
                    Task { await loadPreview(force: true) }
                })
            case nil:
                loadingOrErrorScreen
            }
        }
        .task(id: request.id) {
            await loadPreview()
        }
    }

    private var loadingOrErrorScreen: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer(minLength: 0)

                if isLoading || errorMessage == nil {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading file")
                        .font(AppFont.subheadline(weight: .semibold))
                } else {
                    RemodexIcon.image(systemName: "doc.text")
                        .font(AppFont.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(fileName)
                        .font(AppFont.subheadline(weight: .semibold))
                        .multilineTextAlignment(.center)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                    }
                    WorkspacePreviewRetryButton {
                        Task { await loadPreview(force: true) }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)

            previewTopBar
                .padding(.horizontal, 18)
                .padding(.top, 18)
        }
    }

    private var previewTopBar: some View {
        HStack(spacing: 14) {
            WorkspacePreviewChromeButton(systemName: "xmark", accessibilityLabel: "Close file preview") {
                onDismiss()
            }

            WorkspacePreviewTitlePill(title: fileName)

            Spacer(minLength: 0)
        }
    }

    private var fileName: String {
        let basename = (request.path as NSString).lastPathComponent
        return basename.isEmpty ? "File" : basename
    }

    @MainActor
    private func loadPreview(force: Bool = false) async {
        guard !isLoading else { return }
        if payload != nil, !force {
            return
        }

        isLoading = true
        errorMessage = nil
        if force {
            payload = nil
        }
        defer { isLoading = false }

        switch WorkspaceFileLinkResolver.preferredPreviewKind(for: request.path) {
        case .imageFirst:
            await loadImageThenText(force: force)
        case .textFirst:
            await loadTextThenImage(force: force)
        }
    }

    @MainActor
    private func loadImageThenText(force: Bool) async {
        do {
            payload = try await loadVisualPayload(force: force)
            return
        } catch {
            let imageError = error
            do {
                payload = .text(try await loadTextPayload())
            } catch {
                errorMessage = combinedPreviewError(primary: imageError, fallback: error)
            }
        }
    }

    @MainActor
    private func loadTextThenImage(force: Bool) async {
        do {
            payload = .text(try await loadTextPayload())
            return
        } catch {
            let textError = error
            do {
                payload = try await loadVisualPayload(force: force)
            } catch {
                errorMessage = combinedPreviewError(primary: textError, fallback: error)
            }
        }
    }

    @MainActor
    private func loadVisualPayload(force: Bool) async throws -> WorkspaceLinkedFilePreviewPayload {
        if WorkspaceSVGFilePreviewPayload.isSVGPath(request.path) {
            return .svg(try await loadSVGPayload())
        }
        return .image(try await loadImagePayload(force: force))
    }

    @MainActor
    private func loadImagePayload(force: Bool) async throws -> PreviewImagePayload {
        let imageReference = AssistantMarkdownImageReference(
            path: request.path,
            altText: fileName,
            occurrenceIndex: 0
        )
        return try await AssistantWorkspaceImagePreviewLoader.load(
            reference: imageReference,
            currentWorkingDirectory: request.currentWorkingDirectory,
            codex: codex,
            force: force
        )
    }

    @MainActor
    private func loadSVGPayload() async throws -> WorkspaceSVGFilePreviewPayload {
        let result = try await codex.readWorkspaceImage(
            path: request.path,
            cwd: request.currentWorkingDirectory
        )
        guard let data = result.data,
              let source = String(data: data, encoding: .utf8) else {
            throw CodexServiceError.invalidResponse("SVG preview response did not include readable SVG data.")
        }
        return WorkspaceSVGFilePreviewPayload(
            source: source,
            title: result.fileName.isEmpty ? fileName : result.fileName,
            path: result.path
        )
    }

    @MainActor
    private func loadTextPayload() async throws -> WorkspaceTextFileReadResult {
        try await codex.readWorkspaceTextFile(
            path: request.path,
            cwd: request.currentWorkingDirectory
        )
    }

    private func combinedPreviewError(primary: Error, fallback: Error) -> String {
        let primaryMessage = primary.localizedDescription
        let fallbackMessage = fallback.localizedDescription
        guard !primaryMessage.isEmpty else { return fallbackMessage }
        guard !fallbackMessage.isEmpty, fallbackMessage != primaryMessage else { return primaryMessage }
        return "\(primaryMessage)\n\(fallbackMessage)"
    }
}

private struct WorkspaceTextFileViewerScreen: View {
    let file: WorkspaceTextFileReadResult
    let onDismiss: () -> Void
    let onReload: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingCopiedConfirmation = false
    @State private var copyResetTask: Task<Void, Never>?

    private var content: String {
        file.content ?? ""
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceTextFilePreviewHeader(file: file)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                Divider()
                    .overlay(Color.primary.opacity(0.06))

                WorkspaceRunestoneCodeFileView(
                    content: content,
                    fileName: file.fileName,
                    colorScheme: colorScheme
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(edges: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(WorkspaceRunestoneTheme.backgroundUIColor(for: colorScheme)))
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem(placement: .principal) {
                    WorkspaceTextFilePreviewToolbarTitle(file: file)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        onReload()
                    } label: {
                        RemodexIcon.image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload file")

                    Button {
                        copyFileContents()
                    } label: {
                        RemodexIcon.image(systemName: isShowingCopiedConfirmation ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy file contents")
                }
            }
            .onDisappear { copyResetTask?.cancel() }
        }
    }

    private func copyFileContents() {
        UIPasteboard.general.string = content
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(.easeInOut(duration: 0.18)) {
            isShowingCopiedConfirmation = true
        }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isShowingCopiedConfirmation = false
            }
        }
    }
}

private struct WorkspaceSVGFilePreviewPayload: Equatable {
    let source: String
    let title: String
    let path: String

    static func isSVGPath(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "svg"
    }
}

private struct WorkspaceSVGFilePreviewScreen: View {
    let payload: WorkspaceSVGFilePreviewPayload
    let onDismiss: () -> Void
    let onReload: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
                .ignoresSafeArea()

            WorkspaceSVGWebView(source: payload.source, colorScheme: colorScheme)
                .ignoresSafeArea()

            topBar
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .zIndex(2)
        }
        .background(Color(.systemBackground))
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            WorkspacePreviewChromeButton(systemName: "xmark", accessibilityLabel: "Close SVG preview") {
                onDismiss()
            }

            WorkspacePreviewTitlePill(title: payload.title.isEmpty ? "SVG" : payload.title)

            Spacer(minLength: 0)

            WorkspacePreviewChromeButton(systemName: "arrow.clockwise", accessibilityLabel: "Reload SVG preview") {
                onReload()
            }
        }
    }
}

// Hosts raw SVG markup in an isolated page so vector files preview as artwork, not source text.
struct WorkspaceSVGWebView: UIViewRepresentable {
    let source: String
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 8
        webView.scrollView.bouncesZoom = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = Self.htmlDocument(svgSource: source, isDark: colorScheme == .dark)
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.prepareForHTMLLoad()
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        private var didAllowInitialNavigation = false

        func prepareForHTMLLoad() {
            didAllowInitialNavigation = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if WorkspaceSVGPreviewSecurity.isExternalNavigationURL(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }

            guard !didAllowInitialNavigation, navigationAction.navigationType == .other else {
                decisionHandler(.cancel)
                return
            }

            didAllowInitialNavigation = true
            decisionHandler(.allow)
        }
    }

    static func htmlDocument(svgSource: String, isDark: Bool) -> String {
        let background = isDark ? "#111114" : "#f7f7f8"
        let foreground = isDark ? "#f5f5f7" : "#111114"
        let sanitizedSVG = WorkspaceSVGPreviewSecurity.sanitizedSVGSource(svgSource)
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=8">
        <meta http-equiv="Content-Security-Policy" content="\(WorkspaceSVGPreviewSecurity.contentSecurityPolicy)">
        <style>
        html, body {
          width: 100%;
          height: 100%;
          margin: 0;
          background: \(background);
          color: \(foreground);
        }
        body {
          display: grid;
          place-items: center;
          box-sizing: border-box;
          padding: 88px 20px 28px;
        }
        svg {
          max-width: 100%;
          max-height: 100%;
          width: auto;
          height: auto;
        }
        </style>
        </head>
        <body>
        \(sanitizedSVG)
        </body>
        </html>
        """
    }
}

// Renders an inline icon + filename + folder breadcrumb so the nav bar
// keeps the file in context without truncating the basename mid-word.
private struct WorkspaceTextFilePreviewToolbarTitle: View {
    let file: WorkspaceTextFileReadResult

    var body: some View {
        VStack(spacing: 1) {
            Text(displayName)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let parent = parentDirectoryName {
                Text(parent)
                    .font(AppFont.caption2())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 220)
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        file.fileName.isEmpty ? "File" : file.fileName
    }

    private var parentDirectoryName: String? {
        let parent = (file.path as NSString).deletingLastPathComponent
        let lastComponent = (parent as NSString).lastPathComponent
        guard !lastComponent.isEmpty, lastComponent != "/" else { return nil }
        return lastComponent
    }
}

// Header card under the nav bar: file-type icon, name, breadcrumb path, and metadata chips.
private struct WorkspaceTextFilePreviewHeader: View {
    let file: WorkspaceTextFileReadResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkspaceFileTypeIcon(fileName: displayName)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(AppFont.headline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let languageBadgeTitle {
                        Text(languageBadgeTitle)
                            .font(AppFont.caption2(weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                }

                Text(displayPath)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metadataChips
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayName: String {
        file.fileName.isEmpty ? "File" : file.fileName
    }

    // Collapses the device home directory to `~` so long absolute paths stay readable.
    private var displayPath: String {
        let path = file.path
        let home = NSHomeDirectory()
        if !home.isEmpty, path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        if path == home { return "~" }
        return path
    }

    private var languageBadgeTitle: String? {
        let languageID = WorkspaceRunestoneLanguageResolver.languageID(for: displayName)
        guard languageID != "plain" else { return nil }
        switch languageID {
        case "cpp": return "C++"
        case "csharp": return "C#"
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "jsx": return "JSX"
        case "tsx": return "TSX"
        case "html": return "HTML"
        case "css": return "CSS"
        case "json": return "JSON"
        case "sql": return "SQL"
        case "yaml": return "YAML"
        case "toml": return "TOML"
        default: return languageID.capitalized
        }
    }

    @ViewBuilder
    private var metadataChips: some View {
        HStack(spacing: 6) {
            metadataChip(text: ByteCountFormatter.string(fromByteCount: Int64(file.byteLength), countStyle: .file))
            if let lineCount = file.lineCount {
                metadataChip(text: "\(lineCount) line\(lineCount == 1 ? "" : "s")")
            }
            metadataChip(text: file.encoding.uppercased())
        }
    }

    private func metadataChip(text: String) -> some View {
        Text(text)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
    }
}

// Small rounded badge with a language-aware glyph that sits next to the file name.
private struct WorkspaceFileTypeIcon: View {
    let fileName: String

    var body: some View {
        let style = WorkspaceFileTypeStyle.style(for: fileName)
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(style.tint.opacity(0.14))
            RemodexIcon.image(systemName: style.symbolName)
                .font(AppFont.system(size: 17, weight: .semibold))
                .foregroundStyle(style.tint)
        }
        .frame(width: 38, height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(style.tint.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

private enum WorkspaceFileTypeStyle {
    struct Style {
        let symbolName: String
        let tint: Color
    }

    static func style(for fileName: String) -> Style {
        let languageID = WorkspaceRunestoneLanguageResolver.languageID(for: fileName)
        switch languageID {
        case "swift": return Style(symbolName: "swift", tint: .orange)
        case "javascript": return Style(symbolName: "curlybraces", tint: .yellow)
        case "jsx": return Style(symbolName: "curlybraces", tint: .cyan)
        case "typescript": return Style(symbolName: "curlybraces", tint: .blue)
        case "tsx": return Style(symbolName: "curlybraces", tint: .indigo)
        case "python": return Style(symbolName: "chevron.left.forwardslash.chevron.right", tint: .blue)
        case "ruby": return Style(symbolName: "diamond.fill", tint: .red)
        case "rust": return Style(symbolName: "gearshape.fill", tint: .orange)
        case "go": return Style(symbolName: "g.circle.fill", tint: .cyan)
        case "c": return Style(symbolName: "c.circle.fill", tint: .indigo)
        case "cpp": return Style(symbolName: "c.circle.fill", tint: .purple)
        case "csharp": return Style(symbolName: "c.circle.fill", tint: .green)
        case "java": return Style(symbolName: "cup.and.saucer.fill", tint: .brown)
        case "html": return Style(symbolName: "chevron.left.forwardslash.chevron.right", tint: .orange)
        case "css": return Style(symbolName: "paintbrush.pointed.fill", tint: .blue)
        case "json": return Style(symbolName: "curlybraces.square.fill", tint: .green)
        case "markdown": return Style(symbolName: "text.book.closed.fill", tint: .indigo)
        case "yaml", "toml": return Style(symbolName: "list.bullet.indent", tint: .gray)
        case "sql": return Style(symbolName: "cylinder.split.1x2.fill", tint: .teal)
        case "bash": return Style(symbolName: "terminal.fill", tint: .green)
        default: return Style(symbolName: "doc.text.fill", tint: .accentColor)
        }
    }
}

// Hosts Runestone's native code viewer so workspace files get line numbers, selection, and syntax colors.
private struct WorkspaceRunestoneCodeFileView: UIViewRepresentable {
    let content: String
    let fileName: String
    let colorScheme: ColorScheme

    private static let highlightedTextMaxUTF8Bytes = 512 * 1024

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context _: Context) -> TextView {
        let textView = TextView(frame: .zero)
        configure(textView)
        return textView
    }

    func updateUIView(_ uiView: TextView, context: Context) {
        configure(uiView)

        let renderedContent = displayContent
        // Large files remain scrollable/selectable while avoiding Tree-sitter work on the main thread.
        let shouldSyntaxHighlight = renderedContent.utf8.count <= Self.highlightedTextMaxUTF8Bytes
        let languageID = shouldSyntaxHighlight
            ? WorkspaceRunestoneLanguageResolver.languageID(for: fileName)
            : "plain"
        let signature = Coordinator.Signature(
            content: renderedContent,
            languageID: languageID,
            isDark: colorScheme == .dark
        )

        guard context.coordinator.signature != signature else {
            return
        }

        context.coordinator.signature = signature
        let theme = WorkspaceRunestoneTheme(colorScheme: colorScheme)
        let language = shouldSyntaxHighlight ? WorkspaceRunestoneLanguageResolver.language(for: fileName) : nil
        if let language {
            uiView.setState(TextViewState(text: renderedContent, theme: theme, language: language))
        } else {
            uiView.setState(TextViewState(text: renderedContent, theme: theme))
        }
    }

    private func configure(_ textView: TextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.isLineWrappingEnabled = false
        textView.lineHeightMultiplier = 1.22
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 18)
        textView.backgroundColor = WorkspaceRunestoneTheme.backgroundUIColor(for: colorScheme)
        textView.selectionBarColor = .systemBlue
        textView.selectionHighlightColor = UIColor.systemBlue.withAlphaComponent(0.18)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = true
        textView.keyboardDismissMode = .interactive
        textView.layer.cornerRadius = 0
        textView.layer.borderWidth = 0
        // Keep Runestone's scroll layer from painting behind the fixed file header.
        textView.clipsToBounds = true
        if #available(iOS 16.0, *) {
            textView.isFindInteractionEnabled = true
        }
    }

    private var displayContent: String {
        content.isEmpty ? " " : content
    }

    final class Coordinator {
        var signature: Signature?

        struct Signature: Equatable {
            let content: String
            let languageID: String
            let isDark: Bool
        }
    }
}

private enum WorkspaceRunestoneLanguageResolver {
    static func language(for fileName: String) -> TreeSitterLanguage? {
        switch languageID(for: fileName) {
        case "bash": return .bash
        case "c": return .c
        case "cpp": return .cpp
        case "csharp": return .cSharp
        case "css": return .css
        case "go": return .go
        case "html": return .html
        case "java": return .java
        case "javascript": return .javaScript
        case "jsx": return .jsx
        case "json": return .json
        case "markdown": return .markdown
        case "python": return .python
        case "ruby": return .ruby
        case "rust": return .rust
        case "sql": return .sql
        case "swift": return .swift
        case "toml": return .toml
        case "tsx": return .tsx
        case "typescript": return .typeScript
        case "yaml": return .yaml
        default: return nil
        }
    }

    static func languageID(for fileName: String) -> String {
        let lowercasedName = fileName.lowercased()
        let fileExtension = (lowercasedName as NSString).pathExtension
        let basename = (lowercasedName as NSString).lastPathComponent

        if basename == "dockerfile" {
            return "bash"
        }

        switch fileExtension {
        case "bash", "sh", "zsh": return "bash"
        case "c", "h", "m": return "c"
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx", "mm": return "cpp"
        case "cs": return "csharp"
        case "css", "scss": return "css"
        case "go": return "go"
        case "html", "htm": return "html"
        case "java", "kt": return "java"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "jsx"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "sql": return "sql"
        case "swift": return "swift"
        case "toml": return "toml"
        case "tsx": return "tsx"
        case "ts": return "typescript"
        case "yaml", "yml": return "yaml"
        default: return "plain"
        }
    }
}

private final class WorkspaceRunestoneTheme: Runestone.Theme {
    private let isDark: Bool

    init(colorScheme: ColorScheme) {
        isDark = colorScheme == .dark
    }

    var font: UIFont {
        AppFont.monoUIFont(size: 13, textStyle: .caption1)
    }

    var textColor: UIColor {
        isDark ? UIColor(red: 0.88, green: 0.91, blue: 0.95, alpha: 1) : .label
    }

    var gutterBackgroundColor: UIColor {
        Self.backgroundUIColor(isDark: isDark)
    }

    var gutterHairlineColor: UIColor {
        UIColor.separator.withAlphaComponent(isDark ? 0.22 : 0.32)
    }

    var lineNumberColor: UIColor {
        UIColor.secondaryLabel.withAlphaComponent(isDark ? 0.70 : 0.82)
    }

    var lineNumberFont: UIFont {
        AppFont.monoUIFont(size: 12, textStyle: .caption2)
    }

    var selectedLineBackgroundColor: UIColor {
        UIColor.systemBlue.withAlphaComponent(isDark ? 0.16 : 0.10)
    }

    var selectedLinesLineNumberColor: UIColor {
        .systemBlue
    }

    var selectedLinesGutterBackgroundColor: UIColor {
        UIColor.systemBlue.withAlphaComponent(isDark ? 0.14 : 0.08)
    }

    var invisibleCharactersColor: UIColor {
        UIColor.tertiaryLabel
    }

    var pageGuideHairlineColor: UIColor {
        UIColor.separator.withAlphaComponent(0.35)
    }

    var pageGuideBackgroundColor: UIColor {
        .clear
    }

    var markedTextBackgroundColor: UIColor {
        UIColor.systemYellow.withAlphaComponent(0.25)
    }

    func textColor(for highlightName: String) -> UIColor? {
        let name = highlightName.lowercased()
        if name.contains("comment") { return isDark ? uiColor(0.45, 0.54, 0.63) : uiColor(0.45, 0.49, 0.55) }
        if name.contains("keyword") || name.contains("operator") { return isDark ? uiColor(0.94, 0.56, 0.76) : uiColor(0.73, 0.18, 0.45) }
        if name.contains("string") { return isDark ? uiColor(0.76, 0.84, 0.55) : uiColor(0.17, 0.55, 0.32) }
        if name.contains("number") || name.contains("constant") { return isDark ? uiColor(0.95, 0.67, 0.46) : uiColor(0.72, 0.38, 0.12) }
        if name.contains("function") || name.contains("method") { return isDark ? uiColor(0.50, 0.74, 1.00) : uiColor(0.00, 0.37, 0.74) }
        if name.contains("type") || name.contains("constructor") { return isDark ? uiColor(0.56, 0.86, 0.78) : uiColor(0.08, 0.52, 0.50) }
        if name.contains("property") || name.contains("field") { return isDark ? uiColor(0.84, 0.70, 1.00) : uiColor(0.43, 0.25, 0.74) }
        if name.contains("variable.builtin") { return isDark ? uiColor(1.00, 0.74, 0.47) : uiColor(0.70, 0.33, 0.08) }
        if name.contains("punctuation") { return UIColor.secondaryLabel }
        return nil
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        let name = highlightName.lowercased()
        if name.contains("keyword") || name.contains("type") {
            return .bold
        }
        return []
    }

    static func backgroundUIColor(for colorScheme: ColorScheme) -> UIColor {
        backgroundUIColor(isDark: colorScheme == .dark)
    }

    private static func backgroundUIColor(isDark: Bool) -> UIColor {
        isDark
            ? UIColor(red: 0.071, green: 0.078, blue: 0.090, alpha: 1)
            : UIColor(red: 0.961, green: 0.965, blue: 0.973, alpha: 1)
    }

    private func uiColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}


struct AssistantWorkspaceImagePreviewScreen: View {
    let reference: AssistantMarkdownImageReference
    let currentWorkingDirectory: String?
    let onDismiss: () -> Void

    @Environment(CodexService.self) private var codex
    @State private var isLoading = false
    @State private var payload: PreviewImagePayload?
    @State private var errorMessage: String?

    init(
        reference: AssistantMarkdownImageReference,
        currentWorkingDirectory: String?,
        initialPayload: PreviewImagePayload? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.reference = reference
        self.currentWorkingDirectory = currentWorkingDirectory
        self.onDismiss = onDismiss
        _payload = State(initialValue: initialPayload)
    }

    var body: some View {
        Group {
            if let payload {
                ZoomableImagePreviewScreen(
                    payload: payload,
                    onDismiss: onDismiss
                )
            } else {
                loadingOrErrorScreen
            }
        }
        .task(id: reference.path) {
            await loadPreview()
        }
    }

    private var loadingOrErrorScreen: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(.secondarySystemBackground).opacity(0.7),
                    Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer(minLength: 0)

                if isLoading || errorMessage == nil {
                    ProgressView()
                        .controlSize(.large)
                    Text(reference.fileName.isEmpty ? "Loading image" : reference.fileName)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else {
                    RemodexIcon.image(systemName: "photo")
                        .font(AppFont.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(reference.fileName.isEmpty ? "Image unavailable" : reference.fileName)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                    WorkspacePreviewRetryButton {
                        Task { await loadPreview(force: true) }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)

            topBar
                .padding(.horizontal, 18)
                .padding(.top, 18)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            WorkspacePreviewChromeButton(systemName: "xmark", accessibilityLabel: "Close image preview") {
                onDismiss()
            }

            if !reference.fileName.isEmpty {
                WorkspacePreviewTitlePill(title: reference.fileName)
            }

            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func loadPreview(force: Bool = false) async {
        guard !isLoading else { return }
        if payload != nil, !force {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            payload = try await AssistantWorkspaceImagePreviewLoader.load(
                reference: reference,
                currentWorkingDirectory: currentWorkingDirectory,
                codex: codex,
                force: force
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum AssistantWorkspaceImagePreviewLoader {
    @MainActor
    static func load(
        reference: AssistantMarkdownImageReference,
        currentWorkingDirectory: String?,
        codex: CodexService,
        force: Bool = false
    ) async throws -> PreviewImagePayload {
        let cachedPreview = await WorkspaceImagePreviewCache.shared.cachedPreview(forPath: reference.path)
        let result = try await codex.readWorkspaceImage(
            path: reference.path,
            cwd: currentWorkingDirectory,
            cachedMetadata: force ? nil : cachedPreview?.metadata
        )
        if result.isNotModified, let cachedPreview {
            return PreviewImagePayload(
                image: cachedPreview.payload.image,
                title: cachedPreview.metadata.fileName.isEmpty ? reference.fileName : cachedPreview.metadata.fileName
            )
        }

        let decodedImage = try await WorkspaceImagePreviewCache.shared.preview(for: result)
        return PreviewImagePayload(
            image: decodedImage.image,
            title: result.fileName.isEmpty ? reference.fileName : result.fileName
        )
    }
}

nonisolated struct CachedWorkspaceImagePreview: Sendable {
    let metadata: WorkspaceImageMetadata
    let payload: CommandImagePreviewPayload
}

nonisolated final class CommandImagePreviewPayload: @unchecked Sendable {
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

actor WorkspaceImagePreviewCache {
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
        let mtimeMs = metadata.mtimeMs.map { String($0.bitPattern) } ?? "missing"
        let previewMax = metadata.previewMaxPixelDimension.map(String.init) ?? "original"
        return "\(metadata.path)|\(metadata.byteLength)|\(mtimeMs)|\(previewMax)"
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

nonisolated private enum CommandImagePreviewDecoder {
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
