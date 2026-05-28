// FILE: RemodexIcon.swift
// Purpose: Resolves Remodex-specific icons to bundled Central custom assets with SF Symbol fallback.
// Layer: View Utility
// Exports: RemodexIcon
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

enum RemodexIcon {
    private static let customAssetsBySystemName: [String: String] = [
        "archivebox": "central-archive-1",
        "arrow.down.right.and.arrow.up.left": "central-downsize",
        "arrow.left.arrow.right": "central-arrow-left-right",
        "arrow.trianglehead.2.clockwise.rotate.90": "central-arrows-repeat-circle",
        "arrow.up.circle": "central-arrow-up-circle",
        "arrow.up.right.square": "central-fork-code",
        "at": "central-at",
        "bell.badge": "central-bell-2",
        "bolt": "central-lightning",
        "bolt.fill": "central-lightning",
        "brain": "central-brain",
        "bubble.left.and.bubble.right": "central-bubble-5",
        "camera.fill": "central-camera-1",
        "checklist": "central-checklist",
        "checkmark.seal.fill": "central-shield-check",
        "checkmark.shield": "central-shield-check",
        "cloud": "central-cloud",
        "command": "central-cmd",
        "control": "central-control-key-left",
        "cube": "central-3d-box-top",
        "desktopcomputer": "central-imac",
        "doc.on.doc": "copy",
        "doc.text": "central-page-text",
        "doc.text.magnifyingglass": "central-page-search-lines",
        "ellipsis": "central-dot-grid-1x3-horizontal",
        "envelope": "central-email-1",
        "exclamationmark.circle": "central-exclamation-circle",
        "exclamationmark.circle.fill": "central-exclamation-circle-bold",
        "exclamationmark.triangle": "central-warning-sign",
        "exclamationmark.triangle.fill": "central-warning-sign",
        "folder": "central-folder-2",
        "folder.badge.gearshape": "central-folder-restricted",
        "folder.badge.plus": "central-folder-add-right",
        // `folder.fill` is used to denote a currently-open / selected folder
        // (e.g. the Current Folder row in the local folder browser), so it
        // maps to the open-folder visual rather than the generic closed one.
        "folder.fill": "central-folder-open-reversed",
        "gearshape.fill": "central-settings-gear-2",
        "hand.raised": "central-raising-hand-5-finger",
        "hand.thumbsup": "central-shield-access",
        "hare.fill": "central-speed-high",
        "heart": "central-heart",
        "hourglass": "central-hourglass",
        "key": "central-key-1",
        "keyboard": "central-keyboard",
        "keyboard.chevron.compact.down": "central-keyboard-down",
        "ladybug": "central-ladybug",
        "laptopcomputer": "central-macbook-air",
        "link": "central-chain-link-1",
        "list.bullet.clipboard": "central-clipboard-2",
        "list.bullet.rectangle": "central-list-bullets-square",
        "lock.open.fill": "central-unlocked",
        "lock.shield": "central-shield",
        "lock.shield.fill": "central-shield-check",
        "macbook.and.iphone": "central-devices-2",
        "magnifyingglass": "central-magnifying-glass",
        "message": "central-bubble-5",
        "mic": "central-microphone",
        "mic.fill": "central-microphone",
        "option": "central-opt-alt",
        "photo": "central-image-alt-text",
        "pin": "central-pin",
        "pin.fill": "central-pin",
        "pin.slash": "central-unpin",
        "plus.app": "central-appstore",
        "plus.circle": "central-circle-plus",
        "point.3.connected.trianglepath.dotted": "central-agent-network",
        "qrcode": "central-qr-code",
        "qrcode.viewfinder": "central-scan-code",
        "remodex.changes": "changes",
        "remodex.plan-mode": "central-planning",
        "remodex.skill": "central-building-blocks",
        "server.rack": "central-server",
        "shift": "central-shift",
        "slider.horizontal.3": "central-settings-slider-three",
        "speedometer": "central-dashboard-fast",
        "remodex.fork": "central-fork-code",
        "remodex.git-branch": "git-branch",
        "square.and.pencil": "central-compose-pencil",
        "square.stack.3d.up": "central-layers-three",
        "square.stack.3d.up.slash": "central-layers-behind",
        "terminal": "central-console",
        "terminal.fill": "central-console",
        "trash.circle": "central-trash-can",
        "tray.and.arrow.up": "central-unarchiv",
        "waveform": "central-voice-mode",
        "wifi.exclamationmark": "central-wifi-no-signal",
        "xmark": "central-cross-medium",
        "xmark.circle.fill": "central-cross-medium",
    ]

    static func assetName(for systemName: String) -> String? {
        customAssetsBySystemName[systemName]
    }

    static func image(
        systemName: String,
        size: CGFloat? = nil,
        weight: Font.Weight? = nil,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        RemodexIconView(
            systemName: systemName,
            explicitSize: size,
            explicitWeight: weight,
            scaleTextStyle: textStyle
        )
    }

    static func label(_ title: String, systemName: String) -> some View {
        Label {
            Text(title)
        } icon: {
            image(systemName: systemName)
        }
    }

