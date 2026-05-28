// FILE: UserAttachmentViews.swift
// Purpose: Renders user image attachments in timeline rows and resolves preview images.
// Layer: Turn UI component
// Exports: UserAttachmentStrip, AttachmentPreviewImageResolver
// Depends on: Foundation, SwiftUI, UIKit, CodexImageAttachment, HapticFeedback

import Foundation
import SwiftUI
import UIKit

@MainActor
private enum UserAttachmentThumbnailCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for attachment: CodexImageAttachment) -> UIImage? {
        guard !attachment.thumbnailBase64JPEG.isEmpty else {
            return nil
        }

        let key = cacheKey(for: attachment)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        guard let data = Data(base64Encoded: attachment.thumbnailBase64JPEG),
              let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    // Thumbnail decoding used to happen from the SwiftUI body on every row redraw.
    private static func cacheKey(for attachment: CodexImageAttachment) -> String {
        "\(attachment.id)|\(attachment.thumbnailContentFingerprint.cacheKey)"
    }
}

private struct UserAttachmentThumbnailView: View {
    let attachment: CodexImageAttachment
    private let side = TurnAttachmentThumbnailMetrics.side
    private let cornerRadius = TurnAttachmentThumbnailMetrics.cornerRadius

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
                    RemodexIcon.image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        }
    }

    private var thumbnailUIImage: UIImage? {
        UserAttachmentThumbnailCache.image(for: attachment)
    }
}

struct UserAttachmentStrip: View {
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
    }
}

@MainActor
enum AttachmentPreviewImageResolver {
    // Uses full payload data URL first, then falls back to the cached thumbnail for resilience.
    static func resolve(_ attachment: CodexImageAttachment) -> UIImage? {
        if let payloadDataURL = attachment.payloadDataURL,
           let imageData = decodeImageDataFromDataURL(payloadDataURL),
           let image = UIImage(data: imageData) {
            return image
        }

        return UserAttachmentThumbnailCache.image(for: attachment)
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
