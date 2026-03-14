// FILE: TurnMermaidRenderer.swift
// Purpose: Detects fenced Mermaid blocks and converts them into cached static snapshots for smooth timeline scrolling.
// Layer: View Support
// Exports: MermaidMarkdownContent, MermaidMarkdownSegment, MermaidMarkdownContentCache, MermaidMarkdownContentView
// Depends on: SwiftUI, WebKit, MarkdownTextView

import Foundation
import SwiftUI
import UIKit
import WebKit

struct MermaidMarkdownContent {
    let segments: [MermaidMarkdownSegment]

    var hasMermaidBlocks: Bool {
        segments.contains { $0.kind.isMermaid }
    }
}

struct MermaidMarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case mermaid(String)

        var isMermaid: Bool {
            if case .mermaid = self {
                return true
            }
            return false
        }
    }

    let id: String
    let kind: Kind
}

enum MermaidMarkdownContentCache {
    static let maxEntries = 256
    static let lock = NSLock()
    static var contentByKey: [String: MermaidMarkdownContent?] = [:]

    // Parses Mermaid fences once per message snapshot so the timeline does not redo regex work while scrolling.
    static func content(messageID: String, text: String) -> MermaidMarkdownContent? {
        let cacheKey = "\(messageID)|\(text.hashValue)"

        lock.lock()
        if let cached = contentByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = MermaidMarkdownParser.parse(text)

        lock.lock()
        if contentByKey.count >= maxEntries {
            contentByKey.removeAll(keepingCapacity: true)
        }
        contentByKey[cacheKey] = parsed
        lock.unlock()

        return parsed
    }

    static func reset() {
        lock.lock()
        contentByKey.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

struct MermaidMarkdownContentView: View {
    let content: MermaidMarkdownContent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(content.segments) { segment in
                switch segment.kind {
                case .markdown(let markdown):
                    MarkdownTextView(
                        text: markdown,
                        profile: .assistantProse,
                        enablesSelection: enablesInlineMarkdownSelectionInTimeline
                    )
                case .mermaid(let source):
                    MermaidBlockView(source: source)
                }
            }
        }
    }
}

