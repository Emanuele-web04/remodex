// FILE: RemodexWidgetBundle.swift
// Purpose: Entry point for the Remodex widget extension. Bundles together the
//          Lock Screen accessory widget and the iOS 18 Control Center
//          quick-launch control, both branded with the Remodex outline mark.
// Layer: Widget Extension

import SwiftUI
import WidgetKit

@main
struct RemodexWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        RemodexLockScreenWidget()
        RemodexDisplayIslandLiveActivity()
        if #available(iOS 18.0, *) {
            RemodexLaunchControl()
        }
    }
}
