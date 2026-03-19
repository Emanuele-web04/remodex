// FILE: ThreadRenamePrompt.swift
// Purpose: Centralizes the shared "rename conversation" prompt state and alert UI.
// Layer: View Helper
// Exports: ThreadRenamePromptState, View.threadRenamePrompt
// Depends on: SwiftUI

import SwiftUI

struct ThreadRenamePromptState {
    var isPresented = false
    var draftTitle = ""

    // Seeds the shared rename prompt with the latest visible title before presentation.
    mutating func present(currentTitle: String) {
        draftTitle = currentTitle
        isPresented = true
    }
}

private struct ThreadRenamePromptModifier: ViewModifier {
    @Binding var state: ThreadRenamePromptState
    let onRename: (String) -> Void

    func body(content: Content) -> some View {
        content.alert("Rename Conversation", isPresented: $state.isPresented) {
            TextField("Name", text: $state.draftTitle)
            Button("Rename") {
                commitRename()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // Reuses the same trim-and-ignore-empty behavior across every rename entry point.
    private func commitRename() {
        let trimmedTitle = state.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        onRename(trimmedTitle)
    }
}

extension View {
    func threadRenamePrompt(
        state: Binding<ThreadRenamePromptState>,
        onRename: @escaping (String) -> Void
    ) -> some View {
        modifier(ThreadRenamePromptModifier(state: state, onRename: onRename))
    }
}
