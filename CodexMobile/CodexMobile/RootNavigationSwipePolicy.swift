// FILE: RootNavigationSwipePolicy.swift
// Purpose: Centralizes route-aware horizontal swipe decisions for sidebar open/close and back navigation.
// Layer: View Support
// Exports: RootNavigationSwipeAction, RootNavigationSwipePolicy
// Depends on: CoreGraphics

import CoreGraphics

enum RootNavigationSwipeAction: Equatable {
    case openSidebar
    case closeSidebar
    case navigateBack

    var debugKind: String {
        switch self {
        case .openSidebar:
            return "open"
        case .closeSidebar:
            return "close"
        case .navigateBack:
            return "back"
        }
    }
}

struct RootNavigationSwipePolicy {
    private static let horizontalBiasRatio: CGFloat = 1.15
    private static let systemBackEdgeWidth: CGFloat = 80

    static func action(
        startLocationX: CGFloat,
        translationWidth: CGFloat,
        translationHeight: CGFloat,
        isSidebarOpen: Bool,
        navigationDepth: Int
    ) -> RootNavigationSwipeAction? {
        guard isPredominantlyHorizontal(
            translationWidth: translationWidth,
            translationHeight: translationHeight
        ) else {
            return nil
        }

        if isSidebarOpen {
            return translationWidth < 0 ? .closeSidebar : nil
        }

        guard translationWidth > 0 else {
            return nil
        }

        if navigationDepth > 0 {
            // Keep UIKit's bezel-edge back swipe intact and extend the same
            // gesture into the middle of the screen ourselves.
            guard startLocationX > systemBackEdgeWidth else {
                return nil
            }
            return .navigateBack
        }

        return .openSidebar
    }

    static func progressTranslation(
        for action: RootNavigationSwipeAction,
        translationWidth: CGFloat
    ) -> CGFloat {
        switch action {
        case .openSidebar, .navigateBack:
            return max(0, translationWidth)
        case .closeSidebar:
            return max(0, -translationWidth)
        }
    }

    static func isCommitReached(
        for action: RootNavigationSwipeAction,
        translationWidth: CGFloat,
        commitDistance: CGFloat
    ) -> Bool {
        progressTranslation(for: action, translationWidth: translationWidth) >= commitDistance
    }

    private static func isPredominantlyHorizontal(
        translationWidth: CGFloat,
        translationHeight: CGFloat
    ) -> Bool {
        abs(translationWidth) > abs(translationHeight) * horizontalBiasRatio
    }
}
