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

    static let light = RemodexTerminalTheme(
        background: "#f2f2f7",
        foreground: "#6C6C71",
        mutedForeground: "#8E8E95",
        border: "#eeeeef",
        cursorForeground: "#009fff",
        cursorBackground: "#f2f2f7",
        palette: [
            "#1f1f21", "#ff2e3f", "#0dbe4e", "#ffca00",
            "#009fff", "#c635e4", "#08c0ef", "#c6c6c8",
            "#1f1f21", "#ff2e3f", "#0dbe4e", "#ffca00",
            "#009fff", "#c635e4", "#08c0ef", "#c6c6c8",
        ]
    )

    static let dark = RemodexTerminalTheme(
        background: "#0a0a0a",
        foreground: "#adadb1",
        mutedForeground: "#8e8e95",
        border: "#2e2e30",
        cursorForeground: "#009fff",
        cursorBackground: "#0a0a0a",
        palette: [
            "#141415", "#ff2e3f", "#0dbe4e", "#ffca00",
            "#009fff", "#c635e4", "#08c0ef", "#c6c6c8",
            "#141415", "#ff2e3f", "#0dbe4e", "#ffca00",
            "#009fff", "#c635e4", "#08c0ef", "#c6c6c8",
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
