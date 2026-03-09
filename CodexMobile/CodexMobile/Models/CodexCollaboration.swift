// FILE: CodexCollaboration.swift
// Purpose: Shared collaboration-mode models used by composer sends and timeline rendering.
// Layer: Model
// Exports: CodexCollaborationModeKind, CodexPlanState, CodexStructuredUserInputRequest
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
