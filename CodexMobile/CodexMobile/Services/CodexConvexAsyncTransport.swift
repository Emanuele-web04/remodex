// FILE: CodexConvexAsyncTransport.swift
// Purpose: Provides a Convex-backed request/response fallback when live relay transport is unavailable.
// Layer: Service support
// Exports: CodexConvexAsyncTransport
// Depends on: Foundation, CryptoKit, RPCMessage, JSONValue

import CryptoKit
import Foundation

struct CodexConvexAsyncRequestResult: Sendable {
    let data: Data
    let statusCode: Int
}

typealias CodexConvexAsyncRequestExecutor = @Sendable (URLRequest) throws -> CodexConvexAsyncRequestResult

enum CodexConvexAsyncEndpoint {
    case health
    case outboundEnqueue
    case responsePoll
    case responseDelivered

    var pathComponents: [String] {
        switch self {
        case .health:
            return ["async", "health"]
        case .outboundEnqueue:
            return ["async", "outbound", "enqueue"]
        case .responsePoll:
            return ["async", "inbound", "poll"]
        case .responseDelivered:
            return ["async", "inbound", "delivered"]
        }
    }
}

private enum CodexConvexAsyncRecordStatus: String, Codable {
    case queued
    case processing
    case completed
    case delivered
}

private struct CodexConvexAsyncRecord: Codable, Sendable {
    let recordName: String?
    let requestId: String?
    let messageId: String
    let threadId: String?
    let fromDeviceId: String
    let toDeviceId: String
    let method: String
    let ciphertext: String
    let signature: String
    let status: CodexConvexAsyncRecordStatus
    let createdAt: Date
    let expiresAt: Date
    let idempotencyKey: String
}

private struct CodexConvexAsyncPollRequest: Codable, Sendable {
    let requestId: String
    let phoneDeviceId: String
}

private struct CodexConvexAsyncPollResponse: Codable, Sendable {
    let record: CodexConvexAsyncRecord?
}

private struct CodexConvexAsyncDeliveredRequest: Codable, Sendable {
    let recordName: String?
    let requestId: String
    let phoneDeviceId: String
    let deliveredAt: Double
}

private struct CodexConvexAsyncHealthResponse: Codable, Sendable {
    let status: String?
    let provider: String?
}

final class CodexConvexAsyncTransport: CodexAsyncRequestTransporting {
    private let siteURL: URL
    private let session: URLSession?
    private let requestExecutor: CodexConvexAsyncRequestExecutor?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let responseTimeoutNanoseconds: UInt64
    private let initialPollDelayNanoseconds: UInt64
    private let maxPollDelayNanoseconds: UInt64
    private let requestTimeoutSeconds: TimeInterval

    static func isConfigured(siteURL: URL?) -> Bool {
        guard let siteURL,
              let scheme = siteURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = siteURL.host,
              !host.isEmpty,
              siteURL.query == nil,
              siteURL.fragment == nil else {
            return false
        }

        guard siteURL.path.isEmpty || siteURL.path == "/" else {
            return false
        }
        return true
    }

