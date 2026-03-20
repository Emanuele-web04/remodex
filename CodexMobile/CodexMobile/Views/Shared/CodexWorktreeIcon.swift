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
        Image("git-branch")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
    }
}

struct CodexWorktreeIcon: View {
    var pointSize: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        Image(uiImage: Self.menuImage(pointSize: pointSize, weight: uiSymbolWeight))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
    }

    private var uiSymbolWeight: UIImage.SymbolWeight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    static func menuImage(pointSize: CGFloat = 13, weight: UIImage.SymbolWeight = .regular) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = UIImage(systemName: "arrow.triangle.branch", withConfiguration: config)?
            .withRenderingMode(.alwaysTemplate) else {
            return UIImage()
        }

        let canvasSide = max(symbol.size.width, symbol.size.height)
        let canvasSize = CGSize(width: canvasSide, height: canvasSide)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)

        return renderer.image { _ in
            let context = UIGraphicsGetCurrentContext()
            context?.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context?.rotate(by: .pi / 2)

            let drawRect = CGRect(
                x: -symbol.size.width / 2,
                y: -symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: drawRect)
        }
        .withRenderingMode(.alwaysTemplate)
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
