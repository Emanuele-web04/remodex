import XCTest
import CryptoKit
@testable import CodexMobile

final class CodexOffLANAsyncMechanicsTests: XCTestCase {

    func testRequestIDStringExtraction() {
        let stringValue = JSONValue.string("req-123")
        XCTAssertEqual(CodexOffLANAsyncMechanics.requestIDString(from: stringValue), "req-123")

        let intValue = JSONValue.integer(42)
        XCTAssertEqual(CodexOffLANAsyncMechanics.requestIDString(from: intValue), "42")

        let boolValue = JSONValue.bool(true)
        XCTAssertEqual(CodexOffLANAsyncMechanics.requestIDString(from: boolValue), "true")
    }

    func testThreadIdExtraction() {
        let paramsWithThreadId = JSONValue.object(["threadId": .string("thread-xyz")])
        XCTAssertEqual(CodexOffLANAsyncMechanics.threadId(for: "method", params: paramsWithThreadId), "thread-xyz")

        let paramsWithThread_id = JSONValue.object(["thread_id": .string("thread-abc")])
        XCTAssertEqual(CodexOffLANAsyncMechanics.threadId(for: "method", params: paramsWithThread_id), "thread-abc")

        let paramsMissing = JSONValue.object(["other": .string("value")])
        XCTAssertNil(CodexOffLANAsyncMechanics.threadId(for: "method", params: paramsMissing))
    }

    func testIdempotencyKeyGeneration() {
        let withRequestId = CodexOffLANAsyncMechanics.idempotencyKey(
            requestId: "req-1",
            messageId: "msg-1",
            fromDeviceId: "device-1"
        )
        XCTAssertEqual(withRequestId, "req-1|device-1")

        let withoutRequestId = CodexOffLANAsyncMechanics.idempotencyKey(
            requestId: nil,
            messageId: "msg-2",
            fromDeviceId: "device-1"
        )
        XCTAssertEqual(withoutRequestId, "notification|msg-2|device-1")
    }

    func testPayloadEncryptionAndDecryption() throws {
        let secretKey = SymmetricKey(size: .bits256)
        let originalPayload = "Hello, Remodex!".data(using: .utf8)!

        let encrypted = try CodexOffLANAsyncMechanics.encryptPayload(originalPayload, secret: secretKey)
        XCTAssertNotEqual(encrypted, originalPayload)

        let decrypted = try CodexOffLANAsyncMechanics.decryptPayload(encrypted, secret: secretKey)
        XCTAssertEqual(decrypted, originalPayload)
    }

    func testPayloadSigningAndVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let privateKeyBase64 = privateKey.rawRepresentation.base64EncodedString()

        let payload = "Sign this data".data(using: .utf8)!

        let signatureBase64 = try CodexOffLANAsyncMechanics.signPayload(payload, privateKeyBase64: privateKeyBase64)
        
        let isValid = try CodexOffLANAsyncMechanics.verifyPayload(
            payload,
            signatureBase64: signatureBase64,
            publicKeyBase64: publicKeyBase64
        )
        XCTAssertTrue(isValid)

        // Verify that tampered data fails
        let tamperedPayload = "Sign that data".data(using: .utf8)!
        let isInvalid = try CodexOffLANAsyncMechanics.verifyPayload(
            tamperedPayload,
            signatureBase64: signatureBase64,
            publicKeyBase64: publicKeyBase64
        )
        XCTAssertFalse(isInvalid)
    }
}
