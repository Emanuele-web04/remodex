// FILE: FullScreenOverlay.swift
// Purpose: `.fullScreenOverlay(isPresented:)` — covers the whole screen from a
//          small view without presenting a view controller, so the current first
//          responder (and its keyboard) is left completely alone.
// Layer: View Component (UIKit bridge)
// Exports: View.fullScreenOverlay(isPresented:content:)
// Depends on: SwiftUI, UIKit
//
// Design notes
// ------------
// * Presenting a view controller — `fullScreenCover`, or even a UIKit
//   `.overFullScreen` presentation — makes UIKit end editing in the presenting
//   hierarchy: the keyboard slides away and comes back on dismissal. The overlay
//   lives in its OWN `UIWindow` instead, with the hosting controller as that
//   window's root. The window is never made key, so the composer keeps its
//   first responder; and because the host is a proper window root (not a
//   detached or foreign-subview controller), UIKit menus and sheets can present
//   from inside the overlay without "detached view controller" warnings.
// * The window sits just above the app's windows and below the system keyboard
//   window, so a `.ultraThinMaterial` in the content blurs the live app while
//   the keyboard stays visible on top.
// * Content lays out against the full screen (a ZStack centers by default), so
//   the overlay reads the same wherever it was launched from. The keyboard
//   safe-area region is ignored to keep that placement stable whether or not
//   the keyboard is up.
// * The content runs in its own `UIHostingController`, so it inherits UIKit
//   traits (color scheme, Dynamic Type) but NOT the SwiftUI environment of the
//   anchoring view. Pass anything else it needs in explicitly.
// * Appearance and dismissal animations belong to the content: it is inserted
//   and removed without animation, so it should fade/settle itself in
//   `onAppear` and animate out before calling its dismiss callback.

import SwiftUI
import UIKit

extension View {
    // Shows `content` over the whole screen while this view keeps its keyboard.
    func fullScreenOverlay<OverlayContent: View>(
        isPresented: Bool,
        @ViewBuilder content: @escaping () -> OverlayContent
    ) -> some View {
        background(
            FullScreenOverlayAnchor(isPresented: isPresented) {
                // Keep the overlay's placement identical with and without the
                // keyboard: no SwiftUI keyboard avoidance inside the window.
                content().ignoresSafeArea(.keyboard)
            }
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Anchor bridge

private struct FullScreenOverlayAnchor<OverlayContent: View>: UIViewControllerRepresentable {
    let isPresented: Bool
    let content: () -> OverlayContent

    func makeUIViewController(context: Context) -> FullScreenOverlayAnchorController<OverlayContent> {
        FullScreenOverlayAnchorController()
    }

    func updateUIViewController(
        _ controller: FullScreenOverlayAnchorController<OverlayContent>,
        context: Context
    ) {
        controller.update(isPresented: isPresented, content: content())
    }

    // The anchoring view can go away without the flag flipping (the thread it
    // belongs to closes); the overlay must not outlive it.
    static func dismantleUIViewController(
        _ controller: FullScreenOverlayAnchorController<OverlayContent>,
        coordinator: ()
    ) {
        controller.removeOverlay()
    }
}

// MARK: - Anchor controller

final class FullScreenOverlayAnchorController<OverlayContent: View>: UIViewController {
    private var overlayWindow: UIWindow?
    private var host: FullScreenOverlayHostController<OverlayContent>?
    private var latestContent: OverlayContent?
    private var wantsOverlay = false

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        container.isOpaque = false
        // Purely a lifecycle anchor: it must never intercept the host view's taps.
        container.isUserInteractionEnabled = false
        view = container
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Covers the case where the flag flipped before this view had a scene.
        syncOverlay()
    }

    func update(isPresented: Bool, content: OverlayContent) {
        wantsOverlay = isPresented
        latestContent = content
        // Keep a live overlay in sync with the anchoring view's state (the model
        // and effort labels change while the slider is being dragged).
        host?.rootView = content
        syncOverlay()
    }

    func removeOverlay() {
        wantsOverlay = false
        latestContent = nil
        guard let overlayWindow else { return }
        self.overlayWindow = nil
        host = nil
        overlayWindow.isHidden = true
        overlayWindow.rootViewController = nil
    }

    // MARK: - Installation

    private func syncOverlay() {
        if wantsOverlay {
            installOverlayIfNeeded()
        } else if overlayWindow != nil {
            removeOverlay()
        }
    }

    private func installOverlayIfNeeded() {
        guard overlayWindow == nil, let latestContent,
              let windowScene = view.window?.windowScene else { return }

        let host = FullScreenOverlayHostController(rootView: latestContent)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.backgroundColor = .clear
        window.isOpaque = false
        // Above the app's windows, below the system keyboard window. Showing it
        // WITHOUT `makeKey` is what keeps the composer's keyboard alive: key
        // status (and the first responder with it) never moves.
        window.windowLevel = .normal + 1
        window.frame = windowScene.coordinateSpace.bounds
        window.isHidden = false

        self.host = host
        overlayWindow = window
    }
}

// MARK: - Content host

// Transparent host so the content's own material blurs the app underneath
// instead of compositing against an opaque background.
final class FullScreenOverlayHostController<OverlayContent: View>: UIHostingController<OverlayContent> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
    }
}
