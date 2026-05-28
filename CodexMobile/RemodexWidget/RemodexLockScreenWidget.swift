// FILE: RemodexLockScreenWidget.swift
// Purpose: Lock Screen / Always-On accessory widget that surfaces the Remodex
//          filled logo. Tapping the widget launches Remodex on the host
//          device. Three accessory families are supported so the user can pick
//          the layout that fits their Lock Screen.
// Layer: Widget Extension

import SwiftUI
import WidgetKit

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
