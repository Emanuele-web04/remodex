// FILE: OnboardingView.swift
// Purpose: Split onboarding flow — swipeable pages with fixed bottom bar.
// Layer: View
// Exports: OnboardingView
// Depends on: SwiftUI, OnboardingWelcomePage, OnboardingFeaturesPage, OnboardingStepPage

import SwiftUI

struct OnboardingView: View {
    let onScanQRCode: () -> Void
    let onPairWithCode: () -> Void
    @State private var currentPage = 0
    @State private var isShowingCodexInstallReminder = false

    private let pageCount = 5
    private let codexInstallStepIndex = 2
    private let codexInstallCommand = "npm install -g @openai/codex@latest"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(0)

                    OnboardingFeaturesPage()
                        .tag(1)

                    OnboardingStepPage(
                        stepNumber: 1,
                        icon: "terminal",
                        title: "Install Codex CLI",
                        description: "The AI coding agent that lives in your terminal. Remodex connects to it from your iPhone.",
                        command: codexInstallCommand
                    )
                    .tag(2)

                    OnboardingStepPage(
                        stepNumber: 2,
                        icon: "link",
                        title: "Install the Bridge",
                        description: "A lightweight relay that securely connects your Mac to your iPhone.",
                        command: "npm install -g remodex@latest",
                        commandCaption: "Remodex can keep your Mac awake with macOS caffeinate while the bridge is running, but it starts disabled by default. You can enable it later in Settings if you want."
                    )
                    .tag(3)

                    OnboardingStepPage(
                        stepNumber: 3,
                        icon: "qrcode.viewfinder",
                        title: "Start Pairing",
                        description: "Run this on your computer. A QR code will appear in your terminal — scan it next.",
                        command: "remodex up"
                    )
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .alert("Install Codex CLI First", isPresented: $isShowingCodexInstallReminder) {
            Button("Stay Here", role: .cancel) {}
            Button("Continue Anyway") {
                advanceToNextPage()
            }
        } message: {
            Text("Copy and paste \"\(codexInstallCommand)\" on your computer before moving on. Remodex will not work until Codex CLI is installed and available in your PATH.")
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 20) {
            // Animated pill dots
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == currentPage ? Color.white : Color.white.opacity(0.18))
                        .frame(width: i == currentPage ? 24 : 8, height: 8)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentPage)

            finalPageActions

            OpenSourceBadge(style: .light)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
            .offset(y: -50),
            alignment: .top
        )
    }

    // MARK: - State

    @ViewBuilder
    private var finalPageActions: some View {
        if currentPage == pageCount - 1 {
            VStack(spacing: 10) {
                PrimaryCapsuleButton(
                    title: "Scan with QR Code",
                    systemImage: "qrcode",
                    action: handleContinue
                )

                secondaryCapsuleButton(
                    title: "Pair with Code",
                    systemImage: "keyboard",
                    action: onPairWithCode
                )
            }
        } else {
            PrimaryCapsuleButton(
                title: buttonTitle,
                action: handleContinue
            )
        }
    }

    // Offers the first-run manual pairing path without competing visually with the primary QR flow.
    private func secondaryCapsuleButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))

                Text(title)
                    .font(AppFont.body(weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var buttonTitle: String {
        switch currentPage {
        case 0: return "Get Started"
        case 1: return "Set Up"
        default: return "Continue"
        }
    }

    private func handleContinue() {
        // The CLI install step is a hard requirement, so warn before advancing.
        if currentPage == codexInstallStepIndex {
            isShowingCodexInstallReminder = true
            return
        }

        if currentPage < pageCount - 1 {
            advanceToNextPage()
        } else {
            onScanQRCode()
        }
    }

    private func advanceToNextPage() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }
}

// MARK: - Previews

#Preview("Full Flow") {
    OnboardingView(
        onScanQRCode: {
            print("Scan tapped")
        },
        onPairWithCode: {
            print("Code tapped")
        }
    )
}

#Preview("Light Override") {
    OnboardingView(
        onScanQRCode: {
            print("Scan tapped")
        },
        onPairWithCode: {
            print("Code tapped")
        }
    )
    .preferredColorScheme(.light)
}
