// FILE: ProviderCapabilities.swift
// Purpose: Capability flags used by the composer to hide/show rows based on
//          the selected model's provider rather than hardcoded identity checks.
// Layer: Model
// Exports: ProviderCapabilities
// Depends on: Foundation

import Foundation

struct ProviderCapabilities: Codable, Hashable, Sendable {
    let supportsAgentSelection: Bool
    let supportsReasoningEffort: Bool
    let supportsFastMode: Bool
    let supportsPlanMode: Bool
    let supportsStreamingTools: Bool
    let supportsApprovals: Bool
    let supportsFork: Bool
    let supportsVoice: Bool
    let supportsDesktopHandoff: Bool
    let supportsSlashCommands: Bool
    let supportsSlashCommandExecute: Bool
    let supportsMCP: Bool
    let supportsWorktree: Bool
    let supportsSkillAutocomplete: Bool
    let supportsStructuredSkillInput: Bool
    let supportsSkillFileInjection: Bool
    let supportsImageAttachments: Bool
    let supportsSteer: Bool
    let supportsQueue: Bool
    let supportsAccessMode: Bool

    init(
        supportsAgentSelection: Bool,
        supportsReasoningEffort: Bool,
        supportsFastMode: Bool,
        supportsPlanMode: Bool,
        supportsStreamingTools: Bool,
        supportsApprovals: Bool,
        supportsFork: Bool,
        supportsVoice: Bool,
        supportsDesktopHandoff: Bool,
        supportsSlashCommands: Bool,
        supportsSlashCommandExecute: Bool = false,
        supportsMCP: Bool,
        supportsWorktree: Bool,
        supportsSkillAutocomplete: Bool,
        supportsStructuredSkillInput: Bool = false,
        supportsSkillFileInjection: Bool = false,
        supportsImageAttachments: Bool = false,
        supportsSteer: Bool,
        supportsQueue: Bool,
        supportsAccessMode: Bool = false
    ) {
        self.supportsAgentSelection = supportsAgentSelection
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsFastMode = supportsFastMode
        self.supportsPlanMode = supportsPlanMode
        self.supportsStreamingTools = supportsStreamingTools
        self.supportsApprovals = supportsApprovals
        self.supportsFork = supportsFork
        self.supportsVoice = supportsVoice
        self.supportsDesktopHandoff = supportsDesktopHandoff
        self.supportsSlashCommands = supportsSlashCommands
        self.supportsSlashCommandExecute = supportsSlashCommandExecute
        self.supportsMCP = supportsMCP
        self.supportsWorktree = supportsWorktree
        self.supportsSkillAutocomplete = supportsSkillAutocomplete
        self.supportsStructuredSkillInput = supportsStructuredSkillInput
        self.supportsSkillFileInjection = supportsSkillFileInjection
        self.supportsImageAttachments = supportsImageAttachments
        self.supportsSteer = supportsSteer
        self.supportsQueue = supportsQueue
        self.supportsAccessMode = supportsAccessMode
    }

