// FILE: TurnTimelineFooter.swift
// Purpose: Hosts the timeline footer, error affordance and scroll-to-latest control.
// Layer: View Component
// Exports: TurnTimelineFooterContainer
// Depends on: SwiftUI, TurnErrorReportCard

import SwiftUI

struct TurnTimelineFooterContainer<Composer: View>: View {
    let hidesErrorMessage: Bool
    let errorMessage: String?
    let onReportError: (String) -> Void
    let onDismissError: () -> Void
    let shouldShowScrollToLatestButton: Bool
    let scrollToLatestButtonLift: CGFloat
    let onScrollToLatest: (() -> Void)?
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        let footerContent = VStack(spacing: 0) {
            if !hidesErrorMessage, let errorMessage, !errorMessage.isEmpty {
                TurnErrorReportCard(
                    message: errorMessage,
                    onReport: { onReportError(errorMessage) },
                    onDismiss: onDismissError
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            composer()
        }

        footerContent
            .overlay(alignment: .top) {
                if shouldShowScrollToLatestButton, let onScrollToLatest {
                    scrollToLatestButton(action: onScrollToLatest)
                        .offset(y: -scrollToLatestButtonLift)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowScrollToLatestButton)
    }

    private func scrollToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(AppFont.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .adaptiveGlass(.regular, in: Circle())
        }
        .frame(width: 44, height: 44)
        .buttonStyle(TurnFloatingButtonPressStyle())
        .contentShape(Circle())
        .accessibilityLabel("Scroll to latest message")
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

private struct TurnFloatingButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
