import Foundation

enum OpenCodeModelTier: String, Codable, CaseIterable, Sendable {
    case zen
    case go
    case free

    var title: String { rawValue.capitalized }

    // Mirrors the bridge catalog rule for ids seen before the catalog loads.
    init(modelID: String) {
        let (providerID, slug) = OpenCodeModelNaming.split(modelID)
        if providerID == "opencode-go" {
            self = .go
        } else if slug.lowercased().hasSuffix("-free") {
            self = .free
        } else {
            self = .zen
        }
    }
}

struct OpenCodeModelOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let providerID: String
    let providerName: String
    let tier: OpenCodeModelTier
    let variants: [OpenCodeModelVariant]?
    let defaultVariant: String?

    var displayName: String {
        OpenCodeModelNaming.displayName(catalogName: name, tier: tier)
    }

    var reasoningVariants: [OpenCodeModelVariant] { variants ?? [] }

    func supportsVariant(_ id: String) -> Bool {
        reasoningVariants.contains { $0.id == id }
    }
}

// `id` is the exact OpenCode variant key sent on the wire. Custom keys can
// differ from their reasoning effort, for example `deep` -> `high`.
struct OpenCodeModelVariant: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let reasoningEffort: String?
}

// Turns OpenCode catalog names and raw `provider/model` ids into compact,
// consistently cased labels. The tier is rendered separately, so a trailing
// "Free" marker is dropped from free-tier names.
enum OpenCodeModelNaming {
    private static let brandTokens: [String: String] = [
        "deepseek": "DeepSeek",
        "glm": "GLM",
        "gpt": "GPT",
        "longcat": "LongCat",
        "mimo": "MiMo",
        "minimax": "MiniMax",
        "opencode": "OpenCode",
        "xai": "xAI",
    ]

    static func displayName(catalogName: String, tier: OpenCodeModelTier) -> String {
        let trimmed = catalogName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parenIndex = trimmed.firstIndex(of: "(")
        let head = parenIndex.map { String(trimmed[..<$0]) } ?? trimmed
        let tail = parenIndex.map { String(trimmed[$0...]) } ?? ""

        var tokens = head.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init)
        if tier == .free, tokens.count > 1, tokens.last?.lowercased() == "free" {
            tokens.removeLast()
        }
        let label = format(tokens)
        guard !label.isEmpty else { return trimmed }
        return tail.isEmpty ? label : "\(label) \(tail)"
    }

    // Fallback for threads whose model id is known but the catalog is not loaded yet.
    static func displayName(forModelID modelID: String) -> String {
        var slug = split(modelID).slug
        if slug.lowercased().hasSuffix("-free") {
            slug = String(slug.dropLast("-free".count))
        }
        let label = format(slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init))
        return label.isEmpty ? modelID : label
    }

    static func split(_ modelID: String) -> (providerID: String?, slug: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return (nil, trimmed) }
        return (String(trimmed[..<slash]), String(trimmed[trimmed.index(after: slash)...]))
    }

    private static func format(_ tokens: [String]) -> String {
        joinVersionTokens(tokens)
            .map(casedToken)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\bGPT (\d)"#, with: "GPT-$1", options: .regularExpression)
    }

    // "claude-opus-4-5" reads as 4.5; eight-digit date stamps stay separate.
    private static func joinVersionTokens(_ tokens: [String]) -> [String] {
        var merged: [String] = []
        for token in tokens {
            if let previous = merged.last,
               previous.last?.isNumber == true,
               token.allSatisfy(\.isNumber),
               token == "0" || !token.hasPrefix("0"),
               token.count != 8 {
                merged[merged.count - 1] = "\(previous).\(token)"
            } else {
                merged.append(token)
            }
        }
        return merged
    }

    private static func casedToken(_ token: String) -> String {
        let lowercased = token.lowercased()
        if let brand = brandTokens[lowercased] {
            return brand
        }
        // Single-letter version markers: "k2.5" -> "K2.5", "v4" -> "V4".
        if lowercased.count > 1,
           lowercased.first?.isLetter == true,
           lowercased.dropFirst().first?.isNumber == true {
            return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
        }
        guard let first = token.first, first.isLowercase else { return token }
        return first.uppercased() + token.dropFirst()
    }
}