private struct MermaidBlockView: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var resolvedSnapshot: MermaidRenderedSnapshot?
    @State private var renderHeight: CGFloat = 160
    @State private var availableWidth: CGFloat = 0
    @State private var previewImage: PreviewImagePayload?
    @State private var saveCoordinator = ImageSaveCoordinator()
    @State private var saveAlertMessage: String?

    var body: some View {
        Group {
            if let snapshot = currentSnapshot {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    previewImage = PreviewImagePayload(image: snapshot.image, title: "Diagram")
                } label: {
                    Image(uiImage: snapshot.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: max(snapshot.height, 120))
                }
                .buttonStyle(.plain)
            } else if renderDescriptor != nil {
                MermaidSnapshotRenderer(
                    source: source,
                    descriptor: renderDescriptor,
                    renderHeight: $renderHeight
                ) { snapshot in
                    resolvedSnapshot = snapshot
                }
                .frame(maxWidth: .infinity)
                .frame(height: max(renderHeight, 120))
            } else {
                MermaidPlaceholderView()
                    .frame(maxWidth: .infinity)
                    .frame(height: max(renderHeight, 120))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if let snapshot = currentSnapshot {
                saveButton(for: snapshot)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground).opacity(0.35))
        )
        .background(widthReader)
        .onAppear(perform: refreshCachedSnapshot)
        .onChange(of: availableWidth) { _, _ in
            refreshCachedSnapshot()
        }
        .onChange(of: colorScheme) { _, _ in
            refreshCachedSnapshot()
        }
        .onChange(of: source) { _, _ in
            refreshCachedSnapshot()
        }
        .fullScreenCover(item: $previewImage) { payload in
            ZoomableImagePreviewScreen(
                payload: payload,
                onDismiss: { previewImage = nil }
            )
        }
        .alert("Image", isPresented: saveAlertIsPresented, actions: {
            Button("OK", role: .cancel) {
                saveAlertMessage = nil
            }
        }, message: {
            Text(saveAlertMessage ?? "")
        })
    }

    private var renderDescriptor: MermaidRenderDescriptor? {
        guard availableWidth > 1 else {
            return nil
        }
        return MermaidRenderDescriptor(
            source: MermaidSourceNormalizer.normalized(source),
            isDarkMode: colorScheme == .dark,
            targetWidth: availableWidth
        )
    }

    private var currentSnapshot: MermaidRenderedSnapshot? {
        if let resolvedSnapshot {
            return resolvedSnapshot
        }
        guard let descriptor = renderDescriptor else {
            return nil
        }
        return MermaidRenderedSnapshotCache.snapshot(for: descriptor)
    }

    private var widthReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    updateWidth(geometry.size.width)
                }
                .onChange(of: geometry.size.width) { _, width in
                    updateWidth(width)
                }
        }
    }

    private func updateWidth(_ width: CGFloat) {
        let normalizedWidth = max(0, floor(width))
        guard abs(normalizedWidth - availableWidth) > 0.5 else {
            return
        }
        availableWidth = normalizedWidth
    }

    private func refreshCachedSnapshot() {
        guard let descriptor = renderDescriptor else {
            resolvedSnapshot = nil
            renderHeight = 160
            return
        }

        if let cached = MermaidRenderedSnapshotCache.snapshot(for: descriptor) {
            resolvedSnapshot = cached
            renderHeight = cached.height
        } else {
            resolvedSnapshot = nil
            renderHeight = max(MermaidRenderedSnapshotCache.knownHeight(for: descriptor) ?? 160, 120)
        }
    }

    private func saveSnapshot(_ snapshot: MermaidRenderedSnapshot) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        saveCoordinator.save(snapshot.image) { result in
            switch result {
            case .success:
                saveAlertMessage = "Saved to Photos."
            case .failure(let error):
                saveAlertMessage = error.localizedDescription
            }
        }
    }

    private func saveButton(for snapshot: MermaidRenderedSnapshot) -> some View {
        Button {
            saveSnapshot(snapshot)
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(AppFont.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .padding(9)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.48))
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .padding(.trailing, 10)
        .accessibilityLabel("Save diagram")
    }

    private var saveAlertIsPresented: Binding<Bool> {
        Binding(
            get: { saveAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    saveAlertMessage = nil
                }
            }
        )
    }
}

