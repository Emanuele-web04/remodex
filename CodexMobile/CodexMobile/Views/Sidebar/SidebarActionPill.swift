// FILE: SidebarActionPill.swift
// Purpose: Shared capsule "pill" used by the sidebar's bottom action bar so
//          Terminal and Chat (and any future companion action) read as a
//          matched pair — identical font, icon sizing, padding and capsule
//          shape, with only the background / foreground swapped per style.
//          An empty `title` renders the icon-only variant: the same styles on
//          a fixed-diameter circle, used by the bottom bar next to the search
//          capsule.
//          The accent style mirrors the composer send button: it reads the
//          user's `UserBubbleColor` preference and resolves it through
//          `ctaPalette` (Default → Primary) so the pill stays a bold,
//          label-colored CTA that swaps with the bubble color settings.
// Layer: View Component
// Exports: SidebarActionPill, SidebarActionPillStyle
// Depends on: SwiftUI, RemodexIcon, AppFont, UserBubbleColor,
//             AdaptiveGlassModifier, HapticFeedback

import SwiftUI
import UIKit

// MARK: - Style

enum SidebarActionPillStyle {
    // Terminal-style: Liquid Glass capsule on iOS 26, plain glass material on
    // iOS 18, secondary label foreground. Pairs well with `AdaptiveGlassContainer`.
    case glass
    // Chat-style: bubble-palette capsule fill (same color the composer send
    // button uses), bubble-foreground text. Indicates the primary action in
    // the bar.
    case accent
}

// MARK: - Pill

struct SidebarActionPill: View {
    let title: String
    let iconSystemName: String
    let style: SidebarActionPillStyle
    let isEnabled: Bool
    let isLoading: Bool
    let titleFont: Font
    let titleWeight: Font.Weight
    let iconSize: CGFloat
    let iconWeight: Font.Weight
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let circleDiameter: CGFloat
    let hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle
    let accessibilityLabelOverride: String?
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey)
    private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    init(
        title: String = "",
        iconSystemName: String,
        style: SidebarActionPillStyle,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        titleFont: Font = AppFont.body(),
        titleWeight: Font.Weight = .medium,
        iconSize: CGFloat = 20,
        iconWeight: Font.Weight = .semibold,
        horizontalPadding: CGFloat = 16,
        verticalPadding: CGFloat = 12,
        circleDiameter: CGFloat = 44,
        hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium,
        accessibilityLabel: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.title = title
        self.iconSystemName = iconSystemName
        self.style = style
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.titleFont = titleFont
        self.titleWeight = titleWeight
        self.iconSize = iconSize
        self.iconWeight = iconWeight
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.circleDiameter = circleDiameter
        self.hapticStyle = hapticStyle
        self.accessibilityLabelOverride = accessibilityLabel
        self.onTap = onTap
    }

    var body: some View {
        HapticButton(hapticStyle: hapticStyle, action: onTap) {
            pillContent
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(accessibilityLabelOverride ?? title)
    }

    // MARK: - Content

    private var pillContent: some View {
        // A Capsule over the icon-only square frame resolves to a circle, so
        // both variants share the same background modifier and hit shape.
        Group {
            if title.isEmpty {
                iconView
                    .frame(width: circleDiameter, height: circleDiameter)
            } else {
                HStack(spacing: 6) {
                    iconView

                    Text(title)
                        .font(titleFont)
                        .fontWeight(titleWeight)
                        .lineLimit(1)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
        }
        .foregroundStyle(foregroundColor)
        .modifier(
            SidebarActionPillBackground(
                style: style,
                isEnabled: isEnabled,
                accentBackground: accentBackground
            )
        )
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var iconView: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(foregroundColor)
        } else {
            RemodexIcon.image(
                systemName: iconSystemName,
                size: iconSize,
                weight: iconWeight
            )
        }
    }

    // MARK: - Palette resolution

    private var ctaPalette: UserBubbleColor {
        (UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default).ctaPalette
    }

    private var foregroundColor: Color {
        switch style {
        case .glass:
            return .primary
        case .accent:
            return isEnabled
                ? ctaPalette.bubbleForeground(for: colorScheme)
                : Color(.systemGray2)
        }
    }

    private var accentBackground: Color {
        if !isEnabled { return Color(.systemGray5) }
        return ctaPalette.bubbleBackground(for: colorScheme)
    }
}

// MARK: - Background

// Both styles route through the shared `adaptiveGlass` helper so the iOS 26
// Liquid Glass path and the iOS 18 fallback live in one place. The accent
// style passes a `tint`; the helper uses that tint as the fallback
// background, so iOS 18 / glass-off still reads as a solid bubble-palette
// capsule.
private struct SidebarActionPillBackground: ViewModifier {
    let style: SidebarActionPillStyle
    let isEnabled: Bool
    let accentBackground: Color

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content
                .adaptiveGlass(.regular, isInteractive: true, in: Capsule())
        case .accent:
            content
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    tint: accentBackground,
                    in: Capsule()
                )
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Pair") {
    HStack(spacing: 10) {
        SidebarActionPill(
            title: "Terminal",
            iconSystemName: "terminal.fill",
            style: .glass,
            hapticStyle: .light,
            onTap: {}
        )

        SidebarActionPill(
            title: "Chat",
            iconSystemName: "square.and.pencil",
            style: .accent,
            onTap: {}
        )
    }
    .padding()
}

#Preview("States") {
    VStack(spacing: 12) {
        SidebarActionPill(
            title: "Terminal",
            iconSystemName: "terminal.fill",
            style: .glass,
            onTap: {}
        )

        SidebarActionPill(
            title: "Chat",
            iconSystemName: "square.and.pencil",
            style: .accent,
            isLoading: true,
            onTap: {}
        )

        SidebarActionPill(
            title: "Chat",
            iconSystemName: "square.and.pencil",
            style: .accent,
            isEnabled: false,
            onTap: {}
        )
    }
    .padding()
}
#endif
