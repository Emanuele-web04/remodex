import SwiftUI

// MARK: - Preference

enum GlassPreference {
    static let storageKey = "codex.useLiquidGlass"

    static var isSupported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

// MARK: - Glass effect modifier

private struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    @AppStorage(GlassPreference.storageKey) private var glassEnabled = true
    let style: AdaptiveGlassStyle
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26, *), glassEnabled {
            switch style {
            case .regular:
                content.glassEffect(.regular, in: shape)
            case .regularInteractive:
                content.glassEffect(.regular.interactive(), in: shape)
            case .automatic:
                content.glassEffect(in: shape)
            }
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

// MARK: - Navigation bar modifier

private struct AdaptiveNavigationBarModifier: ViewModifier {
    @AppStorage(GlassPreference.storageKey) private var glassEnabled = true

    func body(content: Content) -> some View {
        if #available(iOS 26, *), glassEnabled {
            content
        } else {
            content
        }
    }
}

// MARK: - Toolbar item fallback (glass OFF or iOS < 26)

private struct AdaptiveToolbarItemModifier<S: Shape>: ViewModifier {
    @AppStorage(GlassPreference.storageKey) private var glassEnabled = true
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26, *), glassEnabled {
            content
        } else {
            content
        }
    }
}

// MARK: - View extensions

enum AdaptiveGlassStyle {
    case regular
    case regularInteractive
    case automatic
}

extension View {
    func adaptiveGlass(_ style: AdaptiveGlassStyle, in shape: some Shape) -> some View {
        modifier(AdaptiveGlassModifier(style: style, shape: shape))
    }

    func adaptiveGlass(in shape: some Shape) -> some View {
        modifier(AdaptiveGlassModifier(style: .automatic, shape: shape))
    }

    func adaptiveNavigationBar() -> some View {
        modifier(AdaptiveNavigationBarModifier())
    }

    func adaptiveToolbarItem(in shape: some Shape) -> some View {
        modifier(AdaptiveToolbarItemModifier(shape: shape))
    }
}
