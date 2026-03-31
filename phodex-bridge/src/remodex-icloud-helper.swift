import CloudKit
import CryptoKit
import Darwin
import Foundation

private enum RecordType {
    static let outbound = "RemodexAsyncOutboundMessage"
    static let inbound = "RemodexAsyncInboundMessage"
}

private enum RecordField {
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
}

private enum RecordStatus: String {
    case queued
    case processing
    case completed
    case delivered
}

private struct DeviceState: Decodable {
    let version: Int
    let macDeviceId: String
    let macIdentityPublicKey: String
    let macIdentityPrivateKey: String
    let cloudAsyncSharedSecret: String?
    let trustedPhones: [String: String]
}

private struct PendingRequest {
    let recordName: String
    let fromDeviceId: String
    let requestId: String
}

private enum HelperError: LocalizedError {
    case invalidConfiguration(String)
    case invalidRecord(String)
    case invalidSignature
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidRecord(let message):
            return message
        case .invalidSignature:
            return "Cloud async helper signature verification failed."
        case .decryptFailed:
            return "Cloud async helper could not decrypt the payload."
        }
    }
}

actor CloudAsyncHelperRuntime {
    private let database: CKDatabase
    private let deviceState: DeviceState
    private let sharedSecret: SymmetricKey
    private var pendingRequestsByRecordName: [String: PendingRequest] = [:]
    private let stdoutHandle = FileHandle.standardOutput
    private let stderrHandle = FileHandle.standardError

    init(containerIdentifier: String?) throws {
        let normalizedContainer = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let container = (normalizedContainer?.isEmpty == false)
            ? CKContainer(identifier: normalizedContainer!)
            : CKContainer.default()
        self.database = container.privateCloudDatabase
        self.deviceState = try Self.readDeviceState()
        guard let secretData = Data(base64Encoded: deviceState.cloudAsyncSharedSecret ?? "") else {
            throw HelperError.invalidConfiguration("Missing cloudAsyncSharedSecret in bridge device state.")
        }
        self.sharedSecret = SymmetricKey(data: secretData)
    }

    func run() async throws {
        emitStatus(available: true, lastError: "")
        async let stdinTask: Void = listenForBridgeMessages()
        async let pollTask: Void = pollLoop()
        _ = try await (stdinTask, pollTask)
    }

    private func listenForBridgeMessages() async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["kind"] as? String else {
                emitStatus(available: false, lastError: "Received malformed bridge message.")
                continue
            }
            switch kind {
            case "asyncResponse":
                try await handleBridgeResponse(object)
            case "asyncError":
                try await handleBridgeError(object)
            default:
                continue
            }
        }
    }

    private func pollLoop() async throws {
        while !Task.isCancelled {
            do {
                let records = try await fetchQueuedOutboundRecords()
                for record in records {
                    try await deliver(record)
                }
            } catch {
                emitStatus(available: false, lastError: error.localizedDescription)
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func fetchQueuedOutboundRecords() async throws -> [CKRecord] {
        let predicate = NSPredicate(
            format: "%K == %@ AND (%K == %@ OR %K == %@)",
            RecordField.toDeviceId,
            deviceState.macDeviceId,
            RecordField.status,
            RecordStatus.queued.rawValue,
            RecordField.status,
            RecordStatus.processing.rawValue
        )
        let query = CKQuery(recordType: RecordType.outbound, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: RecordField.createdAt, ascending: true)]
        return try await withCheckedThrowingContinuation { continuation in
            var records: [CKRecord] = []
            let operation = CKQueryOperation(query: query)
            operation.resultsLimit = 20
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result {
                    records.append(record)
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func deliver(_ record: CKRecord) async throws {
        let recordName = record.recordID.recordName
        guard pendingRequestsByRecordName[recordName] == nil else {
            return
        }
        guard let ciphertext = record[RecordField.ciphertext] as? String,
              let signature = record[RecordField.signature] as? String,
              let fromDeviceId = record[RecordField.fromDeviceId] as? String else {
            throw HelperError.invalidRecord("Outbound Cloud async record is incomplete.")
        }
        guard let trustedPhonePublicKey = deviceState.trustedPhones[fromDeviceId] else {
            throw HelperError.invalidRecord("Outbound Cloud async record came from an untrusted phone.")
        }
        let encryptedPayload = Data(base64EncodedOrEmpty: ciphertext)
        let isValid = try verifySignature(
            payload: encryptedPayload,
            signatureBase64: signature,
            publicKeyBase64: trustedPhonePublicKey
        )
        guard isValid else {
            throw HelperError.invalidSignature
        }
        let plaintext = try decryptPayload(encryptedPayload)
        let payloadText = String(data: plaintext, encoding: .utf8) ?? ""
        guard !payloadText.isEmpty else {
            throw HelperError.invalidRecord("Outbound Cloud async payload was empty.")
        }
        let requestId = (record[RecordField.requestId] as? String) ?? ""
        record[RecordField.status] = RecordStatus.processing.rawValue as CKRecordValue
        _ = try await save(record)
        pendingRequestsByRecordName[recordName] = PendingRequest(
            recordName: recordName,
            fromDeviceId: fromDeviceId,
            requestId: requestId
        )
        emitJSON([
            "kind": "asyncRequest",
            "recordName": recordName,
            "requestId": requestId,
            "payloadText": payloadText,
        ])
    }

    private func handleBridgeResponse(_ object: [String: Any]) async throws {
        guard let recordName = object["recordName"] as? String,
              let pendingRequest = pendingRequestsByRecordName[recordName] else {
            return
        }
        let payloadText = (object["payloadText"] as? String) ?? ""
        if payloadText.isEmpty {
            try await markOutboundCompleted(recordName: recordName)
            pendingRequestsByRecordName.removeValue(forKey: recordName)
            return
        }

        let payloadData = Data(payloadText.utf8)
        let encryptedPayload = try encryptPayload(payloadData)
        let signature = try signPayload(encryptedPayload)
        let responseRecord = CKRecord(recordType: RecordType.inbound)
        responseRecord[RecordField.requestId] = pendingRequest.requestId as CKRecordValue
        responseRecord[RecordField.messageId] = UUID().uuidString as CKRecordValue
        responseRecord[RecordField.fromDeviceId] = deviceState.macDeviceId as CKRecordValue
        responseRecord[RecordField.toDeviceId] = pendingRequest.fromDeviceId as CKRecordValue
        responseRecord[RecordField.ciphertext] = encryptedPayload.base64EncodedString() as CKRecordValue
        responseRecord[RecordField.signature] = signature as CKRecordValue
        responseRecord[RecordField.status] = RecordStatus.completed.rawValue as CKRecordValue
        responseRecord[RecordField.createdAt] = Date() as CKRecordValue
        responseRecord[RecordField.expiresAt] = Date().addingTimeInterval(60 * 60) as CKRecordValue
        responseRecord[RecordField.idempotencyKey] = "\(pendingRequest.requestId)|\(deviceState.macDeviceId)" as CKRecordValue
        _ = try await save(responseRecord)
        try await markOutboundCompleted(recordName: recordName)
        pendingRequestsByRecordName.removeValue(forKey: recordName)
    }

    private func handleBridgeError(_ object: [String: Any]) async throws {
        guard let recordName = object["recordName"] as? String,
              let pendingRequest = pendingRequestsByRecordName[recordName] else {
            return
        }
        let message = (object["message"] as? String) ?? "Bridge request failed."
        if pendingRequest.requestId.isEmpty {
            try await markOutboundCompleted(recordName: recordName)
            pendingRequestsByRecordName.removeValue(forKey: recordName)
            return
        }
        let errorResponse: [String: Any] = [
            "id": pendingRequest.requestId,
            "error": [
                "code": -32000,
                "message": message,
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
        let encryptedPayload = try encryptPayload(responseData)
        let signature = try signPayload(encryptedPayload)
        let responseRecord = CKRecord(recordType: RecordType.inbound)
        responseRecord[RecordField.requestId] = pendingRequest.requestId as CKRecordValue
        responseRecord[RecordField.messageId] = UUID().uuidString as CKRecordValue
        responseRecord[RecordField.fromDeviceId] = deviceState.macDeviceId as CKRecordValue
        responseRecord[RecordField.toDeviceId] = pendingRequest.fromDeviceId as CKRecordValue
        responseRecord[RecordField.ciphertext] = encryptedPayload.base64EncodedString() as CKRecordValue
        responseRecord[RecordField.signature] = signature as CKRecordValue
        responseRecord[RecordField.status] = RecordStatus.completed.rawValue as CKRecordValue
        responseRecord[RecordField.createdAt] = Date() as CKRecordValue
        responseRecord[RecordField.expiresAt] = Date().addingTimeInterval(60 * 60) as CKRecordValue
        responseRecord[RecordField.idempotencyKey] = "\(pendingRequest.requestId)|error|\(deviceState.macDeviceId)" as CKRecordValue
        _ = try await save(responseRecord)
        try await markOutboundCompleted(recordName: recordName)
        pendingRequestsByRecordName.removeValue(forKey: recordName)
    }

    private func markOutboundCompleted(recordName: String) async throws {
        let record = try await fetchRecord(recordType: RecordType.outbound, recordName: recordName)
        record[RecordField.status] = RecordStatus.completed.rawValue as CKRecordValue
        _ = try await save(record)
    }

    private func fetchRecord(recordType: String, recordName: String) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: CKRecord.ID(recordName: recordName)) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(throwing: HelperError.invalidRecord("Missing Cloud async record \(recordType): \(recordName)"))
                }
            }
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let savedRecord {
                    continuation.resume(returning: savedRecord)
                } else {
                    continuation.resume(throwing: HelperError.invalidRecord("Cloud async helper save returned no record."))
                }
            }
        }
    }

    private func encryptPayload(_ payload: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(payload, using: sharedSecret)
        guard let combined = sealedBox.combined else {
            throw HelperError.decryptFailed
        }
        return combined
    }

    private func decryptPayload(_ payload: Data) throws -> Data {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: payload),
              let plaintext = try? AES.GCM.open(sealedBox, using: sharedSecret) else {
            throw HelperError.decryptFailed
        }
        return plaintext
    }

    private func signPayload(_ payload: Data) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64EncodedOrEmpty: deviceState.macIdentityPrivateKey)
        )
        let signature = try privateKey.signature(for: payload)
        return signature.base64EncodedString()
    }

    private func verifySignature(payload: Data, signatureBase64: String, publicKeyBase64: String) throws -> Bool {
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64EncodedOrEmpty: publicKeyBase64)
        )
        return publicKey.isValidSignature(Data(base64EncodedOrEmpty: signatureBase64), for: payload)
    }

    private func emitStatus(available: Bool, lastError: String) {
        emitJSON([
            "kind": "helperStatus",
            "available": available,
            "lastError": lastError,
        ])
    }

    private func emitJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        if let lineData = "\(line)\n".data(using: .utf8) {
            try? stdoutHandle.write(contentsOf: lineData)
        }
    }

    private static func readDeviceState() throws -> DeviceState {
        let directory = ProcessInfo.processInfo.environment["REMODEX_DEVICE_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".remodex", isDirectory: true)
        let rootURL = (directory?.isEmpty == false)
            ? URL(fileURLWithPath: directory!, isDirectory: true)
            : defaultRoot
        let stateURL = rootURL.appendingPathComponent("device-state.json", isDirectory: false)
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(DeviceState.self, from: data)
    }
}

private extension Data {
    init(base64EncodedOrEmpty value: String) {
        self = Data(base64Encoded: value) ?? Data()
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "daemon"
guard command == "daemon" else {
    if let data = "Unsupported helper command: \(command)\n".data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
    exit(1)
}

Task {
    do {
        let containerId = ProcessInfo.processInfo.environment["REMODEX_ICLOUD_CONTAINER"]
        let runtime = try CloudAsyncHelperRuntime(containerIdentifier: containerId)
        try await runtime.run()
    } catch {
        if let data = "[icloud-helper] \(error.localizedDescription)\n".data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        exit(1)
    }
}

RunLoop.main.run()
