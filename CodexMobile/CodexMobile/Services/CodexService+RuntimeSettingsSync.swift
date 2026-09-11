// FILE: CodexService+RuntimeSettingsSync.swift
// Purpose: Serializes per-task settings edits and reconciles owner acknowledgements.
// Layer: Service
// Exports: CodexService runtime settings synchronization
// Depends on: Foundation, CodexRuntimeSettings

import Foundation

extension CodexService {
    func queueThreadRuntimeSettingsUpdate(threadId: String, fields: Set<String> = ["model", "effort", "serviceTier"]) {
        var override = threadRuntimeOverride(for: threadId)
            ?? CodexThreadRuntimeOverride(overridesReasoning: false, overridesServiceTier: false)
        var desired: RPCObject = [
            "model": runtimeModelIdentifierForTurn(threadId: threadId).map(JSONValue.string) ?? .null,
            "effort": selectedReasoningEffortForSelectedModel(threadId: threadId).map(JSONValue.string) ?? .null,
            "serviceTier": effectiveServiceTier(for: threadId).map { .string($0.rawValue) } ?? .null,
        ]
        if inheritsOwnerServiceTier(for: threadId) {
            desired.removeValue(forKey: "serviceTier")
        }
        // Assigning an omitted field removes an older staged edit when the user
        // clears that override before owner discovery or reconnect completes.
        for field in fields { override.pendingRuntimeSettings[field] = desired[field] }
        applyThreadRuntimeOverride(override, to: threadId)
        if lastErrorMessage == runtimeSettingsUpdateErrors[threadId] { lastErrorMessage = nil }
        runtimeSettingsUpdateErrors.removeValue(forKey: threadId)
        startRuntimeSettingsUpdate(threadId: threadId)
    }

    func resumePendingRuntimeSettingsUpdates() {
        for (threadId, override) in threadRuntimeOverridesByThreadID where !override.pendingRuntimeSettings.isEmpty {
            startRuntimeSettingsUpdate(threadId: threadId)
        }
    }

    func cancelRuntimeSettingsUpdates() {
        for task in runtimeSettingsUpdateTasks.values { task.cancel() }
        runtimeSettingsUpdateTasks.removeAll()
        runtimeSettingsUpdateIDs.removeAll()
        supportsRuntimeSettingsSync = false
    }

    func resetRuntimeSettingsSyncState() {
        cancelRuntimeSettingsUpdates()
        confirmedRuntimeSettings.removeAll()
        retiredRuntimeSettingsEpochs.removeAll()
        runtimeSettingsUpdateErrors.removeAll()
    }

    func waitForRuntimeSettingsUpdate(threadId: String) async throws {
        guard isConnected, isInitialized else { throw CodexServiceError.disconnected }
        while supportsRuntimeSettingsSync {
            guard isConnected, isInitialized else { throw CodexServiceError.disconnected }
            startRuntimeSettingsUpdate(threadId: threadId)
            await runtimeSettingsUpdateTasks[threadId]?.value
            try Task.checkCancellation()
            guard isConnected, isInitialized else { throw CodexServiceError.disconnected }
            if let message = runtimeSettingsUpdateErrors[threadId] {
                throw CodexServiceError.invalidInput(message)
            }
            if threadRuntimeOverride(for: threadId)?.pendingRuntimeSettings.isEmpty != false { return }
        }
    }

