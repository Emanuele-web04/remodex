// FILE: TerminalRouteChrome.swift
// Purpose: Navigation title, accessory key bar, and empty-state chrome for the terminal route.
// Layer: View Component
// Exports: TerminalRouteTitle, TerminalRouteAccessoryBar, TerminalRouteUnavailableView
// Depends on: SwiftUI, RemodexTerminalTheme, TerminalUIModels

import SwiftUI

struct TerminalRouteTitle: View {
    let topLine: String
    let bottomLine: String
    let theme: RemodexTerminalTheme

    var body: some View {
        VStack(spacing: 1) {
            Text(topLine)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hexString: theme.foreground))
                .lineLimit(1)

            Text(bottomLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hexString: theme.mutedForeground))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 240)
    }
}

struct TerminalRouteAccessoryBar: View {
    let actions: [TerminalToolbarAction]
    let pendingModifier: TerminalPendingModifier?
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onAction: (TerminalToolbarAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    TerminalRouteKeyButton(
                        action: action,
                        isActive: action.modifier == pendingModifier,
                        theme: theme,
                        isEnabled: isEnabled,
                        onAction: onAction
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: remodexTerminalAccessoryHeight)
        }
        .background(Color(hexString: theme.background))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(hexString: theme.border))
                .frame(height: 1)
        }
    }
}

private struct TerminalRouteKeyButton: View {
    let action: TerminalToolbarAction
    let isActive: Bool
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onAction: (TerminalToolbarAction) -> Void

    private var activeAccent: Color {
        Color(hexString: theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground)
    }

    private var textColor: Color {
        isActive ? activeAccent : Color(hexString: theme.foreground)
    }

    private var backgroundColor: Color {
        isActive ? activeAccent.opacity(0.18) : Color(hexString: theme.foreground).opacity(0.07)
    }

    private var borderColor: Color {
        isActive ? activeAccent.opacity(0.32) : Color(hexString: theme.border)
    }

    var body: some View {
        Button {
            onAction(action)
        } label: {
            Text(action.label)
                .font(.system(size: 12, weight: .bold))
                .textCase(action.isModifier ? .uppercase : nil)
                .foregroundStyle(textColor)
                .frame(minWidth: action.label.count > 1 ? 46 : 38)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(borderColor, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(action.label)
    }
}

struct TerminalRouteUnavailableView: View {
    let title: String
    let detail: String
    let theme: RemodexTerminalTheme
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(hexString: theme.foreground))

            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hexString: theme.foreground))

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color(hexString: theme.mutedForeground))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button("SSH connection", action: action)
                .font(.system(size: 12, weight: .bold))
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hexString: theme.background))
    }
}
