// FILE: SelectableMessageTextSheet.swift
// Purpose: Presents selectable text for timeline messages outside the scrolling row tree.
// Layer: View Component
// Exports: SelectableMessageTextSheetState, SelectableMessageTextSheet
// Depends on: SwiftUI, TurnMarkdownTextRendering

import SwiftUI

struct SelectableMessageTextSheetState: Identifiable {
    let id = UUID()
    let role: CodexMessageRole
    let text: String
    let usesMarkdownSelection: Bool

    var title: String {
        switch role {
        case .assistant:
            return "Assistant Message"
        case .system:
            return "System Message"
        case .user:
            return "Message"
        }
    }
}

struct SelectableMessageTextSheet: View {
    let state: SelectableMessageTextSheetState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.usesMarkdownSelection {
                        MarkdownTextView(
                            text: state.text,
                            profile: .assistantProse,
                            enablesSelection: true
                        )
                    } else {
                        Text(state.text)
                            .font(AppFont.body())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
