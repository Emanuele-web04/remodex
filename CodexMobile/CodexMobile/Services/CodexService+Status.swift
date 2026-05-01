// FILE: CodexService+Status.swift
// Purpose: Fetches and tracks status-sheet data such as ChatGPT rate limits.
// Layer: Service
// Exports: CodexService status helpers
// Depends on: CodexRateLimitStatus, RPCMessage

import Foundation

extension CodexService {
    // Refreshes the shared usage surfaces with thread context (when available) plus account rate limits.
    func refreshUsageStatus(threadId: String?) async {
        if let normalizedThreadID = normalizedUsageStatusThreadID(threadId) {
            await refreshContextWindowUsage(threadId: normalizedThreadID)
        }
        await refreshRateLimits()
    }

    // Shared auto-refresh rule for status surfaces so empty-but-valid buckets do not loop forever.
    func shouldAutoRefreshUsageStatus(threadId: String?) -> Bool {
        guard isConnected else { return false }

        let needsContextUsage = normalizedUsageStatusThreadID(threadId).map { normalizedThreadID in
            contextWindowUsageByThread[normalizedThreadID] == nil
        } ?? false

        let needsRateLimits = !hasResolvedRateLimitsSnapshot
        return needsContextUsage || needsRateLimits
    }

    // Fetches the latest thread-scoped context usage from the local bridge fallback.
    func refreshContextWindowUsage(threadId: String) async {
        let trimmedThreadID = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadID.isEmpty else { return }

        var params: RPCObject = ["threadId": .string(trimmedThreadID)]
        if let turnId = activeTurnIdByThread[trimmedThreadID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnId.isEmpty {
            params["turnId"] = .string(turnId)
        }

        do {
            let response = try await sendRequest(method: "thread/contextWindow/read", params: .object(params))
            guard let resultObject = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("thread/contextWindow/read response missing payload")
            }

            guard let usageObject = resultObject["usage"]?.objectValue,
                  let usage = extractContextWindowUsage(from: usageObject) else {
                setDefaultContextWindowUsageIfNeeded(threadId: trimmedThreadID)
                return
            }

            contextWindowUsageByThread[trimmedThreadID] = usage
        } catch {
            setDefaultContextWindowUsageIfNeeded(threadId: trimmedThreadID)
            debugSyncLog("thread/contextWindow/read failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // Fetches the latest ChatGPT rate-limit buckets for the local status sheet.
    func refreshRateLimits() async {
        isLoadingRateLimits = true
        defer { isLoadingRateLimits = false }

        do {
            let response = try await fetchRateLimitsWithCompatRetry()
            guard let resultObject = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("account/rateLimits/read response missing payload")
            }

            applyRateLimitsPayload(resultObject, mergeWithExisting: false)
            hasResolvedRateLimitsSnapshot = true
            rateLimitsErrorMessage = nil
        } catch {
            hasResolvedRateLimitsSnapshot = false
            rateLimitBuckets = []
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            rateLimitsErrorMessage = message.isEmpty ? "Unable to load rate limits" : message
        }
    }

    func handleRateLimitsUpdated(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        applyRateLimitsPayload(paramsObject, mergeWithExisting: true)
        hasResolvedRateLimitsSnapshot = true
        rateLimitsErrorMessage = nil
    }
}

private extension CodexService {
    // Resolves missing context data so fresh chats show 0 instead of an endless loading state.
    func setDefaultContextWindowUsageIfNeeded(threadId: String) {
        if contextWindowUsageByThread[threadId] == nil {
            contextWindowUsageByThread[threadId] = .zero
        }
    }

    func normalizedUsageStatusThreadID(_ threadId: String?) -> String? {
        guard let rawThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawThreadId.isEmpty else {
            return nil
        }

        return rawThreadId
    }

    // Retries the account RPC with both accepted explicit-param shapes because runtimes disagree.
    func fetchRateLimitsWithCompatRetry() async throws -> RPCMessage {
        do {
            return try await sendRequest(method: "account/rateLimits/read", params: .null)
        } catch {
            guard shouldRetryRateLimitsWithEmptyParams(error) else {
                throw error
            }
        }

        return try await sendRequest(method: "account/rateLimits/read", params: .object([:]))
    }

    // Decodes both full read responses and partial realtime updates into display buckets.
    func applyRateLimitsPayload(
        _ payloadObject: IncomingParamsObject,
        mergeWithExisting: Bool
    ) {
        let decodedBuckets = decodeRateLimitBuckets(from: payloadObject)
        let resolvedBuckets = mergeWithExisting
            ? mergeRateLimitBuckets(existing: rateLimitBuckets, incoming: decodedBuckets)
            : decodedBuckets

        rateLimitBuckets = resolvedBuckets.sorted { lhs, rhs in
            if lhs.sortDurationMins == rhs.sortDurationMins {
                return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
            }
            return lhs.sortDurationMins < rhs.sortDurationMins
        }
    }

    func decodeRateLimitBuckets(from payloadObject: IncomingParamsObject) -> [CodexRateLimitBucket] {
        if let keyedBuckets = payloadObject["rateLimitsByLimitId"]?.objectValue
            ?? payloadObject["rate_limits_by_limit_id"]?.objectValue {
            return keyedBuckets.compactMap { limitId, value in
                decodeRateLimitBucket(limitId: limitId, value: value)
            }
        }

        if let nestedBuckets = payloadObject["rateLimits"]?.objectValue
            ?? payloadObject["rate_limits"]?.objectValue {
            if containsDirectRateLimitWindows(nestedBuckets) {
                return decodeDirectRateLimitBuckets(from: nestedBuckets)
            }

            if let decodedBucket = decodeRateLimitBucket(limitId: nil, value: .object(nestedBuckets)) {
                return [decodedBucket]
            }
        }

        if let nestedResult = payloadObject["result"]?.objectValue {
            return decodeRateLimitBuckets(from: nestedResult)
        }

        if containsDirectRateLimitWindows(payloadObject) {
            return decodeDirectRateLimitBuckets(from: payloadObject)
        }

        return []
    }

    func decodeRateLimitBucket(limitId explicitLimitId: String?, value: JSONValue) -> CodexRateLimitBucket? {
        guard let object = value.objectValue else { return nil }

        let limitId = firstNonEmptyString([
            explicitLimitId,
            firstStringValue(in: object, keys: ["limitId", "limit_id", "id"]),
        ]) ?? UUID().uuidString

        let primary = decodeRateLimitWindow(value: object["primary"] ?? object["primary_window"])
        let secondary = decodeRateLimitWindow(value: object["secondary"] ?? object["secondary_window"])

        guard primary != nil || secondary != nil else { return nil }

        return CodexRateLimitBucket(
            limitId: limitId,
            limitName: firstStringValue(in: object, keys: ["limitName", "limit_name", "name"]),
            primary: primary,
            secondary: secondary
        )
    }

    // Flattens direct account snapshots into one visible row per window.
    func decodeDirectRateLimitBuckets(from object: IncomingParamsObject) -> [CodexRateLimitBucket] {
        var buckets: [CodexRateLimitBucket] = []

        if let primary = decodeRateLimitWindow(value: object["primary"] ?? object["primary_window"]) {
            buckets.append(
                CodexRateLimitBucket(
                    limitId: "primary",
                    limitName: firstStringValue(in: object, keys: ["limitName", "limit_name", "name"]),
                    primary: primary,
                    secondary: nil
                )
            )
        }

        if let secondary = decodeRateLimitWindow(value: object["secondary"] ?? object["secondary_window"]) {
            buckets.append(
                CodexRateLimitBucket(
                    limitId: "secondary",
                    limitName: firstStringValue(in: object, keys: ["secondaryName", "secondary_name"]),
                    primary: secondary,
                    secondary: nil
                )
            )
        }

        return buckets
    }

    func decodeRateLimitWindow(value: JSONValue?) -> CodexRateLimitWindow? {
        guard let object = value?.objectValue else { return nil }

        let usedPercent = firstIntValue(in: object, keys: ["usedPercent", "used_percent"]) ?? 0
        let windowDurationMins = firstIntValue(
            in: object,
            keys: ["windowDurationMins", "window_duration_mins", "windowMinutes", "window_minutes"]
        )

        let resetDate: Date?
        if let rawResetsAt = object["resetsAt"]?.doubleValue
            ?? object["resets_at"]?.doubleValue
            ?? object["resetAt"]?.doubleValue
            ?? object["reset_at"]?.doubleValue {
            let secondsValue = rawResetsAt > 10_000_000_000 ? rawResetsAt / 1000 : rawResetsAt
            resetDate = Date(timeIntervalSince1970: secondsValue)
        } else if let rawResetsAtString = firstStringValue(
            in: object,
            keys: ["resetsAt", "resets_at", "resetAt", "reset_at"]
        ) {
            resetDate = ISO8601DateFormatter().date(from: rawResetsAtString)
        } else {
            resetDate = nil
        }

        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: windowDurationMins,
            resetsAt: resetDate
        )
    }

    func containsDirectRateLimitWindows(_ object: IncomingParamsObject) -> Bool {
        object["primary"] != nil
            || object["secondary"] != nil
            || object["primary_window"] != nil
            || object["secondary_window"] != nil
    }

    func mergeRateLimitBuckets(
        existing: [CodexRateLimitBucket],
        incoming: [CodexRateLimitBucket]
    ) -> [CodexRateLimitBucket] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var mergedById = Dictionary(uniqueKeysWithValues: existing.map { ($0.limitId, $0) })
        for bucket in incoming {
            if let current = mergedById[bucket.limitId] {
                mergedById[bucket.limitId] = CodexRateLimitBucket(
                    limitId: bucket.limitId,
                    limitName: bucket.limitName ?? current.limitName,
                    primary: bucket.primary ?? current.primary,
                    secondary: bucket.secondary ?? current.secondary
                )
            } else {
                mergedById[bucket.limitId] = bucket
            }
        }

        return Array(mergedById.values)
    }

    func shouldRetryRateLimitsWithEmptyParams(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32602 || rpcError.code == -32600 else {
            return false
        }

        let lowered = rpcError.message.lowercased()
        return lowered.contains("invalid params")
            || lowered.contains("invalid param")
            || lowered.contains("failed to parse")
            || lowered.contains("expected")
            || lowered.contains("missing field `params`")
            || lowered.contains("missing field params")
    }
}
