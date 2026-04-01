// FILE: CodexCloudAsyncTransport.swift
// Purpose: Provides a CloudKit-backed off-LAN async lane when live relay transport is unavailable.
// Layer: Service support
// Exports: CodexTransportMode, CodexCloudAsyncAvailability, CodexAsyncRequestTransporting, CodexCloudAsyncTransport
// Depends on: CloudKit, CryptoKit, Foundation, RPCMessage, JSONValue

import CloudKit
import CryptoKit
import Foundation

enum CodexTransportMode: String, Equatable, Sendable {
    case disconnected
    case lanRelay
    case convexRemote
}

enum CodexTransportPreference: String, CaseIterable, Equatable, Hashable, Sendable {
    case automatic
    case lanOnly
    case convexOnly

    var displayName: String {
        switch self {
        case .automatic:
            return "Both (LAN Preferred)"
        case .lanOnly:
            return "LAN only"
        case .convexOnly:
            return "Convex only"
        }
    }
}

enum CodexCloudAsyncAvailability: Equatable, Sendable {
    case unavailable(String)
    case available

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

enum CodexCloudAsyncTransportError: LocalizedError {
    case unavailable(String)
    case missingSharedSecret
    case missingTrustedMac
    case invalidRecord(String)
    case invalidSignature
    case decryptFailed
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message),
             .invalidRecord(let message),
             .timedOut(let message):
            return message
        case .missingSharedSecret:
            return "Cloud async pairing is unavailable until you scan a fresh QR code."
        case .missingTrustedMac:
            return "No trusted Mac is available for Cloud async messaging."
        case .invalidSignature:
            return "Cloud async message signature verification failed."
        case .decryptFailed:
            return "Cloud async message decryption failed."
        }
    }
}

protocol CodexAsyncRequestTransporting: AnyObject {
    func availability(for service: CodexService) async -> CodexCloudAsyncAvailability
    func performRequest(
        method: String,
        params: JSONValue?,
        requestID: JSONValue,
        service: CodexService
    ) async throws -> RPCMessage
    func performNotification(
        method: String,
        params: JSONValue?,
        service: CodexService
    ) async throws
}

enum CodexCloudAsyncRuntimeSupport {
    private static let disabledBundleIdentifiersForCloudAsync: Set<String> = [
        "com.zackkirsh.remodex"
    ]

    static func isSupported(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        provisioningProfileText: String? = nil
    ) -> Bool {
        if let bundleIdentifier, disabledBundleIdentifiersForCloudAsync.contains(bundleIdentifier) {
            return false
        }

        if let profile = provisioningProfileText {
            let entitlementsSection = provisioningProfileEntitlementsSection(in: profile) ?? profile

            return entitlementsSection.contains("com.apple.developer.icloud-container-identifiers")
                || entitlementsSection.contains("com.apple.developer.icloud-services")
                || entitlementsSection.contains("com.apple.developer.ubiquity-kvstore-identifier")
        }

        #if targetEnvironment(simulator)
        return false
        #else
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }

        guard let profile = loadEmbeddedProvisioningProfile() else {
            return false
        }

        let entitlementsSection = provisioningProfileEntitlementsSection(in: profile) ?? profile

        return entitlementsSection.contains("com.apple.developer.icloud-container-identifiers")
            || entitlementsSection.contains("com.apple.developer.icloud-services")
            || entitlementsSection.contains("com.apple.developer.ubiquity-kvstore-identifier")
        #endif
    }

    private static func loadEmbeddedProvisioningProfile() -> String? {
        let profileURL = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profileURL.path),
              let data = try? Data(contentsOf: profileURL),
              let text = String(data: data, encoding: .ascii) else {
            return nil
        }
        return text
    }

    private static func provisioningProfileEntitlementsSection(in profile: String) -> String? {
        guard let entitlementsKeyRange = profile.range(of: "<key>Entitlements</key>"),
              let dictStart = profile.range(of: "<dict>", range: entitlementsKeyRange.upperBound..<profile.endIndex),
              let dictEnd = profile.range(of: "</dict>", range: dictStart.upperBound..<profile.endIndex) else {
            return nil
        }

        return String(profile[dictStart.lowerBound..<dictEnd.upperBound])
    }
}

private enum CodexCloudAsyncRecordType {
    static let conversation = "RemodexAsyncConversation"
    static let deliveryCursor = "RemodexAsyncDeliveryCursor"
    static let outbound = "RemodexAsyncOutboundMessage"
    static let inbound = "RemodexAsyncInboundMessage"
}

