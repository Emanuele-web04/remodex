// FILE: WhatsNewSheet.swift
// Purpose: Lightweight root sheet that summarizes one release's notable improvements.
// Layer: View
// Exports: WhatsNewSheet
// Depends on: SwiftUI, AppFont

import SwiftUI

private let whatsNewItems: [String] = [
    "New UI for sidebar, chats, projects, settings, composer, icons, and timelines",
    "Better Projects with folder search, local picking, allowed roots, and clearer controls",
    "Projectless Quick Chats, rootless general chats, and draft-first chat creation",
    "Native SSH terminal with saved hosts, keys, known hosts, routing, and setup help",
    "Pair with code when QR scanning is not convenient",
    "More reliable QR pairing, trusted reconnect, saved-device recovery, and connection switching",
    "Multiple Mac and multiple device support with better device management",
    "Remodex CLI 2.0 support, bridge compatibility checks, legacy 1.5.1 path, and better bridge/menu bar status",
    "Lower bridge memory and network usage",
    "Stronger reconnects after sleep, relaunch, foregrounding, relay reconnects, and network changes",
    "Better Windows host and relay compatibility",
    "New markdown rendering for links, code, user bubbles, and message text",
    "Better file previews, image previews, diffs, command output, tool calls, history items, and terminal output",
    "Smoother streaming, queued turns, thinking states, timelines, long messages, history loading, sync, and hydration",
    "Better composer drafts, scrolling, thumbnails, mentions, slash commands, runtime controls, spacing, and runtime recovery",
    "Voice mode and voice transcription reliability improvements",
    "Better Git actions, publish progress, branch/worktree controls, draft actions, and patch fallbacks",
    "Improved Plan Mode display and completed-step handling",
    "Pinned threads, auto titles, cleaner thread actions, and pending states",
    "New `/compact` slash command",
    "Better error reports, feedback details, timestamps, settings polish, app review prompts, and stability fixes",
]

struct WhatsNewSheet: View {
    let version: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        featureList
                        visibilityNote
                    }
                    .padding(24)
                    .padding(.bottom, 140)
                }

                pinnedDismissButton
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's New")
                .font(AppFont.title2(weight: .bold))

            Text("Remodex \(version)")
                .font(AppFont.mono(.subheadline))
                .foregroundStyle(.secondary)

            Text("Here’s what changed in this build.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(whatsNewItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    RemodexIcon.image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    Text(.init(item))
                        .font(AppFont.body())
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibilityNote: some View {
        Text("We'll only show this once for each app version.")
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
    }

    private var pinnedDismissButton: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0),
                    Color(.systemBackground).opacity(0.92),
                    Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 64)
            .allowsHitTesting(false)

            PrimaryCapsuleButton(title: "Got It") {
                onDismiss()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
    }
}
