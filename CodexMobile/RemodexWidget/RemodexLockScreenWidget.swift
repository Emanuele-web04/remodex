// FILE: RemodexLockScreenWidget.swift
// Purpose: Lock Screen / Always-On accessory widget that surfaces the Remodex
//          filled logo. Tapping the widget launches Remodex on the host
//          device. Three accessory families are supported so the user can pick
//          the layout that fits their Lock Screen.
// Layer: Widget Extension

import SwiftUI
import WidgetKit
import ActivityKit

struct RemodexLockScreenEntry: TimelineEntry {
    let date: Date
}

struct RemodexLockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemodexLockScreenEntry {
        RemodexLockScreenEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (RemodexLockScreenEntry) -> Void) {
        completion(RemodexLockScreenEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RemodexLockScreenEntry>) -> Void) {
        // Static branding widget — no time-based refresh required.
        let timeline = Timeline(entries: [RemodexLockScreenEntry(date: Date())], policy: .never)
        completion(timeline)
    }
}

struct RemodexLockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemodexLockScreenEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularBody
            case .accessoryRectangular:
                rectangularBody
            case .accessoryInline:
                inlineBody
            default:
                EmptyView()
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var circularBody: some View {
        // Keep the circular accessory as a bare glyph; the Lock Screen slot
        // already supplies the surrounding widget chrome.
        Image("remodex_symbol_medium")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetAccentable()
    }

    private var rectangularBody: some View {
        HStack(spacing: 8) {
            Image("remodex_symbol_medium")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: 0) {
                Text("Remodex")
                    .font(.headline)
                    .lineLimit(1)
                Text("Open Codex chat")
                    .font(.caption)
                    .opacity(0.8)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var inlineBody: some View {
        // Inline accessories collapse to a single line next to the clock; the
        // image is auto-tinted by the system.
        Label("Remodex", image: "remodex_symbol_medium")
    }
}

struct RemodexLockScreenWidget: Widget {
    static let kind = "com.emanueledipietro.Remodex.RemodexWidget.LockScreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RemodexLockScreenProvider()) { entry in
            RemodexLockScreenWidgetView(entry: entry)
        }
        .configurationDisplayName("Remodex")
        .description("Quick access to Remodex from your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RemodexDisplayIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemodexDisplayIslandAttributes.self) { context in
            RemodexDisplayIslandLockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.05, green: 0.055, blue: 0.06))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.primaryThreadURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RemodexDisplayIslandCountView(
                        value: context.state.runningConversations.count,
                        title: context.isStale ? "Paused" : "Running",
                        tint: runningCountTint(for: context.state, isStale: context.isStale)
                    )
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RemodexDisplayIslandCountView(
                        value: reviewCount(for: context.state),
                        title: "Review",
                        tint: reviewCountTint(for: context.state)
                    )
                    .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        RemodexDisplayIslandExpandedList(state: context.state, isStale: context.isStale, style: .island)

                        // When the app can no longer push updates the counts/timers
                        // freeze; surface how old the data is instead of hiding it,
                        // so a "Paused" island still tells the truth.
                        if context.isStale {
                            Label {
                                Text(context.state.updatedAt, style: .relative)
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                }
            } compactLeading: {
                RemodexDisplayIslandMark()
                    .padding(.vertical, 2)
            } compactTrailing: {
                Text(compactStatusText(for: context.state))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                RemodexDisplayIslandMark()
                    .padding(.vertical, 2)
            }
            .keylineTint(context.isStale ? .gray : .green)
            .widgetURL(context.state.primaryThreadURL)
        }
    }

    private func runningCountTint(for state: RemodexDisplayIslandAttributes.ContentState, isStale: Bool) -> Color {
        // Only assert live-green when there is something actually running; a stale
        // or zero count is neutral so it doesn't read as active progress.
        if isStale || state.runningConversations.isEmpty {
            return .secondary
        }
        return .green
    }

    private func reviewCount(for state: RemodexDisplayIslandAttributes.ContentState) -> Int {
        state.completedConversations.count + state.failedConversations.count
    }

    private func reviewCountTint(for state: RemodexDisplayIslandAttributes.ContentState) -> Color {
        if reviewCount(for: state) == 0 {
            return .secondary
        }
        return state.failedConversations.isEmpty ? .cyan : .orange
    }

    private func compactStatusText(for state: RemodexDisplayIslandAttributes.ContentState) -> String {
        let runningCount = state.runningConversations.count
        if runningCount > 0 {
            return "\(runningCount)"
        }
        if !state.failedConversations.isEmpty {
            return "!"
        }
        return "\(state.completedConversations.count)"
    }
}

