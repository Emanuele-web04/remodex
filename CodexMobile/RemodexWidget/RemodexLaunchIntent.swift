// FILE: RemodexLaunchIntent.swift
// Purpose: OpenIntent used by the Control Center quick-launch button to bring
//          Remodex to the foreground. This file is compiled into both the app
//          and widget targets because Control Widgets require that membership
//          before an intent can open the parent app.
// Layer: Widget Extension

import ActivityKit
import AppIntents
import Foundation

enum RemodexLaunchTarget: String, AppEnum {
    case home

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Remodex")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .home: "Remodex"
    ]
}

struct RemodexLaunchIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Remodex"
    static var description = IntentDescription("Brings Remodex to the foreground.")

    @Parameter(title: "Target")
    var target: RemodexLaunchTarget

    init() {
        self.target = .home
    }

    init(target: RemodexLaunchTarget) {
        self.target = target
    }
}

// Single vocabulary for Live Activity conversation states; the wire format stays
// String (Codable content state), so coordinator and widget construct/compare
// through this enum instead of raw literals.
enum RemodexDisplayIslandConversationState: String, Sendable {
    case running = "Running"
    case finishing = "Finishing"
    case ready = "Ready"
    case failed = "Failed"
    case paused = "Paused"

    var isRunningLike: Bool {
        self == .running || self == .finishing
    }
}

struct RemodexDisplayIslandConversation: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: String
    var runningStartedAt: Date?

    var resolvedState: RemodexDisplayIslandConversationState? {
        RemodexDisplayIslandConversationState(rawValue: state)
    }

    var threadURL: URL? {
        var components = URLComponents()
        components.scheme = "phodex"
        components.host = "thread"
        components.percentEncodedPath = "/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
        return components.url
    }
}

struct RemodexDisplayIslandAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var runningConversations: [RemodexDisplayIslandConversation]
        var completedConversations: [RemodexDisplayIslandConversation]
        var failedConversations: [RemodexDisplayIslandConversation]
        var updatedAt: Date

        var primaryThreadURL: URL? {
            runningConversations.first?.threadURL
                ?? failedConversations.first?.threadURL
                ?? completedConversations.first?.threadURL
        }
    }

    let title: String
}
