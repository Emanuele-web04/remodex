// FILE: CodexMessage.swift
// Purpose: Defines chat messages rendered in each thread conversation timeline.
// Layer: Model
// Exports: CodexMessage, CodexMessageRole
// Depends on: Foundation

import Foundation

enum CodexMessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
}

enum CodexMessageDeliveryState: String, Codable, Hashable, Sendable {
    case pending
    case confirmed
    case failed
}

enum CodexMessageKind: String, Codable, Hashable, Sendable {
    case chat
    case thinking
    case toolActivity
    case fileChange
    case commandExecution
    case subagentAction
    case plan
    case userInputPrompt
}

struct CodexMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let threadId: String
    let role: CodexMessageRole
    var kind: CodexMessageKind
    var text: String
    var fileMentions: [String]
    let createdAt: Date
    var turnId: String?
    var itemId: String?
    var isStreaming: Bool
    var deliveryState: CodexMessageDeliveryState
    var attachments: [CodexImageAttachment]
    var planState: CodexPlanState?
    var subagentAction: CodexSubagentAction?
    var structuredUserInputRequest: CodexStructuredUserInputRequest?

    /// Monotonically increasing counter that preserves insertion order.
    /// Used as primary sort key so messages are never reordered by timestamp drift.
    var orderIndex: Int

    init(
        id: String = UUID().uuidString,
        threadId: String,
        role: CodexMessageRole,
        kind: CodexMessageKind = .chat,
        text: String,
        fileMentions: [String] = [],
        createdAt: Date = Date(),
        turnId: String? = nil,
        itemId: String? = nil,
        isStreaming: Bool = false,
        deliveryState: CodexMessageDeliveryState = .confirmed,
        attachments: [CodexImageAttachment] = [],
        planState: CodexPlanState? = nil,
        subagentAction: CodexSubagentAction? = nil,
        structuredUserInputRequest: CodexStructuredUserInputRequest? = nil,
        orderIndex: Int? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.kind = kind
        self.text = text
        self.fileMentions = fileMentions
        self.createdAt = createdAt
        self.turnId = turnId
        self.itemId = itemId
        self.isStreaming = isStreaming
        self.deliveryState = deliveryState
        self.attachments = attachments
        self.planState = planState
        self.subagentAction = subagentAction
        self.structuredUserInputRequest = structuredUserInputRequest
        self.orderIndex = orderIndex ?? CodexMessageOrderCounter.next()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case threadId
        case role
        case kind
        case text
        case fileMentions
        case createdAt
        case turnId
        case itemId
        case isStreaming
        case deliveryState
        case attachments
        case planState
        case subagentAction
        case structuredUserInputRequest
        case orderIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadId = try container.decode(String.self, forKey: .threadId)
        role = try container.decode(CodexMessageRole.self, forKey: .role)
        kind = try container.decodeIfPresent(CodexMessageKind.self, forKey: .kind) ?? .chat
        text = try container.decode(String.self, forKey: .text)
        fileMentions = try container.decodeIfPresent([String].self, forKey: .fileMentions) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        itemId = try container.decodeIfPresent(String.self, forKey: .itemId)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        deliveryState = try container.decodeIfPresent(CodexMessageDeliveryState.self, forKey: .deliveryState) ?? .confirmed
        attachments = try container.decodeIfPresent([CodexImageAttachment].self, forKey: .attachments) ?? []
        planState = try container.decodeIfPresent(CodexPlanState.self, forKey: .planState)
        subagentAction = try container.decodeIfPresent(CodexSubagentAction.self, forKey: .subagentAction)
        structuredUserInputRequest = try container.decodeIfPresent(
            CodexStructuredUserInputRequest.self,
            forKey: .structuredUserInputRequest
        )
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? CodexMessageOrderCounter.next()
    }
}