private struct RemodexDisplayIslandLockScreenView: View {
    let state: RemodexDisplayIslandAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RemodexDisplayIslandMark()
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Remodex")
                        .font(.subheadline.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            RemodexDisplayIslandExpandedList(state: state, isStale: isStale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        let running = state.runningConversations.count
        let completed = state.completedConversations.count
        let failed = state.failedConversations.count
        // Stale content can no longer vouch for live runs; describe them as paused
        // to match the row rendering.
        let runningLabel = isStale ? "paused" : "running"
        if failed > 0, running > 0 {
            return "\(running) \(runningLabel), \(failed) failed"
        }
        if failed > 0 {
            return failed == 1 ? "1 conversation failed" : "\(failed) conversations failed"
        }
        if running > 0, completed > 0 {
            return "\(running) \(runningLabel), \(completed) ready"
        }
        if running > 0 {
            return running == 1 ? "1 conversation \(runningLabel)" : "\(running) conversations \(runningLabel)"
        }
        return completed == 1 ? "1 conversation ready" : "\(completed) conversations ready"
    }
}

// Distinguishes the Dynamic Island expanded rows (which sit beneath the
// "Running"/"Review" count headers) from the standalone banner rows, so the
// island can drop the per-row status labels the headers already convey while
// the banner keeps them.
private enum RemodexDisplayIslandRowStyle {
    case banner
    case island
}

private struct RemodexDisplayIslandExpandedList: View {
    let state: RemodexDisplayIslandAttributes.ContentState
    var isStale: Bool = false
    var style: RemodexDisplayIslandRowStyle = .banner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(displayRows) { row in
                if let url = row.threadURL {
                    Link(destination: url) {
                        RemodexDisplayIslandRow(conversation: row, isStale: isStale, style: style)
                    }
                } else {
                    RemodexDisplayIslandRow(conversation: row, isStale: isStale, style: style)
                }
            }
        }
    }

    private var displayRows: [RemodexDisplayIslandConversation] {
        Array((state.runningConversations + state.failedConversations + state.completedConversations).prefix(3))
    }
}

private struct RemodexDisplayIslandRow: View {
    let conversation: RemodexDisplayIslandConversation
    var isStale: Bool = false
    var style: RemodexDisplayIslandRowStyle = .banner

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(conversation.detail.isEmpty ? displayState : conversation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                if !hidesRedundantStatusLabel {
                    Text(displayState)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }

                if let runningStartedAt = conversation.runningStartedAt, !isStaleRunningRow {
                    Text(runningStartedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(hidesRedundantStatusLabel ? tint : .secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
    }

    // In the Dynamic Island the leading header already reads "Running", so the
    // per-row "Running" label is pure duplication: drop it for live running rows
    // and let the timer (tinted with the state color) carry the status. The
    // banner keeps the label, and non-running / stale rows keep it too since the
    // header does not disambiguate ready vs failed.
    private var hidesRedundantStatusLabel: Bool {
        style == .island
            && !isStale
            && conversation.resolvedState == .running
            && conversation.runningStartedAt != nil
    }

    // Without updates from the app (suspended/offline) a "Running" row is only a
    // guess; stop the ticking timer and show a neutral state instead of faking
    // live progress.
    private var isStaleRunningRow: Bool {
        isStale && conversation.resolvedState?.isRunningLike == true
    }

    private var displayState: String {
        isStaleRunningRow ? RemodexDisplayIslandConversationState.paused.rawValue : conversation.state
    }

    private var tint: Color {
        if isStaleRunningRow {
            return .secondary
        }
        switch conversation.resolvedState {
        case .ready:
            return .cyan
        case .failed:
            return .orange
        default:
            return .green
        }
    }
}

private struct RemodexDisplayIslandCountView: View {
    let value: Int
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(tint)
        }
    }
}

private struct RemodexDisplayIslandMark: View {
    var body: some View {
        // Use the same filled Remodex symbol as the in-app logo and the Lock
        // Screen widget (remodex_symbol_medium) instead of the outline glyph so
        // the Live Activity stays visually consistent with the rest of the app.
        Image("remodex_symbol_medium")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.white)
    }
}

#if DEBUG
#Preview("Circular", as: .accessoryCircular) {
    RemodexLockScreenWidget()
} timeline: {
    RemodexLockScreenEntry(date: Date())
}

#Preview("Rectangular", as: .accessoryRectangular) {
    RemodexLockScreenWidget()
} timeline: {
    RemodexLockScreenEntry(date: Date())
}

#Preview("Inline", as: .accessoryInline) {
    RemodexLockScreenWidget()
} timeline: {
    RemodexLockScreenEntry(date: Date())
}
#endif
