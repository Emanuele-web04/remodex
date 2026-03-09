// FILE: AppFont.swift
// Purpose: Centralised font provider that switches between system and JetBrains Mono.
// Layer: Model
// Exports: AppFont
// Depends on: SwiftUI

import SwiftUI

enum AppFont {

    static var storageKey: String { "codex.useJetBrainsMono" }

    // MARK: - Read preference

    static var useJetBrainsMono: Bool {
        // Default to true so JetBrains Mono is active on first launch.
        if UserDefaults.standard.object(forKey: storageKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: storageKey)
    }

    // MARK: - Private helpers

    private static func jbFaceName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black, .semibold:
            return "JetBrainsMono-Bold"
        case .medium:
            return "JetBrainsMono-Medium"
        default:
            return "JetBrainsMono-Regular"
        }
    }

    // MARK: - Semantic helpers

    static func body(weight: Font.Weight = .regular) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 15)
            : .system(.body, design: .default, weight: weight)
    }

    static func callout(weight: Font.Weight = .regular) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 14.5)
            : .system(.callout, design: .default, weight: weight)
    }

    static func subheadline(weight: Font.Weight = .regular) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 14)
            : .system(.subheadline, design: .default, weight: weight)
    }

    static func footnote(weight: Font.Weight = .regular) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 12)
            : .system(.footnote, design: .default, weight: weight)
    }

    static func caption(weight: Font.Weight = .regular) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 11)
            : .system(.caption, design: .default, weight: weight)
    }

    static func caption2(weight: Font.Weight = .regular) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 10)
            : .system(.caption2, design: .default, weight: weight)
    }

    static func headline(weight: Font.Weight = .bold) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 15.5)
            : .system(.headline, design: .default, weight: weight)
    }

    static func title2(weight: Font.Weight = .bold) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 20)
            : .system(.title2, design: .default, weight: weight)
    }

    static func title3(weight: Font.Weight = .medium) -> Font {
        useJetBrainsMono
            ? .custom(jbFaceName(for: weight), size: 18)
            : .system(.title3, design: .default, weight: weight)
    }

    // MARK: - Monospaced (code blocks, diffs, etc.)
    // These always use JetBrains Mono when enabled, otherwise system monospaced.

    static func mono(_ style: Font.TextStyle) -> Font {
        if useJetBrainsMono {
            switch style {
            case .body:        return .custom("JetBrainsMono-Regular", size: 15)
            case .callout:     return .custom("JetBrainsMono-Regular", size: 14.5)
            case .subheadline: return .custom("JetBrainsMono-Regular", size: 14)
            case .caption:     return .custom("JetBrainsMono-Regular", size: 11)
            case .caption2:    return .custom("JetBrainsMono-Regular", size: 10)
            case .title3:      return .custom("JetBrainsMono-Medium", size: 18)
            default:           return .custom("JetBrainsMono-Regular", size: 15)
            }
        }
        return .system(style, design: .monospaced)
    }

    // MARK: - Sized helpers

    static func system(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if useJetBrainsMono {
            return .custom(jbFaceName(for: weight), size: size - 1.5)
        }
        return .system(size: size, weight: weight)
    }
}
