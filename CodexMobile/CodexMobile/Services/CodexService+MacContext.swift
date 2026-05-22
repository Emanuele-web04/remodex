// FILE: CodexService+MacContext.swift
// Purpose: Loads, saves, and clears Mac-scoped local app state between explicit Mac switches.
// Layer: Service extension
// Exports: CodexService Mac context helpers
// Depends on: Foundation

import Foundation

extension CodexService {
    var currentMacScopedPersistenceDeviceId: String? {
        resolvedMacScopedDeviceId()
    }

    func macScopedDefaultsKey(_ baseKey: String, macDeviceId: String? = nil) -> String {
        guard let normalizedMacDeviceId = resolvedMacScopedDeviceId(explicitMacDeviceId: macDeviceId) else {
            return baseKey
        }

        return "\(baseKey).\(normalizedMacDeviceId)"
    }

    func loadCurrentMacScopedLocalState() {
        loadLocalState(for: currentMacScopedPersistenceDeviceId)
    }

    // Persists the active Mac's message and change-set caches without changing the current selection.
    func persistCurrentMacMessages() {
        guard !suspendAutomaticMacScopedPersistence else {
            return
        }

        saveLocalState(for: currentMacScopedPersistenceDeviceId)
    }

    // Persists the currently loaded local state under the provided Mac namespace.
    func saveLocalState(for macDeviceId: String?) {
        let normalizedMacDeviceId = normalizedMacScopedDeviceId(macDeviceId)
        messagePersistence.save(messagesByThread, macDeviceId: normalizedMacDeviceId)
        composerDraftPersistence.save(composerDraftsByThreadID, macDeviceId: normalizedMacDeviceId)
        aiChangeSetPersistence.save(Array(aiChangeSetsByID.values), macDeviceId: normalizedMacDeviceId)
    }

