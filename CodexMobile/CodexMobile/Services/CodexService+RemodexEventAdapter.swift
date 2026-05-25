// FILE: CodexService+RemodexEventAdapter.swift
// Purpose: Adapts runtime-neutral Remodex bridge events into the existing timeline handlers.
// Layer: Service
// Exports: CodexService Remodex canonical event adapter
// Depends on: RPCMessage, JSONValue

import Foundation

extension CodexService {
    func remodexAdaptedRPCMessage(_ message: RPCMessage) -> RPCMessage {
        guard let method = message.method,
              let params = message.params?.objectValue else {
            return message
        }

        if method == "remodex/request/permission" {
            return remodexPermissionApprovalRequest(from: message, params: params)
        }

        guard method.hasPrefix("remodex/event/") else {
            return message
        }

        let eventType = String(method.dropFirst("remodex/event/".count))
        let payload = params["payload"]?.objectValue ?? [:]
        let base = remodexBaseParams(from: params)

        switch eventType {
        case "thread_started":
            var adapted = base
            adapted["thread"] = payload["thread"] ?? .object([
                "id": base["threadId"] ?? .string(""),
                "agentRuntime": params["agentRuntime"] ?? .string("codex"),
                "agentSessionId": params["agentSessionId"] ?? base["threadId"] ?? .string("")
            ])
            return RPCMessage(method: "thread/started", params: .object(adapted))

        case "turn_started":
            return RPCMessage(method: "turn/started", params: .object(base))

        case "user_message":
            var adapted = base
            adapted["message"] = firstJSONValue(payload, keys: ["text", "message", "content"])
            return RPCMessage(method: "timeline/user_message", params: .object(adapted))

        case "assistant_delta":
            var adapted = base
            if let reasoning = firstJSONValue(payload, keys: ["reasoning"]) {
                adapted["delta"] = reasoning
                return RPCMessage(method: "item/reasoning/textDelta", params: .object(adapted))
            }
            if let plan = payload["plan"] {
                adapted["delta"] = remodexPlanDeltaValue(plan)
                return RPCMessage(method: "item/plan/delta", params: .object(adapted))
            }
            adapted["delta"] = firstJSONValue(payload, keys: ["delta", "text", "content"])
            return RPCMessage(method: "item/agentMessage/delta", params: .object(adapted))

        case "assistant_completed":
            var adapted = base
            let text = firstJSONValue(payload, keys: ["text", "message", "content"]) ?? .string("")
            adapted["message"] = text
            adapted["item"] = .object([
                "id": base["itemId"] ?? .string("assistant-completed"),
                "type": .string("agent_message"),
                "role": .string("assistant"),
                "text": text,
                "content": text
            ])
            return RPCMessage(method: "item/completed", params: .object(adapted))

        case "tool_started", "tool_delta", "tool_completed":
            var adapted = base
            adapted["delta"] = remodexToolDeltaValue(eventType: eventType, payload: payload)
            return RPCMessage(method: "item/toolCall/outputDelta", params: .object(adapted))

        case "diff_updated":
            var adapted = base
            adapted["diff"] = firstJSONValue(payload, keys: ["diff", "patch", "unified_diff"])
            return RPCMessage(method: "turn/diff/updated", params: .object(adapted))

        case "turn_completed":
            var adapted = base
            adapted["status"] = firstJSONValue(payload, keys: ["status"]) ?? .string("completed")
            if let error = firstJSONValue(payload, keys: ["error", "message", "errorMessage"]) {
                adapted["error"] = error
            }
            return RPCMessage(method: "turn/completed", params: .object(adapted))

        case "error":
            var adapted = base
            adapted["message"] = firstJSONValue(payload, keys: ["message", "error"]) ?? .string("Runtime error")
            return RPCMessage(method: "error", params: .object(adapted))

        // Explicit plan event support (improves completeness for Gap #4 / canonical plan flows)
        case "turn_plan_updated", "plan_updated":
            var adapted = base
            adapted["plan"] = firstJSONValue(payload, keys: ["plan", "steps", "content"])
            return RPCMessage(method: "turn/plan/updated", params: .object(adapted))

        default:
            return message
        }
    }

    private func remodexBaseParams(from params: IncomingParamsObject) -> IncomingParamsObject {
        var base: IncomingParamsObject = [:]
        for key in ["threadId", "thread_id", "turnId", "turn_id", "itemId", "item_id", "agentRuntime", "agentSessionId"] {
            if let value = params[key] {
                base[key] = value
            }
        }
        if base["threadId"] == nil, let value = params["thread_id"] {
            base["threadId"] = value
        }
        if base["turnId"] == nil, let value = params["turn_id"] {
            base["turnId"] = value
        }
        if base["itemId"] == nil, let value = params["item_id"] {
            base["itemId"] = value
        }
        return base
    }

    private func remodexPermissionApprovalRequest(from message: RPCMessage, params: IncomingParamsObject) -> RPCMessage {
        let payload = params["payload"]?.objectValue ?? [:]
        let request = payload["request"]?.objectValue ?? [:]
        var adapted = remodexBaseParams(from: params)
        // Use the canonical agentRuntime from the event; fall back to "codex" for legacy/raw paths (not "cursor" — that was a copy-paste bug).
        adapted["agentRuntime"] = params["agentRuntime"] ?? .string("codex")
        adapted["reason"] = firstJSONValue(request, keys: ["reason", "description", "message"])
            ?? firstJSONValue(payload, keys: ["reason", "description", "message"])
            ?? .string("Agent runtime is requesting permission to continue.")
        adapted["command"] = firstJSONValue(request, keys: ["command", "title", "name"])
        adapted["permissions"] = firstJSONValue(request, keys: ["permissions", "options", "actions"])
            ?? firstJSONValue(payload, keys: ["permissions"])
            ?? .object([:])
        adapted["sourceMethod"] = payload["sourceMethod"]

        let requestID = message.id
            ?? params["permissionId"]
            ?? params["itemId"]
            ?? .string("remodex-permission-\(UUID().uuidString)")

        return RPCMessage(
            id: requestID,
            method: "item/permissions/requestApproval",
            params: .object(adapted)
        )
    }

    private func remodexPlanDeltaValue(_ value: JSONValue) -> JSONValue {
        if let string = value.stringValue {
            return .string(string)
        }
        return .string(String(describing: value))
    }

    private func remodexToolDeltaValue(eventType: String, payload: IncomingParamsObject) -> JSONValue {
        if let delta = firstJSONValue(payload, keys: ["delta", "text", "content", "status"]) {
            return delta
        }
        let toolName = firstJSONValue(payload, keys: ["toolName", "tool_name", "name"])?.stringValue ?? "tool"
        switch eventType {
        case "tool_started":
            return .string("Started \(toolName)")
        case "tool_completed":
            return .string("Completed \(toolName)")
        default:
            return .string(toolName)
        }
    }

    private func firstJSONValue(_ object: IncomingParamsObject, keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = object[key], value != .null {
                return value
            }
        }
        return nil
    }
}
