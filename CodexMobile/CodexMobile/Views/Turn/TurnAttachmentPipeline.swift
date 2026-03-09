// FILE: TurnAttachmentPipeline.swift
// Purpose: Normalizes picked images into payload+thumbnail and caches decoded previews.
// Layer: View Helper
// Exports: TurnAttachmentPipeline, TurnComposerImageAttachment, TurnComposerImageAttachmentState
// Depends on: SwiftUI, UIKit, CodexImageAttachment

import SwiftUI
import UIKit

struct TurnComposerImageAttachment: Identifiable {
    let id: String
    var state: TurnComposerImageAttachmentState
}

enum TurnComposerImageAttachmentState: Equatable {
    case loading
    case ready(CodexImageAttachment)
    case failed
}

enum TurnAttachmentPipeline {
    static let thumbnailSide: CGFloat = 70
    static let thumbnailCornerRadius: CGFloat = 12

    private static let maxPayloadDimension: CGFloat = 1600
    private static let payloadCompressionQuality: CGFloat = 0.8
    private static let thumbnailCompressionQuality: CGFloat = 0.8
    private static let thumbnailCache = NSCache<NSString, UIImage>()

    // Builds both payload and preview formats from raw picker data.
    static func makeAttachment(from sourceData: Data) -> CodexImageAttachment? {
        guard let normalizedJPEGData = normalizePayloadJPEG(from: sourceData),
              let thumbnailBase64 = makeThumbnailBase64JPEG(from: normalizedJPEGData) else {
            return nil
        }

        let payloadDataURL = "data:image/jpeg;base64,\(normalizedJPEGData.base64EncodedString())"
        return CodexImageAttachment(
            thumbnailBase64JPEG: thumbnailBase64,
            payloadDataURL: payloadDataURL,
            sourceURL: nil
        )
    }

    // Decodes/returns cached thumbnails so scrolling does not repeatedly decode base64.
    static func thumbnailImage(fromBase64 value: String) -> UIImage? {
        guard !value.isEmpty else {
            return nil
        }

        let cacheKey = value as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let data = Data(base64Encoded: value),
              let image = UIImage(data: data) else {
            return nil
        }

        thumbnailCache.setObject(image, forKey: cacheKey)
        return image
    }

    // Converts any image source into a normalized JPEG payload to keep network and memory predictable.
    private static func normalizePayloadJPEG(from sourceData: Data) -> Data? {
        guard let image = UIImage(data: sourceData) else {
            return nil
        }

        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let longestSide = max(sourceSize.width, sourceSize.height)
        let scale = min(1, maxPayloadDimension / longestSide)
        let targetSize = CGSize(width: floor(sourceSize.width * scale), height: floor(sourceSize.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return rendered.jpegData(compressionQuality: payloadCompressionQuality)
    }

    // Produces the exact 70x70 cover thumbnail shown in composer and user bubble.
    private static func makeThumbnailBase64JPEG(from imageData: Data) -> String? {
        guard let image = UIImage(data: imageData) else {
            return nil
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: thumbnailSide, height: thumbnailSide))
        let rendered = renderer.image { _ in
            let sourceSize = image.size
            let scale = max(thumbnailSide / sourceSize.width, thumbnailSide / sourceSize.height)
            let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = CGPoint(
                x: (thumbnailSide - scaledSize.width) / 2,
                y: (thumbnailSide - scaledSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }

        guard let jpegData = rendered.jpegData(compressionQuality: thumbnailCompressionQuality) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }
}
