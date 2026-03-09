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
                                .frame(width: geo.size.width, height: geo.size.height * 0.45)
                                .clipped()

                            LinearGradient(
                                colors: [.clear, Color(.systemBackground).opacity(0.7), Color(.systemBackground)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 120)
                        }
                        .frame(height: geo.size.height * 0.45)

                        // Content
                        VStack(spacing: 24) {
                            // Logo + name
                            VStack(spacing: 10) {
                                Image("AppLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                Text("Remodex")
                                    .font(AppFont.title2(weight: .bold))

                                Text("Control Codex from your iPhone.")
                                    .font(AppFont.caption(weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)

                            // Steps
                            VStack(spacing: 14) {
                                OnboardingStepRow(
                                    number: "1",
                                    title: "Install the package",
                                    command: "npm install -g remodex"
                                )

                                OnboardingStepRow(
                                    number: "2",
                                    title: "Start the relay",
                                    command: "remodex up"
                                )

                                OnboardingStepRow(
                                    number: "3",
                                    title: "Scan the QR code",
                                   
                                )
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

                            // GitHub link
                            Button {
                                if let url = URL(string: "https://github.com/Emanuele-web04/remodex") {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image("GitHub_Invertocat_Black")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 14, height: 14)
                                    Text("Star on GitHub")
                                        .font(AppFont.caption(weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
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
                    OnboardingCommandRow(command: command)
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

private struct OnboardingCommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            Text(command)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
                .padding(.leading, 10)
                .padding(.vertical, 8)

            Spacer(minLength: 4)

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
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

// MARK: - Preview

#Preview {
    OnboardingView {
        print("Continue tapped")
    }
}