private struct MermaidPlaceholderView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))

            Text("Rendering diagram…")
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MermaidSnapshotRenderer: UIViewRepresentable {
    let source: String
    let descriptor: MermaidRenderDescriptor?
    @Binding var renderHeight: CGFloat
    let onResolved: (MermaidRenderedSnapshot) -> Void

    func makeCoordinator() -> MermaidSnapshotRendererCoordinator {
        MermaidSnapshotRendererCoordinator(renderHeight: $renderHeight, onResolved: onResolved)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(
            context.coordinator,
            name: MermaidSnapshotRendererCoordinator.heightMessageName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        context.coordinator.loadIfNeeded(
            webView: webView,
            source: MermaidSourceNormalizer.normalized(source),
            descriptor: descriptor
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.attach(webView)
        context.coordinator.loadIfNeeded(
            webView: webView,
            source: MermaidSourceNormalizer.normalized(source),
            descriptor: descriptor
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: MermaidSnapshotRendererCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: MermaidSnapshotRendererCoordinator.heightMessageName
        )
        webView.navigationDelegate = nil
    }
}

private final class MermaidSnapshotRendererCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let heightMessageName = "mermaidHeight"

    private let renderHeight: Binding<CGFloat>
    private let onResolved: (MermaidRenderedSnapshot) -> Void
    private weak var webView: WKWebView?
    private var lastSignature: String?
    private var currentDescriptor: MermaidRenderDescriptor?
    private var hasCapturedSnapshot = false
    private var lastResolvedSignature: String?

    init(renderHeight: Binding<CGFloat>, onResolved: @escaping (MermaidRenderedSnapshot) -> Void) {
        self.renderHeight = renderHeight
        self.onResolved = onResolved
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func loadIfNeeded(webView: WKWebView, source: String, descriptor: MermaidRenderDescriptor?) {
        guard let descriptor else {
            return
        }

        let signature = descriptor.cacheKey
        if let cached = MermaidRenderedSnapshotCache.snapshot(for: descriptor) {
            // Defer binding writes so UIViewRepresentable updates never mutate SwiftUI state inline.
            commitRenderHeightIfNeeded(cached.height, signature: signature)
            lastSignature = signature
            currentDescriptor = descriptor
            hasCapturedSnapshot = true
            resolveSnapshot(cached, signature: signature)
            return
        }

        guard lastSignature != signature else {
            return
        }

        lastSignature = signature
        currentDescriptor = descriptor
        hasCapturedSnapshot = false
        lastResolvedSignature = nil
        let fallbackHeight = max(MermaidRenderedSnapshotCache.knownHeight(for: descriptor) ?? 160, 120)
        commitRenderHeightIfNeeded(fallbackHeight, signature: signature)
        webView.frame = CGRect(origin: .zero, size: CGSize(width: descriptor.targetWidth, height: fallbackHeight))

        let html = MermaidHTMLBuilder.html(source: source, isDarkMode: descriptor.isDarkMode)
        if let assetDirectoryURL = MermaidBundledAsset.scriptURL()?.deletingLastPathComponent() {
            webView.loadHTMLString(html, baseURL: assetDirectoryURL)
        } else {
            webView.loadHTMLString(MermaidHTMLBuilder.fallbackHTML(source: source), baseURL: nil)
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.heightMessageName,
              let descriptor = currentDescriptor else {
            return
        }

        let resolvedHeight: CGFloat?
        if let value = message.body as? Double {
            resolvedHeight = CGFloat(value)
        } else if let value = message.body as? Int {
            resolvedHeight = CGFloat(value)
        } else if let value = message.body as? NSNumber {
            resolvedHeight = CGFloat(truncating: value)
        } else {
            resolvedHeight = nil
        }

        guard let resolvedHeight, resolvedHeight.isFinite else {
            return
        }

        let normalizedHeight = max(120, min(resolvedHeight, 1200))
        MermaidRenderedSnapshotCache.storeKnownHeight(normalizedHeight, for: descriptor)
        commitRenderHeightIfNeeded(normalizedHeight, signature: descriptor.cacheKey)

        guard !hasCapturedSnapshot else {
            return
        }
        hasCapturedSnapshot = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.captureSnapshot(height: normalizedHeight)
        }
    }

    private func captureSnapshot(height: CGFloat) {
        guard let webView,
              let descriptor = currentDescriptor else {
            return
        }

        webView.frame = CGRect(origin: .zero, size: CGSize(width: descriptor.targetWidth, height: height))
        webView.layoutIfNeeded()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: CGSize(width: descriptor.targetWidth, height: height))
        configuration.snapshotWidth = NSNumber(value: Double(descriptor.targetWidth))

        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image else {
                self.hasCapturedSnapshot = false
                return
            }

            let snapshot = MermaidRenderedSnapshot(image: image, height: height)
            MermaidRenderedSnapshotCache.store(snapshot, for: descriptor)
            self.resolveSnapshot(snapshot, signature: descriptor.cacheKey)
        }
    }

    // Schedules height changes onto the next main-queue turn so SwiftUI never sees
    // a binding mutation from inside make/updateUIView.
    private func commitRenderHeightIfNeeded(_ height: CGFloat, signature: String) {
        guard abs(renderHeight.wrappedValue - height) > 0.5 else {
            return
        }

        DispatchQueue.main.async {
            guard self.currentDescriptor?.cacheKey == signature else {
                return
            }
            guard abs(self.renderHeight.wrappedValue - height) > 0.5 else {
                return
            }
            self.renderHeight.wrappedValue = height
        }
    }

    // Bounces snapshot resolution out of the current representable update pass.
    private func resolveSnapshot(_ snapshot: MermaidRenderedSnapshot, signature: String) {
        DispatchQueue.main.async {
            guard self.currentDescriptor?.cacheKey == signature else {
                return
            }
            guard self.lastResolvedSignature != signature else {
                return
            }
            self.lastResolvedSignature = signature
            self.onResolved(snapshot)
        }
    }
}