    enum CodingKeys: String, CodingKey {
        case supportsAgentSelection
        case supportsReasoningEffort
        case supportsFastMode
        case supportsPlanMode
        case supportsStreamingTools
        case supportsApprovals
        case supportsFork
        case supportsVoice
        case supportsDesktopHandoff
        case supportsSlashCommands
        case supportsSlashCommandExecute
        case supportsMCP
        case supportsWorktree
        case supportsSkillAutocomplete
        case supportsStructuredSkillInput
        case supportsSkillFileInjection
        case supportsImageAttachments
        case supportsSteer
        case supportsQueue
        case supportsAccessMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsAgentSelection = (try? container.decodeIfPresent(Bool.self, forKey: .supportsAgentSelection)) ?? false
        supportsReasoningEffort = (try? container.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort)) ?? false
        supportsFastMode = (try? container.decodeIfPresent(Bool.self, forKey: .supportsFastMode)) ?? false
        supportsPlanMode = (try? container.decodeIfPresent(Bool.self, forKey: .supportsPlanMode)) ?? false
        supportsStreamingTools = (try? container.decodeIfPresent(Bool.self, forKey: .supportsStreamingTools)) ?? false
        supportsApprovals = (try? container.decodeIfPresent(Bool.self, forKey: .supportsApprovals)) ?? false
        supportsFork = (try? container.decodeIfPresent(Bool.self, forKey: .supportsFork)) ?? false
        supportsVoice = (try? container.decodeIfPresent(Bool.self, forKey: .supportsVoice)) ?? false
        supportsDesktopHandoff = (try? container.decodeIfPresent(Bool.self, forKey: .supportsDesktopHandoff)) ?? false
        supportsSlashCommands = (try? container.decodeIfPresent(Bool.self, forKey: .supportsSlashCommands)) ?? false
        supportsSlashCommandExecute =
            (try? container.decodeIfPresent(Bool.self, forKey: .supportsSlashCommandExecute)) ?? false
        supportsMCP = (try? container.decodeIfPresent(Bool.self, forKey: .supportsMCP)) ?? false
        supportsWorktree = (try? container.decodeIfPresent(Bool.self, forKey: .supportsWorktree)) ?? false
        supportsSkillAutocomplete = (try? container.decodeIfPresent(Bool.self, forKey: .supportsSkillAutocomplete)) ?? false
        supportsStructuredSkillInput =
            (try? container.decodeIfPresent(Bool.self, forKey: .supportsStructuredSkillInput)) ?? false
        supportsSkillFileInjection =
            (try? container.decodeIfPresent(Bool.self, forKey: .supportsSkillFileInjection)) ?? false
        supportsImageAttachments =
            (try? container.decodeIfPresent(Bool.self, forKey: .supportsImageAttachments)) ?? false
        supportsSteer = (try? container.decodeIfPresent(Bool.self, forKey: .supportsSteer)) ?? false
        supportsQueue = (try? container.decodeIfPresent(Bool.self, forKey: .supportsQueue)) ?? false
        supportsAccessMode = (try? container.decodeIfPresent(Bool.self, forKey: .supportsAccessMode)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(supportsAgentSelection, forKey: .supportsAgentSelection)
        try container.encode(supportsReasoningEffort, forKey: .supportsReasoningEffort)
        try container.encode(supportsFastMode, forKey: .supportsFastMode)
        try container.encode(supportsPlanMode, forKey: .supportsPlanMode)
        try container.encode(supportsStreamingTools, forKey: .supportsStreamingTools)
        try container.encode(supportsApprovals, forKey: .supportsApprovals)
        try container.encode(supportsFork, forKey: .supportsFork)
        try container.encode(supportsVoice, forKey: .supportsVoice)
        try container.encode(supportsDesktopHandoff, forKey: .supportsDesktopHandoff)
        try container.encode(supportsSlashCommands, forKey: .supportsSlashCommands)
        try container.encode(supportsSlashCommandExecute, forKey: .supportsSlashCommandExecute)
        try container.encode(supportsMCP, forKey: .supportsMCP)
        try container.encode(supportsWorktree, forKey: .supportsWorktree)
        try container.encode(supportsSkillAutocomplete, forKey: .supportsSkillAutocomplete)
        try container.encode(supportsStructuredSkillInput, forKey: .supportsStructuredSkillInput)
        try container.encode(supportsSkillFileInjection, forKey: .supportsSkillFileInjection)
        try container.encode(supportsImageAttachments, forKey: .supportsImageAttachments)
        try container.encode(supportsSteer, forKey: .supportsSteer)
        try container.encode(supportsQueue, forKey: .supportsQueue)
        try container.encode(supportsAccessMode, forKey: .supportsAccessMode)
    }

    static let defaultCodex = ProviderCapabilities(
        supportsAgentSelection: false,
        supportsReasoningEffort: true,
        supportsFastMode: true,
        supportsPlanMode: true,
        supportsStreamingTools: true,
        supportsApprovals: true,
        supportsFork: true,
        supportsVoice: true,
        supportsDesktopHandoff: true,
        supportsSlashCommands: true,
        supportsSlashCommandExecute: false,
        supportsMCP: true,
        supportsWorktree: true,
        supportsSkillAutocomplete: true,
        supportsStructuredSkillInput: true,
        supportsSkillFileInjection: true,
        supportsImageAttachments: true,
        supportsSteer: true,
        supportsQueue: true,
        supportsAccessMode: true
    )

    static let defaultOpenCode = ProviderCapabilities(
        supportsAgentSelection: true,
        supportsReasoningEffort: false,
        supportsFastMode: false,
        supportsPlanMode: false,
        supportsStreamingTools: true,
        supportsApprovals: true,
        supportsFork: true,
        supportsVoice: false,
        supportsDesktopHandoff: false,
        supportsSlashCommands: true,
        supportsSlashCommandExecute: true,
        supportsMCP: false,
        supportsWorktree: false,
        supportsSkillAutocomplete: true,
        supportsStructuredSkillInput: false,
        supportsSkillFileInjection: true,
        supportsImageAttachments: true,
        supportsSteer: false,
        supportsQueue: true,
        supportsAccessMode: false
    )
}
