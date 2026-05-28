// FILE: TerminalOptionsMenu.swift
// Purpose: Encapsulates terminal status, clipboard, session, font-size, and connection actions.
// Layer: View Component
// Exports: TerminalOptionsMenu
// Depends on: SwiftUI, TerminalUIModels

import SwiftUI

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
    let canClear: Bool
    let canResetKnownHost: Bool
    let onSelectSession: (String) -> Void
    let onOpenNewTerminal: () -> Void
    let onToggleConnection: () -> Void
    let onOpenConnectionEditor: () -> Void
    let onPaste: () -> Void
    let onClear: () -> Void
    let onResetKnownHost: () -> Void
    let onAdjustFontSize: (Double) -> Void

    var body: some View {
        Menu {
            statusSection
            textSizeSection
            sessionSection
            clipboardSection
            connectionSection
        } label: {
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
        }
        .accessibilityLabel("Terminal options")
        .accessibilityValue(statusLabel)
    }

    private var statusSection: some View {
        Section {
            Text(statusLabel)
            if let errorDetail {
                Text(errorDetail)
            }
        }
    }

    private var textSizeSection: some View {
        Section("Text size") {
            Button("A- \(String(format: "%.1f", nextSmallerFontSize)) pt") {
                onAdjustFontSize(-remodexTerminalFontSizeStep)
            }
            .disabled(fontSize <= remodexTerminalMinFontSize)

            Button("A+ \(String(format: "%.1f", nextLargerFontSize)) pt") {
                onAdjustFontSize(remodexTerminalFontSizeStep)
            }
            .disabled(fontSize >= remodexTerminalMaxFontSize)
        }
    }

    private var sessionSection: some View {
        Section {
            ForEach(sessions) { session in
                Button {
                    onSelectSession(session.terminalId)
                } label: {
                    RemodexIcon.menuLabel(
                        session.displayLabel,
                        systemName: session.terminalId == activeTerminalId ? "checkmark" : "terminal"
                    )
                }
            }

            Button(action: onOpenNewTerminal) {
                Label("Open new terminal", systemImage: "plus")
            }
        }
    }

    private var clipboardSection: some View {
        Section {
            Button(action: onPaste) {
                RemodexIcon.menuLabel("Paste", systemName: "doc.on.clipboard")
            }
            .disabled(!canPaste)
        }
    }

    private var connectionSection: some View {
        Section {
            Button(action: onToggleConnection) {
                RemodexIcon.menuLabel(isRunning ? "Disconnect" : "Connect", systemName: isRunning ? "xmark" : "terminal")
            }
            .disabled(!hasConnectionConfiguration && !isRunning)

            Button(action: onOpenConnectionEditor) {
                RemodexIcon.menuLabel("SSH connection", systemName: "lock.shield")
            }

            Button("Clear", systemImage: "trash", action: onClear)
                .disabled(!canClear)

            Button(action: onResetKnownHost) {
                RemodexIcon.menuLabel("Reset host key", systemName: "key")
            }
                .disabled(!canResetKnownHost)
        }
    }

    private var nextSmallerFontSize: Double {
        max(remodexTerminalMinFontSize, fontSize - remodexTerminalFontSizeStep)
    }

    private var nextLargerFontSize: Double {
        min(remodexTerminalMaxFontSize, fontSize + remodexTerminalFontSizeStep)
    }
}
