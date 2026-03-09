// FILE: RPCMessage.swift
// Purpose: Models inbound/outbound JSON-RPC 2.0 envelopes for Codex App Server.
// Layer: Model
// Exports: RPCMessage, RPCError, RPCObject
// Depends on: JSONValue

import Foundation

typealias RPCObject = [String: JSONValue]

struct RPCMessage: Codable, Sendable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: RPCError?

    // --- Convenience initializers ---------------------------------------------

    // Builds an RPC request/notification payload to send over WebSocket.
    init(id: JSONValue? = nil, method: String, params: JSONValue? = nil, includeJSONRPC: Bool = true) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = method
        self.params = params
        self.result = nil
        self.error = nil
    }

    // Builds an RPC successful response payload.
    init(id: JSONValue?, result: JSONValue, includeJSONRPC: Bool = true) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = nil
        self.params = nil
        self.result = result
        self.error = nil
    }

    // Builds an RPC error response payload.
    init(id: JSONValue?, error: RPCError, includeJSONRPC: Bool = true) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = nil
        self.params = nil
        self.result = nil
        self.error = error
    }

    // Allows decoding messages that already include all JSON-RPC fields.
    init(
        jsonrpc: String? = "2.0",
        id: JSONValue? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: RPCError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

extension RPCMessage {
    // --- Message kind helpers -------------------------------------------------

    var isRequest: Bool {
        method != nil
    }

    var isResponse: Bool {
        result != nil || error != nil
    }

    var isErrorResponse: Bool {
        error != nil
    }
}

struct RPCError: Codable, Error, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}