private struct MermaidRenderDescriptor: Hashable {
    let cacheKey: String
    let isDarkMode: Bool
    let targetWidth: CGFloat

    init(source: String, isDarkMode: Bool, targetWidth: CGFloat) {
        let roundedWidth = max(1, Int(targetWidth.rounded(.toNearestOrEven)))
        self.isDarkMode = isDarkMode
        self.targetWidth = CGFloat(roundedWidth)
        self.cacheKey = "\(isDarkMode ? "dark" : "light")|\(roundedWidth)|\(source.hashValue)"
    }
}

private struct MermaidRenderedSnapshot {
    let image: UIImage
    let height: CGFloat
}

private final class MermaidRenderedSnapshotBox: NSObject {
    let snapshot: MermaidRenderedSnapshot

    init(snapshot: MermaidRenderedSnapshot) {
        self.snapshot = snapshot
    }
}

private enum MermaidRenderedSnapshotCache {
    static let snapshotCache: NSCache<NSString, MermaidRenderedSnapshotBox> = {
        let cache = NSCache<NSString, MermaidRenderedSnapshotBox>()
        cache.countLimit = 96
        return cache
    }()
    static let lock = NSLock()
    static var knownHeightsByKey: [String: CGFloat] = [:]

    static func snapshot(for descriptor: MermaidRenderDescriptor) -> MermaidRenderedSnapshot? {
        snapshotCache.object(forKey: descriptor.cacheKey as NSString)?.snapshot
    }

    static func knownHeight(for descriptor: MermaidRenderDescriptor) -> CGFloat? {
        lock.lock()
        let height = knownHeightsByKey[descriptor.cacheKey]
        lock.unlock()
        return height
    }

    static func store(_ snapshot: MermaidRenderedSnapshot, for descriptor: MermaidRenderDescriptor) {
        snapshotCache.setObject(MermaidRenderedSnapshotBox(snapshot: snapshot), forKey: descriptor.cacheKey as NSString)
        storeKnownHeight(snapshot.height, for: descriptor)
    }

    static func storeKnownHeight(_ height: CGFloat, for descriptor: MermaidRenderDescriptor) {
        lock.lock()
        if knownHeightsByKey.count >= 256 {
            knownHeightsByKey.removeAll(keepingCapacity: true)
        }
        knownHeightsByKey[descriptor.cacheKey] = height
        lock.unlock()
    }
}

private enum MermaidBundledAsset {
    static func scriptURL() -> URL? {
        if let url = Bundle.main.url(
            forResource: "mermaid.min",
            withExtension: "js",
            subdirectory: "Resources/Mermaid"
        ) {
            return url
        }

        if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") {
            return url
        }

        return Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: nil)?
            .first(where: { $0.lastPathComponent == "mermaid.min.js" })
    }
}

