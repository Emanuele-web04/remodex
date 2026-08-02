// FILE: TerminalOptionsMenu.swift
// Purpose: Encapsulates terminal status, clipboard, session, font-size, and connection actions.
// Layer: View Component
// Exports: TerminalOptionsMenu
// Depends on: SwiftUI, TerminalUIModels

import SwiftUI
import UIKit

struct TerminalOptionsMenu: View {
    let statusLabel: String
    let errorDetail: String?
    let statusTone: TerminalStatusTone
    let theme: RemodexTerminalTheme
    let fontSize: Double
    let sessions: [TerminalMenuSessionItem]
    let activeTerminalId: String
    let isRunning: Bool
    let hasConnectionConfiguration: Bool
    let canPaste: Bool
    let canSelectText: Bool
    let canClear: Bool
    let canResetKnownHost: Bool
    let onSelectSession: (String) -> Void
    let onOpenNewTerminal: () -> Void
    let onToggleConnection: () -> Void
    let onOpenConnectionEditor: () -> Void
    let onPaste: () -> Void
    let onSelectText: () -> Void
    let onClear: () -> Void
    let onResetKnownHost: () -> Void
    let onAdjustFontSize: (Double) -> Void

    var body: some View {
        UIKitMenuButton {
            // No fixed frame / background — the icon sits in the toolbar like
            // a stock nav-bar button. A small status dot floats just above the
            // glyph so we keep the running/error glance without a pill.
            RemodexIcon.image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hexString: theme.foreground))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color(hexString: statusTone.tint))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color(hexString: theme.background).opacity(0.7), lineWidth: 1)
                        )
                        .offset(x: 4, y: -4)
                }
        } menu: {
            terminalMenu()
        }
        .accessibilityLabel("Terminal options")
        .accessibilityValue(statusLabel)
    }

    private func terminalMenu() -> UIMenu {
        var statusActions: [UIMenuElement] = [
            menuAction(title: statusLabel, isEnabled: false) {},
        ]
        if let errorDetail {
            statusActions.append(menuAction(title: errorDetail, isEnabled: false) {})
        }

        let textSizeActions: [UIMenuElement] = [
            menuAction(
                title: "A- \(String(format: "%.1f", nextSmallerFontSize)) pt",
                isEnabled: fontSize > remodexTerminalMinFontSize
            ) {
                onAdjustFontSize(-remodexTerminalFontSizeStep)
            },
            menuAction(
                title: "A+ \(String(format: "%.1f", nextLargerFontSize)) pt",
                isEnabled: fontSize < remodexTerminalMaxFontSize
            ) {
                onAdjustFontSize(remodexTerminalFontSizeStep)
            },
        ]

        var sessionActions: [UIMenuElement] = sessions.map { session in
            menuAction(
                title: session.displayLabel,
                systemName: "terminal",
                state: session.terminalId == activeTerminalId ? .on : .off
            ) {
                onSelectSession(session.terminalId)
            }
        }
        sessionActions.append(menuAction(title: "Open new terminal", systemName: "plus", handler: onOpenNewTerminal))

        let clipboardActions: [UIMenuElement] = [
            menuAction(title: "Paste", systemName: "doc.on.clipboard", isEnabled: canPaste, handler: onPaste),
            menuAction(title: "Select text", systemName: "text.cursor", isEnabled: canSelectText, handler: onSelectText),
        ]

        let connectionActions: [UIMenuElement] = [
            menuAction(
                title: isRunning ? "Disconnect" : "Connect",
                systemName: isRunning ? "xmark" : "terminal",
                isEnabled: hasConnectionConfiguration || isRunning,
                handler: onToggleConnection
            ),
            menuAction(title: "SSH connection", systemName: "lock.shield", handler: onOpenConnectionEditor),
            menuAction(title: "Clear", systemName: "trash", isEnabled: canClear, handler: onClear),
            menuAction(title: "Reset host key", systemName: "key", isEnabled: canResetKnownHost, handler: onResetKnownHost),
        ]

        return UIMenu(children: [
            UIMenu(options: [.displayInline], children: statusActions),
            UIMenu(title: "Text size", options: [.displayInline], children: textSizeActions),
            UIMenu(options: [.displayInline], children: sessionActions),
            UIMenu(options: [.displayInline], children: clipboardActions),
            UIMenu(options: [.displayInline], children: connectionActions),
        ])
    }

    private func menuAction(
        title: String,
        systemName: String? = nil,
        isEnabled: Bool = true,
        state: UIMenuElement.State = .off,
        handler: @escaping () -> Void
    ) -> UIAction {
        UIAction(
            title: title,
            image: systemName.flatMap { RemodexIcon.menuUIImage(systemName: $0) },
            attributes: isEnabled ? [] : .disabled,
            state: state
        ) { _ in
            handler()
        }
    }

    private var nextSmallerFontSize: Double {
        max(remodexTerminalMinFontSize, fontSize - remodexTerminalFontSizeStep)
    }

    private var nextLargerFontSize: Double {
        min(remodexTerminalMaxFontSize, fontSize + remodexTerminalFontSizeStep)
    }
}
