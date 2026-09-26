import Foundation

nonisolated struct CodexAsyncUserInputQuestion: Codable, Hashable, Sendable {
    let title: String
    let options: [String]?
}

nonisolated enum CodexAsyncUserInputStatus: String, Codable, Hashable, Sendable {
    case unanswered
    case submitting
    case queued
    case answered
    case uncertain
}

/// The answer is a local projection: Codex does not update its original agentMessage.
nonisolated struct CodexAsyncUserInput: Codable, Hashable, Sendable {
    let questions: [CodexAsyncUserInputQuestion]
    var answers: [String]?
    var status: CodexAsyncUserInputStatus = .unanswered
    var responseMessageID: String?
    var responseRecordedAt: Date?
    var canonicalAbsenceCount: Int = 0
    var lastCanonicalAbsenceAt: Date?

    var responseText: String? {
        guard let answers, answers.count == questions.count else { return nil }
        return zip(questions, answers).map { "\($0.title)\n\($1)" }.joined(separator: "\n\n")
    }

    mutating func prepareForRetry() {
        // Preserve the draft so reconnect recovery does not erase the user's answer.
        status = .unanswered
        responseMessageID = nil
        responseRecordedAt = nil
        canonicalAbsenceCount = 0
        lastCanonicalAbsenceAt = nil
    }

    static func decode(from item: [String: JSONValue]) -> Self? {
        guard item["delivery"]?.stringValue?.lowercased() == "async",
              let rawQuestions = item["questions"]?.arrayValue,
              !rawQuestions.isEmpty else { return nil }
        let questions = rawQuestions.compactMap { value -> CodexAsyncUserInputQuestion? in
            guard let object = value.objectValue,
                  let title = object["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            var options: [String]?
            if let rawOptions = object["options"], case .null = rawOptions {
                options = nil
            } else if let rawOptions = object["options"] {
                guard let values = rawOptions.arrayValue else { return nil }
                let decoded = values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard decoded.count == values.count, decoded.allSatisfy({ !$0.isEmpty }) else { return nil }
                options = decoded
            }
            return .init(title: title, options: options)
        }
        guard questions.count == rawQuestions.count else { return nil }
        return .init(questions: questions)
    }

    static func merge(local: Self?, incoming: Self) -> Self {
        guard let local, local.questions == incoming.questions else { return incoming }
        if incoming.status == .answered { return incoming }
        var value = incoming
        value.answers = local.answers
        value.status = local.status
        value.responseMessageID = local.responseMessageID
        value.responseRecordedAt = local.responseRecordedAt
        value.canonicalAbsenceCount = local.canonicalAbsenceCount
        value.lastCanonicalAbsenceAt = local.lastCanonicalAbsenceAt
        return value
    }
}
