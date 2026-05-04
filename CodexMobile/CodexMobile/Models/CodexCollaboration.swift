// FILE: CodexCollaboration.swift
// Purpose: Shared collaboration-mode and multi-agent models used by composer sends and timeline rendering.
// Layer: Model
// Exports: CodexCollaborationModeKind, CodexPlanState, CodexStructuredUserInputRequest,
//   CodexSubagentAction
// Depends on: Foundation, JSONValue

import Foundation

enum CodexCollaborationModeKind: String, Codable, Hashable, Sendable {
    case `default`
    case plan
}

enum CodexPlanStepStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct CodexPlanStep: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let step: String
    let status: CodexPlanStepStatus

    init(id: String = UUID().uuidString, step: String, status: CodexPlanStepStatus) {
        self.id = id
        self.step = step
        self.status = status
    }
}

struct CodexPlanState: Codable, Hashable, Sendable {
    var explanation: String?
    var steps: [CodexPlanStep]

    init(explanation: String? = nil, steps: [CodexPlanStep] = []) {
        self.explanation = explanation
        self.steps = steps
    }
}

struct CodexStructuredUserInputOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let label: String
    let description: String

    init(id: String = UUID().uuidString, label: String, description: String) {
        self.id = id
        self.label = label
        self.description = description
    }
}

struct CodexStructuredUserInputQuestion: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let options: [CodexStructuredUserInputOption]

    init(
        id: String,
        header: String,
        question: String,
        isOther: Bool,
        isSecret: Bool,
        options: [CodexStructuredUserInputOption]
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.isOther = isOther
        self.isSecret = isSecret
        self.options = options
    }
}

struct CodexStructuredUserInputRequest: Codable, Hashable, Sendable {
    let requestID: JSONValue
    let questions: [CodexStructuredUserInputQuestion]

    init(requestID: JSONValue, questions: [CodexStructuredUserInputQuestion]) {
        self.requestID = requestID
        self.questions = questions
    }
}

struct CodexSubagentRef: Codable, Hashable, Sendable {
    let threadId: String
    let agentId: String?
    let nickname: String?
    let role: String?
    let model: String?
    let prompt: String?

    init(
        threadId: String,
        agentId: String? = nil,
        nickname: String? = nil,
        role: String? = nil,
        model: String? = nil,
        prompt: String? = nil
    ) {
        self.threadId = threadId
        self.agentId = agentId
        self.nickname = nickname
        self.role = role
        self.model = model
        self.prompt = prompt
    }
}

struct CodexSubagentState: Codable, Hashable, Sendable {
    let threadId: String
    var status: String
    var message: String?

    init(threadId: String, status: String, message: String? = nil) {
        self.threadId = threadId
        self.status = status
        self.message = message
    }
}

struct CodexSubagentThreadPresentation: Identifiable, Hashable, Sendable {
    let threadId: String
    let agentId: String?
    let nickname: String?
    let role: String?
    let model: String?
    let modelIsRequestedHint: Bool
    let prompt: String?
    let fallbackStatus: String?
    let fallbackMessage: String?

    var id: String { threadId }

    // Formats the row label the same way across cards, sheets, and buttons.
    var displayLabel: String {
        let trimmedNickname = sanitizedAgentIdentity(nickname)
        let trimmedRole = sanitizedAgentIdentity(role)

        if let trimmedNickname, !trimmedNickname.isEmpty,
           let trimmedRole, !trimmedRole.isEmpty {
            return "\(trimmedNickname) [\(trimmedRole)]"
        }

        if let trimmedNickname, !trimmedNickname.isEmpty {
            return trimmedNickname
        }

        if let trimmedRole, !trimmedRole.isEmpty {
            return trimmedRole.capitalized
        }

        let compactThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        if compactThreadId.count > 14 {
            return "Agent \(compactThreadId.suffix(8))"
        }
        return compactThreadId.isEmpty ? "Agent" : compactThreadId
    }

    private func sanitizedAgentIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered == "collabagenttoolcall" || lowered == "collabtoolcall" {
            return nil
        }

        return trimmed
    }
}

struct CodexSubagentAction: Codable, Hashable, Sendable {
    var tool: String
    var status: String
    var prompt: String?
    var model: String?
    var receiverThreadIds: [String]
    var receiverAgents: [CodexSubagentRef]
    var agentStates: [String: CodexSubagentState]

    init(
        tool: String,
        status: String,
        prompt: String? = nil,
        model: String? = nil,
        receiverThreadIds: [String] = [],
        receiverAgents: [CodexSubagentRef] = [],
        agentStates: [String: CodexSubagentState] = [:]
    ) {
        self.tool = tool
        self.status = status
        self.prompt = prompt
        self.model = model
        self.receiverThreadIds = receiverThreadIds
        self.receiverAgents = receiverAgents
        self.agentStates = agentStates
    }

    // Produces the stable agent rows used by the timeline card and detail sheet.
    var agentRows: [CodexSubagentThreadPresentation] {
        var orderedThreadIds: [String] = []
        for threadId in receiverThreadIds where !orderedThreadIds.contains(threadId) {
            orderedThreadIds.append(threadId)
        }
        for agent in receiverAgents where !orderedThreadIds.contains(agent.threadId) {
            orderedThreadIds.append(agent.threadId)
        }
        for threadId in agentStates.keys.sorted() where !orderedThreadIds.contains(threadId) {
            orderedThreadIds.append(threadId)
        }

        return orderedThreadIds.map { threadId in
            let matchingAgent = receiverAgents.first(where: { $0.threadId == threadId })
            let matchingState = agentStates[threadId]
            return CodexSubagentThreadPresentation(
                threadId: threadId,
                agentId: matchingAgent?.agentId,
                nickname: matchingAgent?.nickname,
                role: matchingAgent?.role,
                // App-server emits the requested subagent model at the top-level collabToolCall
                // item, so rows fall back to that when no per-agent payload exists yet.
                model: matchingAgent?.model ?? model,
                modelIsRequestedHint: matchingAgent?.model == nil && model != nil,
                prompt: matchingAgent?.prompt,
                fallbackStatus: matchingState?.status,
                fallbackMessage: matchingState?.message
            )
        }
    }

    var normalizedTool: String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    var summaryText: String {
        let count = max(1, max(agentRows.count, receiverThreadIds.count, receiverAgents.count))
        let noun = count == 1 ? "agent" : "agents"

        switch normalizedTool {
        case "spawnagent":
            return "Spawning \(count) \(noun)"
        case "wait", "waitagent":
            return "Waiting on \(count) \(noun)"
        case "closeagent":
            return "Closing \(count) \(noun)"
        case "resumeagent":
            return "Resuming \(count) \(noun)"
        case "sendinput":
            return count == 1 ? "Updating agent" : "Updating agents"
        default:
            return count == 1 ? "Agent activity" : "Agent activity (\(count))"
        }
    }
}
