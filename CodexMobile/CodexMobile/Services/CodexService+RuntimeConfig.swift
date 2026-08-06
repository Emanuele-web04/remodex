// FILE: CodexService+RuntimeConfig.swift
// Purpose: Runtime model/reasoning/access preferences, per-thread overrides, and model/list loading.
// Layer: Service
// Exports: CodexService runtime config APIs
// Depends on: CodexModelOption, CodexReasoningEffortOption, CodexAccessMode

import Foundation

private let runtimeDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private enum RuntimeConfigLoadingPolicy {
    static let modelListTimeoutNanoseconds: UInt64 = 8_000_000_000
}

private enum RuntimeDebugLogPolicy {
    static let maximumStoredEntries = 400
    static let storedEntryTrimBatch = 80
    static let itemCompletionBatchSize = 100
    static let itemCompletionFlushNanoseconds: UInt64 = 2_000_000_000
    static let maximumReportedItemTypes = 6
}

private enum RuntimeSelectionDefaults {
    static let modelId = "gpt-5.6-sol"
    static let fallbackModelIds = [modelId, "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
    static let reasoningEffort = "medium"

    static func reasoningEffort(for unresolvedModelId: String?) -> String? {
        guard let unresolvedModelId,
              unresolvedModelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modelId else {
            return nil
        }
        return reasoningEffort
    }
}

private enum RuntimeSandboxParameter {
    case sandbox
    case sandboxPolicy

    var name: String {
        switch self {
        case .sandbox:
            return "sandbox"
        case .sandboxPolicy:
            return "sandboxPolicy"
        }
    }

    func applying(
        configuration: RuntimeAccessConfiguration,
        to baseParams: RPCObject
    ) -> RPCObject {
        var params = baseParams
        switch self {
        case .sandbox:
            params[name] = .string(configuration.legacySandbox)
        case .sandboxPolicy:
            params[name] = configuration.sandboxPolicy
        }
        return params
    }
}

private enum RuntimeRequestContract {
    static let approvalOverrideMethods: Set<String> = [
        "thread/start",
        "thread/resume",
        "thread/fork",
        "turn/start",
    ]

    static func sandboxParameters(for method: String) -> [RuntimeSandboxParameter]? {
        switch method {
        case "thread/start", "thread/resume", "thread/fork":
            return [.sandbox, .sandboxPolicy]
        case "turn/start":
            return [.sandboxPolicy, .sandbox]
        default:
            return nil
        }
    }
}

extension CodexService {
    func runtimeAccessConfiguration() -> RuntimeAccessConfiguration {
        RuntimeAccessConfiguration(mode: selectedAccessMode)
    }

    // Resolves the effective per-chat override record after normalizing the thread id.
    func threadRuntimeOverride(for threadId: String?) -> CodexThreadRuntimeOverride? {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return nil
        }
        return threadRuntimeOverridesByThreadID[normalizedThreadID]
    }