    func applyConfirmedRuntimeSettings(_ settings: CodexRuntimeSettings, threadId: String) {
        let current = threadRuntimeOverride(for: threadId)
        let previous = confirmedRuntimeSettings[threadId]
        let previousEpoch = previous?.epoch ?? current?.runtimeSettingsEpoch
        let previousRevision = previous?.revision ?? current?.runtimeSettingsRevision ?? 0
        if previousEpoch == settings.epoch && settings.revision < previousRevision { return }
        if previousEpoch != settings.epoch {
            // Older replay batches can outlive an app relaunch, when the in-memory
            // retired epoch set is empty. Compare the persisted owner timestamp too.
            let previousUpdatedAt = previous?.updatedAt ?? current?.runtimeSettingsUpdatedAt ?? 0
            if settings.updatedAt < previousUpdatedAt { return }
            if retiredRuntimeSettingsEpochs[threadId]?.contains(settings.epoch) == true { return }
            if let previousEpoch { retiredRuntimeSettingsEpochs[threadId, default: []].insert(previousEpoch) }
        }
        confirmedRuntimeSettings[threadId] = settings
        // Keep unsent/in-flight edits visible. The latest owner state is retained
        // separately and applied once the queue drains.
        guard current?.pendingRuntimeSettings.isEmpty != false else { return }
        var override = current ?? CodexThreadRuntimeOverride(overridesReasoning: false, overridesServiceTier: false)
        if settings.contains("model") {
            override.modelId = settings.model
            override.overridesModel = settings.model != nil
        }
        if settings.contains("reasoningEffort") {
            override.reasoningEffort = settings.reasoningEffort
            override.overridesReasoning = true
        }
        if settings.contains("serviceTier") {
            override.serviceTierRawValue = settings.serviceTier.flatMap(CodexServiceTier.init(rawValue:))?.rawValue
            override.overridesServiceTier = true
        }
        override.runtimeSettingsRevision = settings.revision
        override.runtimeSettingsUpdatedAt = settings.updatedAt
        override.runtimeSettingsEpoch = settings.epoch
        applyThreadRuntimeOverride(override, to: threadId)
    }

    private func startRuntimeSettingsUpdate(threadId: String) {
        guard supportsRuntimeSettingsSync, isConnected, isInitialized,
              runtimeSettingsUpdateTasks[threadId] == nil,
              threadRuntimeOverride(for: threadId)?.pendingRuntimeSettings.isEmpty == false else { return }
        let identifier = UUID()
        runtimeSettingsUpdateIDs[threadId] = identifier
        runtimeSettingsUpdateTasks[threadId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.runtimeSettingsUpdateIDs[threadId] == identifier {
                    self.runtimeSettingsUpdateTasks.removeValue(forKey: threadId)
                    self.runtimeSettingsUpdateIDs.removeValue(forKey: threadId)
                }
            }
            while !Task.isCancelled, self.isConnected {
                var sent: RPCObject = [:]
                do {
                    // Reconnect clears the runtime's loaded tasks and Desktop
                    // ownership probes. Use the existing resume path before editing.
                    try await self.ensureThreadResumed(threadId: threadId)
                    guard !Task.isCancelled, self.runtimeSettingsUpdateIDs[threadId] == identifier,
                          let pending = self.threadRuntimeOverride(for: threadId)?.pendingRuntimeSettings,
                          !pending.isEmpty else { return }
                    sent = pending
                    var params = sent
                    params["threadId"] = .string(threadId)
                    let response = try await self.sendRequest(method: "thread/settings/update", params: .object(params))
                    guard !Task.isCancelled, self.runtimeSettingsUpdateIDs[threadId] == identifier else { return }
                    if let value = response.result?.objectValue?["runtimeSettings"],
                       let settings = self.decodeModel(CodexRuntimeSettings.self, from: value) {
                        self.applyConfirmedRuntimeSettings(settings, threadId: threadId)
                    }
                    if var current = self.threadRuntimeOverride(for: threadId) {
                        for (key, value) in sent where current.pendingRuntimeSettings[key] == value {
                            current.pendingRuntimeSettings.removeValue(forKey: key)
                        }
                        self.applyThreadRuntimeOverride(current, to: threadId)
                    }
                    if self.lastErrorMessage == self.runtimeSettingsUpdateErrors[threadId] { self.lastErrorMessage = nil }
                    self.runtimeSettingsUpdateErrors.removeValue(forKey: threadId)
                    if let confirmed = self.confirmedRuntimeSettings[threadId] {
                        self.applyConfirmedRuntimeSettings(confirmed, threadId: threadId)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    // A newer edit supersedes this failed request. Send that choice
                    // instead of leaving the queue stuck on an obsolete error.
                    if !sent.isEmpty,
                       let pending = self.threadRuntimeOverride(for: threadId)?.pendingRuntimeSettings,
                       !pending.isEmpty, pending != sent { continue }
                    let message = "Could not apply task settings: \(error.localizedDescription)"
                    self.runtimeSettingsUpdateErrors[threadId] = message
                    self.lastErrorMessage = message
                    return
                }
            }
        }
    }
}
