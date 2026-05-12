// FILE: WorkspaceImagePreview.swift
// Purpose: Loads, caches, downsamples, and presents assistant/workspace image previews.
// Layer: Turn UI preview service
// Exports: AssistantWorkspaceImagePreviewScreen, AssistantWorkspaceImagePreviewLoader, WorkspaceImagePreviewCache
// Depends on: Foundation, ImageIO, SwiftUI, UIKit, CodexService workspace image APIs

import Foundation
import ImageIO
import SwiftUI
import UIKit

struct AssistantWorkspaceImagePreviewRequest: Identifiable {
    let id = UUID()
    let reference: AssistantMarkdownImageReference
    let currentWorkingDirectory: String?
    let initialPayload: PreviewImagePayload?
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
                    Image(systemName: "photo")
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

            Image(systemName: "arrow.up.left.and.arrow.down.right")
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
                    Image(systemName: "photo")
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
                    Button {
                        Task { await loadPreview(force: true) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(AppFont.subheadline(weight: .semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .adaptiveGlass(.regular, in: Capsule())
                    }
                    .buttonStyle(.plain)
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
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(AppFont.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .adaptiveGlass(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            if !reference.fileName.isEmpty {
                Text(reference.fileName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .adaptiveGlass(.regular, in: Capsule())
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
