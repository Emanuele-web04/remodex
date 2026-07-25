// FILE: SidebarContentScopePicker.swift
// Purpose: Compact Liquid Glass chip picker that switches the sidebar between
//          project-backed threads and rootless chats.
//          The selected chip uses the same bubble-palette CTA fill as the
//          composer send button and the sidebar Chat pill (read from the
//          `UserBubbleColor` AppStorage, collapsed through `ctaPalette`),
//          so the entire accent surface in the sidebar stays in sync with
//          the user's chosen color.
// Layer: View Component
// Exports: SidebarContentScopePicker, SidebarFolderExpansionToggleButton
// Depends on: SwiftUI, SidebarContentScope, HapticButton, AppFont,
//             UserBubbleColor, RemodexIcon, AdaptiveGlassModifier

import SwiftUI

struct SidebarContentScopePicker: View {
    @Binding var selection: SidebarContentScope

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserBubbleColor.storageKey)
    private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue

    private static let selectionAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.78)

    var body: some View {
        AdaptiveGlassContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(SidebarContentScope.allCases) { scope in
                    scopeButton(scope)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Self.selectionAnimation, value: selection)
    }

    // Tiny Liquid Glass chip: bubble-palette-tinted glass when selected, plain
    // glass when not. A single spring on the parent drives the tint crossfade
    // so the swap reads less abrupt without adding a visible frame around the
    // chip.
    private func scopeButton(_ scope: SidebarContentScope) -> some View {
        let isSelected = selection == scope

        return HapticButton(hapticStyle: .light, action: {
            withAnimation(Self.selectionAnimation) {
                selection = scope
            }
        }) {
            Text(scope.title)
                .font(AppFont.callout(weight: .medium))
                .foregroundStyle(isSelected ? selectedForeground : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    tint: isSelected ? selectedBackground : nil,
                    fallbackMaterial: .ultraThinMaterial,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scope.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Palette resolution (mirrors composer send button)

    private var ctaPalette: UserBubbleColor {
        (UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default).ctaPalette
    }

    private var selectedBackground: Color {
        ctaPalette.bubbleBackground(for: colorScheme)
    }

    private var selectedForeground: Color {
        ctaPalette.bubbleForeground(for: colorScheme)
    }
}

// Icon-only companion to the scope chips; the parent owns the folder state.
struct SidebarFolderExpansionToggleButton: View {
    let areAllFoldersCollapsed: Bool
    let action: () -> Void

    private var title: String {
        areAllFoldersCollapsed ? "Expand all" : "Collapse all"
    }

    private var iconSystemName: String {
        areAllFoldersCollapsed
            ? "arrow.down.backward.and.arrow.up.forward"
            : "arrow.up.right.and.arrow.down.left"
    }

    var body: some View {
        HapticButton(hapticStyle: .light, action: action) {
            RemodexIcon.image(systemName: iconSystemName)
                .font(AppFont.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .ultraThinMaterial,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(
            areAllFoldersCollapsed ? "Expands all project folders" : "Collapses all project folders"
        )
        .help(title)
    }
}

#if DEBUG

// Interactive preview: tap the chips to swap selection live. Renders the chip
// on plain background, on a tinted card, and over a photo-like gradient so the
// Liquid Glass sampling region is visible while iterating.
private struct SidebarContentScopePickerPreviewHost: View {
    @State private var selection: SidebarContentScope = .projects

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("Interactive") {
                    HStack(spacing: 8) {
                        SidebarContentScopePicker(selection: $selection)
                        SidebarFolderExpansionToggleButton(areAllFoldersCollapsed: false, action: {})
                    }
                }

                section("Projects selected") {
                    SidebarContentScopePicker(
                        selection: .constant(.projects)
                    )
                }

                section("Chats selected") {
                    SidebarContentScopePicker(
                        selection: .constant(.chats)
                    )
                }

                section("On tinted card") {
                    SidebarContentScopePicker(selection: $selection)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                }

                section("On photo-style background") {
                    SidebarContentScopePicker(selection: $selection)
                        .padding(12)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.purple.opacity(0.55),
                                    Color.orange.opacity(0.55),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        )
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

#Preview("Scope Picker — Light") {
    SidebarContentScopePickerPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("Scope Picker — Dark") {
    SidebarContentScopePickerPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