    // Loads messages, drafts, and assistant change-set metadata for the provided Mac namespace.
    func loadLocalState(for macDeviceId: String?) {
        let normalizedMacDeviceId = normalizedMacScopedDeviceId(macDeviceId)
        let includeLegacyFallback = shouldLoadLegacyLocalStateFallback(for: normalizedMacDeviceId)
        withApplyingMacScopedState {
            let loadedMessages = messagePersistence.load(
                macDeviceId: normalizedMacDeviceId,
                includeLegacyFallback: includeLegacyFallback
            ).mapValues { messages in
                messages.map { message in
                    var value = message
                    value.isStreaming = false
                    return value
                }
            }

            CodexMessageOrderCounter.seed(from: loadedMessages)
            messagesByThread = loadedMessages
            composerDraftsByThreadID = composerDraftPersistence.load(
                macDeviceId: normalizedMacDeviceId,
                includeLegacyFallback: includeLegacyFallback
            )
            messageRevisionByThread = Dictionary(uniqueKeysWithValues: loadedMessages.keys.map { ($0, 0) })
            messageIndexCacheByThread.removeAll()
            latestAssistantOutputByThread.removeAll()
            latestRepoAffectingMessageSignalByThread.removeAll()
            assistantCompletionFingerprintByThread.removeAll()
            recentActivityLineByThread.removeAll()
            contextWindowUsageByThread.removeAll()
            removeAllThreadTimelineState()

            let loadedChangeSets = aiChangeSetPersistence.load(
                macDeviceId: normalizedMacDeviceId,
                includeLegacyFallback: includeLegacyFallback
            )
            aiChangeSetsByID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
                partialResult[changeSet.id] = changeSet
            }
            aiChangeSetIDByTurnID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
                partialResult[changeSet.turnId] = changeSet.id
            }
            aiChangeSetIDByAssistantMessageID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
                if let assistantMessageId = changeSet.assistantMessageId {
                    partialResult[assistantMessageId] = changeSet.id
                }
            }
            rehydrateLegacyFallbackChangeSetsFromPersistedMessages()

            if includeLegacyFallback {
                saveLocalState(for: normalizedMacDeviceId)
                markLegacyLocalStateFallbackMigrated()
            }
        }
    }

    func loadCurrentMacScopedDefaultsState() {
        loadMacScopedDefaultsState(for: normalizedCurrentTrustedMacDeviceId)
    }

    func loadMacScopedDefaultsState(for macDeviceId: String?) {
        withApplyingMacScopedState {
            if let savedThreadRuntimeOverrides = defaults.data(forKey: macScopedDefaultsKey(Self.threadRuntimeOverridesDefaultsKey, macDeviceId: macDeviceId)),
               let decodedThreadRuntimeOverrides = try? decoder.decode(
                   [String: CodexThreadRuntimeOverride].self,
                   from: savedThreadRuntimeOverrides
               ) {
                threadRuntimeOverridesByThreadID = decodedThreadRuntimeOverrides
            } else {
                threadRuntimeOverridesByThreadID = [:]
            }

            if let savedPlanSessionSources = defaults.data(forKey: macScopedDefaultsKey(Self.planSessionSourcesDefaultsKey, macDeviceId: macDeviceId)),
               let decodedPlanSessionSources = try? decoder.decode(
                   [String: CodexPlanSessionSource].self,
                   from: savedPlanSessionSources
               ) {
                planSessionSourceByThread = decodedPlanSessionSources
            } else {
                planSessionSourceByThread = [:]
            }

            if let savedForkOrigins = defaults.data(forKey: macScopedDefaultsKey(Self.forkedThreadOriginsDefaultsKey, macDeviceId: macDeviceId)),
               let decodedForkOrigins = try? decoder.decode([String: String].self, from: savedForkOrigins) {
                forkedFromThreadIDByThreadID = decodedForkOrigins
            } else {
                forkedFromThreadIDByThreadID = [:]
            }

            if let savedRenamedThreadNames = defaults.data(forKey: macScopedDefaultsKey(Self.renamedThreadNamesDefaultsKey, macDeviceId: macDeviceId)),
               let decodedRenamedThreadNames = try? decoder.decode([String: String].self, from: savedRenamedThreadNames) {
                renamedThreadNameByThreadID = decodedRenamedThreadNames
            } else {
                renamedThreadNameByThreadID = [:]
            }

            if let savedPinnedThreadIDs = defaults.data(
                forKey: macScopedDefaultsKey(Self.pinnedThreadIDsDefaultsKey, macDeviceId: macDeviceId)
            ),
               let decodedPinnedThreadIDs = try? decoder.decode([String].self, from: savedPinnedThreadIDs) {
                pinnedThreadIDs = decodedPinnedThreadIDs
            } else {
                pinnedThreadIDs = []
            }

            if let savedPinnedThreadSnapshots = defaults.data(
                forKey: macScopedDefaultsKey(Self.pinnedThreadSnapshotsDefaultsKey, macDeviceId: macDeviceId)
            ),
               let decodedPinnedThreadSnapshots = try? decoder.decode(
                   [String: [CodexThread]].self,
                   from: savedPinnedThreadSnapshots
               ) {
                pinnedThreadSnapshotsByRootID = decodedPinnedThreadSnapshots
            } else {
                pinnedThreadSnapshotsByRootID = [:]
            }

            if let savedAssociatedManagedWorktreePaths = defaults.data(
                forKey: macScopedDefaultsKey(Self.associatedManagedWorktreePathsDefaultsKey, macDeviceId: macDeviceId)
            ),
               let decodedAssociatedManagedWorktreePaths = try? decoder.decode(
                   [String: String].self,
                   from: savedAssociatedManagedWorktreePaths
               ) {
                associatedManagedWorktreePathByThreadID = decodedAssociatedManagedWorktreePaths
            } else {
                associatedManagedWorktreePathByThreadID = [:]
            }

            authoritativeProjectPathByThreadID = [:]

            if let savedTurnTerminalStates = defaults.data(
                forKey: macScopedDefaultsKey(Self.turnTerminalStatesDefaultsKey, macDeviceId: macDeviceId)
            ),
               let decodedTurnTerminalStates = try? decoder.decode(
                   [String: CodexTurnTerminalState].self,
                   from: savedTurnTerminalStates
               ) {
                terminalStateByTurnID = decodedTurnTerminalStates
            } else {
                terminalStateByTurnID = [:]
            }
            latestTurnTerminalStateByThread = [:]

            if let savedThreadHistoryPaginationState = defaults.data(
                forKey: macScopedDefaultsKey(Self.threadHistoryPaginationStateDefaultsKey, macDeviceId: macDeviceId)
            ),
               let decodedThreadHistoryPaginationState = try? decoder.decode(
                   [String: CodexThreadHistoryPaginationState].self,
                   from: savedThreadHistoryPaginationState
               ) {
                olderThreadHistoryCursorByThreadID = decodedThreadHistoryPaginationState.compactMapValues(\.olderCursor)
                exhaustedOlderThreadHistoryCursorByThreadID = decodedThreadHistoryPaginationState.compactMapValues(\.exhaustedOlderCursor)
                threadsWithAuthoritativeLocalHistoryStart = Set(
                    decodedThreadHistoryPaginationState.compactMap { threadId, state in
                        state.hasAuthoritativeLocalHistoryStart ? threadId : nil
                    }
                )
            } else {
                olderThreadHistoryCursorByThreadID = [:]
                exhaustedOlderThreadHistoryCursorByThreadID = [:]
                threadsWithAuthoritativeLocalHistoryStart = []
            }
            loadingOlderThreadHistoryIDs = []
            threadTimelineProjectionLimitByThreadID = [:]
            initialTurnsLoadedByThreadID = []
            olderHistoryLoadErrorByThreadID = [:]

            if let persistedGPTAccountSnapshot = loadPersistedGPTAccountSnapshot(macDeviceId: macDeviceId) {
                gptAccountSnapshot = persistedGPTAccountSnapshot
            } else {
                gptAccountSnapshot = codexGPTAccountInitialSnapshot()
            }

            if let pendingLogin = gptPendingLoginState(macDeviceId: macDeviceId),
               !gptAccountSnapshot.isAuthenticated,
               gptAccountSnapshot.status != .loginPending {
                gptAccountSnapshot = CodexGPTAccountSnapshot(
                    status: .loginPending,
                    authMethod: .chatgpt,
                    email: nil,
                    displayName: nil,
                    planType: nil,
                    hostPlatform: gptAccountSnapshot.hostPlatform,
                    hostCapabilities: gptAccountSnapshot.hostCapabilities,
                    loginInFlight: true,
                    needsReauth: false,
                    expiresAt: pendingLogin.expiresAt,
                    tokenReady: false,
                    tokenUnavailableSince: nil,
                    updatedAt: .now
                )
            }
        }
    }

    // Clears in-memory state that is tied to the active Mac before another Mac is loaded.
    func clearInMemoryMacScopedState() {
        withApplyingMacScopedState {
            threads = []
            activeThreadId = nil
            activeTurnId = nil
            activeTurnIdByThread.removeAll()
            messagesByThread.removeAll()
            composerDraftsByThreadID.removeAll()
            messageRevisionByThread.removeAll()
            threadIdByTurnID.removeAll()
            queuedTurnDraftsByThread.removeAll()
            queuePauseStateByThread.removeAll()
            assistantCompletionFingerprintByThread.removeAll()
            recentActivityLineByThread.removeAll()
            contextWindowUsageByThread.removeAll()
            aiChangeSetsByID.removeAll()
            aiChangeSetIDByTurnID.removeAll()
            aiChangeSetIDByAssistantMessageID.removeAll()
            clearAllRunningState()
            readyThreadIDs.removeAll()
            failedThreadIDs.removeAll()
            removeAllThreadTimelineState()
            assistantRevertStateCacheByThread.removeAll()
            assistantRevertStateRevision = 0
            messageIndexCacheByThread.removeAll()
            latestAssistantOutputByThread.removeAll()
            latestRepoAffectingMessageSignalByThread.removeAll()
            currentOutput = ""
            latestTurnTerminalStateByThread.removeAll()
            terminalStateByTurnID.removeAll()
            olderThreadHistoryCursorByThreadID.removeAll()
            exhaustedOlderThreadHistoryCursorByThreadID.removeAll()
            loadingOlderThreadHistoryIDs.removeAll()
            threadTimelineProjectionLimitByThreadID.removeAll()
            initialTurnsLoadedByThreadID.removeAll()
            threadsWithAuthoritativeLocalHistoryStart.removeAll()
            olderHistoryLoadErrorByThreadID.removeAll()
            threadRuntimeOverridesByThreadID.removeAll()
            planSessionSourceByThread.removeAll()
            forkedFromThreadIDByThreadID.removeAll()
            renamedThreadNameByThreadID.removeAll()
            pinnedThreadIDs.removeAll()
            pinnedThreadSnapshotsByRootID.removeAll()
            snapshotOnlyPinnedThreadIDs.removeAll()
            associatedManagedWorktreePathByThreadID.removeAll()
            authoritativeProjectPathByThreadID.removeAll()
            gptAccountSnapshot = codexGPTAccountInitialSnapshot()
            gptAccountErrorMessage = nil
        }
    }

    func migrateLegacyMacScopedDefaultsIfNeeded() {
        migrateLegacyMacScopedDefaultsValue(for: Self.threadRuntimeOverridesDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.planSessionSourcesDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.locallyArchivedThreadIDsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.locallyDeletedThreadIDsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.forkedThreadOriginsDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.renamedThreadNamesDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.pinnedThreadIDsDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.pinnedThreadSnapshotsDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.associatedManagedWorktreePathsDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.turnTerminalStatesDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.threadHistoryPaginationStateDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.gptAccountSnapshotDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.gptPendingLoginStateDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.gptPendingLoginCallbackDefaultsKey)
    }

    // Moves local state saved under rotated bridge ids onto the freshly trusted device id.
    @discardableResult
    func migrateMacScopedState(from oldMacDeviceIds: [String], to newMacDeviceId: String) -> Bool {
        guard let targetDeviceId = normalizedMacScopedDeviceId(newMacDeviceId) else {
            return false
        }

        let sourceDeviceIds = uniqueNormalizedMacDeviceIds(oldMacDeviceIds)
            .filter { $0 != targetDeviceId }
        guard !sourceDeviceIds.isEmpty else {
            return false
        }

        var migratedDefaults = false
        migratedDefaults = migrateMacScopedLocalCaches(
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.threadRuntimeOverridesDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: CodexThreadRuntimeOverride].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.planSessionSourcesDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: CodexPlanSessionSource].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.forkedThreadOriginsDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: String].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.renamedThreadNamesDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: String].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.pinnedThreadSnapshotsDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: [CodexThread]].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.associatedManagedWorktreePathsDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: String].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.turnTerminalStatesDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: CodexTurnTerminalState].self
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataDictionary(
            Self.threadHistoryPaginationStateDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId,
            as: [String: CodexThreadHistoryPaginationState].self
        ) || migratedDefaults

        migratedDefaults = mergeMacScopedDefaultsStringList(
            Self.locallyArchivedThreadIDsKey,
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsStringList(
            Self.locallyDeletedThreadIDsKey,
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults
        migratedDefaults = mergeMacScopedDefaultsDataList(
            Self.pinnedThreadIDsDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults

        migratedDefaults = migrateMacScopedOpaqueDefault(
            Self.gptAccountSnapshotDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults
        migratedDefaults = migrateMacScopedOpaqueDefault(
            Self.gptPendingLoginStateDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults
        migratedDefaults = migrateMacScopedOpaqueDefault(
            Self.gptPendingLoginCallbackDefaultsKey,
            from: sourceDeviceIds,
            to: targetDeviceId
        ) || migratedDefaults

        return migratedDefaults
    }
}

private extension CodexService {
    static var legacyLocalStateMigrationCompletedDefaultsKey: String {
        "codex.macScopedLocalState.legacyMigrationCompleted"
    }

    func withApplyingMacScopedState(_ work: () -> Void) {
        let previous = isApplyingMacScopedState
        isApplyingMacScopedState = true
        defer { isApplyingMacScopedState = previous }
        work()
    }

    func resolvedMacScopedDeviceId(explicitMacDeviceId: String? = nil) -> String? {
        normalizedMacScopedDeviceId(
            explicitMacDeviceId
                ?? macScopedContextOverrideDeviceId
                ?? normalizedCurrentTrustedMacDeviceId
                ?? normalizedRelayMacDeviceId
        )
    }

    func migrateLegacyMacScopedDefaultsValue(for baseKey: String) {
        guard let normalizedCurrentTrustedMacDeviceId else {
            return
        }

        let scopedKey = macScopedDefaultsKey(baseKey, macDeviceId: normalizedCurrentTrustedMacDeviceId)
        guard scopedKey != baseKey else {
            return
        }

        if defaults.object(forKey: scopedKey) == nil,
           let legacyValue = defaults.object(forKey: baseKey) {
            defaults.set(legacyValue, forKey: scopedKey)
        }

        defaults.removeObject(forKey: baseKey)
    }

    func uniqueNormalizedMacDeviceIds(_ macDeviceIds: [String]) -> [String] {
        var seen: Set<String> = []
        var normalizedDeviceIds: [String] = []

        for macDeviceId in macDeviceIds {
            guard let normalizedDeviceId = normalizedMacScopedDeviceId(macDeviceId),
                  !seen.contains(normalizedDeviceId) else {
                continue
            }

            seen.insert(normalizedDeviceId)
            normalizedDeviceIds.append(normalizedDeviceId)
        }

        return normalizedDeviceIds
    }

    func migrateMacScopedLocalCaches(from sourceDeviceIds: [String], to targetDeviceId: String) -> Bool {
        var migratedCaches = false

        migratedCaches = mergeMacScopedMessages(from: sourceDeviceIds, to: targetDeviceId) || migratedCaches
        migratedCaches = mergeMacScopedComposerDrafts(from: sourceDeviceIds, to: targetDeviceId) || migratedCaches
        migratedCaches = mergeMacScopedChangeSets(from: sourceDeviceIds, to: targetDeviceId) || migratedCaches

        return migratedCaches
    }

    func mergeMacScopedMessages(from sourceDeviceIds: [String], to targetDeviceId: String) -> Bool {
        var targetMessages = messagePersistence.load(macDeviceId: targetDeviceId)
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            defer { messagePersistence.delete(macDeviceId: sourceDeviceId) }
            let sourceMessages = messagePersistence.load(macDeviceId: sourceDeviceId)
            for (threadId, messages) in sourceMessages where targetMessages[threadId] == nil {
                targetMessages[threadId] = messages
                changed = true
            }
        }

        guard changed else {
            return false
        }

        messagePersistence.save(targetMessages, macDeviceId: targetDeviceId)
        return true
    }

    func mergeMacScopedComposerDrafts(from sourceDeviceIds: [String], to targetDeviceId: String) -> Bool {
        var targetDrafts = composerDraftPersistence.load(macDeviceId: targetDeviceId)
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            defer { composerDraftPersistence.delete(macDeviceId: sourceDeviceId) }
            let sourceDrafts = composerDraftPersistence.load(macDeviceId: sourceDeviceId)
            for (threadId, draft) in sourceDrafts where targetDrafts[threadId] == nil {
                targetDrafts[threadId] = draft
                changed = true
            }
        }

        guard changed else {
            return false
        }

        composerDraftPersistence.save(targetDrafts, macDeviceId: targetDeviceId)
        return true
    }

    func mergeMacScopedChangeSets(from sourceDeviceIds: [String], to targetDeviceId: String) -> Bool {
        var targetChangeSetsById = aiChangeSetPersistence.load(macDeviceId: targetDeviceId)
            .reduce(into: [String: AIChangeSet]()) { partialResult, changeSet in
                partialResult[changeSet.id] = changeSet
            }
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            defer { aiChangeSetPersistence.delete(macDeviceId: sourceDeviceId) }
            for changeSet in aiChangeSetPersistence.load(macDeviceId: sourceDeviceId)
                where targetChangeSetsById[changeSet.id] == nil {
                targetChangeSetsById[changeSet.id] = changeSet
                changed = true
            }
        }

        guard changed else {
            return false
        }

        aiChangeSetPersistence.save(Array(targetChangeSetsById.values), macDeviceId: targetDeviceId)
        return true
    }

    // Target values win so a current device's fresh settings are not overwritten by stale ids.
    func mergeMacScopedDefaultsDataDictionary<Value: Codable>(
        _ baseKey: String,
        from sourceDeviceIds: [String],
        to targetDeviceId: String,
        as _: [String: Value].Type
    ) -> Bool {
        let targetKey = macScopedDefaultsKey(baseKey, macDeviceId: targetDeviceId)
        var targetValue = decodedMacScopedDefaultsDataDictionary(baseKey, macDeviceId: targetDeviceId, as: [String: Value].self)
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            let sourceKey = macScopedDefaultsKey(baseKey, macDeviceId: sourceDeviceId)
            defer { defaults.removeObject(forKey: sourceKey) }

            guard let sourceValue = decodedMacScopedDefaultsDataDictionary(
                baseKey,
                macDeviceId: sourceDeviceId,
                as: [String: Value].self
            ) else {
                changed = migrateMacScopedOpaqueDefaultIfEmpty(fromKey: sourceKey, toKey: targetKey) || changed
                continue
            }

            if targetValue == nil {
                targetValue = [:]
            }

            for (key, value) in sourceValue where targetValue?[key] == nil {
                targetValue?[key] = value
                changed = true
            }
        }

        guard changed, let targetValue, let encoded = try? encoder.encode(targetValue) else {
            return changed
        }

        defaults.set(encoded, forKey: targetKey)
        return true
    }

    func decodedMacScopedDefaultsDataDictionary<Value: Codable>(
        _ baseKey: String,
        macDeviceId: String,
        as _: [String: Value].Type
    ) -> [String: Value]? {
        guard let data = defaults.data(forKey: macScopedDefaultsKey(baseKey, macDeviceId: macDeviceId)) else {
            return nil
        }

        return try? decoder.decode([String: Value].self, from: data)
    }

    func mergeMacScopedDefaultsStringList(
        _ baseKey: String,
        from sourceDeviceIds: [String],
        to targetDeviceId: String
    ) -> Bool {
        let targetKey = macScopedDefaultsKey(baseKey, macDeviceId: targetDeviceId)
        var mergedValues = defaults.stringArray(forKey: targetKey) ?? []
        var seenValues = Set(mergedValues)
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            let sourceKey = macScopedDefaultsKey(baseKey, macDeviceId: sourceDeviceId)
            defer { defaults.removeObject(forKey: sourceKey) }

            for value in defaults.stringArray(forKey: sourceKey) ?? [] where !seenValues.contains(value) {
                seenValues.insert(value)
                mergedValues.append(value)
                changed = true
            }
        }

        guard changed else {
            return false
        }

        defaults.set(mergedValues, forKey: targetKey)
        return true
    }

    func mergeMacScopedDefaultsDataList(_ baseKey: String, from sourceDeviceIds: [String], to targetDeviceId: String) -> Bool {
        let targetKey = macScopedDefaultsKey(baseKey, macDeviceId: targetDeviceId)
        var mergedValues = decodedMacScopedDefaultsDataList(baseKey, macDeviceId: targetDeviceId) ?? []
        var seenValues = Set(mergedValues)
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            let sourceKey = macScopedDefaultsKey(baseKey, macDeviceId: sourceDeviceId)
            defer { defaults.removeObject(forKey: sourceKey) }

            guard let sourceValues = decodedMacScopedDefaultsDataList(baseKey, macDeviceId: sourceDeviceId) else {
                changed = migrateMacScopedOpaqueDefaultIfEmpty(fromKey: sourceKey, toKey: targetKey) || changed
                continue
            }

            for value in sourceValues where !seenValues.contains(value) {
                seenValues.insert(value)
                mergedValues.append(value)
                changed = true
            }
        }

        guard changed, let encoded = try? encoder.encode(mergedValues) else {
            return changed
        }

        defaults.set(encoded, forKey: targetKey)
        return true
    }

    func decodedMacScopedDefaultsDataList(_ baseKey: String, macDeviceId: String) -> [String]? {
        guard let data = defaults.data(forKey: macScopedDefaultsKey(baseKey, macDeviceId: macDeviceId)) else {
            return nil
        }

        return try? decoder.decode([String].self, from: data)
    }

    func migrateMacScopedOpaqueDefault(_ baseKey: String, from sourceDeviceIds: [String], to targetDeviceId: String) -> Bool {
        let targetKey = macScopedDefaultsKey(baseKey, macDeviceId: targetDeviceId)
        var changed = false

        for sourceDeviceId in sourceDeviceIds {
            let sourceKey = macScopedDefaultsKey(baseKey, macDeviceId: sourceDeviceId)
            changed = migrateMacScopedOpaqueDefaultIfEmpty(fromKey: sourceKey, toKey: targetKey) || changed
            defaults.removeObject(forKey: sourceKey)
        }

        return changed
    }

    func migrateMacScopedOpaqueDefaultIfEmpty(fromKey sourceKey: String, toKey targetKey: String) -> Bool {
        guard defaults.object(forKey: targetKey) == nil,
              let sourceValue = defaults.object(forKey: sourceKey) else {
            return false
        }

        defaults.set(sourceValue, forKey: targetKey)
        return true
    }

    func normalizedMacScopedDeviceId(_ macDeviceId: String?) -> String? {
        guard let trimmed = macDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func shouldLoadLegacyLocalStateFallback(for macDeviceId: String?) -> Bool {
        guard normalizedMacScopedDeviceId(macDeviceId) != nil else {
            return false
        }

        return !defaults.bool(forKey: Self.legacyLocalStateMigrationCompletedDefaultsKey)
    }

    func markLegacyLocalStateFallbackMigrated() {
        defaults.set(true, forKey: Self.legacyLocalStateMigrationCompletedDefaultsKey)
    }
}
