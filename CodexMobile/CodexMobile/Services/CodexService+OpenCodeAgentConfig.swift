// FILE: CodexService+OpenCodeAgentConfig.swift
// Purpose: OpenCode per-thread agent overrides, effective agent resolution, and catalog metadata.
// Layer: Service
// Exports: CodexService OpenCode agent config APIs
// Depends on: CodexModelOption, RuntimeInfo, AgentOption

import Foundation

extension CodexService {

    func effectiveOpenCodeAgent(threadId: String?) -> String {
        if let normalizedThreadID = normalizedInterruptIdentifier(threadId),
           let override = threadRuntimeOverridesByThreadID[normalizedThreadID],
           override.overridesAgent,
           let overrideAgent = override.opencodeAgentId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overrideAgent.isEmpty,
           let validated = validatedOpenCodeAgentId(overrideAgent) {
            return validated
        }

        if let normalizedThreadID = normalizedInterruptIdentifier(threadId),
           let threadAgent = thread(for: normalizedThreadID)?.opencodeAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadAgent.isEmpty,
           let validated = validatedOpenCodeAgentId(threadAgent) {
            return validated
        }

        return resolvedAgentIdForDefault()
    }

    private func resolvedAgentIdForDefault() -> String {
        if let defaultAgent = defaultOpenCodeAgentId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultAgent.isEmpty,
           let validated = validatedOpenCodeAgentId(defaultAgent) {
            return validated
        }
        if let firstCatalogAgent = availableAgents.first?.id,
           let validated = validatedOpenCodeAgentId(firstCatalogAgent) {
            return validated
        }
        return "build"
    }

    func showsBetaLabel(forProvider provider: String) -> Bool {
        let normalized = CodexModelOption.normalizedProvider(provider)
        return availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == normalized
        })?.showsBetaLabel ?? false
    }

    func catalogUnavailableReason(forProvider provider: String) -> String? {
        let normalized = CodexModelOption.normalizedProvider(provider)
        return availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == normalized
        })?.unavailableReason
    }

    func validatedOpenCodeAgentId(_ agentId: String) -> String? {
        let normalized = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard !availableAgents.isEmpty else {
            return normalized
        }
        if availableAgents.contains(where: { $0.id == normalized }) {
            return normalized
        }
        return nil
    }
}
