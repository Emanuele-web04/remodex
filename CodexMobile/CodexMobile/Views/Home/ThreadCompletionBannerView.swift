// FILE: ThreadCompletionBannerView.swift
// Purpose: Shows reusable in-app toast banners, including thread-completion notifications.
// Layer: View
// Exports: InAppToastBannerView, ThreadCompletionBannerView
// Depends on: SwiftUI, CodexThreadCompletionBanner

import SwiftUI

struct InAppToastBannerAction {
    let title: String
    let action: () -> Void
}

struct InAppToastBannerView<LeadingIcon: View>: View {
    let title: String
    let subtitle: String?
    let detailLines: [String]
    let accessibilityHint: String?
    let isDismissable: Bool
    let onTap: (() -> Void)?
    let onDismiss: (() -> Void)?
    let trailingAction: InAppToastBannerAction?
    let leadingIcon: () -> LeadingIcon

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    init(
        title: String,
        subtitle: String?,
        detailLines: [String] = [],
        accessibilityHint: String?,
        isDismissable: Bool,
        onTap: (() -> Void)?,
        onDismiss: (() -> Void)?,
        trailingAction: InAppToastBannerAction? = nil,
        @ViewBuilder leadingIcon: @escaping () -> LeadingIcon
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detailLines = detailLines
        self.accessibilityHint = accessibilityHint
        self.isDismissable = isDismissable
        self.onTap = onTap
        self.onDismiss = onDismiss
        self.trailingAction = trailingAction
        self.leadingIcon = leadingIcon
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !detailLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(detailLines, id: \.self) { line in
                            Text(line)
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, subtitle == nil ? 0 : 2)
                }
            }

            Spacer(minLength: 8)

            if let trailingAction {
                Button(action: trailingAction.action) {
                    Text(trailingAction.title)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trailingAction.title)
            }

            if isDismissable, let onDismiss {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .adaptiveGlass(.regular, in: shape)
        .overlay(
            shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(shape)
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }

    private var accessibilityLabel: String {
        let detail = detailLines.joined(separator: " ")
        if let subtitle {
            return [title, subtitle, detail]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
        }
        return [title, detail]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

struct ThreadCompletionBannerView: View {
    let banner: CodexThreadCompletionBanner
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        InAppToastBannerView(
            title: banner.title,
            subtitle: "Answer ready in another chat",
            accessibilityHint: "Opens the completed chat.",
            isDismissable: true,
            onTap: onTap,
            onDismiss: onDismiss
        ) {
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color(.systemBackground), lineWidth: 1)
                )
        }
    }
}
