// FILE: ComposerAttachmentsPreview.swift
// Purpose: Horizontal scrolling strip of image-attachment tiles.
// Layer: View Component
// Exports: ComposerAttachmentsPreview
// Depends on: SwiftUI, ComposerAttachmentTile

import SwiftUI

struct ComposerAttachmentsPreview: View {
    let attachments: [TurnComposerImageAttachment]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentTile(attachment: attachment, onRemove: onRemove)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