private enum CodexCloudAsyncRecordField {
    static let requestId = "requestId"
    static let messageId = "messageId"
    static let threadId = "threadId"
    static let fromDeviceId = "fromDeviceId"
    static let toDeviceId = "toDeviceId"
    static let method = "method"
    static let ciphertext = "ciphertext"
    static let signature = "signature"
    static let status = "status"
    static let createdAt = "createdAt"
    static let expiresAt = "expiresAt"
    static let idempotencyKey = "idempotencyKey"
    static let lastProcessedMessageId = "lastProcessedMessageId"
    static let updatedAt = "updatedAt"
}

private enum CodexCloudAsyncRecordStatus: String {
    case queued
    case processing
    case completed
    case delivered
}

final class CodexCloudAsyncTransport: CodexAsyncRequestTransporting {
    private let container: CKContainer
    private let database: CKDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let responseTimeoutNanoseconds: UInt64
    private let initialPollDelayNanoseconds: UInt64
    private let maxPollDelayNanoseconds: UInt64

    static func makeIfSupported() -> CodexAsyncRequestTransporting? {
        guard CodexCloudAsyncRuntimeSupport.isSupported() else {
            return nil
        }
        return CodexCloudAsyncTransport()
    }

    init(
        container: CKContainer = .default(),
        responseTimeoutNanoseconds: UInt64 = 60_000_000_000,
        initialPollDelayNanoseconds: UInt64 = 1_000_000_000,
        maxPollDelayNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.responseTimeoutNanoseconds = responseTimeoutNanoseconds
        self.initialPollDelayNanoseconds = initialPollDelayNanoseconds
        self.maxPollDelayNanoseconds = maxPollDelayNanoseconds
    }

    func availability(for service: CodexService) async -> CodexCloudAsyncAvailability {
        guard service.hasConvexLaneCredentials else {
            return .unavailable("Cloud async pairing is unavailable until you scan a fresh QR code.")
        }

        do {
            let status = try await accountStatus()
            switch status {
            case .available:
                return .available
            case .restricted:
                return .unavailable("iCloud is restricted on this device.")
            case .couldNotDetermine:
                return .unavailable("Could not determine iCloud availability.")
            case .noAccount:
                return .unavailable("Sign in to iCloud to use off-LAN async messaging.")
            case .temporarilyUnavailable:
                return .unavailable("iCloud is temporarily unavailable. Try again shortly.")
            @unknown default:
                return .unavailable("iCloud is unavailable on this device.")
            }
        } catch {
            return .unavailable("Could not reach CloudKit for async messaging.")
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
        let requestId = CodexOffLANAsyncMechanics.requestIDString(from: requestID)
        let payloadData = try encoder.encode(requestMessage)
        let encryptedPayload = try CodexOffLANAsyncMechanics.encryptPayload(payloadData, secret: context.sharedSecret)
        let signature = try CodexOffLANAsyncMechanics.signPayload(encryptedPayload, privateKeyBase64: service.phoneIdentityState.phoneIdentityPrivateKey)
        let outboundRecord = CKRecord(recordType: CodexCloudAsyncRecordType.outbound)
        outboundRecord[CodexCloudAsyncRecordField.requestId] = requestId as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.messageId] = UUID().uuidString as CKRecordValue
        if let threadId = CodexOffLANAsyncMechanics.threadId(for: method, params: params) {
            outboundRecord[CodexCloudAsyncRecordField.threadId] = threadId as CKRecordValue
        }
        outboundRecord[CodexCloudAsyncRecordField.fromDeviceId] = context.phoneDeviceId as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.toDeviceId] = context.macDeviceId as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.method] = method as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.ciphertext] = encryptedPayload.base64EncodedString() as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.signature] = signature as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.status] = CodexCloudAsyncRecordStatus.queued.rawValue as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.createdAt] = Date() as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.expiresAt] = Date().addingTimeInterval(60 * 60) as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.idempotencyKey] = "\(requestId)|\(context.phoneDeviceId)" as CKRecordValue
        _ = try await save(record: outboundRecord)
        if let threadId = CodexOffLANAsyncMechanics.threadId(for: method, params: params) {
            try await upsertConversationRecord(threadId: threadId, macDeviceId: context.macDeviceId)
        }

        guard let responseRecord = try await pollForResponse(
            requestId: requestId,
            phoneDeviceId: context.phoneDeviceId
        ) else {
            throw CodexCloudAsyncTransportError.timedOut(
                "Timed out waiting for the Mac to respond over Cloud async transport."
            )
        }

        try await markInboundRecordDelivered(responseRecord)
        try await upsertDeliveryCursorRecord(deviceId: context.phoneDeviceId, lastProcessedMessageId: requestId)
        return try decodeResponseRecord(responseRecord, macIdentityPublicKey: context.macIdentityPublicKey, sharedSecret: context.sharedSecret)
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
        let encryptedPayload = try CodexOffLANAsyncMechanics.encryptPayload(payloadData, secret: context.sharedSecret)
        let signature = try CodexOffLANAsyncMechanics.signPayload(encryptedPayload, privateKeyBase64: service.phoneIdentityState.phoneIdentityPrivateKey)
        let outboundRecord = CKRecord(recordType: CodexCloudAsyncRecordType.outbound)
        outboundRecord[CodexCloudAsyncRecordField.messageId] = UUID().uuidString as CKRecordValue
        if let threadId = CodexOffLANAsyncMechanics.threadId(for: method, params: params) {
            outboundRecord[CodexCloudAsyncRecordField.threadId] = threadId as CKRecordValue
        }
        outboundRecord[CodexCloudAsyncRecordField.fromDeviceId] = context.phoneDeviceId as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.toDeviceId] = context.macDeviceId as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.method] = method as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.ciphertext] = encryptedPayload.base64EncodedString() as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.signature] = signature as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.status] = CodexCloudAsyncRecordStatus.queued.rawValue as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.createdAt] = Date() as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.expiresAt] = Date().addingTimeInterval(30 * 60) as CKRecordValue
        outboundRecord[CodexCloudAsyncRecordField.idempotencyKey] = "notification|\(UUID().uuidString)" as CKRecordValue
        _ = try await save(record: outboundRecord)
        if let threadId = CodexOffLANAsyncMechanics.threadId(for: method, params: params) {
            try await upsertConversationRecord(threadId: threadId, macDeviceId: context.macDeviceId)
        }
    }
}