    // Sends one request while trying approval policy and reviewer variants for cross-version compatibility.
    func sendRequestWithApprovalPolicyFallback(
        method: String,
        baseParams: RPCObject,
        context: String,
        accessConfiguration: RuntimeAccessConfiguration? = nil
    ) async throws -> RPCMessage {
        let accessConfiguration = accessConfiguration ?? RuntimeAccessConfiguration(mode: selectedAccessMode)
        let policies = accessConfiguration.approvalPolicyCandidates
        let supportsReviewerOverride = RuntimeRequestContract.approvalOverrideMethods.contains(method)
        let reviewers = supportsReviewerOverride
            ? accessConfiguration.approvalsReviewerCandidates
            : [nil]
        var lastError: Error?

        for (reviewerIndex, reviewer) in reviewers.enumerated() {
            for (policyIndex, policy) in policies.enumerated() {
                var params = baseParams
                params["approvalPolicy"] = .string(policy)
                if let reviewer {
                    params["approvalsReviewer"] = .string(reviewer)
                }

                do {
                    return try await sendRequest(method: method, params: .object(params))
                } catch {
                    lastError = error
                    let hasMorePolicies = policyIndex < (policies.count - 1)
                    // Reviewer rejections must advance the reviewer loop directly;
                    // retrying other policy candidates with a known-bad reviewer
                    // only burns transport round trips.
                    if hasMorePolicies,
                       shouldRetryWithApprovalPolicyFallback(error),
                       !shouldRetryWithApprovalsReviewerFallback(error) {
                        debugRuntimeLog("\(method) \(context) fallback approvalPolicy=\(policy)")
                        continue
                    }
                    break
                }
            }

            let hasMoreReviewers = reviewerIndex < (reviewers.count - 1)
            if hasMoreReviewers, let lastError, shouldRetryWithApprovalsReviewerFallback(lastError) {
                debugRuntimeLog(
                    "\(method) \(context) fallback approvalsReviewer=\(reviewer ?? "omitted")"
                )
                continue
            }
            break
        }

        if supportsReviewerOverride,
           accessConfiguration.mode == .autoReview,
           let lastError,
           shouldRetryWithApprovalsReviewerFallback(lastError) {
            throw CodexServiceError.invalidInput(
                "Approve for me requires a newer Codex version. Update Codex on your Mac and retry."
            )
        }

        throw lastError ?? CodexServiceError.invalidResponse("\(method) failed with unknown approvalPolicy error")
    }

    // On-demand retry for runtime surfaces: the bootstrap `model/list` can fail
    // or still be in flight when the user opens a picker, and nothing else
    // re-requests it until the next reconnect. Cheap no-op once models exist.
    func refreshModelsIfNeeded() {
        guard availableModels.isEmpty, !isLoadingModels, isConnected else { return }
        Task { @MainActor in
            try? await listModels()
        }
    }

    func listModels() async throws {
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            let response = try await sendRequest(
                method: "model/list",
                params: .object([
                    "cursor": .null,
                    "limit": .integer(50),
                    "includeHidden": .bool(false),
                ]),
                timeoutNanoseconds: RuntimeConfigLoadingPolicy.modelListTimeoutNanoseconds,
                timeoutMessage: "model/list timed out while syncing runtime options."
            )

            guard let resultObject = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("model/list response missing payload")
            }

            let items =
                resultObject["items"]?.arrayValue
                ?? resultObject["data"]?.arrayValue
                ?? resultObject["models"]?.arrayValue
                ?? []

            let decodedModels = items.compactMap { decodeModel(CodexModelOption.self, from: $0) }
            availableModels = decodedModels
            modelsErrorMessage = nil
            normalizeRuntimeSelectionsAfterModelsUpdate()

