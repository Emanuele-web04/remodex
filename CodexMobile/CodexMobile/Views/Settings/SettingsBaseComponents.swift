// FILE: SettingsBaseComponents.swift
// Purpose: Shared section and row primitives used across settings sections.
// Layer: Settings UI primitives
// Exports: SettingsCard, SettingsButton, SettingsStatusPill
// Depends on: SwiftUI, AppFont

import SwiftUI

// Renders a native grouped List section. Each child of `content` becomes
// its own List row, so callers should provide top-level rows directly
// (HStack, Toggle, Picker, Text, Button, NavigationLink, ...). Avoid
// wrapping rows in a VStack or inserting Dividers — the List handles
// row separation automatically.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        }
    }
}

// Plain text button styled to match a native iOS Settings row. Use
// `role: .destructive` for red destructive actions.
struct SettingsButton: View {
    let title: String
    var role: ButtonRole?
    var isLoading: Bool = false
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                        .foregroundStyle(role == .destructive ? Color.red : (role == .cancel ? .secondary : .primary))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

struct SettingsStatusPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }
}