enum MermaidSourceNormalizer {
    private static let looseArrowLabelRegex = try? NSRegularExpression(
        pattern: #"^(\s*.+?)\s*--\s+(.+?)\s+-->\s+(.+?)\s*$"#,
        options: []
    )
    private static let squareNodeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9_]*)\[([^\[\]\n"]+)\]"#,
        options: []
    )
    private static let decisionNodeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9_]*)\{([^{}\n"]+)\}"#,
        options: []
    )

    // Fixes common model-generated Mermaid near-misses without changing already-valid diagrams.
    static func normalized(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let normalizedArrows = normalizeLooseArrowLabels(in: String(line))
                return normalizeNodeLabels(in: normalizedArrows)
            }
            .joined(separator: "\n")
    }

    private static func normalizeLooseArrowLabels(in line: String) -> String {
        guard !line.contains("-->|"),
              line.contains("--"),
              line.contains("-->"),
              let looseArrowLabelRegex else {
            return line
        }

        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = looseArrowLabelRegex.firstMatch(in: line, range: range),
              match.numberOfRanges == 4,
              let fromRange = Range(match.range(at: 1), in: line),
              let labelRange = Range(match.range(at: 2), in: line),
              let toRange = Range(match.range(at: 3), in: line) else {
            return line
        }

        let from = String(line[fromRange]).trimmingCharacters(in: .whitespaces)
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
        let to = String(line[toRange]).trimmingCharacters(in: .whitespaces)

        guard !from.isEmpty,
              !label.isEmpty,
              !to.isEmpty else {
            return line
        }

        return "\(from) -->|\(label)| \(to)"
    }

    private static func normalizeNodeLabels(in line: String) -> String {
        let squared = replaceNodeLabels(in: line, regex: squareNodeRegex, opening: "[", closing: "]")
        return replaceNodeLabels(in: squared, regex: decisionNodeRegex, opening: "{", closing: "}")
    }

    private static func replaceNodeLabels(
        in line: String,
        regex: NSRegularExpression?,
        opening: String,
        closing: String
    ) -> String {
        guard let regex else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let mutable = NSMutableString(string: line)
        for match in matches.reversed() {
            guard match.numberOfRanges == 3 else {
                continue
            }

            let idRange = match.range(at: 1)
            let labelRange = match.range(at: 2)
            guard idRange.location != NSNotFound,
                  labelRange.location != NSNotFound else {
                continue
            }

            let nodeID = nsLine.substring(with: idRange)
            let rawLabel = nsLine.substring(with: labelRange).trimmingCharacters(in: .whitespaces)
            guard !rawLabel.isEmpty,
                  !rawLabel.hasPrefix("\""),
                  !rawLabel.hasSuffix("\"") else {
                continue
            }

            let escapedLabel = rawLabel.replacingOccurrences(of: "\"", with: "&quot;")
            let replacement = "\(nodeID)\(opening)\"\(escapedLabel)\"\(closing)"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return String(mutable)
    }
}

private enum MermaidHTMLBuilder {
    static func html(source: String, isDarkMode: Bool) -> String {
        let sourceJSON = jsonStringLiteral(source)
        let configJSON = jsonObjectLiteral(configuration(isDarkMode: isDarkMode))

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <style>
            :root {
              color-scheme: \(isDarkMode ? "dark" : "light");
            }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
            }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              overflow: hidden;
            }
            #diagram {
              width: 100%;
            }
            #diagram svg {
              width: 100%;
              height: auto;
              display: block;
            }
            #fallback {
              display: none;
              margin: 0;
              white-space: pre-wrap;
              font: 13px/1.45 "JetBrains Mono", ui-monospace, monospace;
              color: \(isDarkMode ? "#F5F5F5" : "#1A1A1A");
            }
          </style>
          <script src="mermaid.min.js"></script>
        </head>
        <body>
          <div id="diagram"></div>
          <pre id="fallback"></pre>
          <script>
            const source = \(sourceJSON);
            const config = \(configJSON);
            const diagram = document.getElementById("diagram");
            const fallback = document.getElementById("fallback");

            function reportHeight() {
              const height = Math.ceil(
                Math.max(
                  document.body.scrollHeight,
                  document.documentElement.scrollHeight,
                  diagram.getBoundingClientRect().height,
                  fallback.getBoundingClientRect().height
                )
              );
              if (window.webkit?.messageHandlers?.mermaidHeight) {
                window.webkit.messageHandlers.mermaidHeight.postMessage(height);
              }
            }

            async function renderDiagram() {
              try {
                mermaid.initialize(config);
                const result = await mermaid.render("mermaid-" + Math.random().toString(36).slice(2), source);
                diagram.innerHTML = result.svg;
                fallback.style.display = "none";
              } catch (error) {
                diagram.innerHTML = "";
                fallback.textContent = source;
                fallback.style.display = "block";
              }

              requestAnimationFrame(() => {
                reportHeight();
                setTimeout(reportHeight, 40);
              });
            }

            window.addEventListener("load", renderDiagram);
            window.addEventListener("resize", reportHeight);
          </script>
        </body>
        </html>
        """
    }

    static func fallbackHTML(source: String) -> String {
        let sourceJSON = jsonStringLiteral(source)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
            }
            body {
              white-space: pre-wrap;
              font: 13px/1.45 "JetBrains Mono", ui-monospace, monospace;
              color: #F5F5F5;
            }
          </style>
        </head>
        <body><script>document.write(\(sourceJSON).replace(/</g, "&lt;"));</script></body>
        </html>
        """
    }

    private static func configuration(isDarkMode: Bool) -> [String: Any] {
        [
            "startOnLoad": false,
            "securityLevel": "strict",
            "theme": "base",
            "fontFamily": "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
            "flowchart": [
                "useMaxWidth": true,
                "htmlLabels": true,
                "curve": "basis"
            ],
            "themeVariables": themeVariables(isDarkMode: isDarkMode)
        ]
    }

    private static func themeVariables(isDarkMode: Bool) -> [String: String] {
        if isDarkMode {
            return [
                "background": "transparent",
                "primaryColor": "#132033",
                "primaryBorderColor": "#456FAD",
                "primaryTextColor": "#EAF2FF",
                "secondaryColor": "#152A27",
                "secondaryBorderColor": "#3B8C7C",
                "secondaryTextColor": "#E7FFF9",
                "tertiaryColor": "#25153F",
                "tertiaryBorderColor": "#7554C7",
                "tertiaryTextColor": "#F3EDFF",
                "lineColor": "#8EA0B8",
                "textColor": "#F5F7FB"
            ]
        }

        return [
            "background": "transparent",
            "primaryColor": "#E8F0FF",
            "primaryBorderColor": "#4F6FB0",
            "primaryTextColor": "#13284A",
            "secondaryColor": "#E7F6F1",
            "secondaryBorderColor": "#3E8C79",
            "secondaryTextColor": "#173B33",
            "tertiaryColor": "#F1EAFE",
            "tertiaryBorderColor": "#7A57C4",
            "tertiaryTextColor": "#321C63",
            "lineColor": "#65758B",
            "textColor": "#142033"
        ]
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    private static func jsonObjectLiteral(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let literal = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return literal
    }
}