    init(
        siteURL: URL,
        responseTimeoutNanoseconds: UInt64 = 60_000_000_000,
        initialPollDelayNanoseconds: UInt64 = 1_000_000_000,
        maxPollDelayNanoseconds: UInt64 = 3_000_000_000,
        requestTimeoutSeconds: TimeInterval = 30,
        requestExecutor: CodexConvexAsyncRequestExecutor? = nil
    ) {
        self.siteURL = siteURL
        self.responseTimeoutNanoseconds = responseTimeoutNanoseconds
        self.initialPollDelayNanoseconds = initialPollDelayNanoseconds
        self.maxPollDelayNanoseconds = maxPollDelayNanoseconds
        self.requestTimeoutSeconds = requestTimeoutSeconds

        if let requestExecutor {
            self.session = nil
            self.requestExecutor = requestExecutor
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.httpAdditionalHeaders = [
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: configuration)
            self.requestExecutor = nil
        }

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func endpointURL(_ endpoint: CodexConvexAsyncEndpoint) -> URL {
        endpoint.pathComponents.reduce(siteURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
    }

    func availability(for service: CodexService) async -> CodexCloudAsyncAvailability {
        await availability(hasConvexLaneCredentials: service.hasConvexLaneCredentials)
    }

    func availability(hasConvexLaneCredentials: Bool) async -> CodexCloudAsyncAvailability {
        guard Self.isConfigured(siteURL: siteURL) else {
            return .unavailable("Convex async transport is not configured.")
        }

        guard hasConvexLaneCredentials else {
            return .unavailable("Off-LAN async pairing is unavailable until you scan a fresh QR code.")
        }

        do {
            let data = try await performJSONRequest(
                endpoint: .health,
                method: "GET",
                body: nil,
                acceptableStatusCodes: [200, 204]
            )
            if let data, !data.isEmpty {
                let health = try decoder.decode(CodexConvexAsyncHealthResponse.self, from: data)
                let status = health.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if status != "ok" {
                    return .unavailable("Convex async transport reported it is unavailable.")
                }
                let provider = health.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard provider == "convex" else {
                    return .unavailable("Convex async transport reported an unexpected provider.")
                }
            }
            return .available
        } catch {
            return .unavailable("Could not reach Convex for off-LAN async messaging.")
        }
    }

    func performRequest(
        method: String,
        params: JSONValue?,
        requestID: JSONValue,
        service: CodexService
    ) async throws -> RPCMessage {
        try await ensureAvailability(for: service)
        let context = try makeContext(for: service)
        let requestMessage = RPCMessage(
            id: requestID,
            method: method,
            params: params,
            includeJSONRPC: false
        )
        let requestId = requestIDString(from: requestID)
        let payloadData = try encoder.encode(requestMessage)
        let encryptedPayload = try encryptPayload(payloadData, secret: context.sharedSecret)
        let signature = try signPayload(
            encryptedPayload,
            privateKeyBase64: service.phoneIdentityState.phoneIdentityPrivateKey
        )
        let outboundRecord = makeOutboundRecord(
            requestId: requestId,
            messageId: UUID().uuidString,
            threadId: threadId(for: method, params: params),
            fromDeviceId: context.phoneDeviceId,
            toDeviceId: context.macDeviceId,
            method: method,
            ciphertext: encryptedPayload.base64EncodedString(),
            signature: signature,
            status: .queued,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
        try await enqueueOutbound(outboundRecord)

        guard let responseRecord = try await pollForResponse(
            requestId: requestId,
            phoneDeviceId: context.phoneDeviceId,
            context: context
        ) else {
            throw CodexCloudAsyncTransportError.timedOut(
                "Timed out waiting for the Mac to respond over Convex transport."
            )
        }

        let response = try decodeResponseRecord(
            responseRecord,
            context: context
        )
        try await markInboundRecordDelivered(
            requestId: requestId,
            recordName: responseRecord.recordName,
            phoneDeviceId: context.phoneDeviceId
        )
        return response
    }

    func performNotification(
        method: String,
        params: JSONValue?,
        service: CodexService
    ) async throws {
        try await ensureAvailability(for: service)
        let context = try makeContext(for: service)
        let notificationMessage = RPCMessage(
            jsonrpc: nil,
            id: nil,
            method: method,
            params: params,
            result: nil,
            error: nil
        )
        let payloadData = try encoder.encode(notificationMessage)
        let encryptedPayload = try encryptPayload(payloadData, secret: context.sharedSecret)
        let signature = try signPayload(
            encryptedPayload,
            privateKeyBase64: service.phoneIdentityState.phoneIdentityPrivateKey
        )
        let outboundRecord = makeOutboundRecord(
            requestId: nil,
            messageId: UUID().uuidString,
            threadId: threadId(for: method, params: params),
            fromDeviceId: context.phoneDeviceId,
            toDeviceId: context.macDeviceId,
            method: method,
            ciphertext: encryptedPayload.base64EncodedString(),
            signature: signature,
            status: .queued,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(30 * 60)
        )
        try await enqueueOutbound(outboundRecord)
    }
}

private extension CodexConvexAsyncTransport {
    struct Context {
        let phoneDeviceId: String
        let macDeviceId: String
        let macIdentityPublicKey: String
        let sharedSecret: SymmetricKey
    }

    func ensureAvailability(for service: CodexService) async throws {
        let state = await availability(for: service)
        guard case .available = state else {
            if case .unavailable(let message) = state {
                throw CodexCloudAsyncTransportError.unavailable(message)
            }
            throw CodexCloudAsyncTransportError.unavailable("Convex async transport is unavailable.")
        }
    }

    func makeContext(for service: CodexService) throws -> Context {
        guard let phoneDeviceId = service.phoneIdentityState.phoneDeviceId.nilIfEmpty else {
            throw CodexCloudAsyncTransportError.unavailable(
                "Off-LAN async pairing is unavailable until you scan a fresh QR code."
            )
        }
        guard let credentials = service.convexLaneCredentials,
              let secretData = credentials.sharedSecretData else {
            throw CodexCloudAsyncTransportError.unavailable(
                "Off-LAN async pairing is unavailable until you scan a fresh QR code."
            )
        }
        return Context(
            phoneDeviceId: phoneDeviceId,
            macDeviceId: credentials.macDeviceId,
            macIdentityPublicKey: credentials.macIdentityPublicKey,
            sharedSecret: SymmetricKey(data: secretData)
        )
    }

    func makeOutboundRecord(
        requestId: String?,
        messageId: String,
        threadId: String?,
        fromDeviceId: String,
        toDeviceId: String,
        method: String,
        ciphertext: String,
        signature: String,
        status: CodexConvexAsyncRecordStatus,
        createdAt: Date,
        expiresAt: Date
    ) -> CodexConvexAsyncRecord {
        CodexConvexAsyncRecord(
            recordName: nil,
            requestId: requestId,
            messageId: messageId,
            threadId: threadId,
            fromDeviceId: fromDeviceId,
            toDeviceId: toDeviceId,
            method: method,
            ciphertext: ciphertext,
            signature: signature,
            status: status,
            createdAt: createdAt,
            expiresAt: expiresAt,
            idempotencyKey: idempotencyKey(requestId: requestId, messageId: messageId, fromDeviceId: fromDeviceId)
        )
    }

    func enqueueOutbound(_ record: CodexConvexAsyncRecord) async throws {
        _ = try await performJSONRequest(
            endpoint: .outboundEnqueue,
            method: "POST",
            body: try encoder.encode(record),
            acceptableStatusCodes: [200, 201, 202, 204]
        )
    }

    func pollForResponse(
        requestId: String,
        phoneDeviceId: String,
        context: Context
    ) async throws -> CodexConvexAsyncRecord? {
        let startedAt = Date()
        var nextDelay = initialPollDelayNanoseconds

        while Date().timeIntervalSince(startedAt) < TimeInterval(responseTimeoutNanoseconds) / 1_000_000_000 {
            if let responseRecord = try await fetchResponseRecord(
                requestId: requestId,
                phoneDeviceId: phoneDeviceId,
                context: context
            ) {
                return responseRecord
            }
            try await Task.sleep(nanoseconds: nextDelay)
            nextDelay = min(maxPollDelayNanoseconds, nextDelay + 500_000_000)
        }

        return nil
    }

    func fetchResponseRecord(
        requestId: String,
        phoneDeviceId: String,
        context: Context
    ) async throws -> CodexConvexAsyncRecord? {
        let request = CodexConvexAsyncPollRequest(
            requestId: requestId,
            phoneDeviceId: phoneDeviceId
        )
        let data = try await performJSONRequest(
            endpoint: .responsePoll,
            method: "POST",
            body: try encoder.encode(request),
            acceptableStatusCodes: [200, 204]
        )
        guard let data, !data.isEmpty else {
            return nil
        }
        let response = try decoder.decode(CodexConvexAsyncPollResponse.self, from: data)
        guard let record = response.record else {
            return nil
        }
        try validateInboundRecord(
            record,
            expectedRequestId: requestId,
            expectedPhoneDeviceId: phoneDeviceId,
            expectedMacDeviceId: context.macDeviceId
        )
        return record
    }

    func markInboundRecordDelivered(
        requestId: String,
        recordName: String?,
        phoneDeviceId: String
    ) async throws {
        let request = CodexConvexAsyncDeliveredRequest(
            recordName: recordName,
            requestId: requestId,
            phoneDeviceId: phoneDeviceId,
            deliveredAt: Date().timeIntervalSince1970 * 1000
        )
        _ = try await performJSONRequest(
            endpoint: .responseDelivered,
            method: "POST",
            body: try encoder.encode(request),
            acceptableStatusCodes: [200, 204]
        )
    }

    func decodeResponseRecord(
        _ record: CodexConvexAsyncRecord,
        context: Context
    ) throws -> RPCMessage {
        let encryptedPayload = Data(base64EncodedOrEmpty: record.ciphertext)
        let verified = try verifyPayload(
            encryptedPayload,
            signatureBase64: record.signature,
            publicKeyBase64: context.macIdentityPublicKey
        )
        guard verified else {
            throw CodexCloudAsyncTransportError.invalidSignature
        }
        let plaintext = try decryptPayload(encryptedPayload, secret: context.sharedSecret)
        return try decoder.decode(RPCMessage.self, from: plaintext)
    }

    func validateInboundRecord(
        _ record: CodexConvexAsyncRecord,
        expectedRequestId: String,
        expectedPhoneDeviceId: String,
        expectedMacDeviceId: String
    ) throws {
        guard record.requestId == expectedRequestId else {
            throw CodexCloudAsyncTransportError.invalidRecord(
                "Convex async response request id did not match the original request."
            )
        }
        guard record.toDeviceId == expectedPhoneDeviceId else {
            throw CodexCloudAsyncTransportError.invalidRecord(
                "Convex async response was not addressed to this phone."
            )
        }
        guard record.fromDeviceId == expectedMacDeviceId else {
            throw CodexCloudAsyncTransportError.invalidRecord(
                "Convex async response did not come from the trusted Mac."
            )
        }
        guard !record.messageId.isEmpty else {
            throw CodexCloudAsyncTransportError.invalidRecord(
                "Convex async response record was missing a message id."
            )
        }
    }

    func performJSONRequest(
        endpoint: CodexConvexAsyncEndpoint,
        method: String,
        body: Data?,
        acceptableStatusCodes: Set<Int>
    ) async throws -> Data? {
        var request = URLRequest(url: endpointURL(endpoint))
        request.httpMethod = method
        request.timeoutInterval = requestTimeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let requestExecutor = self.requestExecutor
        let session = self.session
        let result: CodexConvexAsyncRequestResult
        if let requestExecutor {
            result = try requestExecutor(request)
        } else if let session {
            let (data, response) = try await session.data(for: request)
            result = CodexConvexAsyncRequestResult(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        } else {
            throw CodexCloudAsyncTransportError.unavailable("Convex async transport is not configured.")
        }
        guard acceptableStatusCodes.contains(result.statusCode) else {
            let responseText = String(data: result.data, encoding: .utf8)
            let suffix = responseText.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            throw CodexCloudAsyncTransportError.unavailable(
                "Convex async request failed with HTTP \(result.statusCode)\(suffix)"
            )
        }

        return result.data.isEmpty ? nil : result.data
    }

    func encryptPayload(_ payload: Data, secret: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(payload, using: secret)
        guard let combined = sealedBox.combined else {
            throw CodexCloudAsyncTransportError.decryptFailed
        }
        return combined
    }

    func decryptPayload(_ payload: Data, secret: SymmetricKey) throws -> Data {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: payload) else {
            throw CodexCloudAsyncTransportError.decryptFailed
        }
        guard let plaintext = try? AES.GCM.open(sealedBox, using: secret) else {
            throw CodexCloudAsyncTransportError.decryptFailed
        }
        return plaintext
    }

    func signPayload(_ payload: Data, privateKeyBase64: String) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64EncodedOrEmpty: privateKeyBase64)
        )
        let signature = try privateKey.signature(for: payload)
        return signature.base64EncodedString()
    }

    func verifyPayload(_ payload: Data, signatureBase64: String, publicKeyBase64: String) throws -> Bool {
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64EncodedOrEmpty: publicKeyBase64)
        )
        return publicKey.isValidSignature(Data(base64EncodedOrEmpty: signatureBase64), for: payload)
    }

    func threadId(for _: String, params: JSONValue?) -> String? {
        let object = params?.objectValue
        return object?["threadId"]?.stringValue
            ?? object?["thread_id"]?.stringValue
    }

    func requestIDString(from id: JSONValue) -> String {
        switch id {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return UUID().uuidString
        case .object, .array:
            return UUID().uuidString
        }
    }

    func idempotencyKey(requestId: String?, messageId: String, fromDeviceId: String) -> String {
        if let requestId {
            return "\(requestId)|\(fromDeviceId)"
        }

        return "notification|\(messageId)|\(fromDeviceId)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
