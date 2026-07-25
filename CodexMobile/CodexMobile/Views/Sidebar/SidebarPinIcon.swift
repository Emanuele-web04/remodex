// FILE: SidebarPinIcon.swift
// Purpose: Single pin glyph reused by the Pinned section header and by every
//          pinned thread row so asset, size and weight stay in sync across
//          surfaces. Row variant uses the shared sidebar metadata tint.
// Layer: View Component
// Exports: SidebarPinIcon
// Depends on: SwiftUI, RemodexIcon, AppFont, SidebarForegroundStyle

import SwiftUI

struct SidebarPinIcon: View {
    enum Style {
        // Pinned section header glyph: outline pin, prominent.
        case header
        // Inline badge prepended to a pinned thread row's title.
        case rowBadge
    }

    let style: Style

    var body: some View {
        // Both variants route through the same explicit-size path so they
        // render at identical bounds; the font-driven path used to make the
        // row badge anchor on an SF Symbol bounding box larger than the
        // header glyph. Asset name doesn't matter: `pin` and `pin.fill` both
        // map to `central-pin` in `RemodexIcon`.
        RemodexIcon.image(systemName: "pin", size: 18, weight: .medium)
            .foregroundStyle(style.foregroundStyle)
    }
}

private extension SidebarPinIcon.Style {
    var foregroundStyle: AnyShapeStyle {
        switch self {
        case .header:
            AnyShapeStyle(HierarchicalShapeStyle.primary)
        case .rowBadge:
            AnyShapeStyle(SidebarForegroundStyle.meta)
        }
    }
}

#if DEBUG
#Preview("SidebarPinIcon") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
            SidebarPinIcon(style: .header)
            Text("Pinned").font(AppFont.body(weight: .medium))
        }
        HStack(spacing: 6) {
            SidebarPinIcon(style: .rowBadge)
            Text("Investigate flaky tests")
        }
    }
    .padding()
}
#endif
