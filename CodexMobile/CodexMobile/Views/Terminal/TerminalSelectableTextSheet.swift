// FILE: TerminalSelectableTextSheet.swift
// Purpose: Presents the visible terminal text as plain text with classic iOS selection.
// Layer: View Component
// Exports: TerminalSelectableTextState, TerminalSelectableTextSheet
// Depends on: SwiftUI, RemodexTerminalTheme

import SwiftUI

struct TerminalSelectableTextState: Identifiable {
    let id = UUID()
    let text: String
}

/// Native-selection escape hatch for the GPU-rendered terminal: the Ghostty
/// surface cannot host UIKit text selection in place, so this sheet mirrors
/// the visible grid as real text where loupe/handles/Copy all work natively.
struct TerminalSelectableTextSheet: View {
    let state: TerminalSelectableTextState
    let fontSize: CGFloat
    let theme: RemodexTerminalTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(state.text)
                    .font(.system(size: max(fontSize, 13), design: .monospaced))
                    .foregroundStyle(Color(hexString: theme.foreground))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(hexString: theme.background))
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