private enum MermaidMarkdownParser {
    static let mermaidRegex = try? NSRegularExpression(
        pattern: "```mermaid[^\\n]*\\n([\\s\\S]*?)```",
        options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> MermaidMarkdownContent? {
        guard text.localizedCaseInsensitiveContains("```mermaid") else {
            return nil
        }
        guard let mermaidRegex else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = mermaidRegex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return nil
        }

        var segments: [MermaidMarkdownSegment] = []
        var cursor = text.startIndex

        for match in matches {
            guard let fullMatchRange = Range(match.range, in: text),
                  match.numberOfRanges > 1,
                  let mermaidRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            appendMarkdownSegment(
                from: cursor,
                to: fullMatchRange.lowerBound,
                source: text,
                segments: &segments
            )

            let mermaidSource = String(text[mermaidRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !mermaidSource.isEmpty {
                segments.append(
                    MermaidMarkdownSegment(
                        id: "mermaid-\(match.range.location)-\(match.range.length)",
                        kind: .mermaid(mermaidSource)
                    )
                )
            }

            cursor = fullMatchRange.upperBound
        }

        appendMarkdownSegment(from: cursor, to: text.endIndex, source: text, segments: &segments)

        let content = MermaidMarkdownContent(segments: segments)
        return content.hasMermaidBlocks ? content : nil
    }

    private static func appendMarkdownSegment(
        from start: String.Index,
        to end: String.Index,
        source: String,
        segments: inout [MermaidMarkdownSegment]
    ) {
        guard start < end else {
            return
        }

        let markdown = String(source[start..<end])
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        segments.append(
            MermaidMarkdownSegment(
                id: "markdown-\(source[..<start].utf16.count)-\(source[..<end].utf16.count)",
                kind: .markdown(markdown)
            )
        )
    }
}
