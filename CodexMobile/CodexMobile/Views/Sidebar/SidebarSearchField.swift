// FILE: SidebarSearchField.swift
// Purpose: Compact search pill for filtering sidebar threads.
// Layer: View Component
// Exports: SidebarSearchField

import SwiftUI

struct SidebarSearchField: View {
    // Mirrors the selected sidebar row so the search field feels like part of the same list system.
    private let selectedRowCornerRadius: CGFloat = 14

    @Binding var text: String
    @Binding var isActive: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)

                TextField("Search conversations", text: $text)
                    .font(AppFont.subheadline())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        isFocused = false
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                isFocused = false
                            }
                        }
                    }

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppFont.subheadline())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.tertiarySystemFill).opacity(0.8),
                in: RoundedRectangle(cornerRadius: selectedRowCornerRadius, style: .continuous)
            )

            if isFocused {
                Button("Cancel") {
                    text = ""
                    isFocused = false
                }
                .font(AppFont.subheadline())
                .foregroundStyle(.primary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onChange(of: isFocused) { _, newValue in
            isActive = newValue
        }
        .onChange(of: isActive) { _, newValue in
            if !newValue {
                isFocused = false
            }
        }
    }
}
