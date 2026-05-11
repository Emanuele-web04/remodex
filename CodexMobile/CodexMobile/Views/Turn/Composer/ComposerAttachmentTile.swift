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
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(AppFont.system(size: 16, weight: .semibold))
                                .foregroundStyle(.orange)
                        )
                }
            }
            .frame(
                width: TurnAttachmentPipeline.thumbnailSide,
                height: TurnAttachmentPipeline.thumbnailSide
            )
            .clipShape(RoundedRectangle(cornerRadius: TurnAttachmentPipeline.thumbnailCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TurnAttachmentPipeline.thumbnailCornerRadius, style: .continuous)
                    .stroke(borderColor(for: attachment), lineWidth: 1)
            )

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(AppFont.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .offset(x: 8, y: -8)
            .accessibilityLabel("Remove image")
        }
    }

    // MARK: - Private

    private var placeholderTile: some View {
        RoundedRectangle(cornerRadius: TurnAttachmentPipeline.thumbnailCornerRadius, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .overlay(
                Image(systemName: "photo")
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