    // SwiftUI Menu / contextMenu strip Label's `icon:` closure and only render
    // the title when given the closure-based initializer. The `Label(_, image:)`
    // and `Label(_, systemImage:)` initializers ARE respected, so this helper
    // routes through whichever one preserves the Central asset (or SF Symbol).
    // Use this whenever a Label is the direct child of a Menu / Picker / contextMenu.
    @ViewBuilder
    static func menuLabel(_ title: String, systemName: String) -> some View {
        if let assetName = assetName(for: systemName) {
            Label(title, image: assetName)
        } else {
            Label(title, systemImage: systemName)
        }
    }

    static func uiImage(systemName: String, withConfiguration configuration: UIImage.Configuration? = nil) -> UIImage? {
        guard let assetName = assetName(for: systemName) else {
            return UIImage(systemName: systemName, withConfiguration: configuration)
        }
        let image = UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate)
        guard let configuration else {
            return image
        }
        return image?.withConfiguration(configuration)
    }

    /// Returns a UIImage suitable for `UIAction(image:)` / `UIMenu(image:)`
    /// rows so Central artwork visually matches the SF Symbol "menu glyph"
    /// metric that UIKit applies to native symbols inside menus.
    ///
    /// Why this exists:
    /// - SF Symbols rendered via `UIImage(systemName:)` get a built-in menu
    ///   glyph treatment from UIKit (~17pt body-equivalent, regular weight).
    /// - `UIImage(named:)` for our Central SVG assets does NOT get that
    ///   treatment: UIMenu draws them at their intrinsic asset size (24pt)
    ///   so they read visibly larger than the SF Symbols in the same row.
    /// - Pre-rendering the Central asset to `menuGlyphPointSize` × that size
    ///   as a template image makes the menu row draw it at the matching
    ///   metric, restoring visual parity row-to-row.
    ///
    /// Dynamic Type is honored via `UIFontMetrics`, mirroring how SF Symbols
    /// in menus scale with the user's preferred content size.
    static func menuUIImage(systemName: String) -> UIImage? {
        guard let assetName = assetName(for: systemName) else {
            return UIImage(systemName: systemName)
        }
        guard let base = UIImage(named: assetName) else { return nil }
        let pointSize = menuGlyphPointSize
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.withRenderingMode(.alwaysTemplate)
    }

    // Larger than the ~17pt body-equivalent SF Symbol menu glyph: the
    // Central artwork's thin stroke reads visually smaller than an SF Symbol
    // at the same point size, so bumping to 20pt gives the custom glyphs
    // the "a little bolder than native" feel the design calls for without
    // going back to the original 24pt mismatch this helper was introduced
    // to fix.
    private static var menuGlyphPointSize: CGFloat {
        UIFontMetrics.default.scaledValue(for: 20)
    }
}

// SF Symbol used purely as a sizing anchor for custom assets. Picked because
// it is guaranteed-square at every weight / dynamic type setting, so the
// invisible bounding box matches the asset's 1:1 aspect ratio.
private let remodexIconSquareAnchorSymbol = "square"

private struct RemodexIconView: View {
    let systemName: String
    let explicitSize: CGFloat?
    let explicitWeight: Font.Weight?
    // Tracks Dynamic Type scaling for the explicit-size code path so icons
    // grow/shrink with the user's preferred content size category just like
    // SF Symbols do when sized via `.font(...)`.
    @ScaledMetric private var scaledExplicitSize: CGFloat

    init(
        systemName: String,
        explicitSize: CGFloat?,
        explicitWeight: Font.Weight?,
        scaleTextStyle: Font.TextStyle
    ) {
        self.systemName = systemName
        self.explicitSize = explicitSize
        self.explicitWeight = explicitWeight
        self._scaledExplicitSize = ScaledMetric(
            wrappedValue: explicitSize ?? 0,
            relativeTo: scaleTextStyle
        )
    }

    var body: some View {
        if let assetName = RemodexIcon.assetName(for: systemName) {
            customAsset(assetName)
        } else if explicitSize != nil {
            Image(systemName: systemName)
                .font(.system(size: scaledExplicitSize, weight: explicitWeight ?? .regular))
        } else if let explicitWeight {
            Image(systemName: systemName)
                .fontWeight(explicitWeight)
        } else {
            Image(systemName: systemName)
        }
    }

    @ViewBuilder
    private func customAsset(_ assetName: String) -> some View {
        let asset = Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()

        if explicitSize != nil {
            asset.frame(width: scaledExplicitSize, height: scaledExplicitSize)
        } else {
            // Anchor to a SQUARE SF Symbol bounding box (rather than the mapped
            // symbol's natural box) so custom assets render at their full 1:1
            // size regardless of how tall/narrow or wide/short the mapped
            // SF Symbol is. The anchor still scales with the ambient font and
            // Dynamic Type because `Image(systemName:)` size tracks the font.
            //
            // Background: the previous "use the mapped symbol as anchor"
            // approach caused central-* assets (which are square) to be
            // squeezed by `scaledToFit` whenever the SF Symbol was non-square
            // (mic, folder, laptopcomputer, ...). Anchoring on a guaranteed-
            // square symbol fixes the whole class of issues in one place.
            Image(systemName: remodexIconSquareAnchorSymbol)
                .opacity(0)
                .accessibilityHidden(true)
                .overlay { asset }
        }
    }
}
