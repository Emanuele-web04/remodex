// FILE: CodeCommentFindingCard.swift
// Purpose: Displays one parsed code-comment directive finding inside assistant messages.
// Layer: Turn UI component
// Exports: CodeCommentFindingCard
// Depends on: Foundation, SwiftUI, AppFont, CodeCommentDirectiveFinding

import Foundation
import SwiftUI

struct CodeCommentFindingCard: View {
    let finding: CodeCommentDirectiveFinding

    private var priorityLevel: Int {
        min(max(finding.priority ?? 3, 0), 3)
    }

    private var priorityColor: Color {
        switch priorityLevel {
        case 0:
            return .red
        case 1:
            return .orange
        case 2:
            return .yellow
        default:
            return .blue
        }
    }

    private var fileName: String {
        let basename = (finding.file as NSString).lastPathComponent
        return basename.isEmpty ? finding.file : basename
    }

    private var lineLabel: String? {
        guard let startLine = finding.startLine else { return nil }
        if let endLine = finding.endLine, endLine != startLine {
            return "L\(startLine)-\(endLine)"
        }
        return "L\(startLine)"
    }

    private var confidenceLabel: String? {
        guard let confidence = finding.confidence else { return nil }
        let clamped = min(max(confidence, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("P\(priorityLevel)")
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(priorityColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(priorityColor.opacity(0.12), in: Capsule())

                Text(finding.title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            Text(finding.body)
                .font(AppFont.body())
                .foregroundStyle(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(fileName)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(1)

                if let lineLabel {
                    Text(lineLabel)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }

                if let confidenceLabel {
                    Text(confidenceLabel)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(priorityColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(priorityColor.opacity(0.28), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}
