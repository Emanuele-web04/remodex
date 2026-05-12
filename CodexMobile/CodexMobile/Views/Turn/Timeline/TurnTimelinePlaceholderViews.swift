// FILE: TurnTimelinePlaceholderViews.swift
// Purpose: Provides timeline loading and running-empty placeholder chrome.
// Layer: View Component
// Exports: TurnTimelineRunningEmptyState, TurnTimelineLoadingOverlay
// Depends on: SwiftUI

import SwiftUI

struct TurnTimelineRunningEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Working on it...")
                .font(AppFont.title3(weight: .semibold))
            Text("The run is still active. You can stop it below if needed.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
    }
}

struct TurnTimelineLoadingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Loading chat...")
                .font(AppFont.title3(weight: .semibold))
            Text("Preparing recent messages for this conversation.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
