// FILE: CodexWorktreeIcon.swift
// Purpose: Shared fork + worktree icons so branching affordances stay visually aligned across the app.
// Layer: View Component
// Exports: CodexForkIcon, CodexWorktreeIcon, CodexWorktreeMenuLabelRow
// Depends on: SwiftUI, AppFont

import SwiftUI
import UIKit

struct CodexForkIcon: View {
    var pointSize: CGFloat = 13

    var body: some View {
        // `remodex.fork` is a virtual key in RemodexIcon mapped to
        // central-fork-code; routing through RemodexIcon keeps Dynamic Type
        // scaling and the square anchor logic in one place.
        RemodexIcon.image(systemName: "remodex.fork", size: pointSize)
    }
}

struct CodexWorktreeIcon: View {
    var pointSize: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        // Synara uses Central's arrow-split-right for worktrees; keep Remodex
        // on the same glyph through the shared icon resolver.
        RemodexIcon.image(
            systemName: "remodex.worktree",
            size: pointSize,
            weight: weight
        )
    }

    static func menuImage(pointSize: CGFloat = 13, weight _: UIImage.SymbolWeight = .regular) -> UIImage {
        guard let base = RemodexIcon.uiImage(systemName: "remodex.worktree") else {
            return UIImage()
        }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.withRenderingMode(.alwaysTemplate)
    }

    // Matches the UIKit menu glyph metric used by `RemodexIcon.menuUIImage`.
    static func toolbarMenuUIImage() -> UIImage {
        let pointSize = UIFontMetrics.default.scaledValue(for: 20)
        return menuImage(pointSize: pointSize, weight: .regular)
    }
}

struct CodexWorktreeMenuLabelRow: View {
    let title: String
    var pointSize: CGFloat = 13
    var weight: UIImage.SymbolWeight = .regular

    var body: some View {
        HStack(spacing: 10) {
            Image(uiImage: CodexWorktreeIcon.menuImage(pointSize: pointSize, weight: weight))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: pointSize, height: pointSize)
            Text(title)
        }
    }
}
