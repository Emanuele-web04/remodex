// FILE: RuntimeInfo.swift
// Purpose: Runtime-level info from runtime/catalog — capabilities, enabled flag, agents.
// Layer: Model
// Exports: RuntimeInfo
// Depends on: Foundation, ProviderCapabilities

import Foundation

struct RuntimeInfo: Codable, Hashable, Sendable {
    let id: String
    let label: String
    let enabled: Bool
    let unavailableReason: String?
    let reasonCode: String?
    let showsBetaLabel: Bool
    let capabilities: ProviderCapabilities
    let agents: [AgentOption]
    let opencode: OpenCodeRuntimeDetails?

    init(
        id: String,
        label: String,
        enabled: Bool,
        unavailableReason: String?,
        reasonCode: String?,
        showsBetaLabel: Bool,
        capabilities: ProviderCapabilities,
        agents: [AgentOption],
        opencode: OpenCodeRuntimeDetails? = nil
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.unavailableReason = unavailableReason
        self.reasonCode = reasonCode
        self.showsBetaLabel = showsBetaLabel
        self.capabilities = capabilities
        self.agents = agents
        self.opencode = opencode
    }
}