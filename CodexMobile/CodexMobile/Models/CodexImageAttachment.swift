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
    let thumbnailContentFingerprint: CodexTextContentFingerprint
    let payloadContentFingerprint: CodexTextContentFingerprint?
    let sourceContentFingerprint: CodexTextContentFingerprint?

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
        self.thumbnailContentFingerprint = CodexTextContentFingerprint(thumbnailBase64JPEG)
        self.payloadContentFingerprint = payloadDataURL.map(CodexTextContentFingerprint.init)
        self.sourceContentFingerprint = sourceURL.map(CodexTextContentFingerprint.init)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case thumbnailBase64JPEG
        case payloadDataURL
        case sourceURL
        case thumbnailContentFingerprint
        case payloadContentFingerprint
        case sourceContentFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        thumbnailBase64JPEG = try container.decode(String.self, forKey: .thumbnailBase64JPEG)
        payloadDataURL = try container.decodeIfPresent(String.self, forKey: .payloadDataURL)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        thumbnailContentFingerprint = try container.decodeIfPresent(
            CodexTextContentFingerprint.self,
            forKey: .thumbnailContentFingerprint
        ) ?? CodexTextContentFingerprint(thumbnailBase64JPEG)
        let decodedPayloadFingerprint = try container.decodeIfPresent(
            CodexTextContentFingerprint.self,
            forKey: .payloadContentFingerprint
        )
        payloadContentFingerprint = payloadDataURL == nil
            ? nil
            : decodedPayloadFingerprint ?? payloadDataURL.map(CodexTextContentFingerprint.init)
        let decodedSourceFingerprint = try container.decodeIfPresent(
            CodexTextContentFingerprint.self,
            forKey: .sourceContentFingerprint
        )
        sourceContentFingerprint = sourceURL == nil
            ? nil
            : decodedSourceFingerprint ?? sourceURL.map(CodexTextContentFingerprint.init)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(thumbnailBase64JPEG, forKey: .thumbnailBase64JPEG)
        try container.encodeIfPresent(payloadDataURL, forKey: .payloadDataURL)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(thumbnailContentFingerprint, forKey: .thumbnailContentFingerprint)
        try container.encodeIfPresent(payloadContentFingerprint, forKey: .payloadContentFingerprint)
        try container.encodeIfPresent(sourceContentFingerprint, forKey: .sourceContentFingerprint)
    }

    // History rows usually keep thumbnails; callers can preserve bounded inline payloads
    // when the original file path is not previewable through the workspace bridge.
    func sanitizedForStorage(preservingPayloadDataURL: Bool) -> CodexImageAttachment {
        CodexImageAttachment(
            id: id,
            thumbnailBase64JPEG: thumbnailBase64JPEG,
            payloadDataURL: preservingPayloadDataURL ? normalizedPayloadDataURL : nil,
            sourceURL: normalizedSourceURL
        )
    }

    // Keeps attachment matching stable without hashing giant inline data URLs.
    nonisolated var stableIdentityKey: String {
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

    // Used by timeline renderers to avoid empty image placeholders from path-only history items.
    nonisolated var hasPreviewPayload: Bool {
        !thumbnailBase64JPEG.isEmpty || normalizedPayloadDataURL != nil
    }

    nonisolated private var normalizedPayloadDataURL: String? {
        let trimmed = payloadDataURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private var normalizedSourceURL: String? {
        let trimmed = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !Self.isInlineImageDataURL(trimmed) else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func isInlineImageDataURL(_ value: String) -> Bool {
        value.lowercased().hasPrefix("data:image")
    }
}
