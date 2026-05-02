// FILE: AppFont.swift
// Purpose: Centralised font provider that uses a selectable prose font plus a dedicated mono font for code.
// Layer: Model
// Exports: AppFont
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

enum AppFont {
    enum Style: String, CaseIterable, Identifiable {
        case system
        case geist
        case geistMono
        case jetBrainsMono

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .geist: return "Geist"
            case .geistMono: return "Geist Mono"
            case .jetBrainsMono: return "JetBrains Mono"
            }
        }

        var subtitle: String {
            switch self {
            case .system:
                return "Use the native iOS font for regular text. Code stays monospaced."
            case .geist:
                return "Use Geist for regular text. Code stays monospaced."
            case .geistMono:
                return "Use Geist Mono for regular text and code."
            case .jetBrainsMono:
                return "Use JetBrains Mono for regular text and code."
            }
        }
    }

    static var storageKey: String { "codex.appFontStyle" }
    static var legacyStorageKey: String { "codex.useJetBrainsMono" }
    static var defaultStoredStyleRawValue: String { resolvedStoredStyle.rawValue }
    static var defaultStyle: Style { .system }

    // MARK: - Read preference

    static var currentStyle: Style { resolvedStoredStyle }

    // MARK: - Private helpers

    // Resolves the current style and preserves the old JetBrains preference for existing installs.
    private static var resolvedStoredStyle: Style {
        if let rawStyle = UserDefaults.standard.string(forKey: storageKey),
           let style = Style(rawValue: rawStyle) {
            return style
        }

        // Older builds may have stored "jetBrainsMono" in the new key during the transition.
        if UserDefaults.standard.string(forKey: storageKey) == "jetBrainsMono" {
            return .jetBrainsMono
        }

        if UserDefaults.standard.object(forKey: legacyStorageKey) != nil {
            return .jetBrainsMono
        }

        return defaultStyle
    }

    private static func candidateFaceNames(for weight: Font.Weight, style: Style) -> [String] {
        switch style {
        case .system:
            return []
        case .geist:
            switch weight {
            case .black, .heavy, .bold:
                return ["Geist-Bold", "Geist-SemiBold", "Geist-Regular", "Geist"]
            case .semibold:
                return ["Geist-SemiBold", "Geist-Bold", "Geist-Medium", "Geist-Regular", "Geist"]
            case .medium:
                return ["Geist-Medium", "Geist-Regular", "Geist"]
            default:
                return ["Geist-Regular", "Geist-Medium", "Geist"]
            }
        case .geistMono:
            switch weight {
            case .bold, .heavy, .black, .semibold:
                return ["GeistMono-Bold", "GeistMono-Medium", "GeistMono-Regular"]
            case .medium:
                return ["GeistMono-Medium", "GeistMono-Regular"]
            default:
                return ["GeistMono-Regular", "GeistMono-Medium"]
            }
        case .jetBrainsMono:
            switch weight {
            case .bold, .heavy, .black, .semibold:
                return ["JetBrainsMono-Bold", "JetBrainsMono-Medium", "JetBrainsMono-Regular"]
            case .medium:
                return ["JetBrainsMono-Medium", "JetBrainsMono-Regular"]
            default:
                return ["JetBrainsMono-Regular", "JetBrainsMono-Medium"]
            }
        }
    }

    private static func fontSizeAdjustment(for style: Style) -> CGFloat {
        switch style {
        case .system, .geist, .geistMono, .jetBrainsMono:
            return 0
        }
    }

    private static func uiKitWeight(for weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight:
            return .ultraLight
        case .thin:
            return .thin
        case .light:
            return .light
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        default:
            return .regular
        }
    }

    private static func resolvedCustomFaceName(
        for weight: Font.Weight,
        style: Style,
        size: CGFloat
    ) -> String? {
        for faceName in candidateFaceNames(for: weight, style: style) {
            if UIFont(name: faceName, size: size) != nil {
                return faceName
            }
        }

        return nil
    }

    private static func resolvedUIFont(
        size: CGFloat,
        weight: Font.Weight,
        fallbackTextStyle: UIFont.TextStyle
    ) -> UIFont {
        let selectedStyle = currentStyle
        let adjustedSize = max(size + fontSizeAdjustment(for: selectedStyle), 1)
        let metrics = UIFontMetrics(forTextStyle: fallbackTextStyle)

        if let faceName = resolvedCustomFaceName(for: weight, style: selectedStyle, size: adjustedSize),
           let font = UIFont(name: faceName, size: adjustedSize) {
            return metrics.scaledFont(for: font)
        }

        return UIFont.preferredFont(forTextStyle: fallbackTextStyle)
    }

    // Keeps code surfaces on the selected mono family when the user picks a mono UI font.
    private static var preferredMonoStyle: Style {
        switch currentStyle {
        case .geistMono:
            return .geistMono
        case .jetBrainsMono, .system, .geist:
            return .jetBrainsMono
        }
    }

    private static func candidateMonoFaceNames(for weight: Font.Weight, style: Style) -> [String] {
        switch style {
        case .geistMono:
            switch weight {
            case .bold, .heavy, .black, .semibold:
                return ["GeistMono-Bold", "GeistMono-Medium", "GeistMono-Regular"]
            case .medium:
                return ["GeistMono-Medium", "GeistMono-Regular"]
            default:
                return ["GeistMono-Regular", "GeistMono-Medium"]
            }
        case .jetBrainsMono, .system, .geist:
            break
        }

        switch weight {
        case .bold, .heavy, .black, .semibold:
            return ["JetBrainsMono-Bold", "JetBrainsMono-Medium", "JetBrainsMono-Regular"]
        case .medium:
            return ["JetBrainsMono-Medium", "JetBrainsMono-Regular"]
        default:
            return ["JetBrainsMono-Regular", "JetBrainsMono-Medium"]
        }
    }

    private static func monoSizeAdjustment() -> CGFloat {
        0
    }

    private static func resolvedMonoFaceName(for weight: Font.Weight, size: CGFloat) -> String? {
        for faceName in candidateMonoFaceNames(for: weight, style: preferredMonoStyle) {
            if UIFont(name: faceName, size: size) != nil {
                return faceName
            }
        }

        return nil
    }

    private static func resolvedMonoUIFont(
        size: CGFloat,
        weight: Font.Weight,
        fallbackTextStyle: UIFont.TextStyle
    ) -> UIFont {
        let adjustedSize = max(size + monoSizeAdjustment(), 1)
        let metrics = UIFontMetrics(forTextStyle: fallbackTextStyle)

        if let faceName = resolvedMonoFaceName(for: weight, size: adjustedSize),
           let font = UIFont(name: faceName, size: adjustedSize) {
            return metrics.scaledFont(for: font)
        }

        if let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: fallbackTextStyle)
            .withDesign(.monospaced) {
            return UIFont(descriptor: descriptor, size: 0)
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: uiKitWeight(for: weight))
    }

    private static func monoFont(size: CGFloat, weight: Font.Weight, style: Font.TextStyle) -> Font {
        let adjustedSize = max(size + monoSizeAdjustment(), 1)
        if let faceName = resolvedMonoFaceName(for: weight, size: adjustedSize) {
            return .custom(faceName, size: adjustedSize, relativeTo: style)
        }

        return .system(style, design: .monospaced, weight: weight)
    }

    static func monoUIFont(size: CGFloat, weight: Font.Weight = .regular, textStyle: UIFont.TextStyle = .body) -> UIFont {
        resolvedMonoUIFont(size: size, weight: weight, fallbackTextStyle: textStyle)
    }

    // Mirrors the active monospaced family inside HTML renderers such as Mermaid fallback blocks.
    static var webMonospaceFontStack: String {
        switch preferredMonoStyle {
        case .geistMono:
            return "\"Geist Mono\", \"JetBrains Mono\", ui-monospace, monospace"
        case .jetBrainsMono, .system, .geist:
            return "\"JetBrains Mono\", \"Geist Mono\", ui-monospace, monospace"
        }
    }

    private static func proseFont(
        size: CGFloat,
        weight: Font.Weight,
        style: Font.TextStyle,
        systemDesign: Font.Design = .default
    ) -> Font {
        let selectedStyle = currentStyle
        if selectedStyle == .system {
            return .system(style, design: systemDesign, weight: weight)
        }

        let adjustedSize = max(size + fontSizeAdjustment(for: selectedStyle), 1)
        if let faceName = resolvedCustomFaceName(for: weight, style: selectedStyle, size: adjustedSize) {
            return .custom(faceName, size: adjustedSize, relativeTo: style)
        }

        return .system(style, design: systemDesign, weight: weight)
    }

    static func uiFont(size: CGFloat, weight: Font.Weight = .regular, textStyle: UIFont.TextStyle = .body) -> UIFont {
        resolvedUIFont(size: size, weight: weight, fallbackTextStyle: textStyle)
    }

    // MARK: - Semantic helpers

    static func body(weight: Font.Weight = .regular) -> Font {
        proseFont(size: 15, weight: weight, style: .body)
    }

    static func callout(weight: Font.Weight = .regular) -> Font {
        proseFont(size: 14.5, weight: weight, style: .callout)
    }

    static func subheadline(weight: Font.Weight = .regular) -> Font {
        proseFont(size: 14, weight: weight, style: .subheadline)
    }

    static func footnote(weight: Font.Weight = .regular) -> Font {
        proseFont(size: 12, weight: weight, style: .footnote)
    }

    static func caption(weight: Font.Weight = .regular) -> Font {
        proseFont(size: 11, weight: weight, style: .caption)
    }

    static func caption2(weight: Font.Weight = .regular) -> Font {
        proseFont(size: 10, weight: weight, style: .caption2)
    }

    static func headline(weight: Font.Weight = .bold) -> Font {
        proseFont(size: 15.5, weight: weight, style: .headline)
    }

    static func title2(weight: Font.Weight = .bold) -> Font {
        proseFont(size: 20, weight: weight, style: .title2)
    }

    static func title3(weight: Font.Weight = .medium) -> Font {
        proseFont(size: 18, weight: weight, style: .title3)
    }

    // MARK: - Monospaced (inline code, code blocks, diffs, shell output)

    static func mono(_ style: Font.TextStyle) -> Font {
        switch style {
        case .body:
            return monoFont(size: 15, weight: .regular, style: .body)
        case .callout:
            return monoFont(size: 14.5, weight: .regular, style: .callout)
        case .subheadline:
            return monoFont(size: 14, weight: .regular, style: .subheadline)
        case .caption:
            return monoFont(size: 11, weight: .regular, style: .caption)
        case .caption2:
            return monoFont(size: 10, weight: .regular, style: .caption2)
        case .title3:
            return monoFont(size: 18, weight: .medium, style: .title3)
        default:
            return monoFont(size: 15, weight: .regular, style: .body)
        }
    }

    // MARK: - Sized helpers

    static func system(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let selectedStyle = currentStyle
        if selectedStyle == .system {
            return .system(size: size, weight: weight)
        }

        let adjustedSize = max(size + fontSizeAdjustment(for: selectedStyle), 1)
        if let faceName = resolvedCustomFaceName(for: weight, style: selectedStyle, size: adjustedSize) {
            return .custom(faceName, size: adjustedSize)
        }

        return .system(size: size, weight: weight)
    }
}

