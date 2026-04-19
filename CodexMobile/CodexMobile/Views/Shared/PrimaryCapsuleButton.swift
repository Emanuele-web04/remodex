// FILE: PrimaryCapsuleButton.swift
// Purpose: Shared full-width CTA used by onboarding-style flows and modal confirmations.
// Layer: View Component
// Exports: PrimaryCapsuleButton
// Depends on: SwiftUI, AppFont

import SwiftUI

struct PrimaryCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage, !systemImage.isEmpty {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }

                Text(title)
                    .font(AppFont.body(weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack {
            PrimaryCapsuleButton(title: "Get Started") {}
            PrimaryCapsuleButton(title: "Scan QR Code", systemImage: "qrcode") {}
        }
        .padding(24)
    }
}
