// FILE: CodexMessage.swift
// Purpose: Defines chat messages and timestamp metadata rendered in each thread timeline.
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

struct CodexMessageTextRenderSignature: Codable, Hashable, Sendable {
    let byteCount: Int
    let revision: Int

    init(text: String) {
        self.byteCount = text.utf8.count
        self.revision = CodexMessageTextRenderSignatureCounter.next()
    }
}

/// Gives message text changes a tiny render-facing identity so SwiftUI equality
/// can avoid rescanning large transcripts while rows are diffed.
nonisolated enum CodexMessageTextRenderSignatureCounter {
    private nonisolated(unsafe) static var counter: Int = 0
    private static let lock = NSLock()

    static func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = counter
        counter += 1
        return value
    }
}

struct CodexMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let threadId: String
    let role: CodexMessageRole
    var kind: CodexMessageKind
    var assistantPhase: String?
    var text: String {
        didSet {
            textRenderSignature = CodexMessageTextRenderSignature(text: text)
        }
    }
    var textRenderSignature: CodexMessageTextRenderSignature
    var fileMentions: [String]
    var skillMentions: [String]
    var pluginMentions: [String]
    var createdAt: Date
    var timeZoneIdentifier: String?
    var turnId: String?
    var itemId: String?
    var isStreaming: Bool
    var deliveryState: CodexMessageDeliveryState
    var attachments: [CodexImageAttachment]
    var planState: CodexPlanState?
    var planPresentation: CodexPlanPresentation?
    var proposedPlan: CodexProposedPlan?
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
        assistantPhase: String? = nil,
        text: String,
        fileMentions: [String] = [],
        skillMentions: [String] = [],
        pluginMentions: [String] = [],
        createdAt: Date = Date(),
        timeZoneIdentifier: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        isStreaming: Bool = false,
        deliveryState: CodexMessageDeliveryState = .confirmed,
        attachments: [CodexImageAttachment] = [],
        planState: CodexPlanState? = nil,
        planPresentation: CodexPlanPresentation? = nil,
        proposedPlan: CodexProposedPlan? = nil,
        subagentAction: CodexSubagentAction? = nil,
        structuredUserInputRequest: CodexStructuredUserInputRequest? = nil,
        orderIndex: Int? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.kind = kind
        self.assistantPhase = assistantPhase
        self.text = text
        self.textRenderSignature = CodexMessageTextRenderSignature(text: text)
        self.fileMentions = fileMentions
        self.skillMentions = skillMentions
        self.pluginMentions = pluginMentions
        self.createdAt = createdAt
        self.timeZoneIdentifier = Self.validatedTimeZoneIdentifier(timeZoneIdentifier)
        self.turnId = turnId
        self.itemId = itemId
        self.isStreaming = isStreaming
        self.deliveryState = deliveryState
        self.attachments = attachments
        self.planState = planState
        self.planPresentation = Self.derivedPlanPresentation(
            role: role,
            kind: kind,
            planState: planState,
            planPresentation: planPresentation,
            itemId: itemId,
            proposedPlan: proposedPlan
        )
        self.proposedPlan = proposedPlan ?? Self.derivedProposedPlan(
            role: role,
            kind: kind,
            text: text,
            itemId: itemId,
            planState: planState,
            planPresentation: self.planPresentation
        )
        self.subagentAction = subagentAction
        self.structuredUserInputRequest = structuredUserInputRequest
        self.orderIndex = orderIndex ?? CodexMessageOrderCounter.next()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case threadId
        case role
        case kind
        case assistantPhase
        case text
        case fileMentions
        case skillMentions
        case pluginMentions
        case createdAt
        case timeZoneIdentifier
        case turnId
        case itemId
        case isStreaming
        case deliveryState
        case attachments
        case planState
        case planPresentation
        case proposedPlan
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
        assistantPhase = try container.decodeIfPresent(String.self, forKey: .assistantPhase)
        text = try container.decode(String.self, forKey: .text)
        textRenderSignature = CodexMessageTextRenderSignature(text: text)
        fileMentions = try container.decodeIfPresent([String].self, forKey: .fileMentions) ?? []
        skillMentions = try container.decodeIfPresent([String].self, forKey: .skillMentions) ?? []
        pluginMentions = try container.decodeIfPresent([String].self, forKey: .pluginMentions) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        timeZoneIdentifier = Self.validatedTimeZoneIdentifier(
            try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        )
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        itemId = try container.decodeIfPresent(String.self, forKey: .itemId)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        deliveryState = try container.decodeIfPresent(CodexMessageDeliveryState.self, forKey: .deliveryState) ?? .confirmed
        attachments = try container.decodeIfPresent([CodexImageAttachment].self, forKey: .attachments) ?? []
        planState = try container.decodeIfPresent(CodexPlanState.self, forKey: .planState)
        let decodedProposedPlan = try container.decodeIfPresent(CodexProposedPlan.self, forKey: .proposedPlan)
        planPresentation = Self.derivedPlanPresentation(
            role: role,
            kind: kind,
            planState: planState,
            planPresentation: try container.decodeIfPresent(CodexPlanPresentation.self, forKey: .planPresentation),
            itemId: itemId,
            proposedPlan: decodedProposedPlan
        )
        proposedPlan = decodedProposedPlan
            ?? Self.derivedProposedPlan(
                role: role,
                kind: kind,
                text: text,
                itemId: itemId,
                planState: planState,
                planPresentation: planPresentation
            )
        subagentAction = try container.decodeIfPresent(CodexSubagentAction.self, forKey: .subagentAction)
        structuredUserInputRequest = try container.decodeIfPresent(
            CodexStructuredUserInputRequest.self,
            forKey: .structuredUserInputRequest
        )
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? CodexMessageOrderCounter.next()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(role, forKey: .role)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(assistantPhase, forKey: .assistantPhase)
        try container.encode(text, forKey: .text)
        try container.encode(fileMentions, forKey: .fileMentions)
        try container.encode(skillMentions, forKey: .skillMentions)
        try container.encode(pluginMentions, forKey: .pluginMentions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encodeIfPresent(turnId, forKey: .turnId)
        try container.encodeIfPresent(itemId, forKey: .itemId)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(deliveryState, forKey: .deliveryState)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(planState, forKey: .planState)
        try container.encodeIfPresent(planPresentation, forKey: .planPresentation)
        try container.encodeIfPresent(proposedPlan, forKey: .proposedPlan)
        try container.encodeIfPresent(subagentAction, forKey: .subagentAction)
        try container.encodeIfPresent(structuredUserInputRequest, forKey: .structuredUserInputRequest)
        try container.encode(orderIndex, forKey: .orderIndex)
    }

    // Formats timeline chrome in the originating desktop timezone when history provides it.
    func formattedTimelineTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        if let timeZoneIdentifier,
           let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = .autoupdatingCurrent
        }
        return formatter.string(from: createdAt)
    }

    private static func validatedTimeZoneIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              TimeZone(identifier: trimmedValue) != nil else {
            return nil
        }
        return trimmedValue
    }

    static func == (lhs: CodexMessage, rhs: CodexMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.threadId == rhs.threadId
            && lhs.role == rhs.role
            && lhs.kind == rhs.kind
            && lhs.assistantPhase == rhs.assistantPhase
            && lhs.text == rhs.text
            && lhs.fileMentions == rhs.fileMentions
            && lhs.skillMentions == rhs.skillMentions
            && lhs.pluginMentions == rhs.pluginMentions
            && lhs.createdAt == rhs.createdAt
            && lhs.timeZoneIdentifier == rhs.timeZoneIdentifier
            && lhs.turnId == rhs.turnId
            && lhs.itemId == rhs.itemId
            && lhs.isStreaming == rhs.isStreaming
            && lhs.deliveryState == rhs.deliveryState
            && lhs.attachments == rhs.attachments
            && lhs.planState == rhs.planState
            && lhs.planPresentation == rhs.planPresentation
            && lhs.proposedPlan == rhs.proposedPlan
            && lhs.subagentAction == rhs.subagentAction
            && lhs.structuredUserInputRequest == rhs.structuredUserInputRequest
            && lhs.orderIndex == rhs.orderIndex
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(threadId)
        hasher.combine(role)
        hasher.combine(kind)
        hasher.combine(assistantPhase)
        hasher.combine(text)
        hasher.combine(fileMentions)
        hasher.combine(skillMentions)
        hasher.combine(pluginMentions)
        hasher.combine(createdAt)
        hasher.combine(timeZoneIdentifier)
        hasher.combine(turnId)
        hasher.combine(itemId)
        hasher.combine(isStreaming)
        hasher.combine(deliveryState)
        hasher.combine(attachments)
        hasher.combine(planState)
        hasher.combine(planPresentation)
        hasher.combine(proposedPlan)
        hasher.combine(subagentAction)
        hasher.combine(structuredUserInputRequest)
        hasher.combine(orderIndex)
    }

    private static func derivedProposedPlan(
        role: CodexMessageRole,
        kind: CodexMessageKind,
        text: String,
        itemId: String?,
        planState: CodexPlanState?,
        planPresentation: CodexPlanPresentation?
    ) -> CodexProposedPlan? {
        if role == .system && kind == .plan {
            let resolvedPresentation = derivedPlanPresentation(
                role: role,
                kind: kind,
                planState: planState,
                planPresentation: planPresentation,
                itemId: itemId,
                proposedPlan: nil
            )
            guard resolvedPresentation == .resultCompletedItem || resolvedPresentation == .resultReady else {
                return nil
            }

            return CodexProposedPlanParser.parsePlanItem(from: text)
        }

        return CodexProposedPlanParser.parse(from: text)
    }

    private static func derivedPlanPresentation(
        role: CodexMessageRole,
        kind: CodexMessageKind,
        planState: CodexPlanState?,
        planPresentation: CodexPlanPresentation?,
        itemId: String?,
        proposedPlan: CodexProposedPlan?
    ) -> CodexPlanPresentation? {
        guard role == .system, kind == .plan else {
            return nil
        }

        if let planPresentation {
            return planPresentation
        }

        let hasPlanSteps = !(planState?.steps.isEmpty ?? true)
        let hasExplanation = !(planState?.explanation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hasPlanSteps || hasExplanation {
            return .progress
        }

        if let itemId, !itemId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Older persisted plan-item rows may not include explicit presentation metadata.
            // If they already persisted a parsed proposed plan, recover them as ready; otherwise
            // keep them conservative until fresher runtime/history data reclassifies them.
            return proposedPlan == nil ? .resultClosed : .resultReady
        }

        return nil
    }

    var resolvedPlanPresentation: CodexPlanPresentation? {
        Self.derivedPlanPresentation(
            role: role,
            kind: kind,
            planState: planState,
            planPresentation: planPresentation,
            itemId: itemId,
            proposedPlan: proposedPlan
        )
    }

}
