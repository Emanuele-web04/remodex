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
//   here is instead installed as a CHILD view controller of the top-most
//   ancestor, i.e. plain view hierarchy work that never touches the responder
//   chain. It also means a `.ultraThinMaterial` in the content blurs the live app
//   underneath, since everything stays in one window.
// * The content is bottom-anchored against the ANCHOR's bottom edge, published as
//   `additionalSafeAreaInsets.bottom`. Callers attach this to the view that
//   already follows the keyboard (the composer), so the overlay lands exactly
//   where that view sits — above the keyboard — without depending on a fresh
//   hosting controller inheriting an already-visible keyboard's frame. The
//   content ignores the keyboard safe-area region so the two never stack.
// * The content runs in its own `UIHostingController`, so it inherits UIKit
//   traits (color scheme, Dynamic Type) but NOT the SwiftUI environment of the
//   anchoring view. Pass anything else it needs in explicitly.
// * Appearance and dismissal animations belong to the content: it is inserted and
//   removed without animation, so it should fade/settle itself in `onAppear` and
//   animate out before calling its dismiss callback.

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
                // The overlay is positioned from the anchor's geometry, so
                // SwiftUI must not add its own keyboard inset on top.
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
    private var host: FullScreenOverlayHostController<OverlayContent>?
    private var latestContent: OverlayContent?
    private var wantsOverlay = false

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        container.isOpaque = false
        // Purely a geometry anchor: it must never intercept the host view's taps.
        container.isUserInteractionEnabled = false
        view = container
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncBottomInset()
        // Covers the case where the flag flipped before this view was installed.
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
        guard let host else { return }
        self.host = nil
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }

    // MARK: - Installation

    private func syncOverlay() {
        if wantsOverlay {
            installOverlayIfNeeded()
        } else if host != nil {
            removeOverlay()
        }
    }

    private func installOverlayIfNeeded() {
        guard host == nil, let latestContent, let container = overlayContainer else { return }

        let host = FullScreenOverlayHostController(rootView: latestContent)
        // Anchor before the first layout so the content never lands at the screen
        // bottom for one frame and then jumps up.
        applyBottomInset(to: host)

        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        host.didMove(toParent: container)

        self.host = host
    }

    // The top-most ancestor covers the whole surface this view belongs to (the
    // screen, or the sheet hosting it), so the overlay can blur all of it.
    private var overlayContainer: UIViewController? {
        var candidate: UIViewController = self
        while let parent = candidate.parent {
            candidate = parent
        }
        return candidate === self ? nil : candidate
    }

    // MARK: - Geometry

    // Publishes the gap between the anchor's bottom edge and the window's, so
    // bottom-anchored overlay content lands exactly where the anchoring view sits
    // (i.e. above the keyboard while it is up).
    private func syncBottomInset() {
        guard let host else { return }
        applyBottomInset(to: host)
    }

    private func applyBottomInset(to host: FullScreenOverlayHostController<OverlayContent>) {
        guard let window = view.window else { return }
        let frameInWindow = view.convert(view.bounds, to: window)
        let gap = max(window.bounds.maxY - frameInWindow.maxY, 0)
        // `additionalSafeAreaInsets` stacks on the safe area the full-screen host
        // already inherits, so publish only the extra distance above it —
        // otherwise the content floats a home-indicator height too high.
        let inset = max(gap - window.safeAreaInsets.bottom, 0)
        guard abs(host.additionalSafeAreaInsets.bottom - inset) > 0.5 else { return }
        host.additionalSafeAreaInsets.bottom = inset
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
