// FILE: CodexService+Transport.swift
// Purpose: Outbound JSON-RPC transport and pending-response coordination.
// Layer: Service
// Exports: CodexService transport internals
// Depends on: Network.NWConnection, URLSessionWebSocketTask, CryptoKit, Security, CodexURLSessionWebSocketDelegate

import CryptoKit
import Foundation
import Network
import Security

extension CodexService {
    // Sends an RPC request and waits for the matching response by request id.
    func sendRequest(method: String, params: JSONValue?) async throws -> RPCMessage {
        if let requestTransportOverride {
            return try await requestTransportOverride(method, params)
        }

        guard isConnected, webSocketConnection != nil || webSocketTask != nil else {
            throw CodexServiceError.disconnected
        }

        let requestID: JSONValue = .string(UUID().uuidString)
        let requestKey = idKey(from: requestID)

        let request = RPCMessage(
            id: requestID,
            method: method,
            params: params,
            includeJSONRPC: false
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestKey] = continuation

            Task {
                do {
                    try await sendMessage(request)
                } catch {
                    if shouldTreatSendFailureAsDisconnect(error) {
                        handleReceiveError(error)
                        return
                    }

                    // Avoid double-resume if the request was already completed
                    // (for example by a disconnect race that fails all pending requests).
                    if let pendingContinuation = pendingRequests.removeValue(forKey: requestKey) {
                        pendingContinuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // Sends a fire-and-forget RPC notification.
    func sendNotification(method: String, params: JSONValue?) async throws {
        let notification = RPCMessage(
            jsonrpc: nil,
            id: nil,
            method: method,
            params: params,
            result: nil,
            error: nil
        )

        try await sendMessage(notification)
    }

    // Sends an RPC response for a server-initiated request.
    func sendResponse(id: JSONValue, result: JSONValue) async throws {
        let response = RPCMessage(id: id, result: result, includeJSONRPC: false)
        try await sendMessage(response)
    }

    // Sends an RPC error response for unsupported or invalid server requests.
    func sendErrorResponse(id: JSONValue?, code: Int, message: String, data: JSONValue? = nil) async throws {
        let rpcError = RPCError(code: code, message: message, data: data)
        let response = RPCMessage(id: id, error: rpcError, includeJSONRPC: false)
        try await sendMessage(response)
    }

    func sendMessage(_ message: RPCMessage) async throws {
        let payload = try encoder.encode(message)
        guard let plaintext = String(data: payload, encoding: .utf8) else {
            throw CodexServiceError.invalidResponse("Unable to encode outgoing JSON-RPC payload")
        }

        let secureText = try secureWireText(for: plaintext)
        try await sendRawText(secureText)
    }

    // Sends raw secure control messages before the JSON-RPC channel is initialized.
    func sendRawText(_ text: String) async throws {
        if usesManualWebSocketTransport {
            guard let connection = webSocketConnection else {
                throw CodexServiceError.disconnected
            }
            try await sendManualWebSocketFrame(opcode: 0x1, payload: Data(text.utf8), on: connection)
            return
        }

        if let task = webSocketTask {
            try await task.send(.string(text))
            return
        }

        guard let connection = webSocketConnection else {
            throw CodexServiceError.disconnected
        }

        let payload = Data(text.utf8)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "codex-jsonrpc", metadata: [metadata])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: payload,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    func startReceiveLoop(with connection: NWConnection) {
        receiveNextMessage(on: connection)
    }

    func startReceiveLoop(with task: URLSessionWebSocketTask) {
        receiveNextMessage(on: task)
    }

    // Reads raw TCP bytes and drains manual websocket frames for the relay LAN fallback.
    func startManualReceiveLoop(with connection: NWConnection) {
        receiveNextManualChunk(on: connection)
    }

    func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            // Pre-decode wire text off the main actor so JSONDecoder doesn't block UI frames.
            let wireText: String? = data.flatMap { String(data: $0, encoding: .utf8) }
            let preDecoded = wireText.map { WireMessagePreDecoder.classify($0) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection else { return }

                if let error {
                    self.handleReceiveError(error)
                    return
                }

                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .close {
                    self.handleReceiveError(
                        CodexServiceError.disconnected,
                        relayCloseCode: metadata.closeCode
                    )
                    return
                }

                if let text = wireText, let decoded = preDecoded {
                    if decoded.isSecure {
                        // Secure control or encrypted envelope — must stay on MainActor.
                        self.processIncomingWireText(text)
                    } else if let rpcResult = decoded.rpcResult {
                        self.handleDecodedRPCResult(rpcResult, rawText: text)
                    }
                }

                self.receiveNextMessage(on: connection)
            }
        }
    }

    func receiveNextManualChunk(on connection: NWConnection) {
        receiveRaw(on: connection) { [weak self] result in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection, self.usesManualWebSocketTransport else { return }

                switch result {
                case .failure(let error):
                    self.handleReceiveError(error)
                case .success(nil):
                    self.handleReceiveError(CodexServiceError.disconnected)
                case .success(let data?):
                    if !data.isEmpty {
                        self.manualWebSocketReadBuffer.append(data)
                        do {
                            try await self.drainManualWebSocketFrames(on: connection)
                        } catch {
                            self.handleReceiveError(error)
                            return
                        }
                    }
                    self.receiveNextManualChunk(on: connection)
                }
            }
        }
    }

    func receiveNextMessage(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            // Extract text and pre-decode off the main actor.
            var wireText: String?
            var preDecoded: WireMessagePreDecoder.Classification?
            if case .success(let message) = result {
                switch message {
                case .string(let text):
                    wireText = text
                case .data(let data):
                    wireText = String(data: data, encoding: .utf8)
                @unknown default:
                    break
                }
                if let text = wireText {
                    preDecoded = WireMessagePreDecoder.classify(text)
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketTask === task else { return }

                switch result {
                case .failure(let error):
                    self.handleReceiveError(
                        error,
                        relayCloseCode: self.relayCloseCode(for: task.closeCode)
                    )
                case .success:
                    if let text = wireText, let decoded = preDecoded {
                        if decoded.isSecure {
                            self.processIncomingWireText(text)
                        } else if let rpcResult = decoded.rpcResult {
                            self.handleDecodedRPCResult(rpcResult, rawText: text)
                        }
                    }

                    self.receiveNextMessage(on: task)
                }
            }
        }
    }

    func establishWebSocketConnection(url: URL, token: String, role: String? = nil) async throws -> CodexWebSocketTransport {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }

        if requiresLocalNetworkAuthorization(for: url) {
            do {
                return try await establishURLSessionWebSocketConnection(url: url, token: token, role: role)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   nsError.code == NSURLErrorNotConnectedToInternet {
                    print("[PAIRING] URLSession local websocket reported offline; retrying with manual TCP websocket fallback")
                    return try await establishManualTCPWebSocketConnection(url: url, token: token, role: role)
                }
                throw error
            }
        }

        return try await establishNWWebSocketConnection(url: url, token: token, role: role)
    }