            debugRuntimeLog("model/list success count=\(decodedModels.count)")
        } catch {
            handleModelListFailure(error)
            throw error
        }
    }

    func setSelectedModelId(_ modelId: String?) {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized?.isEmpty == false {
            selectedModelId = normalized
        } else {
            selectedModelId = RuntimeSelectionDefaults.modelId
            selectedReasoningEffort = RuntimeSelectionDefaults.reasoningEffort
        }
        hasPersistedSelectedModelId = true
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    func setSelectedGitWriterModelId(_ modelId: String?) {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedGitWriterModelId = (normalized?.isEmpty == false) ? normalized : nil
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    func setSelectedReasoningEffort(_ effort: String?) {
        let normalized = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedReasoningEffort = (normalized?.isEmpty == false) ? normalized : nil
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    func setThreadModelOverride(_ modelId: String, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }
        let normalizedModelID = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else {
            clearThreadModelOverride(for: normalizedThreadID)
            return
        }
        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.modelId = normalizedModelID
            override.overridesModel = true
        }
    }

    func clearThreadModelOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }
        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.modelId = nil
            override.overridesModel = false
        }
    }

    func setThreadReasoningEffortOverride(_ effort: String, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        let normalizedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEffort.isEmpty else {
            clearThreadReasoningEffortOverride(for: normalizedThreadID)
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.reasoningEffort = normalizedEffort
            override.overridesReasoning = true
        }
    }

    func clearThreadReasoningEffortOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.reasoningEffort = nil
            override.overridesReasoning = false
        }
    }

    func setSelectedServiceTier(_ serviceTier: CodexServiceTier?) {
        selectedServiceTier = normalizedServiceTierForSelectedModel(serviceTier)
        persistRuntimeSelections()
    }

    func setThreadServiceTierOverride(_ serviceTier: CodexServiceTier?, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        let normalizedServiceTier = normalizedServiceTierForSelectedModel(serviceTier, threadId: normalizedThreadID)
        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.serviceTierRawValue = normalizedServiceTier?.rawValue
            override.overridesServiceTier = true
        }
    }

    func clearThreadServiceTierOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.serviceTierRawValue = nil
            override.overridesServiceTier = false
        }
    }

    func applyThreadRuntimeOverride(_ runtimeOverride: CodexThreadRuntimeOverride?, to threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        guard let runtimeOverride, !runtimeOverride.isEmpty else {
            threadRuntimeOverridesByThreadID.removeValue(forKey: normalizedThreadID)
            persistThreadRuntimeOverrides()
            return
        }

        threadRuntimeOverridesByThreadID[normalizedThreadID] = runtimeOverride
        persistThreadRuntimeOverrides()
    }

    func setSelectedAccessMode(_ accessMode: CodexAccessMode) {
        selectedAccessMode = accessMode
        persistRuntimeSelections()
    }

    func selectedModelOption(threadId: String? = nil) -> CodexModelOption? {
        let selectedIdentifier = selectedModelIdentifier(threadId: threadId)
        return availableModels.first {
            $0.id == selectedIdentifier || $0.model == selectedIdentifier
        }
    }

    // Composer chrome should not present the canonical fallback as a loaded user choice.
    func visibleSelectedModelIDForComposer(threadId: String? = nil) -> String? {
        if let selectedModel = selectedModelOption(threadId: threadId) {
            return selectedModel.id
        }

        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesModel,
           let modelId = threadOverride.modelId {
            return modelId
        }

        guard hasPersistedSelectedModelId else {
            return nil
        }

        if shouldHidePersistedDefaultWhileRuntimeLoads {
            return nil
        }

        return selectedModelId
    }

    // Keeps the model pill honest while bridge runtime metadata is still in flight.
    func isRuntimeSelectionLoadingForComposer(threadId: String? = nil) -> Bool {
        guard visibleSelectedModelIDForComposer(threadId: threadId) == nil else {
            return false
        }
        return isBootstrappingConnectionSync || isLoadingThreads || isLoadingModels
    }

    func selectedGitWriterModelOption() -> CodexModelOption? {
        selectedGitWriterModelOption(from: availableModels)
    }

    func selectedModelSupportsServiceTier(
        _ serviceTier: CodexServiceTier,
        threadId: String? = nil
    ) -> Bool {
        if let model = selectedModelOption(threadId: threadId) {
            return model.supportsServiceTier(serviceTier)
        }
        return threadRuntimeOverride(for: threadId)?.serviceTier == serviceTier
    }

    func gitWriterModelIdentifier() -> String? {
        selectedGitWriterModelOption()?.model
    }

    func supportedReasoningEffortsForSelectedModel(threadId: String? = nil) -> [CodexReasoningEffortOption] {
        selectedModelOption(threadId: threadId)?.supportedReasoningEfforts ?? []
    }

    func isThreadReasoningEffortOverridden(_ threadId: String?) -> Bool {
        guard let threadOverride = threadRuntimeOverride(for: threadId),
              threadOverride.overridesReasoning,
              let selectedReasoning = threadOverride.reasoningEffort else {
            return false
        }

        let supportedReasoningEfforts = Set(
            supportedReasoningEffortsForSelectedModel(threadId: threadId).map(\.reasoningEffort)
        )
        return supportedReasoningEfforts.contains(selectedReasoning)
    }

    func isThreadServiceTierOverridden(_ threadId: String?) -> Bool {
        threadRuntimeOverride(for: threadId)?.overridesServiceTier == true
    }

    func selectedReasoningEffortForSelectedModel(threadId: String? = nil) -> String? {
        let selectedIdentifier = selectedModelIdentifier(threadId: threadId)
        guard let model = selectedModelOption(threadId: threadId) else {
            if let threadOverride = threadRuntimeOverride(for: threadId),
               threadOverride.overridesReasoning,
               let reasoningEffort = threadOverride.reasoningEffort {
                return reasoningEffort
            }
            return RuntimeSelectionDefaults.reasoningEffort(for: selectedIdentifier)
                ?? selectedReasoningEffort
                ?? RuntimeSelectionDefaults.reasoningEffort
        }

        let supported = Set(model.supportedReasoningEfforts.map { $0.reasoningEffort })
        guard !supported.isEmpty else {
            return nil
        }

        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesReasoning,
           let selected = threadOverride.reasoningEffort,
           supported.contains(selected) {
            return selected
        }

        if let selected = selectedReasoningEffort,
           supported.contains(selected) {
            return selected
        }

        if let defaultEffort = model.defaultReasoningEffort,
           supported.contains(defaultEffort) {
            return defaultEffort
        }

        if supported.contains("medium") {
            return "medium"
        }

        return model.supportedReasoningEfforts.first?.reasoningEffort
    }

    func runtimeModelIdentifierForTurn(threadId: String? = nil) -> String? {
        selectedModelOption(threadId: threadId)?.model
            ?? selectedModelIdentifier(threadId: threadId)
            ?? RuntimeSelectionDefaults.modelId
    }

    func effectiveServiceTier(for threadId: String? = nil) -> CodexServiceTier? {
        let candidate: CodexServiceTier?
        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesServiceTier {
            candidate = threadOverride.serviceTier
        } else {
            candidate = selectedServiceTier
        }

        guard let candidate else {
            return nil
        }
        return selectedModelSupportsServiceTier(candidate, threadId: threadId) ? candidate : nil
    }

    func runtimeServiceTierForTurn(threadId: String? = nil) -> String? {
        guard supportsServiceTier else {
            return nil
        }
        return effectiveServiceTier(for: threadId)?.rawValue
    }

    // Copies per-chat runtime overrides forward when we continue an archived thread.
    func inheritThreadRuntimeOverrides(from sourceThreadId: String?, to destinationThreadId: String?) {
        guard let normalizedSourceThreadID = normalizedInterruptIdentifier(sourceThreadId),
              let normalizedDestinationThreadID = normalizedInterruptIdentifier(destinationThreadId),
              normalizedSourceThreadID != normalizedDestinationThreadID else {
            return
        }

        guard let sourceOverride = threadRuntimeOverridesByThreadID[normalizedSourceThreadID] else {
            applyThreadRuntimeOverride(nil, to: normalizedDestinationThreadID)
            return
        }

        var inheritedOverride = sourceOverride
        // Revisions are scoped to one thread in the bridge store. Carrying the
        // source cursor into a fork makes the destination reject its own first
        // remote updates, whose revision correctly starts again from one.
        inheritedOverride.runtimeSettingsRevision = 0
        inheritedOverride.runtimeSettingsUpdatedAt = 0
        applyThreadRuntimeOverride(inheritedOverride, to: normalizedDestinationThreadID)
    }

    func shouldFallbackFromSandboxPolicy(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code != -32602 && rpcError.code != -32600 {
            return false
        }

        let loweredMessage = rpcError.message.lowercased()
        if loweredMessage.contains("thread not found") || loweredMessage.contains("unknown thread") {
            return false
        }

        let identifiesSandbox = loweredMessage.contains("sandboxpolicy")
            || loweredMessage.contains("sandbox_policy")
            || loweredMessage.contains("sandbox")
        guard identifiesSandbox else {
            return false
        }

        return loweredMessage.contains("invalid")
            || loweredMessage.contains("unknown field")
            || loweredMessage.contains("unexpected field")
            || loweredMessage.contains("unrecognized field")
            || loweredMessage.contains("failed to parse")
            || loweredMessage.contains("unsupported")
    }

    func sendRequestWithSandboxFallback(
        method: String,
        baseParams: RPCObject,
        accessConfiguration: RuntimeAccessConfiguration? = nil
    ) async throws -> RPCMessage {
        guard let sandboxParameters = RuntimeRequestContract.sandboxParameters(for: method) else {
            throw CodexServiceError.invalidInput(
                "\(method) does not support runtime sandbox overrides."
            )
        }

        let accessConfiguration = accessConfiguration ?? RuntimeAccessConfiguration(mode: selectedAccessMode)
        var lastError: Error?
        for (index, sandboxParameter) in sandboxParameters.enumerated() {
            let params = sandboxParameter.applying(
                configuration: accessConfiguration,
                to: baseParams
            )
            do {
                debugRuntimeLog("\(method) using \(sandboxParameter.name)")
                return try await sendRequestWithApprovalPolicyFallback(
                    method: method,
                    baseParams: params,
                    context: sandboxParameter.name,
                    accessConfiguration: accessConfiguration
                )
            } catch {
                lastError = error
                let hasFallback = index < sandboxParameters.count - 1
                guard hasFallback, shouldFallbackFromSandboxPolicy(error) else {
                    throw error
                }
                debugRuntimeLog("\(method) fallback from \(sandboxParameter.name)")
            }
        }

        throw lastError ?? CodexServiceError.invalidResponse(
            "\(method) failed with an unknown sandbox error."
        )
    }

    func validateAppliedAccessConfiguration(
        in response: RPCMessage,
        expected: RuntimeAccessConfiguration,
        context: String
    ) throws {
        guard let result = response.result?.objectValue else {
            if expected.mode == .autoReview {
                throw CodexServiceError.invalidResponse(
                    "\(context) did not report the applied approval reviewer."
                )
            }
            return
        }

        // Desktop-owned resumes are synthetic bridge reads. Their next
        // turn/start still carries the captured access configuration, but the
        // read itself cannot report app-server-applied settings.
        if result["remodexDesktopIpcMirror"]?.boolValue == true {
            return
        }

        guard let reviewer = result["approvalsReviewer"]?.stringValue else {
            if expected.mode == .autoReview {
                throw CodexServiceError.invalidInput(
                    "Approve for me is not supported by this Codex runtime. Update Codex on your Mac and retry."
                )
            }
            return
        }

        // Mismatches below are diagnostic, never fatal. When the app-server
        // rejoins an already-running thread it ignores resume-time overrides
        // and echoes the thread's pre-existing state, so a reopen after
        // switching access modes legitimately reports the old values. The
        // enforcement point that matters is the per-turn override set
        // (approvalPolicy/approvalsReviewer/sandboxPolicy) sent with every
        // turn/start; runtimes that lack a capability outright reject it at
        // request time, which the fallback chains already surface as errors.
        if !expected.approvalsReviewerCandidates.compactMap({ $0 }).contains(reviewer) {
            debugRuntimeLog(
                "\(context) reported approval reviewer \(reviewer) instead of \(expected.approvalsReviewer ?? "the selected reviewer"); relying on per-turn overrides"
            )
        }

        if let policy = result["approvalPolicy"]?.stringValue {
            let normalizedPolicy = policy.lowercased().filter(\.isLetter)
            let expectedPolicies = expected.approvalPolicyCandidates.map {
                $0.lowercased().filter(\.isLetter)
            }
            if !expectedPolicies.contains(normalizedPolicy) {
                debugRuntimeLog(
                    "\(context) reported approval policy \(policy) instead of \(expected.approvalPolicy); relying on per-turn overrides"
                )
            }
        }

        // The response `sandbox` is a documented legacy compatibility echo, and
        // thread-level params cannot express `networkAccess` at all, so only
        // the type is worth comparing.
        if let appliedType = result["sandbox"]?.objectValue?["type"]?.stringValue,
           let expectedType = expected.sandboxPolicy.objectValue?["type"]?.stringValue {
            let normalizedApplied = appliedType.lowercased().filter(\.isLetter)
            let normalizedExpected = expectedType.lowercased().filter(\.isLetter)
            if normalizedApplied != normalizedExpected {
                debugRuntimeLog(
                    "\(context) reported sandbox \(appliedType) instead of \(expectedType); relying on per-turn sandboxPolicy"
                )
            }
        }
    }

    func handleModelListFailure(_ error: Error) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.isEmpty ? "Unable to load models" : message
        modelsErrorMessage = normalized
        debugRuntimeLog("model/list failed: \(normalized)")
    }

    func debugRuntimeLog(_ message: String) {
        let entry = "[\(runtimeDebugTimestampFormatter.string(from: Date()))] \(message)"
        runtimeDebugLogEntries.append(entry)
        if runtimeDebugLogEntries.count > RuntimeDebugLogPolicy.maximumStoredEntries {
            // Trim in batches so sustained event bursts do not shift the array for every new entry.
            runtimeDebugLogEntries.removeFirst(RuntimeDebugLogPolicy.storedEntryTrimBatch)
        }
#if DEBUG
        print("[CodexRuntime] \(entry)")
#endif
    }

    // Coalesces history replay and desktop-mirror bursts into one diagnostic line per batch.
    func recordCompactRuntimeItemCompletion(itemType: String) {
        compactRuntimeItemCompletedCount += 1
        compactRuntimeItemCompletedTypes[itemType, default: 0] += 1

        if compactRuntimeItemCompletedCount >= RuntimeDebugLogPolicy.itemCompletionBatchSize {
            flushCompactRuntimeItemCompletions()
            return
        }

        guard compactRuntimeItemCompletedFlushTask == nil else {
            return
        }

        compactRuntimeItemCompletedFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: RuntimeDebugLogPolicy.itemCompletionFlushNanoseconds
            )
            guard !Task.isCancelled else { return }
            self?.flushCompactRuntimeItemCompletions()
        }
    }

    func flushCompactRuntimeItemCompletions() {
        compactRuntimeItemCompletedFlushTask?.cancel()
        compactRuntimeItemCompletedFlushTask = nil

        let total = compactRuntimeItemCompletedCount
        let typeCounts = compactRuntimeItemCompletedTypes
        compactRuntimeItemCompletedCount = 0
        compactRuntimeItemCompletedTypes.removeAll(keepingCapacity: true)

        guard total > 0 else {
            return
        }

        let sortedTypes = typeCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let reportedTypes = sortedTypes.prefix(RuntimeDebugLogPolicy.maximumReportedItemTypes)
        var typeSummary = reportedTypes.map { "\($0.key):\($0.value)" }
        let reportedCount = reportedTypes.reduce(into: 0) { partialResult, entry in
            partialResult += entry.value
        }
        if reportedCount < total {
            typeSummary.append("other:\(total - reportedCount)")
        }

        debugRuntimeLog(
            "rpc item/completed ×\(total) types=\(typeSummary.joined(separator: ","))"
        )
    }

    func clearRuntimeDebugLog() {
        compactRuntimeItemCompletedFlushTask?.cancel()
        compactRuntimeItemCompletedFlushTask = nil
        compactRuntimeItemCompletedCount = 0
        compactRuntimeItemCompletedTypes.removeAll(keepingCapacity: true)
        runtimeDebugLogEntries.removeAll()
    }

    func shouldRetryWithApprovalPolicyFallback(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code != -32600 && rpcError.code != -32602 {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("approvalpolicy")
            || message.contains("approval_policy")
            || message.contains("onrequest")
            || message.contains("on-request")
    }

    func shouldRetryWithApprovalsReviewerFallback(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError,
              rpcError.code == -32600 || rpcError.code == -32602 else {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("approvalsreviewer")
            || message.contains("approvals_reviewer")
            || message.contains("auto_review")
            || message.contains("guardian_subagent")
    }

    func normalizedServiceTierForSelectedModel(
        _ serviceTier: CodexServiceTier?,
        threadId: String? = nil
    ) -> CodexServiceTier? {
        guard let serviceTier else {
            return nil
        }
        guard let selectedModel = selectedModelOption(threadId: threadId) else {
            return serviceTier
        }
        return selectedModel.supportsServiceTier(serviceTier) ? serviceTier : nil
    }

    func applyRemoteRuntimeSettings(from thread: CodexThread) {
        // Runtime selection is deliberately phone-authoritative. Ignore stale
        // Desktop-origin records produced by older bidirectional bridge builds.
        guard thread.runtimeSettingsSource == "phone" else {
            return
        }
        guard let revision = thread.runtimeSettingsRevision, revision > 0 else {
            return
        }
        let incomingUpdatedAt = thread.runtimeSettingsUpdatedAt ?? 0
        let currentOverride = threadRuntimeOverride(for: thread.id)
        let currentRevision = currentOverride?.runtimeSettingsRevision ?? 0
        let currentUpdatedAt = currentOverride?.runtimeSettingsUpdatedAt ?? 0
        let hasNewerTimestamp = incomingUpdatedAt > currentUpdatedAt
        let timestampsMatch = incomingUpdatedAt == currentUpdatedAt
        let timestampIsUnavailable = incomingUpdatedAt <= 0 || currentUpdatedAt <= 0
        let hasNewerRevision = revision > currentRevision
            && (timestampsMatch || timestampIsUnavailable)
        // A pruned or recreated bridge store restarts its per-thread revision at
        // one. Its newer timestamp must still win over an older phone cursor.
        guard hasNewerTimestamp || hasNewerRevision else {
            return
        }
        let normalizedModel = thread.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEffort = thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTier = thread.serviceTier.flatMap(CodexServiceTier.init(rawValue:))
        let runtimeOverride = CodexThreadRuntimeOverride(
            modelId: normalizedModel?.isEmpty == false ? normalizedModel : nil,
            reasoningEffort: normalizedEffort?.isEmpty == false ? normalizedEffort : nil,
            serviceTierRawValue: normalizedTier?.rawValue,
            overridesModel: normalizedModel?.isEmpty == false,
            overridesReasoning: normalizedEffort?.isEmpty == false,
            overridesServiceTier: true,
            runtimeSettingsRevision: revision,
            runtimeSettingsUpdatedAt: incomingUpdatedAt
        )
        applyThreadRuntimeOverride(runtimeOverride, to: thread.id)
    }
}

private extension CodexService {
    var shouldHidePersistedDefaultWhileRuntimeLoads: Bool {
        guard availableModels.isEmpty else {
            return false
        }

        guard let selectedModelId else {
            return false
        }

        let normalizedSelection = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedSelection == RuntimeSelectionDefaults.modelId
            && (isBootstrappingConnectionSync || isLoadingModels)
    }

    // Centralizes thread-override mutation so empty records never linger in storage.
    func mutateThreadRuntimeOverride(
        for threadId: String,
        mutate: (inout CodexThreadRuntimeOverride) -> Void
    ) {
        var currentOverride = threadRuntimeOverridesByThreadID[threadId] ?? CodexThreadRuntimeOverride(
            modelId: nil,
            reasoningEffort: nil,
            serviceTierRawValue: nil,
            overridesModel: false,
            overridesReasoning: false,
            overridesServiceTier: false,
            runtimeSettingsRevision: 0,
            runtimeSettingsUpdatedAt: 0
        )

        mutate(&currentOverride)

        if currentOverride.isEmpty {
            threadRuntimeOverridesByThreadID.removeValue(forKey: threadId)
        } else {
            threadRuntimeOverridesByThreadID[threadId] = currentOverride
        }

        persistThreadRuntimeOverrides()
    }

    func selectedModelIdentifier(threadId: String?) -> String? {
        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesModel,
           let modelId = threadOverride.modelId,
           !modelId.isEmpty {
            return modelId
        }
        return selectedModelId
    }

    func selectedModelOption(from models: [CodexModelOption]) -> CodexModelOption? {
        guard !models.isEmpty else {
            return nil
        }

        if let selectedModelId,
           let directMatch = models.first(where: { $0.id == selectedModelId || $0.model == selectedModelId }) {
            return directMatch
        }

        return nil
    }

    func selectedGitWriterModelOption(
        from models: [CodexModelOption],
        explicitModelId: String? = nil
    ) -> CodexModelOption? {
        guard !models.isEmpty else {
            return nil
        }

        let savedSelection = explicitModelId ?? selectedGitWriterModelId
        if let savedSelection,
           let directMatch = models.first(where: { $0.id == savedSelection || $0.model == savedSelection }) {
            return directMatch
        }

        if let miniModel = models.first(where: { $0.id == "gpt-5.4-mini" || $0.model == "gpt-5.4-mini" }) {
            return miniModel
        }

        if let runtimeSelected = selectedModelOption(from: models) {
            return runtimeSelected
        }

        return fallbackModel(from: models)
    }

    func fallbackModel(from models: [CodexModelOption]) -> CodexModelOption? {
        // Prefer the current 5.6 family when the bridge advertises it, while
        // keeping GPT-5.5 as the compatibility fallback for older local runtimes.
        for identifier in RuntimeSelectionDefaults.fallbackModelIds {
            if let preferred = models.first(where: {
                $0.id.lowercased() == identifier || $0.model.lowercased() == identifier
            }) {
                return preferred
            }
        }
        if let defaultModel = models.first(where: { $0.isDefault }) {
            return defaultModel
        }
        return models.first
    }

    func persistRuntimeSelections() {
        if let selectedModelId, !selectedModelId.isEmpty, hasPersistedSelectedModelId {
            defaults.set(selectedModelId, forKey: Self.selectedModelIdDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedModelIdDefaultsKey)
        }

        if let selectedGitWriterModelId, !selectedGitWriterModelId.isEmpty {
            defaults.set(selectedGitWriterModelId, forKey: Self.selectedGitWriterModelIdDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedGitWriterModelIdDefaultsKey)
        }

        if let selectedReasoningEffort, !selectedReasoningEffort.isEmpty {
            defaults.set(selectedReasoningEffort, forKey: Self.selectedReasoningEffortDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedReasoningEffortDefaultsKey)
        }

        if let selectedServiceTier {
            defaults.set(selectedServiceTier.rawValue, forKey: Self.selectedServiceTierDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedServiceTierDefaultsKey)
        }

        defaults.set(selectedAccessMode.rawValue, forKey: Self.selectedAccessModeDefaultsKey)
        persistThreadRuntimeOverrides()
    }

    func persistThreadRuntimeOverrides() {
        guard !threadRuntimeOverridesByThreadID.isEmpty,
              let encodedOverrides = try? encoder.encode(threadRuntimeOverridesByThreadID) else {
            defaults.removeObject(forKey: macScopedDefaultsKey(Self.threadRuntimeOverridesDefaultsKey))
            return
        }

        defaults.set(encodedOverrides, forKey: macScopedDefaultsKey(Self.threadRuntimeOverridesDefaultsKey))
    }
}

extension CodexService {
    func normalizeRuntimeSelectionsAfterModelsUpdate() {
        guard !availableModels.isEmpty else {
            if selectedModelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                selectedModelId = nil
            }
            if selectedReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                selectedReasoningEffort = nil
            }
            persistRuntimeSelections()
            return
        }

        let resolvedModel = selectedModelOption(from: availableModels) ?? fallbackModel(from: availableModels)
        selectedModelId = resolvedModel?.id
        hasPersistedSelectedModelId = resolvedModel != nil

        if let resolvedModel {
            let supported = Set(resolvedModel.supportedReasoningEfforts.map { $0.reasoningEffort })
            if supported.isEmpty {
                selectedReasoningEffort = nil
            } else if let selectedReasoningEffort,
                      supported.contains(selectedReasoningEffort) {
                // Keep current reasoning.
            } else if let modelDefault = resolvedModel.defaultReasoningEffort,
                      supported.contains(modelDefault) {
                selectedReasoningEffort = modelDefault
            } else if supported.contains("medium") {
                selectedReasoningEffort = "medium"
            } else {
                selectedReasoningEffort = resolvedModel.supportedReasoningEfforts.first?.reasoningEffort
            }

            if let selectedServiceTier,
               !resolvedModel.supportsServiceTier(selectedServiceTier) {
                self.selectedServiceTier = nil
            }
        } else {
            selectedReasoningEffort = nil
            selectedServiceTier = nil
        }

        if let selectedGitWriterModelId,
           !availableModels.contains(where: {
               $0.id == selectedGitWriterModelId || $0.model == selectedGitWriterModelId
           }) {
            self.selectedGitWriterModelId = nil
        }

        persistRuntimeSelections()
    }
}
