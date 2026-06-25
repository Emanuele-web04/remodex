// FILE: ComposerCapabilityCopy.swift
// Purpose: User-facing capability grey-out and runtime-unavailable copy for the composer.
// Layer: View Helper
// Exports: ComposerCapability, ComposerCapabilityCopy
// Depends on: Foundation, ProviderCapabilities

import Foundation

enum ComposerCapability {
    case voice
    case planMode
    case fastMode
    case slashCommands
    case slashCommandExecute
    case reasoningEffort
    case agentSelection
    case skillAutocomplete
    case steer
    case queue
    case imageAttachments
    case desktopHandoff
    case mcp
    case pluginMentions
}

enum ComposerCapabilityCopy {
    static func capabilityReason(for capability: ComposerCapability) -> String {
        switch capability {
        case .voice:
            return "Voice not supported by this runtime"
        case .planMode:
            return "Plan mode not supported by this runtime"
        case .fastMode:
            return "Fast mode not supported by this model"
        case .slashCommands:
            return "Slash commands not supported by this runtime"
        case .slashCommandExecute:
            return "Slash command execution not supported by this runtime"
        case .reasoningEffort:
            return "This model does not support reasoning effort levels"
        case .agentSelection:
            return "Agent selection not supported by this runtime"
        case .skillAutocomplete:
            return "Skill-based instructions not supported by this runtime"
        case .steer:
            return "Mid-turn steering not supported by this runtime"
        case .queue:
            return "Queued follow-ups are not available for this runtime"
        case .imageAttachments:
            return "Image attachments not supported by this runtime"
        case .desktopHandoff:
            return "Desktop handoff is not enabled on this Mac bridge"
        case .mcp:
            return "MCP is configured in OpenCode on your Mac, not from Remodex"
        case .pluginMentions:
            return "Plugin mentions are not available for this runtime"
        }
    }

    static func openCodeStatusSummary(version: String?, minVersion: String?, handoffEnvEnabled: Bool) -> String {
        var parts: [String] = []
        if let version, !version.isEmpty {
            if let minVersion, !minVersion.isEmpty {
                parts.append("OpenCode \(version) (min \(minVersion))")
            } else {
                parts.append("OpenCode \(version)")
            }
        } else {
            parts.append("OpenCode on Mac")
        }
        parts.append(handoffEnvEnabled ? "Handoff env on" : "Handoff env off")
        return parts.joined(separator: " · ")
    }

    static func capabilityReasonWhenAgentSelectionUnavailable(capabilities: ProviderCapabilities) -> String {
        capabilities.supportsAgentSelection
            ? "No agents available for this runtime"
            : capabilityReason(for: .agentSelection)
    }

    static func runtimeUnavailableMessage(_ rawReason: String?, reasonCode: String? = nil) -> (title: String, hint: String?) {
        if let code = reasonCode {
            switch code {
            case "opencode_not_enabled":
                return ("OpenCode is not enabled on this Mac", "Enable OpenCode on your Mac bridge to use this runtime.")
            case "opencode_agents_unavailable":
                return ("OpenCode agents could not be listed", "Check OpenCode on your Mac, then refresh the connection.")
            case "opencode_version_below_minimum":
                return (
                    "OpenCode on your Mac is too old",
                    "Upgrade OpenCode on your Mac, then reconnect Remodex."
                )
            default:
                break
            }
        }

        let trimmed = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return ("Runtime unavailable", nil)
        }
        return (trimmed, nil)
    }
}
