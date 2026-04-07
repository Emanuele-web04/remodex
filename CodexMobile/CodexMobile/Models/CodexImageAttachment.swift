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

    // History rows only need a thumbnail and, when available, a lightweight remote URL.
    func sanitizedForStorage(preservingPayloadDataURL: Bool) -> CodexImageAttachment {
        CodexImageAttachment(
            id: id,
            thumbnailBase64JPEG: thumbnailBase64JPEG,
            payloadDataURL: preservingPayloadDataURL ? normalizedPayloadDataURL : nil,
            sourceURL: normalizedSourceURL
        )
    }

    // Keeps attachment matching stable without hashing giant inline data URLs.
    var stableIdentityKey: String {
        if let normalizedSourceURL {
            return normalizedSourceURL
        }
        if !thumbnailBase64JPEG.isEmpty {
            return thumbnailBase64JPEG
        }
        if let normalizedPayloadDataURL {
            return normalizedPayloadDataURL
        }
        return id
    }

    private var normalizedPayloadDataURL: String? {
        let trimmed = payloadDataURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedSourceURL: String? {
        let trimmed = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !Self.isInlineImageDataURL(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func isInlineImageDataURL(_ value: String) -> Bool {
        value.lowercased().hasPrefix("data:image")
    }
}
