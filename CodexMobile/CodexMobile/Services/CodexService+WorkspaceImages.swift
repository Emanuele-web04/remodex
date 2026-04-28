// FILE: CodexService+WorkspaceImages.swift
// Purpose: Fetches local workspace/generated images through the paired Mac bridge on demand.
// Layer: Service extension
// Exports: WorkspaceImageReadResult, CodexService.readWorkspaceImage
// Depends on: Foundation, CodexService, JSONValue

import Foundation

struct WorkspaceImageMetadata: Sendable {
    let path: String
    let fileName: String
    let mimeType: String
    let byteLength: Int
    let mtimeMs: Double?
}

struct WorkspaceImageReadResult: Sendable {
    let path: String
    let fileName: String
    let mimeType: String
    let byteLength: Int
    let mtimeMs: Double?
    let data: Data?
    let isNotModified: Bool

    var metadata: WorkspaceImageMetadata {
        WorkspaceImageMetadata(
            path: path,
            fileName: fileName,
            mimeType: mimeType,
            byteLength: byteLength,
            mtimeMs: mtimeMs
        )
    }
}

extension CodexService {
    // Loads image bytes only after the user asks to preview them, keeping timeline rows lightweight.
    func readWorkspaceImage(
        path: String,
        cwd: String?,
        cachedMetadata: WorkspaceImageMetadata? = nil
    ) async throws -> WorkspaceImageReadResult {
        let result = try await readWorkspaceImageObject(
            path: path,
            cwd: cwd,
            includeData: true,
            cachedMetadata: cachedMetadata
        )
        let metadata = parseWorkspaceImageMetadata(result: result, fallbackPath: path)
        if result["notModified"]?.boolValue == true {
            return WorkspaceImageReadResult(
                path: metadata.path,
                fileName: metadata.fileName,
                mimeType: metadata.mimeType,
                byteLength: metadata.byteLength,
                mtimeMs: metadata.mtimeMs,
                data: nil,
                isNotModified: true
            )
        }

        guard let dataBase64 = result["dataBase64"]?.stringValue else {
            throw CodexServiceError.invalidResponse("Image preview response did not include image data.")
        }
        let data = try await WorkspaceImageBase64Decoder.decode(dataBase64)

        return WorkspaceImageReadResult(
            path: metadata.path,
            fileName: metadata.fileName,
            mimeType: metadata.mimeType,
            byteLength: metadata.byteLength,
            mtimeMs: metadata.mtimeMs,
            data: data,
            isNotModified: false
        )
    }

    private func readWorkspaceImageObject(
        path: String,
        cwd: String?,
        includeData: Bool,
        cachedMetadata: WorkspaceImageMetadata? = nil
    ) async throws -> RPCObject {
        var params: [String: JSONValue] = [
            "path": .string(path),
            "includeData": .bool(includeData)
        ]
        if let cachedMetadata {
            params["ifByteLength"] = .integer(cachedMetadata.byteLength)
            if let mtimeMs = cachedMetadata.mtimeMs {
                params["ifMtimeMs"] = .double(mtimeMs)
            }
        }
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            params["cwd"] = .string(cwd)
        }

        let response = try await sendRequest(method: "workspace/readImage", params: .object(params))
        guard let result = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("Image preview response was missing a result.")
        }
        return result
    }

    private func parseWorkspaceImageMetadata(result: RPCObject, fallbackPath path: String) -> WorkspaceImageMetadata {
        WorkspaceImageMetadata(
            path: result["path"]?.stringValue ?? path,
            fileName: result["fileName"]?.stringValue ?? (path as NSString).lastPathComponent,
            mimeType: result["mimeType"]?.stringValue ?? "image",
            byteLength: result["byteLength"]?.intValue ?? 0,
            mtimeMs: result["mtimeMs"]?.doubleValue
        )
    }
}

private enum WorkspaceImageBase64Decoder {
    static func decode(_ dataBase64: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: dataBase64) else {
                throw CodexServiceError.invalidResponse("Image preview response did not include valid image data.")
            }
            return data
        }.value
    }
}
