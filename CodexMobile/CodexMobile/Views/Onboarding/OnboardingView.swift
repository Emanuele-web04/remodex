// FILE: OnboardingView.swift
// Purpose: One-time onboarding screen shown before the first QR scan.
// Layer: View
// Exports: OnboardingView
// Depends on: SwiftUI

import SwiftUI

struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Hero image
                        ZStack(alignment: .bottom) {
                            Image("three")
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height * 0.44)
                                .clipped()

                            LinearGradient(
                                colors: [.clear, Color(.systemBackground).opacity(0.7), Color(.systemBackground)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 118)
                        }
                        
                        .frame(height: geo.size.height * 0.32)
                        .padding(.top, 20)

                        // Content
                        VStack(spacing: 22) {
                            // Logo + name
                            VStack(spacing: 8) {
                                Image("AppLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                Text("Remodex")
                                    .font(AppFont.title2(weight: .bold))

                                Text("Control Codex from your iPhone.")
                                    .font(AppFont.caption(weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)

                            VStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Before you scan")
                                        .font(AppFont.caption(weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)

                                    Text("Pair your phone in a few quick steps.")
                                        .font(AppFont.title3(weight: .semibold))
                                }

                                VStack(spacing: 14) {
                                    OnboardingStepRow(
                                        number: "1",
                                        title: "Install the Codex CLI",
                                        command: "npm install -g @openai/codex@latest"
                                    )

                                    OnboardingStepRow(
                                        number: "2",
                                        title: "Install the latest Remodex bridge",
                                        command: "npm install -g remodex@latest"
                                    )

                                    OnboardingStepRow(
                                        number: "3",
                                        title: "Start pairing",
                                        command: "remodex up"
                                    )
                                }
                            }

                            // Primary CTA
                            Button(action: onContinue) {
                                HStack(spacing: 8) {
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Scan QR Code")
                                        .font(AppFont.body(weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(.white)
                                .background(.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)

                            // Calls out the privacy posture without adding another action to onboarding.
                            HStack(spacing: 6) {
                                Image(systemName: "lock.shield")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("End-to-end encrypted")
                                    .font(AppFont.caption(weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - Step row

private struct OnboardingStepRow: View {
    let number: String
    let title: String
    var command: String? = nil
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(AppFont.caption2(weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black, in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppFont.subheadline(weight: .medium))

                if let command {
                    OnboardingSetupCommandCard(command: command)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.caption(weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Inline copy-able command

private struct OnboardingSetupCommandCard: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            commandLabel

            Button {
                UIPasteboard.general.string = command
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Group {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Image("copy")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private var commandLabel: some View {
        ViewThatFits(in: .horizontal) {
            Text(command)
                .font(AppFont.mono(.caption2))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(command)
                .font(AppFont.mono(.caption2))
                .foregroundStyle(.primary.opacity(0.9))
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView {
        print("Continue tapped")
    }
}
