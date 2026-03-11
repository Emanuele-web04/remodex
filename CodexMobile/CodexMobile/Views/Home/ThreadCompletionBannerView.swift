// FILE: ThreadCompletionBannerView.swift
// Purpose: Shows a tappable in-app banner when another chat finishes and gets the sidebar ready badge.
// Layer: View
// Exports: ThreadCompletionBannerView
// Depends on: SwiftUI, CodexThreadCompletionBanner

import SwiftUI

struct ThreadCompletionBannerView: View {
    let banner: CodexThreadCompletionBanner
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color(.systemBackground), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .lineLimit(1)

                Text("Answer ready in another chat")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(banner.title). Answer ready in another chat.")
        .accessibilityHint("Opens the completed chat.")
    }
}
