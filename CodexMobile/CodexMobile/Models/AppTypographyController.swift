// FILE: AppTypographyController.swift
// Purpose: Applies the selected app font to native UIKit chrome that does not inherit SwiftUI's font environment.
// Layer: Model
// Exports: AppTypographyController
// Depends on: UIKit, AppFont

import SwiftUI
import UIKit

@MainActor
enum AppTypographyController {
    static func apply() {
        let fonts = Fonts()
        configureAppearance(using: fonts)

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                refresh(view: window, using: fonts)
            }
        }
    }

    private static func configureAppearance(using fonts: Fonts) {
        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = attributes(
            replacingFontIn: navigationBar.titleTextAttributes,
            with: fonts.navigationTitle
        )
        navigationBar.largeTitleTextAttributes = attributes(
            replacingFontIn: navigationBar.largeTitleTextAttributes,
            with: fonts.largeNavigationTitle
        )

        let barButtonItem = UIBarButtonItem.appearance()
        apply(font: fonts.barButton, to: barButtonItem)

        let segmentedControl = UISegmentedControl.appearance()
        apply(font: fonts.segment, to: segmentedControl, for: .normal)
        apply(font: fonts.selectedSegment, to: segmentedControl, for: .selected)
    }

    private static func refresh(view: UIView, using fonts: Fonts) {
        if let navigationBar = view as? UINavigationBar {
            navigationBar.titleTextAttributes = attributes(
                replacingFontIn: navigationBar.titleTextAttributes,
                with: fonts.navigationTitle
            )
            navigationBar.largeTitleTextAttributes = attributes(
                replacingFontIn: navigationBar.largeTitleTextAttributes,
                with: fonts.largeNavigationTitle
            )
            for item in navigationBar.items ?? [] {
                refresh(item: item, using: fonts)
            }
            navigationBar.setNeedsLayout()
        } else if let toolbar = view as? UIToolbar {
            for item in toolbar.items ?? [] {
                apply(font: fonts.barButton, to: item)
            }
            toolbar.setNeedsLayout()
        } else if let segmentedControl = view as? UISegmentedControl {
            apply(font: fonts.segment, to: segmentedControl, for: .normal)
            apply(font: fonts.selectedSegment, to: segmentedControl, for: .selected)
            segmentedControl.setNeedsLayout()
        }

        for subview in view.subviews {
            refresh(view: subview, using: fonts)
        }
    }

    private static func refresh(item: UINavigationItem, using fonts: Fonts) {
        let items = (item.leftBarButtonItems ?? [])
            + (item.rightBarButtonItems ?? [])
            + [item.backBarButtonItem].compactMap { $0 }
        for barButtonItem in items {
            apply(font: fonts.barButton, to: barButtonItem)
        }
    }

    private static func apply(font: UIFont, to item: UIBarButtonItem) {
        for state in [UIControl.State.normal, .highlighted, .disabled, .selected] {
            let updated = attributes(
                replacingFontIn: item.titleTextAttributes(for: state),
                with: font
            )
            item.setTitleTextAttributes(updated, for: state)
        }
    }

    private static func apply(
        font: UIFont,
        to control: UISegmentedControl,
        for state: UIControl.State
    ) {
        let updated = attributes(
            replacingFontIn: control.titleTextAttributes(for: state),
            with: font
        )
        control.setTitleTextAttributes(updated, for: state)
    }

    private static func attributes(
        replacingFontIn attributes: [NSAttributedString.Key: Any]?,
        with font: UIFont
    ) -> [NSAttributedString.Key: Any] {
        var updated = attributes ?? [:]
        updated[.font] = font
        return updated
    }

    private struct Fonts {
        let navigationTitle = AppFont.uiFont(size: 17, weight: .semibold, textStyle: .headline)
        let largeNavigationTitle = AppFont.uiFont(size: 34, weight: .bold, textStyle: .largeTitle)
        let barButton = AppFont.uiFont(size: 17, textStyle: .body)
        let segment = AppFont.uiFont(size: 13, textStyle: .footnote)
        let selectedSegment = AppFont.uiFont(size: 13, weight: .semibold, textStyle: .footnote)
    }
}
