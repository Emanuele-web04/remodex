// FILE: SettingsBaseComponents.swift
// Purpose: Shared section and row primitives used across settings sections.
// Layer: Settings UI primitives
// Exports: SettingsCard, SettingsButton, SettingsStatusPill, SettingsLinkRow, SettingsValueRow,
//   SettingsMenuPickerRow
// Depends on: SwiftUI, AppFont

import SwiftUI

// Keep native switch rails distinct from primary text tint in dark mode.
let settingsToggleTintColor = Color.green

// Renders a native grouped List section. Each child of `content` becomes
// its own List row, so callers should provide top-level rows directly
// (HStack, Toggle, Picker, Text, Button, NavigationLink, ...). Avoid
// wrapping rows in a VStack or inserting Dividers — the List handles
// row separation automatically.
struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    init(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        } footer: {
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsLinkRow<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    var showsDisclosure: Bool = true
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 12) {
            leading()
                .frame(width: 22, height: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.body())
                    .foregroundStyle(.primary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if showsDisclosure {
                RemodexIcon.image(systemName: "chevron.right")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String
    var valueColor: Color = .secondary
    var usesMonospacedValue: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppFont.body())
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(value)
                .font(usesMonospacedValue ? AppFont.mono(.subheadline) : AppFont.subheadline())
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}

struct SettingsMenuPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

struct SettingsMenuPickerRow<Value: Hashable>: View {
    let title: String
    let value: String
    let options: [SettingsMenuPickerOption<Value>]
    @Binding var selection: Value
    var isDisabled = false

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(AppFont.body())
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Text(value)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    RemodexIcon.image(systemName: "chevron.up.chevron.down")
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || options.isEmpty)
    }
}

struct SettingsInlineMessage: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(AppFont.footnote())
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(AppFont.body())
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
    var tint: Color = .secondary

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}
