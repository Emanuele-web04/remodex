// FILE: AppFont.swift
// Purpose: Centralised font provider that uses a selectable prose font plus a dedicated mono font for code.
// Layer: Model
// Exports: AppFont
// Depends on: Foundation, SwiftUI, UIKit

import Foundation
import SwiftUI
import UIKit

enum AppFont {
    enum Style: String, CaseIterable, Identifiable {
        case system
        case systemRounded
        case geist
        case geistMono
        case jetBrainsMono

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .systemRounded: return "SF Pro Rounded"
            case .geist: return "Geist"
            case .geistMono: return "Geist Mono"
            case .jetBrainsMono: return "JetBrains Mono"
            }
        }

        var subtitle: String {
            switch self {
            case .system:
                return "Use the native iOS font for regular text. Code stays monospaced."
            case .systemRounded:
                return "Use the rounded native iOS font for regular text. Code stays monospaced."
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

        if UserDefaults.standard.object(forKey: legacyStorageKey) != nil {
            return .jetBrainsMono
        }

        return defaultStyle
    }

    private static func candidateFaceNames(for weight: Font.Weight, style: Style) -> [String] {
        switch style {
        case .system, .systemRounded:
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
        case .system, .systemRounded, .geist, .geistMono, .jetBrainsMono:
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

        if selectedStyle == .system || selectedStyle == .systemRounded {
            let systemFont = systemUIFont(
                size: adjustedSize,
                weight: weight,
                design: selectedStyle == .systemRounded ? .rounded : .default
            )
            return metrics.scaledFont(for: systemFont)
        }

        if let faceName = resolvedCustomFaceName(for: weight, style: selectedStyle, size: adjustedSize),
           let font = UIFont(name: faceName, size: adjustedSize) {
            return metrics.scaledFont(for: font)
        }

        let fallback = UIFont.systemFont(ofSize: adjustedSize, weight: uiKitWeight(for: weight))
        return metrics.scaledFont(for: fallback)
    }

    // Keeps code surfaces on the selected mono family when the user picks a mono UI font.
    // The two system faces pair with SF Mono, which shares their metrics and Dynamic Type
    // behavior, so only the custom prose families borrow a bundled mono face.
    private static var preferredMonoStyle: Style {
        switch currentStyle {
        case .geistMono:
            return .geistMono
        case .system, .systemRounded:
            return .system
        case .jetBrainsMono, .geist:
            return .jetBrainsMono
        }
    }

    private static func candidateMonoFaceNames(for weight: Font.Weight, style: Style) -> [String] {
        switch style {
        case .system, .systemRounded:
            // SF Mono ships as the system monospaced design, not as a bundled face.
            return []
        case .geistMono:
            switch weight {
            case .bold, .heavy, .black, .semibold:
                return ["GeistMono-Bold", "GeistMono-Medium", "GeistMono-Regular"]
            case .medium:
                return ["GeistMono-Medium", "GeistMono-Regular"]
            default:
                return ["GeistMono-Regular", "GeistMono-Medium"]
            }
        case .jetBrainsMono, .geist:
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

        // SF Mono at the requested point size: the text style only drives Dynamic Type
        // scaling here, so callers keep the size they asked for instead of the style default.
        let systemMono = UIFont.monospacedSystemFont(ofSize: adjustedSize, weight: uiKitWeight(for: weight))
        return metrics.scaledFont(for: systemMono)
    }

    private static func monoFont(size: CGFloat, weight: Font.Weight, style: Font.TextStyle) -> Font {
        let adjustedSize = max(size + monoSizeAdjustment(), 1)
        if let faceName = resolvedMonoFaceName(for: weight, size: adjustedSize) {
            return .custom(faceName, size: adjustedSize, relativeTo: style)
        }

        return Font(resolvedMonoUIFont(size: size, weight: weight, fallbackTextStyle: uiKitTextStyle(for: style)))
    }

    static func monoUIFont(size: CGFloat, weight: Font.Weight = .regular, textStyle: UIFont.TextStyle = .body) -> UIFont {
        resolvedMonoUIFont(size: size, weight: weight, fallbackTextStyle: textStyle)
    }

    // Mirrors the active monospaced family inside HTML renderers such as Mermaid fallback blocks.
    static var webMonospaceFontStack: String {
        switch preferredMonoStyle {
        case .geistMono:
            return "\"Geist Mono\", \"JetBrains Mono\", ui-monospace, monospace"
        case .system, .systemRounded:
            return "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, monospace"
        case .jetBrainsMono, .geist:
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
        let adjustedSize = max(size + fontSizeAdjustment(for: selectedStyle), 1)

        if selectedStyle == .system || selectedStyle == .systemRounded {
            return scaledSystemFont(
                size: adjustedSize,
                weight: weight,
                design: selectedStyle == .systemRounded ? .rounded : .default,
                relativeTo: style
            )
        }

        if let faceName = resolvedCustomFaceName(for: weight, style: selectedStyle, size: adjustedSize) {
            return .custom(faceName, size: adjustedSize, relativeTo: style)
        }

        return .system(style, design: systemDesign, weight: weight)
    }

    private static func scaledSystemFont(
        size: CGFloat,
        weight: Font.Weight,
        design: UIFontDescriptor.SystemDesign = .default,
        relativeTo style: Font.TextStyle
    ) -> Font {
        let base = systemUIFont(size: size, weight: weight, design: design)
        let metrics = UIFontMetrics(forTextStyle: uiKitTextStyle(for: style))
        return Font(metrics.scaledFont(for: base))
    }

    private static func systemUIFont(
        size: CGFloat,
        weight: Font.Weight,
        design: UIFontDescriptor.SystemDesign
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: uiKitWeight(for: weight))
        guard design != .default,
              let descriptor = base.fontDescriptor.withDesign(design) else {
            return base
        }

        return UIFont(descriptor: descriptor, size: size)
    }

    private static func uiKitTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle:
            return .largeTitle
        case .title:
            return .title1
        case .title2:
            return .title2
        case .title3:
            return .title3
        case .headline:
            return .headline
        case .subheadline:
            return .subheadline
        case .body:
            return .body
        case .callout:
            return .callout
        case .footnote:
            return .footnote
        case .caption:
            return .caption1
        case .caption2:
            return .caption2
        @unknown default:
            return .body
        }
    }

    static func uiFont(size: CGFloat, weight: Font.Weight = .regular, textStyle: UIFont.TextStyle = .body) -> UIFont {
        resolvedUIFont(size: size, weight: weight, fallbackTextStyle: textStyle)
    }

    // MARK: - Semantic helpers

    // Single source for prose body size: SwiftUI text, the UIKit surfaces that
    // must line up with it, and inline code all measure from this value.
    static let bodyPointSize: CGFloat = 15

    static func body(weight: Font.Weight = .regular) -> Font {
        proseFont(size: bodyPointSize, weight: weight, style: .body)
    }

    // UIKit text views and measuring code that must match SwiftUI prose body.
    static func bodyUIFont(weight: Font.Weight = .regular) -> UIFont {
        uiFont(size: bodyPointSize, weight: weight, textStyle: .body)
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

    // Sized mono for surfaces that scale their own text (markdown headings),
    // where a text-style mono would ignore the surrounding scale.
    static func mono(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        monoFont(size: size, weight: weight, style: style)
    }

    static func mono(_ style: Font.TextStyle) -> Font {
        switch style {
        case .body:
            return monoFont(size: bodyPointSize, weight: .regular, style: .body)
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

    // Markdown parsers tag inline code with `.code`, and SwiftUI then derives its font from the
    // ambient prose font. That derivation only reaches a fixed-width face when the prose family
    // has one, so SF Pro Rounded and Geist would render code in the prose face. Pin the mono
    // face on those runs instead so code stays monospaced in every app font style.
    static func monospaceCodeSpans(in attributed: inout AttributedString, textStyle: Font.TextStyle = .body) {
        let codeFont = mono(textStyle)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = codeFont
        }
    }

    // MARK: - Sized helpers

    // `design` requests a system design (e.g. .rounded badges) and is honored on
    // the system styles; custom faces ignore it since the family is the design.
    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let selectedStyle = currentStyle
        if selectedStyle == .system {
            return .system(size: size, weight: weight, design: design)
        }

        if selectedStyle == .systemRounded {
            return .system(size: size, weight: weight, design: design == .default ? .rounded : design)
        }

        let adjustedSize = max(size + fontSizeAdjustment(for: selectedStyle), 1)
        if let faceName = resolvedCustomFaceName(for: weight, style: selectedStyle, size: adjustedSize) {
            return .custom(faceName, size: adjustedSize)
        }

        return .system(size: size, weight: weight, design: design)
    }
}

// User prompt bubble palette shared by Settings and timeline rendering.
enum UserBubbleColor: String, CaseIterable, Identifiable {
    case `default`
    case red
    case orange
    case yellow
    case green
    case mint
    case blue
    case indigo
    case teal
    case cyan
    case pink
    case purple
    case brown
    case black

    var id: String { rawValue }

    static var storageKey: String { "codex.userBubbleColor" }
    static var defaultStoredRawValue: String { UserBubbleColor.default.rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .mint: return "Mint"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .teal: return "Teal"
        case .cyan: return "Cyan"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .brown: return "Brown"
        case .black: return "Primary"
        }
    }

    var swatchColor: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        switch self {
        case .default:
            return .systemGray3
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .mint:
            return .systemMint
        case .blue:
            return .systemBlue
        case .indigo:
            return .systemIndigo
        case .teal:
            return .systemTeal
        case .cyan:
            return .systemCyan
        case .pink:
            return UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor(red: 1.0, green: 0.32, blue: 0.70, alpha: 1.0)
                    : UIColor(red: 1.0, green: 0.18, blue: 0.62, alpha: 1.0)
            }
        case .purple:
            return .systemPurple
        case .brown:
            return .systemBrown
        case .black:
            return .label
        }
    }

    // UIKit menu actions template SF Symbols by default, so provide an original-rendered swatch.
    var menuSwatchImage: UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = RemodexIcon.uiImage(systemName: "circle.fill", withConfiguration: configuration) ?? UIImage()
        return image.withTintColor(uiColor, renderingMode: .alwaysOriginal)
    }

    func bubbleBackground(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .default:
            return Color(.tertiarySystemFill).opacity(0.8)
        default:
            let color = Color(uiColor: uiColor)
            return colorScheme == .dark ? color.opacity(0.9) : color
        }
    }

    func bubbleForeground(for _: ColorScheme) -> Color {
        switch self {
        case .default:
            return .primary
        case .black:
            return Color(.systemBackground)
        default:
            return .white
        }
    }

    // CTA palette: collapse the neutral "Default" onto "Primary" (.black) so
    // accent buttons (composer send, sidebar chat pill, scope picker selected
    // chip, ...) stay a bold label-colored CTA regardless of which neutral the
    // user picked for their message bubbles.
    var ctaPalette: UserBubbleColor {
        self == .default ? .black : self
    }

    func mentionForeground(for colorScheme: ColorScheme, fallback: Color) -> Color {
        self == .default ? fallback : bubbleForeground(for: colorScheme)
    }
}
