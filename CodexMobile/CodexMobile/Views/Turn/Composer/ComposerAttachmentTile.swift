// FILE: ComposerAttachmentTile.swift
// Purpose: Single image-attachment thumbnail tile with remove button.
// Layer: View Component
// Exports: ComposerAttachmentTile
// Depends on: SwiftUI, TurnAttachmentPipeline

import SwiftUI

struct ComposerAttachmentTile: View {
    let attachment: TurnComposerImageAttachment
    let onRemove: (String) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch attachment.state {
                case .ready(let imageAttachment):
                    if let image = TurnAttachmentPipeline.thumbnailImage(
                        fromBase64: imageAttachment.thumbnailBase64JPEG
                    ) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholderTile
                    }

                case .loading:
                    placeholderTile
                        .overlay(ProgressView().tint(.secondary))

                case .failed:
                    placeholderTile
                        .overlay(
                            RemodexIcon.image(systemName: "exclamationmark.triangle.fill")
                                .font(AppFont.system(size: 16, weight: .semibold))
                                .foregroundStyle(.orange)
                        )
                }
            }
            .frame(
                width: TurnAttachmentThumbnailMetrics.side,
                height: TurnAttachmentThumbnailMetrics.side
            )
            .clipShape(RoundedRectangle(cornerRadius: TurnAttachmentThumbnailMetrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TurnAttachmentThumbnailMetrics.cornerRadius, style: .continuous)
                    .stroke(borderColor(for: attachment), lineWidth: 1)
            )

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onRemove(attachment.id)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.72))
                        .frame(width: 18, height: 18)

                    RemodexIcon.image(systemName: "xmark")
                        .font(AppFont.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(5)
            .accessibilityLabel("Remove image")
        }
    }

    // MARK: - Private

    private var placeholderTile: some View {
        RoundedRectangle(cornerRadius: TurnAttachmentThumbnailMetrics.cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .overlay(
                RemodexIcon.image(systemName: "photo")
                    .foregroundStyle(.secondary)
            )
    }

    private func borderColor(for attachment: TurnComposerImageAttachment) -> Color {
        switch attachment.state {
        case .failed:
            return .red
        default:
            return Color(.separator)
        }
    }
}
