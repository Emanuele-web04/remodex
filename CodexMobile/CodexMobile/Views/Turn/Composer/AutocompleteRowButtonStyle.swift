// FILE: AutocompleteRowButtonStyle.swift
// Purpose: Highlight style for autocomplete rows in file/skill panels.
// Layer: View Component
// Exports: AutocompleteRowButtonStyle
// Depends on: SwiftUI

import SwiftUI

struct AutocompleteRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color(.systemGray5)
                    : Color.clear
            )
    }
}
