// FILE: TurnStatusSheet.swift
// Purpose: Presents the local session status summary for the `/status` composer command.
// Layer: View Component
// Exports: TurnStatusSheet
// Depends on: SwiftUI, ContextWindowUsage, CodexRateLimitStatus

import SwiftUI

struct TurnStatusSheet: View {
    let contextWindowUsage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    rateLimitsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
        }
        .presentationDetents([.fraction(0.4), .medium, .large])
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let contextWindowUsage {
                metricRow(
                    label: "Context",
                    value: "\(contextWindowUsage.percentRemaining)% left",
                    detail: "(\(compactTokenCount(contextWindowUsage.tokensUsed)) used / \(compactTokenCount(contextWindowUsage.tokenLimit)))"
                )

                progressBar(progress: contextWindowUsage.fractionUsed)
            } else {
                metricRow(label: "Context", value: "Unavailable", detail: "Waiting for token usage")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var rateLimitsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rate limits")
                    .font(AppFont.subheadline(weight: .semibold))

                Spacer(minLength: 12)

                if isLoadingRateLimits {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !rateLimitRows.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rateLimitRows) { row in
                        rateLimitRow(row)
                    }
                }
            } else if let rateLimitsErrorMessage, !rateLimitsErrorMessage.isEmpty {
                Text(rateLimitsErrorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else if isLoadingRateLimits {
                Text("Loading current limits...")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                Text("Rate limits are unavailable for this account.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // Renders each visible rate-limit window separately so 5h and Weekly do not collapse into one row.
    private func rateLimitRow(_ row: CodexRateLimitDisplayRow) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.label)
                    .font(AppFont.mono(.callout))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Text("\(row.window.remainingPercent)% left")
                    .font(AppFont.mono(.callout))
                    .foregroundStyle(.primary)

                if let resetText = resetLabel(for: row.window) {
                    Text("(\(resetText))")
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            progressBar(progress: Double(row.window.clampedUsedPercent) / 100)
        }
    }

    // Some runtimes expose the same 5h/Weekly windows through multiple payload shapes.
    // Dedupe by the visible label so the sheet shows one row per logical limit window.
    private var rateLimitRows: [CodexRateLimitDisplayRow] {
        let rows = rateLimitBuckets.flatMap(\.displayRows)
        var dedupedByLabel: [String: CodexRateLimitDisplayRow] = [:]

        for row in rows {
            if let existing = dedupedByLabel[row.label] {
                dedupedByLabel[row.label] = preferredRateLimitRow(existing, row)
            } else {
                dedupedByLabel[row.label] = row
            }
        }

        return dedupedByLabel.values.sorted { lhs, rhs in
            let lhsDuration = lhs.window.windowDurationMins ?? Int.max
            let rhsDuration = rhs.window.windowDurationMins ?? Int.max
            if lhsDuration == rhsDuration {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return lhsDuration < rhsDuration
        }
    }

    private func preferredRateLimitRow(
        _ current: CodexRateLimitDisplayRow,
        _ candidate: CodexRateLimitDisplayRow
    ) -> CodexRateLimitDisplayRow {
        if candidate.window.clampedUsedPercent != current.window.clampedUsedPercent {
            return candidate.window.clampedUsedPercent > current.window.clampedUsedPercent ? candidate : current
        }

        switch (current.window.resetsAt, candidate.window.resetsAt) {
        case (.none, .some):
            return candidate
        case (.some, .none):
            return current
        case let (.some(currentReset), .some(candidateReset)):
            return candidateReset < currentReset ? candidate : current
        case (.none, .none):
            return current
        }
    }

    private func metricRow(
        label: String,
        value: String,
        detail: String? = nil,
        monospace: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(label):")
                .font(AppFont.mono(.callout))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(monospace ? AppFont.mono(.callout) : AppFont.headline(weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            if let detail {
                Text(detail)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func progressBar(progress: Double) -> some View {
        let clampedProgress = min(max(progress, 0), 1)

        return GeometryReader { geometry in
            let totalWidth = max(geometry.size.width, 1)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.1))

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: totalWidth * CGFloat(clampedProgress))
            }
        }
        .frame(height: 14)
    }

    private func compactTokenCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            let value = Double(count) / 1_000_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M"
                : String(format: "%.1fM", value)
        case 1_000...:
            let value = Double(count) / 1_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))K"
                : String(format: "%.1fK", value)
        default:
            return groupedTokenCount(count)
        }
    }

    private func groupedTokenCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func resetLabel(for window: CodexRateLimitWindow) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }

        let calendar = Calendar.current
        let now = Date()

        if calendar.isDate(resetsAt, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "resets \(formatter.string(from: resetsAt))"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return "resets \(formatter.string(from: resetsAt))"
    }
}