private extension CodexCloudAsyncTransport {
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
            throw CodexCloudAsyncTransportError.unavailable("Cloud async transport is unavailable.")
        }
    }

    func makeContext(for service: CodexService) throws -> Context {
        guard let phoneDeviceId = service.phoneIdentityState.phoneDeviceId.nilIfEmpty else {
            throw CodexCloudAsyncTransportError.missingTrustedMac
        }
        guard let credentials = service.cloudAsyncFallbackCredentials,
              let secretData = credentials.sharedSecretData else {
            throw CodexCloudAsyncTransportError.missingTrustedMac
        }
        return Context(
            phoneDeviceId: phoneDeviceId,
            macDeviceId: credentials.macDeviceId,
            macIdentityPublicKey: credentials.macIdentityPublicKey,
            sharedSecret: SymmetricKey(data: secretData)
        )
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    func save(record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let savedRecord {
                    continuation.resume(returning: savedRecord)
                } else {
                    continuation.resume(throwing: CodexCloudAsyncTransportError.invalidRecord("Cloud async save returned no record."))
                }
            }
        }
    }

    func upsertConversationRecord(threadId: String, macDeviceId: String) async throws {
        let recordID = CKRecord.ID(recordName: "conversation.\(macDeviceId).\(threadId)")
        let record = try? await fetchRecord(recordID: recordID)
        let conversationRecord = record ?? CKRecord(recordType: CodexCloudAsyncRecordType.conversation, recordID: recordID)
        conversationRecord[CodexCloudAsyncRecordField.threadId] = threadId as CKRecordValue
        conversationRecord[CodexCloudAsyncRecordField.toDeviceId] = macDeviceId as CKRecordValue
        conversationRecord[CodexCloudAsyncRecordField.updatedAt] = Date() as CKRecordValue
        _ = try await save(record: conversationRecord)
    }

    func upsertDeliveryCursorRecord(deviceId: String, lastProcessedMessageId: String) async throws {
        let recordID = CKRecord.ID(recordName: "cursor.\(deviceId)")
        let record = try? await fetchRecord(recordID: recordID)
        let cursorRecord = record ?? CKRecord(recordType: CodexCloudAsyncRecordType.deliveryCursor, recordID: recordID)
        cursorRecord[CodexCloudAsyncRecordField.toDeviceId] = deviceId as CKRecordValue
        cursorRecord[CodexCloudAsyncRecordField.lastProcessedMessageId] = lastProcessedMessageId as CKRecordValue
        cursorRecord[CodexCloudAsyncRecordField.updatedAt] = Date() as CKRecordValue
        _ = try await save(record: cursorRecord)
    }

    func pollForResponse(requestId: String, phoneDeviceId: String) async throws -> CKRecord? {
        try await CodexOffLANAsyncMechanics.pollForResponse(
            responseTimeoutNanoseconds: responseTimeoutNanoseconds,
            initialPollDelayNanoseconds: initialPollDelayNanoseconds,
            maxPollDelayNanoseconds: maxPollDelayNanoseconds
        ) {
            try await self.fetchResponseRecord(requestId: requestId, phoneDeviceId: phoneDeviceId)
        }
    }

    func fetchResponseRecord(requestId: String, phoneDeviceId: String) async throws -> CKRecord? {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CodexCloudAsyncRecordField.requestId,
            requestId,
            CodexCloudAsyncRecordField.toDeviceId,
            phoneDeviceId
        )
        let query = CKQuery(recordType: CodexCloudAsyncRecordType.inbound, predicate: predicate)
        return try await withCheckedThrowingContinuation { continuation in
            var firstMatch: CKRecord?
            let operation = CKQueryOperation(query: query)
            operation.resultsLimit = 1
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result, firstMatch == nil {
                    firstMatch = record
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: firstMatch)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(throwing: CodexCloudAsyncTransportError.invalidRecord("Cloud async record was missing."))
                }
            }
        }
    }

    func markInboundRecordDelivered(_ record: CKRecord) async throws {
        record[CodexCloudAsyncRecordField.status] = CodexCloudAsyncRecordStatus.delivered.rawValue as CKRecordValue
        _ = try await save(record: record)
    }

    func decodeResponseRecord(
        _ record: CKRecord,
        macIdentityPublicKey: String,
        sharedSecret: SymmetricKey
    ) throws -> RPCMessage {
        guard let ciphertext = record[CodexCloudAsyncRecordField.ciphertext] as? String,
              let signature = record[CodexCloudAsyncRecordField.signature] as? String else {
            throw CodexCloudAsyncTransportError.invalidRecord("Cloud async response record is incomplete.")
        }
        let encryptedPayload = Data(base64EncodedOrEmpty: ciphertext)
        let verified = try CodexOffLANAsyncMechanics.verifyPayload(
            encryptedPayload,
            signatureBase64: signature,
            publicKeyBase64: macIdentityPublicKey
        )
        guard verified else {
            throw CodexCloudAsyncTransportError.invalidSignature
        }
        let plaintext = try CodexOffLANAsyncMechanics.decryptPayload(encryptedPayload, secret: sharedSecret)
        return try decoder.decode(RPCMessage.self, from: plaintext)
    }

}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CodexOffLANAsyncMechanics {
    static func pollForResponse<T>(
        responseTimeoutNanoseconds: UInt64,
        initialPollDelayNanoseconds: UInt64,
        maxPollDelayNanoseconds: UInt64,
        fetchRecord: () async throws -> T?
    ) async throws -> T? {
        let startedAt = Date()
        var nextDelay = initialPollDelayNanoseconds
        while Date().timeIntervalSince(startedAt) < TimeInterval(responseTimeoutNanoseconds) / 1_000_000_000 {
            if let responseRecord = try await fetchRecord() {
                return responseRecord
            }
            try await Task.sleep(nanoseconds: nextDelay)
            nextDelay = min(maxPollDelayNanoseconds, nextDelay + 500_000_000)
        }
        return nil
    }

    static func encryptPayload(_ payload: Data, secret: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(payload, using: secret)
        guard let combined = sealedBox.combined else {
            throw CodexCloudAsyncTransportError.decryptFailed
        }
        return combined
    }

    static func decryptPayload(_ payload: Data, secret: SymmetricKey) throws -> Data {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: payload) else {
            throw CodexCloudAsyncTransportError.decryptFailed
        }
        guard let plaintext = try? AES.GCM.open(sealedBox, using: secret) else {
            throw CodexCloudAsyncTransportError.decryptFailed
        }
        return plaintext
    }

    static func signPayload(_ payload: Data, privateKeyBase64: String) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64EncodedOrEmpty: privateKeyBase64)
        )
        let signature = try privateKey.signature(for: payload)
        return signature.base64EncodedString()
    }

    static func verifyPayload(_ payload: Data, signatureBase64: String, publicKeyBase64: String) throws -> Bool {
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64EncodedOrEmpty: publicKeyBase64)
        )
        return publicKey.isValidSignature(Data(base64EncodedOrEmpty: signatureBase64), for: payload)
    }

    static func threadId(for _: String, params: JSONValue?) -> String? {
        let object = params?.objectValue
        return object?["threadId"]?.stringValue
            ?? object?["thread_id"]?.stringValue
    }

    static func requestIDString(from id: JSONValue) -> String {
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

    static func idempotencyKey(requestId: String?, messageId: String, fromDeviceId: String) -> String {
        if let requestId {
            return "\(requestId)|\(fromDeviceId)"
        }
        return "notification|\(messageId)|\(fromDeviceId)"
    }
}
