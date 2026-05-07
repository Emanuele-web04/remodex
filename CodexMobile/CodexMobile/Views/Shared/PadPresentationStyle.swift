// FILE: PadPresentationStyle.swift
// Purpose: Centralizes iPad-vs-phone presentation decisions used by shared SwiftUI controls.
// Layer: View Helper
// Exports: PadPresentationStyle
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

enum PadPresentationStyle {
    // Treat any physical iPad as pad UI even when Stage Manager or split screen reports compact width.
    static func usesPadPresentation(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular
    }

    static var modelPickerDetents: Set<PresentationDetent> {
        UIDevice.current.userInterfaceIdiom == .pad ? [.large] : [.medium, .large]
    }
}
