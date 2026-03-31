import Foundation
import XCTest
@testable import CodexMobile

final class CodexConvexAsyncTransportTests: XCTestCase {
    func testAvailabilityReturnsAvailableForHealthyConvexResponse() async {
        let probe = ConvexRequestProbe()
        let executor: CodexConvexAsyncRequestExecutor = { request in
            probe.record(request)
            guard request.url?.path == "/async/health" else {
                return makeUnexpectedResponse()
            }
            return makeHTTPResponse(
                statusCode: 200,
                body: makeJSONData(["status": "ok", "provider": "convex"])
            )
        }
        let transport = makeTransport(executor: executor)

        let availability = await transport.availability(hasCloudAsyncFallbackCredentials: true)

        assertAvailable(availability)
        XCTAssertEqual(probe.requestPaths(), ["/async/health"])
        XCTAssertEqual(probe.requestMethods(), ["GET"])
        XCTAssertEqual(probe.requestBodies(), [nil])
    }

    func testAvailabilityReturnsUnavailableWhenHealthStatusIsNotOk() async {
        let probe = ConvexRequestProbe()
        let executor: CodexConvexAsyncRequestExecutor = { request in
            probe.record(request)
            guard request.url?.path == "/async/health" else {
                return makeUnexpectedResponse()
            }
            return makeHTTPResponse(
                statusCode: 200,
                body: makeJSONData(["status": "degraded", "provider": "convex"])
            )
        }
        let transport = makeTransport(executor: executor)

        let availability = await transport.availability(hasCloudAsyncFallbackCredentials: true)

        assertUnavailable(availability, expectedMessage: "Convex async transport reported it is unavailable.")
        XCTAssertEqual(probe.requestPaths(), ["/async/health"])
        XCTAssertEqual(probe.requestMethods(), ["GET"])
        XCTAssertEqual(probe.requestBodies(), [nil])
    }

    func testAvailabilityReturnsUnavailableWhenHealthProviderMismatch() async {
        let probe = ConvexRequestProbe()
        let executor: CodexConvexAsyncRequestExecutor = { request in
            probe.record(request)
            guard request.url?.path == "/async/health" else {
                return makeUnexpectedResponse()
            }
            return makeHTTPResponse(
                statusCode: 200,
                body: makeJSONData(["status": "ok", "provider": "cloudkit"])
            )
        }
        let transport = makeTransport(executor: executor)

        let availability = await transport.availability(hasCloudAsyncFallbackCredentials: true)

        assertUnavailable(availability, expectedMessage: "Convex async transport reported an unexpected provider.")
        XCTAssertEqual(probe.requestPaths(), ["/async/health"])
        XCTAssertEqual(probe.requestMethods(), ["GET"])
        XCTAssertEqual(probe.requestBodies(), [nil])
    }

    func testAvailabilityReturnsUnavailableForNetworkFailure() async {
        let probe = ConvexRequestProbe()
        let executor: CodexConvexAsyncRequestExecutor = { request in
            probe.record(request)
            throw URLError(.notConnectedToInternet)
        }
        let transport = makeTransport(executor: executor)

        let availability = await transport.availability(hasCloudAsyncFallbackCredentials: true)

        assertUnavailable(availability, expectedMessage: "Could not reach Convex for off-LAN async messaging.")
        XCTAssertEqual(probe.requestPaths(), ["/async/health"])
        XCTAssertEqual(probe.requestMethods(), ["GET"])
        XCTAssertEqual(probe.requestBodies(), [nil])
    }

    func testAvailabilityReturnsFreshQRMessageWhenFallbackCredentialsAreMissing() async {
        let probe = ConvexRequestProbe()
        let executor: CodexConvexAsyncRequestExecutor = { request in
            probe.record(request)
            return makeUnexpectedResponse()
        }
        let transport = makeTransport(executor: executor)

        let availability = await transport.availability(hasCloudAsyncFallbackCredentials: false)

        assertUnavailable(
            availability,
            expectedMessage: "Off-LAN async pairing is unavailable until you scan a fresh QR code."
        )
        XCTAssertTrue(probe.requestPaths().isEmpty)
        XCTAssertTrue(probe.requestMethods().isEmpty)
        XCTAssertTrue(probe.requestBodies().isEmpty)
    }

    func testEndpointURLBuildsExpectedAsyncPaths() {
        let transport = makeTransport()

        XCTAssertEqual(transport.endpointURL(.health).absoluteString, "https://example.convex.site/async/health")
        XCTAssertEqual(transport.endpointURL(.outboundEnqueue).absoluteString, "https://example.convex.site/async/outbound/enqueue")
        XCTAssertEqual(transport.endpointURL(.responsePoll).absoluteString, "https://example.convex.site/async/inbound/poll")
        XCTAssertEqual(transport.endpointURL(.responseDelivered).absoluteString, "https://example.convex.site/async/inbound/delivered")
    }
}

private struct RecordedConvexRequest: Sendable {
    let path: String?
    let method: String?
    let body: Data?
}

private final class ConvexRequestProbe {
    private let lock = NSLock()
    private var requests: [RecordedConvexRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(
            RecordedConvexRequest(
                path: request.url?.path,
                method: request.httpMethod,
                body: request.httpBody
            )
        )
        lock.unlock()
    }

    func requestPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap(\.path)
    }

    func requestMethods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap(\.method)
    }

    func requestBodies() -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.body)
    }
}

private func makeTransport(
    responseTimeoutNanoseconds: UInt64 = 5_000_000_000,
    initialPollDelayNanoseconds: UInt64 = 1_000_000_000,
    maxPollDelayNanoseconds: UInt64 = 3_000_000_000,
    executor: @escaping CodexConvexAsyncRequestExecutor = { _ in
        throw URLError(.notConnectedToInternet)
    }
) -> CodexConvexAsyncTransport {
    CodexConvexAsyncTransport(
        siteURL: URL(string: "https://example.convex.site")!,
        responseTimeoutNanoseconds: responseTimeoutNanoseconds,
        initialPollDelayNanoseconds: initialPollDelayNanoseconds,
        maxPollDelayNanoseconds: maxPollDelayNanoseconds,
        requestTimeoutSeconds: 5,
        requestExecutor: executor
    )
}

private func makeHTTPResponse(
    statusCode: Int,
    body: Data
) -> CodexConvexAsyncRequestResult {
    CodexConvexAsyncRequestResult(data: body, statusCode: statusCode)
}

private func makeUnexpectedResponse() -> CodexConvexAsyncRequestResult {
    CodexConvexAsyncRequestResult(data: Data(), statusCode: 500)
}

private func makeJSONData<T: Encodable>(_ value: T) -> Data {
    try! makeConvexJSONEncoder().encode(value)
}

private func makeConvexJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
}

private func assertAvailable(
    _ availability: CodexCloudAsyncAvailability,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .available = availability else {
        XCTFail("Expected .available", file: file, line: line)
        return
    }
}

private func assertUnavailable(
    _ availability: CodexCloudAsyncAvailability,
    expectedMessage: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .unavailable(let message) = availability else {
        XCTFail("Expected .unavailable", file: file, line: line)
        return
    }
    XCTAssertEqual(message, expectedMessage, file: file, line: line)
}
