// FILE: CodexService+IncomingPlanMode.swift
// Purpose: Handles plan-mode notifications and structured user-input requests.
// Layer: Service
// Exports: CodexService plan-mode incoming handlers
// Depends on: CodexService+Incoming shared routing helpers

import Foundation

extension CodexService {
    // Applies the latest structured plan snapshot for a turn while plan text keeps streaming separately.
    func handleTurnPlanUpdated(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject,
              let turnId = normalizedPlanIdentifier(paramsObject["turnId"]?.stringValue),
              let threadId = resolvePlanThreadID(paramsObject: paramsObject, turnId: turnId) else {
            return
        }

        threadIdByTurnID[turnId] = threadId
        let explanation = normalizedOptionalPlanText(paramsObject["explanation"]?.stringValue)
        let steps = decodePlanSteps(from: paramsObject["plan"])

        upsertPlanMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: nil,
            explanation: explanation,
            steps: steps,
            isStreaming: true,
            planPresentation: .progress
        )
    }

    // Streams the current proposed-plan text while treating the final item/completed body as authoritative.
    func appendPlanDelta(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject,
              let turnId = normalizedPlanIdentifier(paramsObject["turnId"]?.stringValue),
              let threadId = resolvePlanThreadID(paramsObject: paramsObject, turnId: turnId),
              let itemId = normalizedPlanIdentifier(paramsObject["itemId"]?.stringValue) else {
            return
        }

        let delta = paramsObject["delta"]?.stringValue ?? ""
        guard !delta.isEmpty else {
            return
        }

        threadIdByTurnID[turnId] = threadId
        upsertPlanMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            text: delta,
            isStreaming: true,
            planPresentation: .resultStreaming
        )
    }

    // Creates the inline question card used by plan mode when the server needs a structured answer.
    func handleStructuredUserInputRequest(
        requestID: JSONValue,
        paramsObject: IncomingParamsObject?
    ) {
        guard let paramsObject else {
            return
        }

        let turnId = normalizedPlanIdentifier(paramsObject["turnId"]?.stringValue)
        guard let threadId = normalizedPlanIdentifier(paramsObject["threadId"]?.stringValue)
            ?? turnId.flatMap({ threadIdByTurnID[$0] }) else {
            return
        }
        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }
        let itemId = normalizedPlanIdentifier(paramsObject["itemId"]?.stringValue) ?? "request-\(idKey(from: requestID))"
        let questions = decodeStructuredUserInputQuestions(from: paramsObject["questions"])
        guard !questions.isEmpty else {
            return
        }

        upsertStructuredUserInputPrompt(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            request: CodexStructuredUserInputRequest(
                requestID: requestID,
                questions: questions
            )
        )
        markNativePlanSession(for: threadId)
        notifyStructuredUserInputIfNeeded(
            threadId: threadId,
            turnId: turnId,
            requestID: requestID,
            questions: questions
        )
    }

    // Removes inline question cards once the server confirms the request was resolved.
    func handleServerRequestResolved(_ paramsObject: IncomingParamsObject?) {
        guard let requestID = paramsObject?["requestId"] else {
            return
        }

        let threadId = normalizedPlanIdentifier(paramsObject?["threadId"]?.stringValue)
        removeStructuredUserInputPrompt(requestID: requestID, threadIdHint: threadId)
    }
}

private extension CodexService {
    func normalizedPlanIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedOptionalPlanText(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // `turn/plan/updated` is documented around turn identity first, so recover the thread
    // from the stored turn mapping when the server omits `threadId`.
    func resolvePlanThreadID(
        paramsObject: IncomingParamsObject,
        turnId: String
    ) -> String? {
        normalizedPlanIdentifier(paramsObject["threadId"]?.stringValue)
            ?? threadIdByTurnID[turnId]
    }

    func decodePlanSteps(from value: JSONValue?) -> [CodexPlanStep] {
        let items = value?.arrayValue ?? []
        return items.compactMap { value in
            guard let object = value.objectValue,
                  let step = normalizedOptionalPlanText(object["step"]?.stringValue),
                  let rawStatus = normalizedOptionalPlanText(object["status"]?.stringValue),
                  let status = CodexPlanStepStatus(wireValue: rawStatus) else {
                return nil
            }

            return CodexPlanStep(step: step, status: status)
        }
    }

    func decodeStructuredUserInputQuestions(from value: JSONValue?) -> [CodexStructuredUserInputQuestion] {
        let items = value?.arrayValue ?? []
        return items.compactMap { value in
            guard let object = value.objectValue,
                  let id = normalizedPlanIdentifier(object["id"]?.stringValue),
                  let header = normalizedOptionalPlanText(object["header"]?.stringValue) ?? object["header"]?.stringValue,
                  let question = normalizedOptionalPlanText(object["question"]?.stringValue) ?? object["question"]?.stringValue else {
                return nil
            }

            let options = (object["options"]?.arrayValue ?? []).compactMap { optionValue -> CodexStructuredUserInputOption? in
                guard let optionObject = optionValue.objectValue,
                      let label = normalizedPlanIdentifier(optionObject["label"]?.stringValue),
                      let description = normalizedOptionalPlanText(optionObject["description"]?.stringValue) ?? optionObject["description"]?.stringValue else {
                    return nil
                }
                return CodexStructuredUserInputOption(label: label, description: description)
            }

            return CodexStructuredUserInputQuestion(
                id: id,
                header: header,
                question: question,
                isOther: object["isOther"]?.boolValue ?? false,
                isSecret: object["isSecret"]?.boolValue ?? false,
                selectionLimit: object["selectionLimit"]?.intValue ?? object["selection_limit"]?.intValue,
                options: options
            )
        }
    }
}
