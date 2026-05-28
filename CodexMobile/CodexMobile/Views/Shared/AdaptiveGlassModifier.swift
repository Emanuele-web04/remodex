// FILE: AdaptiveGlassModifier.swift
// Purpose: Centralizes Liquid Glass availability, user preference, and fallback styling.
//          Covers the glass material, button styles, navigation bar / toolbar item
//          shells, and the iOS 26 scroll-edge soft fade used under translucent
//          bars hosted via `safeAreaInset`.
// Layer: View Modifier / Shared UI
// Exports: GlassPreference, AdaptiveGlassStyle, AdaptiveGlassContainer, adaptive glass view helpers
// Depends on: SwiftUI

import SwiftUI

// MARK: - Preference

enum GlassPreference {
    static let storageKey = "codex.useLiquidGlass"

    static var isSupported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

// MARK: - Glass configuration

enum AdaptiveGlassStyle {
    case automatic
    case regular
}

enum AdaptiveGlassButtonProminence {
    case regular
    case prominent
}

// MARK: - Glass effect modifier

private struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    @AppStorage(GlassPreference.storageKey) private var glassEnabled = true
    let style: AdaptiveGlassStyle
    let isInteractive: Bool
    let tint: Color?
    let fallbackMaterial: Material
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), glassEnabled {
            switch style {
            case .automatic:
                content.glassEffect(in: shape)
            case .regular:
                content.glassEffect(resolvedGlass, in: shape)
            }
        } else if let tint {
            // When a tint is provided the caller wants a colored surface (e.g. an
            // accent CTA pill). The Liquid Glass fallback `Material` would mute
            // that color, so paint the tint directly as the fallback background.
            content.background(tint, in: shape)
        } else {
            content.background(fallbackMaterial, in: shape)
        }
    }

    @available(iOS 26, *)
    private var resolvedGlass: Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if isInteractive {
            glass = glass.interactive()
        }
        return glass
    }
}

// MARK: - Glass container

struct AdaptiveGlassContainer<Content: View>: View {
    @AppStorage(GlassPreference.storageKey) private var glassEnabled = true
    let spacing: CGFloat
    private let content: () -> Content

    init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26, *), glassEnabled {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Glass button style

private struct AdaptiveGlassButtonStyleModifier: ViewModifier {
    @AppStorage(GlassPreference.storageKey) private var glassEnabled = true
    let prominence: AdaptiveGlassButtonProminence

    func body(content: Content) -> some View {
        if #available(iOS 26, *), glassEnabled {
            switch prominence {
            case .regular:
                content.buttonStyle(.glass)
            case .prominent:
                content.buttonStyle(.glassProminent)
            }
        } else {
            switch prominence {
            case .regular:
                content.buttonStyle(.borderless)
            case .prominent:
                content.buttonStyle(.borderedProminent)
            }
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

// MARK: - Soft scroll edge effect (iOS 26)

// Adds the iOS 26 soft scroll-edge fade so a `ScrollView`'s content gracefully
// fades under a translucent bar hosted via `safeAreaInset` — same visual the
// system navigation bar uses. No-op on iOS 18.
private struct AdaptiveSoftScrollEdgeModifier: ViewModifier {
    let edges: Edge.Set

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: edges)
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
        // On iOS 26 the system toolbar already wraps each `ToolbarItem` in an
        // interactive Liquid Glass capsule/circle; stacking another
        // `glassEffect` on top produced a visible double-background halo
        // around the icon. Keep this a no-op there and let UIKit own the
        // chrome; only the < iOS 26 fallback path needs the material backing.
        if #available(iOS 26, *), glassEnabled {
            content
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

// MARK: - View extensions

extension View {
    func adaptiveGlass(_ style: AdaptiveGlassStyle, in shape: some Shape) -> some View {
        adaptiveGlass(style, isInteractive: false, tint: nil, fallbackMaterial: .thinMaterial, in: shape)
    }

    func adaptiveGlass(
        _ style: AdaptiveGlassStyle,
        isInteractive: Bool,
        tint: Color? = nil,
        fallbackMaterial: Material = .thinMaterial,
        in shape: some Shape
    ) -> some View {
        modifier(AdaptiveGlassModifier(
            style: style,
            isInteractive: isInteractive,
            tint: tint,
            fallbackMaterial: fallbackMaterial,
            shape: shape
        ))
    }

    func adaptiveGlass(in shape: some Shape) -> some View {
        adaptiveGlass(.automatic, isInteractive: false, tint: nil, fallbackMaterial: .thinMaterial, in: shape)
    }

    func adaptiveGlassButtonStyle(_ prominence: AdaptiveGlassButtonProminence = .regular) -> some View {
        modifier(AdaptiveGlassButtonStyleModifier(prominence: prominence))
    }

    func adaptiveNavigationBar() -> some View {
        modifier(AdaptiveNavigationBarModifier())
    }

    func adaptiveToolbarItem(in shape: some Shape) -> some View {
        modifier(AdaptiveToolbarItemModifier(shape: shape))
    }

    @ViewBuilder
    func adaptiveToolbarItem(if isEnabled: Bool, in shape: some Shape) -> some View {
        if isEnabled {
            adaptiveToolbarItem(in: shape)
        } else {
            self
        }
    }

    // Pairs with `safeAreaInset(edge:)` to give scrolled content the iOS 26
    // soft fade under a translucent bar. No-op on iOS 18 so the bar simply
    // sits above unfaded content (typically paired with an opaque fallback
    // fill on the bar itself).
    func adaptiveSoftScrollEdge(for edges: Edge.Set) -> some View {
        modifier(AdaptiveSoftScrollEdgeModifier(edges: edges))
    }

    // Hosts a top-edge bar using the iOS 26 `safeAreaBar` primitive (which
    // owns the Liquid Glass material + scroll-edge handoff that matches a
    // system navigation bar), falling back to `safeAreaInset(edge:.top)` on
    // iOS 18 where `safeAreaBar` does not exist. Use this instead of calling
    // `glassEffect(in: Rectangle())` on a custom bar — that paints a
    // discrete glass card with visible edges rather than blending into the
    // safe area like the system bar does.
    @ViewBuilder
    func adaptiveTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26, *) {
            self.safeAreaBar(edge: .top, content: bar)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }
}