    // Mirrors litter's raw TCP websocket client so LAN pairing can bypass iOS URL loading policy bugs.
    func establishManualTCPWebSocketConnection(
        url: URL,
        token: String,
        role: String? = nil
    ) async throws -> CodexWebSocketTransport {
        guard let host = url.host else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }
        let scheme = (url.scheme ?? "ws").lowercased()
        let defaultPort: UInt16 = (scheme == "wss") ? 443 : 80
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? Int(defaultPort))) else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }

        let parameters = NWParameters(
            tls: (scheme == "wss") ? NWProtocolTLS.Options() : nil,
            tcp: NWProtocolTCP.Options()
        )
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let connectionTimeoutNanoseconds: UInt64 = 12_000_000_000

        print("[PAIRING] opening manual TCP websocket to \(url.absoluteString)")
        try await waitUntilManualConnectionReady(
            connection,
            timeoutNanoseconds: connectionTimeoutNanoseconds
        )
        do {
            try await performManualWebSocketHandshake(on: connection, url: url, token: token, role: role)
            print("[PAIRING] manual TCP websocket connected")
        } catch {
            connection.cancel()
            throw error
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection, self.usesManualWebSocketTransport else { return }

                switch state {
                case .failed(let error):
                    self.handleReceiveError(error)
                case .cancelled:
                    if self.isConnected {
                        self.handleReceiveError(CodexServiceError.disconnected)
                    }
                default:
                    break
                }
            }
        }

        return .manualTCP(connection)
    }

    // Uses Network.framework directly for remote relays and as a fallback when URLSession
    // misclassifies a reachable local relay as offline before sending any upgrade request.
    func establishNWWebSocketConnection(
        url: URL,
        token: String,
        role: String? = nil
    ) async throws -> CodexWebSocketTransport {
        let scheme = (url.scheme ?? "ws").lowercased()
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true

        var additionalHeaders: [(name: String, value: String)] = []
        if let role, !role.isEmpty {
            additionalHeaders.append((name: "x-role", value: role))
        } else if !token.isEmpty {
            additionalHeaders.append((name: "Authorization", value: "Bearer \(token)"))
        }
        if !additionalHeaders.isEmpty {
            webSocketOptions.setAdditionalHeaders(additionalHeaders)
        }

        let tlsOptions: NWProtocolTLS.Options? = (scheme == "wss") ? NWProtocolTLS.Options() : nil
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        print("[PAIRING] opening NWConnection to \(url.absoluteString)")
        let connection = NWConnection(to: .url(url), using: parameters)
        let connectionTimeoutNanoseconds: UInt64 = 12_000_000_000

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var didFinish = false
            var timeoutTask: Task<Void, Never>?

            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didFinish else { return }
                didFinish = true
                timeoutTask?.cancel()
                continuation.resume(with: result)
                // Ignore future state transitions after first completion.
                connection.stateUpdateHandler = { _ in }
            }

            connection.stateUpdateHandler = { state in
                print("[PAIRING] NWConnection state: \(state)")
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    print("[PAIRING] NWConnection failed: \(error)")
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CodexServiceError.disconnected))
                default:
                    break
                }
            }

            connection.start(queue: webSocketQueue)

            timeoutTask = Task { [weak connection] in
                try? await Task.sleep(nanoseconds: connectionTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                connection?.cancel()
                finish(.failure(CodexServiceError.invalidInput("Connection timed out after 12s")))
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection else { return }

                switch state {
                case .failed(let error):
                    self.handleReceiveError(error)
                case .cancelled:
                    if self.isConnected {
                        self.handleReceiveError(CodexServiceError.disconnected)
                    }
                default:
                    break
                }
            }
        }

        return .network(connection)
    }

    // Uses URLSession for LAN relay sockets because NWConnection has been unreliable
    // on some iOS builds for local ws:// endpoints even when the relay is reachable.
    func establishURLSessionWebSocketConnection(
        url: URL,
        token: String,
        role: String? = nil
    ) async throws -> CodexWebSocketTransport {
        var request = URLRequest(url: url)
        if let role, !role.isEmpty {
            request.setValue(role, forHTTPHeaderField: "x-role")
        } else if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.default
        // Local relay sockets should fail fast if the LAN path is unusable instead of
        // waiting indefinitely for a "better" connectivity state that never starts the upgrade.
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        let delegate = CodexURLSessionWebSocketDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let connectionTimeoutNanoseconds: UInt64 = 12_000_000_000

        print("[PAIRING] opening URLSessionWebSocketTask to \(url.absoluteString)")
        task.resume()
        webSocketSessionDelegate = delegate

        let timeoutTask = Task { [weak task, weak delegate] in
            try? await Task.sleep(nanoseconds: connectionTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            task?.cancel(with: .goingAway, reason: nil)
            delegate?.resolveOpen(
                with: .failure(CodexServiceError.invalidInput("Connection timed out after 12s"))
            )
        }
        defer { timeoutTask.cancel() }

        do {
            try await delegate.waitForOpen()
            print("[PAIRING] URLSessionWebSocketTask connected")
        } catch {
            print("[PAIRING] URLSessionWebSocketTask failed: \(urlSessionWebSocketDebugDescription(for: error))")
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            webSocketSessionDelegate = nil
            throw error
        }

        return .urlSession(session, task)
    }

    func failAllPendingRequests(with error: Error) {
        let continuations = pendingRequests
        pendingRequests.removeAll()

        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    func idKey(from id: JSONValue) -> String {
        switch id {
        case .string(let value):
            return "s:\(value)"
        case .integer(let value):
            return "i:\(value)"
        case .double(let value):
            return "d:\(value)"
        case .bool(let value):
            return "b:\(value)"
        case .null:
            return "null"
        case .object, .array:
            return "complex:\(String(describing: id))"
        }
    }

    func relayCloseCode(for closeCode: URLSessionWebSocketTask.CloseCode) -> NWProtocolWebSocket.CloseCode? {
        guard closeCode != .invalid else {
            return nil
        }

        let rawValue = closeCode.rawValue
        if rawValue >= 4000 {
            return .privateCode(UInt16(rawValue))
        }
        if rawValue >= 3000 {
            return .applicationCode(UInt16(rawValue))
        }
        return nil
    }

    // Extracts CFNetwork/NWPath hints from websocket failures so local relay bugs are diagnosable on device.
    func urlSessionWebSocketDebugDescription(for error: Error) -> String {
        let nsError = error as NSError
        let pathDescription = nsError.userInfo["_NSURLErrorNWPathKey"] as? String
        let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError

        var parts = ["\(error)"]
        if let pathDescription, !pathDescription.isEmpty {
            parts.append("nwPath=\(pathDescription)")
        }
        if let underlyingError {
            parts.append("underlying=\(underlyingError.domain)(\(underlyingError.code)) \(underlyingError.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    // Waits for plain TCP readiness before sending the manual websocket upgrade request.
    func waitUntilManualConnectionReady(
        _ connection: NWConnection,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var didFinish = false
            var timeoutTask: Task<Void, Never>?

            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didFinish else { return }
                didFinish = true
                timeoutTask?.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                print("[PAIRING] manual TCP state: \(state)")
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CodexServiceError.disconnected))
                default:
                    break
                }
            }

            connection.start(queue: webSocketQueue)
            timeoutTask = Task { [weak connection] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                connection?.cancel()
                finish(.failure(CodexServiceError.invalidInput("Connection timed out after 12s")))
            }
        }
    }

    // Builds the HTTP upgrade request manually so LAN pairing avoids higher-level websocket APIs.
    func performManualWebSocketHandshake(
        on connection: NWConnection,
        url: URL,
        token: String,
        role: String?
    ) async throws {
        let key = randomManualWebSocketKey()
        let path = manualWebSocketPath(from: url)
        let hostHeader = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        var requestLines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        if let role, !role.isEmpty {
            requestLines.append("x-role: \(role)")
        } else if !token.isEmpty {
            requestLines.append("Authorization: Bearer \(token)")
        }
        requestLines.append(contentsOf: ["", ""])

        try await sendRaw(Data(requestLines.joined(separator: "\r\n").utf8), on: connection)

        var headerBytes = Data()
        while true {
            if let range = headerBytes.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = Data(headerBytes[..<range.upperBound])
                manualWebSocketReadBuffer = Data(headerBytes[range.upperBound...])
                try validateManualWebSocketHandshakeResponse(headerData: headerData, key: key)
                return
            }
            guard let chunk = try await receiveRaw(on: connection) else {
                throw CodexServiceError.disconnected
            }
            headerBytes.append(chunk)
            if headerBytes.count > 65_536 {
                throw CodexServiceError.invalidInput("Relay handshake response was too large")
            }
        }
    }

    func manualWebSocketPath(from url: URL) -> String {
        let base = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            return "\(base)?\(query)"
        }
        return base
    }

    func randomManualWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    func validateManualWebSocketHandshakeResponse(headerData: Data, key: String) throws {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw CodexServiceError.invalidInput("Relay handshake response could not be decoded")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let status = lines.first, status.contains(" 101 ") else {
            throw CodexServiceError.invalidInput("Relay rejected websocket upgrade")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let acceptSeed = "\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let expectedAccept = Data(Insecure.SHA1.hash(data: Data(acceptSeed.utf8))).base64EncodedString()
        guard headers["sec-websocket-accept"] == expectedAccept else {
            throw CodexServiceError.invalidInput("Relay returned an invalid websocket accept key")
        }
    }

    func drainManualWebSocketFrames(on connection: NWConnection) async throws {
        while let frame = parseManualWebSocketFrame(from: &manualWebSocketReadBuffer) {
            switch frame.opcode {
            case 0x1:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    lastRawMessage = text
                    processIncomingWireText(text)
                }
            case 0x8:
                throw CodexServiceError.disconnected
            case 0x9:
                try await sendManualWebSocketFrame(opcode: 0xA, payload: frame.payload, on: connection)
            case 0xA:
                break
            default:
                break
            }
        }
    }

    func parseManualWebSocketFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }

        let firstByte = buffer[buffer.startIndex]
        let secondByte = buffer[buffer.startIndex + 1]
        let opcode = firstByte & 0x0F
        let masked = (secondByte & 0x80) != 0

        var index = 2
        var payloadLength = Int(secondByte & 0x7F)
        if payloadLength == 126 {
            guard buffer.count >= index + 2 else { return nil }
            payloadLength = Int(buffer[index]) << 8 | Int(buffer[index + 1])
            index += 2
        } else if payloadLength == 127 {
            guard buffer.count >= index + 8 else { return nil }
            var decodedLength: UInt64 = 0
            for offset in 0..<8 {
                decodedLength = (decodedLength << 8) | UInt64(buffer[index + offset])
            }
            guard decodedLength <= UInt64(Int.max) else { return nil }
            payloadLength = Int(decodedLength)
            index += 8
        }

        var maskKey = Data()
        if masked {
            guard buffer.count >= index + 4 else { return nil }
            maskKey = buffer.subdata(in: index..<(index + 4))
            index += 4
        }

        guard buffer.count >= index + payloadLength else { return nil }
        var payload = buffer.subdata(in: index..<(index + payloadLength))
        buffer.removeSubrange(0..<(index + payloadLength))

        if masked {
            let maskBytes = [UInt8](maskKey)
            var payloadBytes = [UInt8](payload)
            for i in payloadBytes.indices {
                payloadBytes[i] ^= maskBytes[i % 4]
            }
            payload = Data(payloadBytes)
        }

        return (opcode: opcode, payload: payload)
    }

    func sendManualWebSocketFrame(opcode: UInt8, payload: Data, on connection: NWConnection) async throws {
        var frame = Data()
        frame.append(0x80 | opcode)

        let maskBit: UInt8 = 0x80
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask)
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }

        try await sendRaw(frame, on: connection)
    }

    func sendRaw(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveRaw(
        on connection: NWConnection,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error {
                completion(.failure(error))
                return
            }
            if isComplete && (data == nil || data?.isEmpty == true) {
                completion(.success(nil))
                return
            }
            completion(.success(data ?? Data()))
        }
    }

    func receiveRaw(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            receiveRaw(on: connection) { result in
                continuation.resume(with: result)
            }
        }
    }
}
