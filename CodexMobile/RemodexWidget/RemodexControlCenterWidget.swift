// FILE: RemodexControlCenterWidget.swift
// Purpose: iOS 18 Control Center widget that adds a Remodex quick-launch
//          button to the Controls Gallery. Tapping the button triggers
//          `RemodexLaunchIntent`, which brings the Remodex app to the
//          foreground.
// Layer: Widget Extension

import AppIntents
import SwiftUI
import WidgetKit

private let remodexProjectsURL = URL(string: "phodex://open/projects")!

@available(iOS 18.0, *)
struct RemodexLaunchControl: ControlWidget {
    static let kind = "com.emanueledipietro.Remodex.RemodexWidget.ProjectsControl.v10"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(remodexProjectsURL)) {
                Label("Remodex Projects", image: "remodex_control_symbol")
            }
        }
        .displayName("Remodex Projects")
        .description("Open the Remodex project list from the lock screen.")
    }
}
