// FILE: CodexService+Transport.swift
// Purpose: Outbound JSON-RPC transport and pending-response coordination.
// Layer: Service
// Exports: CodexService transport internals
// Depends on: Network.NWConnection

import Foundation
import Network

extension CodexService {
    // Sends an RPC request and waits for the matching response by request id.
    func sendRequest(method: String, params: JSONValue?) async throws -> RPCMessage {
        if let requestTransportOverride {
            return try await requestTransportOverride(method, params)
        }

        guard isConnected, webSocketConnection != nil else {
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

    func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection else { return }

                if let error {
                    self.handleReceiveError(error)
                    return
                }

                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .close {
                    // Relay close frames carry the reason we need to tell stale QR pairings from retryable blips.
                    self.handleReceiveError(
                        CodexServiceError.disconnected,
                        relayCloseCode: metadata.closeCode
                    )
                    return
                }

                if let data,
                   let text = String(data: data, encoding: .utf8) {
                    self.lastRawMessage = text
                    self.processIncomingWireText(text)
                }

                self.receiveNextMessage(on: connection)
            }
        }
    }

    func establishWebSocketConnection(url: URL, token: String, role: String? = nil) async throws -> NWConnection {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true

        if let role, !role.isEmpty {
            webSocketOptions.setAdditionalHeaders([
                (name: "x-role", value: role)
            ])
        } else if !token.isEmpty {
            webSocketOptions.setAdditionalHeaders([
                (name: "Authorization", value: "Bearer \(token)")
            ])
        }

        let tlsOptions: NWProtocolTLS.Options? = (scheme == "wss") ? NWProtocolTLS.Options() : nil
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

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

        return connection
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
}
