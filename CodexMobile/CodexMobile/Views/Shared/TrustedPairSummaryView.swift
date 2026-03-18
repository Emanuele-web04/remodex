// FILE: TrustedPairSummaryView.swift
// Purpose: Compact summary card for the currently connected or remembered Mac pair.
// Layer: View
// Exports: TrustedPairSummaryView
// Depends on: SwiftUI

import SwiftUI

struct TrustedPairSummaryView: View {
    let title: String
    let name: String
    let systemName: String?
    let detail: String?

    init(title: String, name: String, systemName: String?, detail: String?) {
        self.title = title
        self.name = name
        self.systemName = systemName
        self.detail = detail
    }

    init(presentation: CodexTrustedPairPresentation) {
        self.init(
            title: presentation.title,
            name: presentation.name,
            systemName: presentation.systemName,
            detail: presentation.detail
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let systemName, !systemName.isEmpty {
                        Text("\"\(systemName)\"")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
