// FILE: ComposerAutocompletePanelHeight.swift
// Purpose: Shared inline autocomplete list height caps (PR6: 3 rows + 28% screen).
// Layer: View Component
// Exports: ComposerAutocompletePanelHeight
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

enum ComposerAutocompletePanelHeight {
    static let inlineVisibleRows = 3
    static let maxScreenFraction: CGFloat = 0.28

    /// Caps scrollable list height for bridge slash/skills panels (RP-CMD-2 / RP-SKILL-2).
    static func cappedListHeight(
        rowHeight: CGFloat,
        headerHeights: CGFloat,
        rowCount: Int,
        screenHeight: CGFloat
    ) -> CGFloat {
        let visibleRows = min(max(rowCount, 0), inlineVisibleRows)
        let rowCap = rowHeight * CGFloat(visibleRows) + headerHeights
        let screenCap = screenHeight * maxScreenFraction
        return min(rowCap, screenCap)
    }

    /// Full device height for `maxScreenFraction` (composer panels sit above the keyboard).
    static var screenHeightForCap: CGFloat {
        UIScreen.main.bounds.height
    }

    /// Section header allowance when the inline slice may span multiple scopes/sections.
    static func sectionHeaderAllowance(
        sectionCount: Int,
        sectionHeaderHeight: CGFloat
    ) -> CGFloat {
        guard sectionCount > 0 else { return 0 }
        return sectionHeaderHeight * CGFloat(min(sectionCount, 2))
    }
}