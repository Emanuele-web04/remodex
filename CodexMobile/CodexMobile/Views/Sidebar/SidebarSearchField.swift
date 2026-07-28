// FILE: SidebarSearchField.swift
// Purpose: Liquid glass search capsule for filtering sidebar threads. While
//          focused (or while there is text) a trailing glass-circle X button
//          appears that clears the query and dismisses the keyboard.
// Layer: View Component
// Exports: SidebarSearchField
// Depends on: SwiftUI, RemodexIcon, AppFont, AdaptiveGlassModifier

import SwiftUI

struct SidebarSearchField: View {
    @Binding var text: String
    @Binding var isActive: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        AdaptiveGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    RemodexIcon.image(systemName: "magnifyingglass")
                        .font(AppFont.body())
                        .foregroundStyle(.secondary)

                    TextField("Search Chats", text: $text)
                        .font(AppFont.body())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            isFocused = false
                        }
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .adaptiveGlass(.regular, isInteractive: true, in: Capsule())

                if shouldShowDismissButton {
                    dismissButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shouldShowDismissButton)
        .onChange(of: isFocused) { _, newValue in
            isActive = newValue
        }
        .onChange(of: isActive) { _, newValue in
            if !newValue {
                isFocused = false
            }
        }
    }

    private var shouldShowDismissButton: Bool {
        isFocused || !text.isEmpty
    }

    // Liquid-glass clear + dismiss control. Clears the query and yields first
    // responder so the sidebar list animates back without needing a separate
    // keyboard toolbar "Done" affordance.
    private var dismissButton: some View {
        Button {
            text = ""
            isFocused = false
        } label: {
            RemodexIcon.image(systemName: "xmark", size: 16, weight: .semibold)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .adaptiveGlass(.regular, isInteractive: true, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss search")
    }
}
