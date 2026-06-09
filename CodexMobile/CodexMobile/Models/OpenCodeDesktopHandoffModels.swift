// FILE: OpenCodeDesktopHandoffModels.swift
// Purpose: Encodes and decodes desktop/continueOpenCode RPC params and result payloads.
// Layer: Model
// Exports: OpenCodeDesktopHandoffParams, OpenCodeDesktopHandoffResult
// Depends on: JSONValue

import Foundation

struct OpenCodeDesktopHandoffParams: Equatable, Sendable {
    let threadId: String
    let sessionId: String?
    let directory: String?

    func makeJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "threadId": .string(threadId),
        ]
        if let sessionId, !sessionId.isEmpty {
            object["sessionId"] = .string(sessionId)
        }
        if let directory, !directory.isEmpty {
            object["directory"] = .string(directory)
        }
        return .object(object)
    }

    static func normalized(
        threadId: String,
        sessionId: String? = nil,
        directory: String? = nil
    ) -> OpenCodeDesktopHandoffParams? {
        let trimmedThreadID = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadID.isEmpty else {
            return nil
        }

        let trimmedSessionID = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines)

        return OpenCodeDesktopHandoffParams(
            threadId: trimmedThreadID,
            sessionId: trimmedSessionID?.isEmpty == false ? trimmedSessionID : nil,
            directory: trimmedDirectory?.isEmpty == false ? trimmedDirectory : nil
        )
    }
}

struct OpenCodeDesktopHandoffResult: Equatable, Sendable {
    let success: Bool
    let threadId: String
    let sessionId: String
    let cwd: String
    let model: String
    let agent: String
    let title: String
    let handoffMode: String
    let sessionSelected: Bool
    let desktopAppInstalled: Bool
    let instructions: String

    init(from json: [String: JSONValue]) {
        success = json["success"]?.boolValue ?? false
        threadId = json["threadId"]?.stringValue ?? ""
        sessionId = json["sessionId"]?.stringValue ?? ""
        cwd = json["cwd"]?.stringValue ?? ""
        model = json["model"]?.stringValue ?? ""
        agent = json["agent"]?.stringValue ?? ""
        title = json["title"]?.stringValue ?? ""
        handoffMode = json["handoffMode"]?.stringValue ?? ""
        sessionSelected = json["sessionSelected"]?.boolValue ?? false
        desktopAppInstalled = json["desktopAppInstalled"]?.boolValue ?? false
        instructions = json["instructions"]?.stringValue ?? ""
    }

    var userFacingSummary: String {
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            return trimmedInstructions
        }

        switch handoffMode {
        case "tui":
            return "Session selected in OpenCode on your Mac."
        case "desktop_app":
            return "OpenCode opened on your Mac. Select the session in the app or Terminal if needed."
        case "tui_only":
            return "Run OpenCode in Terminal on your Mac and select this session from the picker."
        default:
            return "Continue this OpenCode session on your Mac."
        }
    }
}