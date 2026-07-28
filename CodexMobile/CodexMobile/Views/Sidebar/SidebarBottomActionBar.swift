// FILE: SidebarBottomActionBar.swift
// Purpose: Bottom-anchored sidebar bar. Hosts the Search Chats capsule plus
//          icon-only Terminal and Chat circles built from the shared
//          `SidebarActionPill` component. While search is engaged (focused or
//          filtering) the action circles slide away so the capsule and its
//          dismiss button take the full row — the bar lives in a bottom
//          `safeAreaInset`, so the keyboard lifts it automatically and search
//          floats right above it. Trusted-device switching lives inside the
//          Connections sheet (via the sidebar overflow menu), so the bar
//          carries no devices affordance.
// Layer: View Component
// Exports: SidebarBottomActionBar
// Depends on: SwiftUI, SidebarActionPill, SidebarSearchField, AdaptiveGlassModifier

import SwiftUI

struct SidebarBottomActionBar: View {
    @Binding var searchText: String
    @Binding var isSearchActive: Bool
    let isChatEnabled: Bool
    let isCreatingThread: Bool
    let onTapChat: () -> Void
    let onTapTerminal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SidebarSearchField(text: $searchText, isActive: $isSearchActive)

            if !isSearchEngaged {
                actionCircles
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSearchEngaged)
        .padding(.horizontal, 16)
        // safeAreaBar(edge:.bottom) on iOS 26 already adds the system safe-area
        // inset, so we only need a tiny visual gap above/below the controls.
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // Keeps the row uncramped while a filter is live: the search field's own
    // dismiss button already occupies the trailing slot in that state.
    private var isSearchEngaged: Bool {
        isSearchActive || !searchText.isEmpty
    }

    // Groups the two circles in the same native Liquid Glass sampling region
    // on iOS 26; the search capsule manages its own glass container.
    private var actionCircles: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                terminalButton
                chatButton
            }
        }
    }

    private var terminalButton: SidebarActionPill {
        SidebarActionPill(
            iconSystemName: "terminal.fill",
            style: .glass,
            hapticStyle: .light,
            accessibilityLabel: "Terminal",
            onTap: onTapTerminal
        )
    }

    private var chatButton: SidebarActionPill {
        SidebarActionPill(
            iconSystemName: "square.and.pencil",
            style: .accent,
            isEnabled: isChatEnabled,
            isLoading: isCreatingThread,
            accessibilityLabel: "New chat",
            onTap: onTapChat
        )
    }
}

#if DEBUG
#Preview {
    @Previewable @State var searchText = ""
    @Previewable @State var isSearchActive = false

    SidebarBottomActionBar(
        searchText: $searchText,
        isSearchActive: $isSearchActive,
        isChatEnabled: true,
        isCreatingThread: false,
        onTapChat: {},
        onTapTerminal: {}
    )
    .environment(CodexService())
}
#endif
