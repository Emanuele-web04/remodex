// FILE: CodexImageAttachment.swift
// Purpose: Defines image attachment payload persisted in user chat messages.
// Layer: Model
// Exports: CodexImageAttachment
// Depends on: Foundation

import Foundation

struct CodexImageAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let thumbnailBase64JPEG: String
    let payloadDataURL: String?
    let sourceURL: String?

    init(
        id: String = UUID().uuidString,
        thumbnailBase64JPEG: String,
        payloadDataURL: String? = nil,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.thumbnailBase64JPEG = thumbnailBase64JPEG
        self.payloadDataURL = payloadDataURL
        self.sourceURL = sourceURL
    }
}