// User prompt bubble palette shared by Settings and timeline rendering.
enum UserBubbleColor: String, CaseIterable, Identifiable {
    case `default`
    case orange
    case yellow
    case green
    case blue
    case pink
    case purple
    case black

    var id: String { rawValue }

    static var storageKey: String { "codex.userBubbleColor" }
    static var defaultStoredRawValue: String { UserBubbleColor.default.rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .black: return "Black"
        }
    }

    var swatchColor: Color {
        switch self {
        case .default:
            return Color(.systemGray3)
        case .orange:
            return Color(red: 0.86, green: 0.22, blue: 0.04)
        case .yellow:
            return Color(red: 0.95, green: 0.68, blue: 0.05)
        case .green:
            return Color(red: 0.07, green: 0.62, blue: 0.24)
        case .blue:
            return Color(red: 0.0, green: 0.45, blue: 0.90)
        case .pink:
            return Color(red: 0.86, green: 0.16, blue: 0.50)
        case .purple:
            return Color(red: 0.53, green: 0.24, blue: 0.85)
        case .black:
            return .black
        }
    }

    func bubbleBackground(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .default:
            return Color(.tertiarySystemFill).opacity(0.8)
        case .orange:
            return colorScheme == .dark
                ? Color(red: 0.77, green: 0.18, blue: 0.03)
                : Color(red: 0.81, green: 0.25, blue: 0.06)
        case .yellow:
            return colorScheme == .dark
                ? Color(red: 0.96, green: 0.71, blue: 0.10)
                : Color(red: 0.93, green: 0.64, blue: 0.04)
        case .green:
            return colorScheme == .dark
                ? Color(red: 0.06, green: 0.45, blue: 0.20)
                : Color(red: 0.08, green: 0.50, blue: 0.24)
        case .blue:
            return colorScheme == .dark
                ? Color(red: 0.02, green: 0.34, blue: 0.76)
                : Color(red: 0.0, green: 0.39, blue: 0.82)
        case .pink:
            return colorScheme == .dark
                ? Color(red: 0.72, green: 0.08, blue: 0.34)
                : Color(red: 0.76, green: 0.09, blue: 0.38)
        case .purple:
            return colorScheme == .dark
                ? Color(red: 0.42, green: 0.18, blue: 0.74)
                : Color(red: 0.48, green: 0.23, blue: 0.78)
        case .black:
            return colorScheme == .dark
                ? .white
                : .black
        }
    }

    func bubbleForeground(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .default:
            return .primary
        case .black:
            return colorScheme == .dark ? .black : .white
        default:
            return .white
        }
    }

    func mentionForeground(for colorScheme: ColorScheme, fallback: Color) -> Color {
        self == .default ? fallback : bubbleForeground(for: colorScheme)
    }
}
