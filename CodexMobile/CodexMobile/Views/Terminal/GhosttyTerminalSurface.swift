// FILE: GhosttyTerminalSurface.swift
// Purpose: SwiftUI wrapper and theme mapping for the native Ghostty terminal view.
// Layer: View Infrastructure
// Exports: GhosttyTerminalSurface, RemodexTerminalTheme
// Depends on: SwiftUI, GhosttyTerminalView

import Foundation
import SwiftUI

struct RemodexTerminalTheme: Equatable {
    let background: String
    let foreground: String
    let mutedForeground: String
    let border: String
    let cursorForeground: String
    let cursorBackground: String
    let palette: [String]

    static func resolved(for colorScheme: ColorScheme) -> RemodexTerminalTheme {
        colorScheme == .light ? light : dark
    }

    // Ghostty ships many bundled themes from iTerm2 color schemes; the screenshots match the
    // softer "pastel on near-black" family much more than the stock/vivid ANSI palette.
    // These values are based on Catppuccin Frappe's official Ghostty ANSI colors, with the
    // darker neutral background from the reference screenshots.
    static let light = RemodexTerminalTheme(
        background: "#eff1f5",
        foreground: "#4c4f69",
        mutedForeground: "#8c8fa1",
        border: "#ccd0da",
        cursorForeground: "#dc8a78",
        cursorBackground: "#eff1f5",
        palette: [
            "#5c5f77", "#d20f39", "#40a02b", "#df8e1d",
            "#1e66f5", "#ea76cb", "#179299", "#acb0be",
            "#6c6f85", "#d20f39", "#40a02b", "#df8e1d",
            "#1e66f5", "#ea76cb", "#179299", "#bcc0cc",
        ]
    )

    static let dark = RemodexTerminalTheme(
        background: "#101113",
        foreground: "#d7d7dc",
        mutedForeground: "#96979f",
        border: "#2d2e33",
        cursorForeground: "#4dd78a",
        cursorBackground: "#101113",
        palette: [
            "#535766", "#e78284", "#a6d189", "#e5c890",
            "#8caaee", "#f4b8e4", "#81c8be", "#b7bfd6",
            "#626880", "#e78284", "#a6d189", "#e5c890",
            "#8caaee", "#f4b8e4", "#81c8be", "#d8dee9",
        ]
    )

    var ghosttyConfig: String {
        var lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursorForeground)",
            "cursor-text = \(cursorBackground)",
        ]
        for (index, color) in palette.enumerated() {
            lines.append("palette = \(index)=\(color)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct GhosttyTerminalSurface: UIViewRepresentable {
    let terminalKey: String
    let buffer: Data
    let fontSize: CGFloat
    let colorScheme: ColorScheme
    let theme: RemodexTerminalTheme
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void
    var onNativeAvailabilityChanged: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: GhosttyTerminalView, context: Context) {
        configure(uiView)
    }

    // Keeps all prop bridging in one place so SwiftUI updates don't churn the Ghostty surface identity.
    private func configure(_ view: GhosttyTerminalView) {
        view.onInput = onInput
        view.onResize = onResize
        view.onNativeAvailabilityChanged = onNativeAvailabilityChanged
        view.terminalKey = terminalKey
        view.fontSize = fontSize
        view.appearanceScheme = colorScheme == .light ? "light" : "dark"
        view.backgroundColorHex = theme.background
        view.themeConfig = theme.ghosttyConfig
        view.initialBuffer = buffer
    }
}
