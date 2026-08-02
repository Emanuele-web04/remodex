// FILE: AppMenuPresentation.swift
// Purpose: Keeps native menu typography and glyphs proportional to Remodex's compact UI.
// Layer: View Helper
// Exports: AppMenuPresentation
// Depends on: Foundation, UIKit, AppFont

import Foundation
import UIKit

enum AppMenuPresentation {
    // The old 20pt menu assets were too dominant, while 16pt was visibly too
    // small beside native symbols. Keep the shared artwork at the middle 18pt metric.
    static var glyphPointSize: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 18)
    }

    /// UIKit doesn't expose a public font property for `UIAction` rows. This
    /// project already relies on the guarded `attributedTitle` selector for
    /// colored Git totals; use the same guarded path to align menu titles with
    /// Remodex's 15pt prose body while retaining any existing title colors.
    @discardableResult
    static func style(_ menu: UIMenu) -> UIMenu {
        styleTitle(of: menu)
        style(menu.children)
        return menu
    }

    @discardableResult
    static func style(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        for element in elements {
            styleTitle(of: element)
            if let submenu = element as? UIMenu {
                style(submenu.children)
            }
        }
        return elements
    }

    private static func styleTitle(of element: UIMenuElement) {
        let setter = NSSelectorFromString("setAttributedTitle:")
        guard !element.title.isEmpty, element.responds(to: setter) else { return }

        let getter = NSSelectorFromString("attributedTitle")
        let existingTitle = element.responds(to: getter)
            ? element.value(forKey: "attributedTitle") as? NSAttributedString
            : nil
        let attributedTitle = NSMutableAttributedString(
            attributedString: existingTitle ?? NSAttributedString(string: element.title)
        )
        attributedTitle.addAttribute(
            .font,
            value: AppFont.bodyUIFont(),
            range: NSRange(location: 0, length: attributedTitle.length)
        )
        element.setValue(attributedTitle, forKey: "attributedTitle")
    }
}
