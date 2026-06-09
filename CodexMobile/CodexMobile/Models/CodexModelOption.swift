// FILE: CodexModelOption.swift
// Purpose: Represents one model entry returned by model/list.
// Layer: Model
// Exports: CodexModelOption
// Depends on: Foundation, CodexReasoningEffortOption, CodexServiceTier

import Foundation

struct CodexModelOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let model: String
    let modelProvider: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let supportsFastMode: Bool
    let supportedReasoningEfforts: [CodexReasoningEffortOption]
    let defaultReasoningEffort: String?
    let capabilities: ProviderCapabilities
    let upstreamProviderId: String?
    let upstreamProviderDisplayName: String?
    let logoProviderId: String?
    let contextWindow: [String: JSONValue]?
    let modelStatus: String?

    var composerLogoProviderId: String {
        logoProviderId ?? modelProvider
    }

    init(
        id: String,
        model: String,
        modelProvider: String = "codex",
        displayName: String,
        description: String,
        isDefault: Bool,
        supportsFastMode: Bool = false,
        supportedReasoningEfforts: [CodexReasoningEffortOption],
        defaultReasoningEffort: String?,
        capabilities: ProviderCapabilities? = nil,
        upstreamProviderId: String? = nil,
        upstreamProviderDisplayName: String? = nil,
        logoProviderId: String? = nil,
        contextWindow: [String: JSONValue]? = nil,
        modelStatus: String? = nil
    ) {
        self.id = id
        self.model = model
        self.modelProvider = Self.normalizedProvider(modelProvider)
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.supportsFastMode = supportsFastMode
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.capabilities = capabilities
            ?? (Self.normalizedProvider(modelProvider) == "opencode"
                ? .defaultOpenCode
                : .defaultCodex)
        self.upstreamProviderId = upstreamProviderId
        self.upstreamProviderDisplayName = upstreamProviderDisplayName
        self.logoProviderId = logoProviderId
        self.contextWindow = contextWindow
        self.modelStatus = modelStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case slug
        case name
        case provider
        case modelProvider
        case modelProviderSnake = "model_provider"
        case runtimeProvider
        case runtimeProviderSnake = "runtime_provider"
        case harness
        case displayName
        case displayNameSnake = "display_name"
        case description
        case isDefault
        case isDefaultSnake = "is_default"
        case supportsFastMode
        case supportsFastModeSnake = "supports_fast_mode"
        case fastMode
        case fastModeSnake = "fast_mode"
        case fastServiceTier
        case fastServiceTierSnake = "fast_service_tier"
        case additionalSpeedTiers
        case additionalSpeedTiersSnake = "additional_speed_tiers"
        case supportedReasoningEfforts
        case supportedReasoningEffortsSnake = "supported_reasoning_efforts"
        case defaultReasoningEffort
        case defaultReasoningEffortSnake = "default_reasoning_effort"
        case capabilities
        case upstreamProviderId
        case upstreamProviderIdSnake = "upstream_provider_id"
        case upstreamProviderDisplayName
        case upstreamProviderDisplayNameSnake = "upstream_provider_display_name"
        case logoProviderId
        case contextWindow
        case contextWindowSnake = "context_window"
        case modelStatus = "status"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let modelValue = try container.decodeIfPresent(String.self, forKey: .model)
        let slugValue = try container.decodeIfPresent(String.self, forKey: .slug)
        let idValue = try container.decodeIfPresent(String.self, forKey: .id)
        let rawModel = modelValue ?? slugValue ?? idValue ?? ""
        let normalizedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawProvider = try Self.decodeProvider(from: container)

        let rawID = idValue ?? slugValue ?? normalizedModel

        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayNameValue = try container.decodeIfPresent(String.self, forKey: .displayName)
        let displayNameSnakeValue = try container.decodeIfPresent(String.self, forKey: .displayNameSnake)
        let nameValue = try container.decodeIfPresent(String.self, forKey: .name)
        let rawDisplayName = displayNameValue ?? displayNameSnakeValue ?? nameValue ?? normalizedModel

        let normalizedDisplayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDescription = (try container.decodeIfPresent(String.self, forKey: .description)) ?? ""

        let camelEfforts = try container.decodeIfPresent(
            [CodexReasoningEffortOption].self,
            forKey: .supportedReasoningEfforts
        )
        let snakeEfforts = try container.decodeIfPresent(
            [CodexReasoningEffortOption].self,
            forKey: .supportedReasoningEffortsSnake
        )
        let efforts = camelEfforts ?? snakeEfforts ?? []

        let normalizedEfforts = efforts.filter {
            !$0.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let camelDefaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        let snakeDefaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffortSnake)
        let defaultEffort = camelDefaultEffort ?? snakeDefaultEffort

        let camelDefaultFlag = try container.decodeIfPresent(Bool.self, forKey: .isDefault)
        let snakeDefaultFlag = try container.decodeIfPresent(Bool.self, forKey: .isDefaultSnake)
        let explicitFastMode = Self.decodeExplicitFastMode(from: container)
        let additionalSpeedTiers = Self.decodeAdditionalSpeedTiers(from: container)

        id = normalizedID.isEmpty ? normalizedModel : normalizedID
        model = normalizedModel
        modelProvider = Self.normalizedProvider(rawProvider)
        displayName = normalizedDisplayName.isEmpty ? normalizedModel : normalizedDisplayName
        description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        isDefault = camelDefaultFlag ?? snakeDefaultFlag ?? false
        supportsFastMode = CodexModelCapabilityResolver.supportsFastMode(
            model: normalizedModel,
            id: normalizedID,
            explicitFastMode: explicitFastMode,
            additionalSpeedTiers: additionalSpeedTiers
        )
        supportedReasoningEfforts = normalizedEfforts

        let normalizedDefault = defaultEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultReasoningEffort = (normalizedDefault?.isEmpty == true) ? nil : normalizedDefault

        let decodedCapabilities = try container.decodeIfPresent(ProviderCapabilities.self, forKey: .capabilities)
        capabilities = decodedCapabilities
            ?? (modelProvider == "opencode" ? .defaultOpenCode : .defaultCodex)

        let upstreamId = try container.decodeIfPresent(String.self, forKey: .upstreamProviderId)
        let upstreamIdSnake = try container.decodeIfPresent(String.self, forKey: .upstreamProviderIdSnake)
        upstreamProviderId = upstreamId ?? upstreamIdSnake

        let upstreamName = try container.decodeIfPresent(String.self, forKey: .upstreamProviderDisplayName)
        let upstreamNameSnake = try container.decodeIfPresent(String.self, forKey: .upstreamProviderDisplayNameSnake)
        upstreamProviderDisplayName = upstreamName ?? upstreamNameSnake

        logoProviderId = try container.decodeIfPresent(String.self, forKey: .logoProviderId)

        contextWindow = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .contextWindow))
            ?? (try? container.decodeIfPresent([String: JSONValue].self, forKey: .contextWindowSnake))
        modelStatus = try container.decodeIfPresent(String.self, forKey: .modelStatus)
    }

    // Codex model/list has shipped several field spellings; keep this parser
    // data-driven so the main decoder stays small enough for Swift's type checker.
    private static func decodeExplicitFastMode(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Bool? {
        let keys: [CodingKeys] = [
            .supportsFastMode,
            .supportsFastModeSnake,
            .fastMode,
            .fastModeSnake,
            .fastServiceTier,
            .fastServiceTierSnake,
        ]

        for key in keys {
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeAdditionalSpeedTiers(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [String] {
        let camelTiers = (try? container.decodeIfPresent([String].self, forKey: .additionalSpeedTiers)) ?? []
        let snakeTiers = (try? container.decodeIfPresent([String].self, forKey: .additionalSpeedTiersSnake)) ?? []
        return camelTiers + snakeTiers
    }

    private static func decodeProvider(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        let keys: [CodingKeys] = [
            .modelProvider,
            .modelProviderSnake,
            .provider,
            .runtimeProvider,
            .runtimeProviderSnake,
            .harness,
        ]

        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return "codex"
    }

    func supportsServiceTier(_ serviceTier: CodexServiceTier) -> Bool {
        switch serviceTier {
        case .fast:
            return supportsFastMode
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(modelProvider, forKey: .modelProvider)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(supportsFastMode, forKey: .supportsFastMode)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(upstreamProviderId, forKey: .upstreamProviderId)
        try container.encodeIfPresent(upstreamProviderDisplayName, forKey: .upstreamProviderDisplayName)
        try container.encodeIfPresent(logoProviderId, forKey: .logoProviderId)
        try container.encodeIfPresent(modelStatus, forKey: .modelStatus)
    }

    var selectionKey: String {
        Self.selectionKey(provider: modelProvider, modelId: id)
    }

    static func selectionKey(provider: String?, modelId: String?) -> String {
        let normalizedProvider = normalizedProvider(provider)
        let normalizedModelID = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalizedProvider):\(normalizedModelID)"
    }

    static func normalizedProvider(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "":
            return "codex"
        case "open-code", "open_code":
            return "opencode"
        case "claude-code", "claudecode":
            return "claude"
        default:
            return normalized
        }
    }

    static func splitSelectionKey(_ value: String?) -> (provider: String, modelId: String?) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let separatorIndex = normalized.firstIndex(of: ":") else {
            return (normalizedProvider(nil), normalized.isEmpty ? nil : normalized)
        }

        let provider = String(normalized[..<separatorIndex])
        let modelStart = normalized.index(after: separatorIndex)
        let modelId = String(normalized[modelStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalizedProvider(provider), modelId.isEmpty ? nil : modelId)
    }
}

private enum CodexModelCapabilityResolver {
    // Mirrors the desktop capability table only when older bridges omit explicit model speed metadata.
    private static let staticFastModeModelIdentifiers: Set<String> = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.2-codex",
        "gpt-5.2",
    ]

    static func supportsFastMode(
        model: String,
        id: String,
        explicitFastMode: Bool?,
        additionalSpeedTiers: [String]
    ) -> Bool {
        if let explicitFastMode {
            return explicitFastMode
        }
        if supportsServiceTier(.fast, in: additionalSpeedTiers) {
            return true
        }
        return staticFastModeFallback(for: [model, id])
    }

    private static func supportsServiceTier(
        _ serviceTier: CodexServiceTier,
        in additionalSpeedTiers: [String]
    ) -> Bool {
        additionalSpeedTiers.contains { tier in
            tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == serviceTier.rawValue
        }
    }

    private static func staticFastModeFallback(for identifiers: [String]) -> Bool {
        identifiers.contains { identifier in
            staticFastModeModelIdentifiers.contains(
                identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
    }
}
