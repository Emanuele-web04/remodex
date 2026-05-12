// FILE: TerminalUIModels.swift
// Purpose: Shared presentation constants and small value types for the SSH terminal route.
// Layer: View Model
// Exports: TerminalPendingModifier, TerminalHostPlatform, TerminalToolbarAction, TerminalStatusTone
// Depends on: SwiftUI, RemodexTerminalModels

import SwiftUI

let remodexTerminalDefaultFontSize = 10.0
let remodexTerminalFontSizeStep = 0.5
let remodexTerminalMinFontSize = 6.0
let remodexTerminalMaxFontSize = 14.0
let remodexTerminalAccessoryHeight: CGFloat = 52

enum TerminalPendingModifier: Equatable {
    case ctrl
    case meta
}

enum TerminalHostPlatform {
    case mac
    case linux
    case windows
    case unknown

    static func infer(from value: String?) -> TerminalHostPlatform {
        let lowercased = value?.lowercased() ?? ""
        if lowercased.contains("mac")
            || lowercased.contains("macbook")
            || lowercased.contains("mac mini")
            || lowercased.contains("imac")
            || lowercased.contains("darwin") {
            return .mac
        }
        if lowercased.contains("windows") || lowercased.contains("win") {
            return .windows
        }
        if lowercased.contains("linux")
            || lowercased.contains("ubuntu")
            || lowercased.contains("debian") {
            return .linux
        }
        return .unknown
    }
}

struct TerminalStatusTone {
    let tint: String
    let text: String
}

struct TerminalMenuSessionItem: Identifiable {
    let terminalId: String
    let displayLabel: String
    let status: RemodexTerminalStatus
    let cwd: String

    var id: String { terminalId }
}

enum TerminalToolbarActionKind {
    case send(String)
    case modifier(TerminalPendingModifier)
}

struct TerminalToolbarAction: Identifiable {
    let kind: TerminalToolbarActionKind
    let key: String
    let label: String

    var id: String { key }

    var modifier: TerminalPendingModifier? {
        if case .modifier(let modifier) = kind {
            return modifier
        }
        return nil
    }

    var isModifier: Bool {
        modifier != nil
    }
}

extension Color {
    init(hexString: String) {
        let sanitized = hexString.replacingOccurrences(of: "#", with: "")
        let value = Int(sanitized, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
