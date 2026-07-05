// FILE: BridgeUpdateSheet.swift
// Purpose: Presents a guided recovery flow when the computer bridge package needs an update.
// Layer: View
// Exports: BridgeUpdateSheet
// Depends on: SwiftUI, UIKit, CodexBridgeUpdatePrompt

import SwiftUI
import UIKit

struct BridgeUpdateSheet: View {
    let prompt: CodexBridgeUpdatePrompt
    let isRetrying: Bool
    let onRetry: () -> Void
    let onScanNewQR: () -> Void
    let onDismiss: () -> Void

    @State private var didCopyCommand = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        updateInstructions

                        Text(prompt.command == nil
                            ? "After the app finishes updating on your iPhone, reconnect to the device bridge."
                            : "After the package finishes updating, restart the bridge on your device and come back here."
                        )
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                }

                actionButtons
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.title)
                .font(AppFont.title3(weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(prompt.message)
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Keeps long bridge-version copy scrollable while the recovery actions stay reachable.
    @ViewBuilder
    private var updateInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = prompt.command, !command.isEmpty {
                Text("Run this on your device")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 12) {
                    Text(command)
                        .font(AppFont.mono(.subheadline))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    Button {
                        UIPasteboard.general.string = command
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            didCopyCommand = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                didCopyCommand = false
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            RemodexIcon.image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc", size: 13, weight: .semibold)
                            Text(didCopyCommand ? "Copied" : "Copy")
                                .font(AppFont.caption(weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy bridge update command")
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.tertiarySystemFill).opacity(0.75))
                )
            } else {
                Text("Install the latest Remodex build on this iPhone, then come back here and reconnect.")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: onRetry) {
                HStack(spacing: 8) {
                    if isRetrying {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isRetrying ? "Reconnecting..." : "I Updated It")
                        .font(AppFont.body(weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)

            Button("Scan New QR Code", action: onScanNewQR)
                .font(AppFont.body(weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                )
                .buttonStyle(.plain)

            Button("Not Now", role: .cancel, action: onDismiss)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
    }
}
