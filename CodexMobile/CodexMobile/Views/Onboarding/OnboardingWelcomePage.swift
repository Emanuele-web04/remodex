// FILE: OnboardingWelcomePage.swift
// Purpose: Welcome splash — first page of the onboarding flow with hero image.
// Layer: View
// Exports: OnboardingWelcomePage
// Depends on: SwiftUI, AppFont

import SwiftUI

struct OnboardingWelcomePage: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Hero image — fit full width, pinned to top
                Image("three")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                    .ignoresSafeArea()

                // Gradient fade to black — subtle, only at the bottom
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.5), location: 0.6),
                        .init(color: .black, location: 0.72),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Content overlaid at bottom
                VStack(spacing: 24) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.25), .white.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )

                    VStack(spacing: 8) {
                        Text("Remodex")
                            .font(AppFont.system(size: 32, weight: .bold))

                        Text("Control Codex from your iPhone.")
                            .font(AppFont.subheadline(weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11, weight: .medium))
                        Text("End-to-end encrypted")
                            .font(AppFont.caption(weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingWelcomePage()
    }
    .preferredColorScheme(.dark)
}
