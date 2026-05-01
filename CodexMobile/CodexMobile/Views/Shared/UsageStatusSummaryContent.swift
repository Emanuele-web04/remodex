// FILE: UsageStatusSummaryContent.swift
// Purpose: Shared usage + rate-limit summary used by status, settings, and context popovers.
// Layer: View Component
// Exports: UsageStatusSummaryContent, UsageStatusRefreshControl
// Depends on: SwiftUI, ContextWindowUsage, CodexRateLimitStatus

import SwiftUI

struct UsageStatusRefreshControl {
    let title: String
    let isRefreshing: Bool
    let action: () -> Void
}

struct UsageStatusSummaryContent: View {
    enum ContextPlacement {
        case top
        case bottom
    }

    let contextWindowUsage: ContextWindowUsage?
    let showsContextWindowSection: Bool
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let contextPlacement: ContextPlacement
    let showsRateLimitHeader: Bool
    let refreshControl: UsageStatusRefreshControl?

    init(
        contextWindowUsage: ContextWindowUsage?,
        showsContextWindowSection: Bool = true,
        rateLimitBuckets: [CodexRateLimitBucket],
        isLoadingRateLimits: Bool,
        rateLimitsErrorMessage: String?,
        contextPlacement: ContextPlacement = .top,
        showsRateLimitHeader: Bool = true,
        refreshControl: UsageStatusRefreshControl? = nil
    ) {
        self.contextWindowUsage = contextWindowUsage
        self.showsContextWindowSection = showsContextWindowSection
        self.rateLimitBuckets = rateLimitBuckets
        self.isLoadingRateLimits = isLoadingRateLimits
        self.rateLimitsErrorMessage = rateLimitsErrorMessage
        self.contextPlacement = contextPlacement
        self.showsRateLimitHeader = showsRateLimitHeader
        self.refreshControl = refreshControl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let refreshControl {
                refreshButton(refreshControl)
            }

            if showsContextWindowSection && contextPlacement == .top {
                contextSection
            }

            if showsDividerBeforeRateLimits {
                Divider()
            }

            rateLimitsSection

            if showsContextWindowSection && contextPlacement == .bottom {
                Divider()
                contextSection
            }
        }
    }

    // ─── Shared Sections ────────────────────────────────────────

    private var showsDividerBeforeRateLimits: Bool {
        guard showsContextWindowSection, contextPlacement == .top else { return false }
        return !rateLimitRows.isEmpty || isLoadingRateLimits || !(rateLimitsErrorMessage?.isEmpty ?? true)
    }

    private var rateLimitsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsRateLimitHeader {
                HStack {
                    Text("Rate limits")
                        .font(AppFont.subheadline(weight: .semibold))

                    Spacer(minLength: 12)

                    if isLoadingRateLimits {
                        ProgressView()
                            .controlSize(.small)
                    }
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
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Context window")
                .font(AppFont.subheadline(weight: .semibold))

            if let contextWindowUsage {
                metricRow(
                    label: "Context",
                    value: contextValue(for: contextWindowUsage),
                    detail: contextDetail(for: contextWindowUsage),
                    monospace: true
                )

                progressBar(progress: contextWindowUsage.fractionUsed)
            } else {
                metricRow(label: "Context", value: "Unavailable", detail: "Waiting for token usage")
            }
        }
    }

    // ─── Row Rendering ──────────────────────────────────────────

    private var rateLimitRows: [CodexRateLimitDisplayRow] {
        CodexRateLimitBucket.visibleDisplayRows(from: rateLimitBuckets)
    }

    private func refreshButton(_ refreshControl: UsageStatusRefreshControl) -> some View {
        Button(action: refreshControl.action) {
            HStack(spacing: 8) {
                if refreshControl.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(AppFont.system(size: 12, weight: .semibold))
                }

                Text(refreshControl.isRefreshing ? "Refreshing..." : refreshControl.title)
                    .font(AppFont.subheadline(weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .disabled(refreshControl.isRefreshing)
    }

    private func rateLimitRow(_ row: CodexRateLimitDisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

    private func metricRow(
        label: String,
        value: String,
        detail: String? = nil,
        monospace: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(label):")
                .font(AppFont.mono(.callout))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(monospace ? AppFont.mono(.callout) : AppFont.headline(weight: .semibold))
                .foregroundStyle(.primary)

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

    // ─── Formatting Helpers ─────────────────────────────────────

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

    private func contextValue(for usage: ContextWindowUsage) -> String {
        usage.tokenLimit > 0 ? "\(usage.percentRemaining)% left" : "0 used"
    }

    private func contextDetail(for usage: ContextWindowUsage) -> String? {
        guard usage.tokenLimit > 0 else { return nil }
        return "(\(compactTokenCount(usage.tokensUsed)) used / \(compactTokenCount(usage.tokenLimit)))"
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
