import Foundation

/// Links reply user items to their original async question item without relying on
/// a server-side answered flag (which the Codex app-server does not provide).
nonisolated enum CodexAsyncUserInputProjection {
    private struct NativeReply {
        let itemID: String
        let indexedAnswers: [(index: Int, title: String, answer: String)]

        var displayText: String {
            indexedAnswers.sorted { $0.index < $1.index }
                .map { "\($0.title)\n\($0.answer)" }
                .joined(separator: "\n\n")
        }
    }

    static func reconcile(_ messages: inout [CodexMessage]) {
        for userIndex in messages.indices where messages[userIndex].role == .user {
            let raw = messages[userIndex].text
            if let reply = nativeReply(from: raw) {
                messages[userIndex].kind = .asyncUserInputAnswer
                guard let questionIndex = messages.indices.reversed().first(where: { index in
                    index < userIndex
                        && messages[index].role == .assistant
                        && messages[index].itemId == reply.itemID
                        && messages[index].asyncUserInput != nil
                }), let input = messages[questionIndex].asyncUserInput,
                    reply.indexedAnswers.count == input.questions.count else { continue }
                let sorted = reply.indexedAnswers.sorted { $0.index < $1.index }
                guard sorted.enumerated().allSatisfy({ offset, entry in
                    entry.index == offset && entry.title == input.questions[offset].title
                }) else { continue }
                messages[userIndex].text = reply.displayText
                markAnswered(&messages, questionIndex: questionIndex, userIndex: userIndex,
                             answers: sorted.map(\.answer))
                continue
            }

            guard messages[userIndex].kind == .chat else { continue }
            // Synara sends ordinary title/newline/answer text. Bind only to the
            // nearest preceding unanswered question and require every title verbatim.
            guard let questionIndex = messages.indices.reversed().first(where: { index in
                guard index < userIndex,
                      let input = messages[index].asyncUserInput,
                      input.status != .answered else { return false }
                return formattedAnswers(from: raw, questions: input.questions) != nil
            }), let input = messages[questionIndex].asyncUserInput,
                let answers = formattedAnswers(from: raw, questions: input.questions) else { continue }
            markAnswered(&messages, questionIndex: questionIndex, userIndex: userIndex, answers: answers)
            messages[userIndex].kind = .asyncUserInputAnswer
        }
    }

    private static func markAnswered(
        _ messages: inout [CodexMessage],
        questionIndex: Int,
        userIndex: Int,
        answers: [String]
    ) {
        let responseID = messages[userIndex].id
        let responseDate = messages[userIndex].createdAt
        let wasAnswered = messages[questionIndex].asyncUserInput?.status == .answered
        messages[questionIndex].asyncUserInput?.answers = answers
        messages[questionIndex].asyncUserInput?.status = .answered
        messages[questionIndex].asyncUserInput?.responseMessageID = responseID
        if !wasAnswered {
            messages[questionIndex].asyncUserInput?.responseRecordedAt = responseDate
            messages[questionIndex].asyncUserInput?.canonicalAbsenceCount = 0
            messages[questionIndex].asyncUserInput?.lastCanonicalAbsenceAt = nil
        }
    }

    /// Only a complete canonical read can invalidate a previously accepted reply.
    /// Two separated reads avoid reopening on one stale snapshot during reconnect.
    static func hasMissingAnswerCandidate(in messages: [CodexMessage], canonical: [CodexMessage]) -> Bool {
        let questionIDs = Set(canonical.compactMap { $0.asyncUserInput != nil ? $0.itemId : nil })
        let answeredIDs = Set(canonical.compactMap { $0.asyncUserInput?.status == .answered ? $0.itemId : nil })
        return messages.contains {
            ($0.asyncUserInput?.status == .answered || $0.asyncUserInput?.status == .uncertain)
                && $0.itemId.map { questionIDs.contains($0) && !answeredIDs.contains($0) } == true
        }
    }

    static func reopenRepliesMissingFromCanonicalHistory(
        _ messages: inout [CodexMessage],
        canonical: [CodexMessage],
        now: Date = Date()
    ) -> TimeInterval? {
        let canonicalQuestionIDs = Set(canonical.compactMap { message -> String? in
            message.asyncUserInput != nil ? message.itemId : nil
        })
        let canonicalAnsweredIDs = Set(canonical.compactMap { message -> String? in
            message.asyncUserInput?.status == .answered ? message.itemId : nil
        })
        var removedResponseIDs: Set<String> = []
        var nextCheckDelay: TimeInterval?
        for index in messages.indices {
            guard let itemID = messages[index].itemId,
                  canonicalQuestionIDs.contains(itemID),
                  var input = messages[index].asyncUserInput,
                  input.status == .answered || input.status == .uncertain else { continue }
            if canonicalAnsweredIDs.contains(itemID) {
                input.status = .answered
                input.canonicalAbsenceCount = 0
                input.lastCanonicalAbsenceAt = nil
                messages[index].asyncUserInput = input
                continue
            }
            guard let recordedAt = input.responseRecordedAt else { continue }
            let age = now.timeIntervalSince(recordedAt)
            if age <= 8 {
                nextCheckDelay = min(nextCheckDelay ?? .infinity, max(3, min(30, 8 - age + 0.5)))
                continue
            }
            if let last = input.lastCanonicalAbsenceAt,
               now.timeIntervalSince(last) >= 2 {
                input.canonicalAbsenceCount += 1
            } else if input.lastCanonicalAbsenceAt == nil {
                input.canonicalAbsenceCount = 1
            } else {
                nextCheckDelay = min(nextCheckDelay ?? .infinity, 3)
                continue
            }
            input.lastCanonicalAbsenceAt = now
            if input.canonicalAbsenceCount >= 2 {
                if let responseID = input.responseMessageID { removedResponseIDs.insert(responseID) }
                input.prepareForRetry()
            } else {
                nextCheckDelay = min(nextCheckDelay ?? .infinity, 3)
            }
            messages[index].asyncUserInput = input
        }
        if !removedResponseIDs.isEmpty {
            messages.removeAll { removedResponseIDs.contains($0.id) && $0.kind == .asyncUserInputAnswer }
        }
        return nextCheckDelay
    }

    private static func formattedAnswers(
        from text: String,
        questions: [CodexAsyncUserInputQuestion]
    ) -> [String]? {
        guard !questions.isEmpty else { return nil }
        var remaining = text[...]
        var answers: [String] = []
        for index in questions.indices {
            let prefix = questions[index].title + "\n"
            guard remaining.hasPrefix(prefix) else { return nil }
            remaining = remaining.dropFirst(prefix.count)
            let answer: Substring
            if index + 1 < questions.count {
                let next = "\n\n" + questions[index + 1].title + "\n"
                guard let range = remaining.range(of: next) else { return nil }
                answer = remaining[..<range.lowerBound]
                remaining = remaining[range.lowerBound...].dropFirst(2)
            } else {
                answer = remaining
            }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            answers.append(String(answer))
        }
        return answers
    }

    private static func nativeReply(from text: String) -> NativeReply? {
        let start = "<send_user_message_question_reply>\n"
        let end = "\n</send_user_message_question_reply>"
        guard text.hasPrefix(start), text.hasSuffix(end) else { return nil }
        let body = String(text.dropFirst(start.count).dropLast(end.count))
        guard let data = body.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]],
              !entries.isEmpty else { return nil }
        var itemID: String?
        var answers: [(index: Int, title: String, answer: String)] = []
        for entry in entries {
            guard let key = entry["questionItemId"],
                  let keyData = key.data(using: .utf8),
                  let parts = (try? JSONSerialization.jsonObject(with: keyData)) as? [Any],
                  parts.count == 3, parts[0] as? String == "request_user_input_async",
                  let currentID = parts[1] as? String,
                  let index = parts[2] as? Int,
                  index >= 0,
                  let title = entry["question"], !title.isEmpty,
                  let answer = entry["answer"], !answer.isEmpty else { return nil }
            if let itemID, itemID != currentID { return nil }
            itemID = currentID
            answers.append((index, title, answer))
        }
        guard let itemID, Set(answers.map(\.index)).count == answers.count else { return nil }
        return NativeReply(itemID: itemID, indexedAnswers: answers)
    }
}
