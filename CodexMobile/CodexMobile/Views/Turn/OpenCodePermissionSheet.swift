// FILE: OpenCodePermissionSheet.swift
// Purpose: Rich OpenCode permission UI — allow now / allow always / deny (D7).
// Layer: View
// Exports: OpenCodePermissionSheet
// Depends on: SwiftUI, OpenCodePermissionRequest

import SwiftUI

struct OpenCodePermissionSheet: View {
    let request: OpenCodePermissionRequest
    let threadTitle: String?
    let isSubmitting: Bool
    let onAllowNow: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let threadTitle, !threadTitle.isEmpty {
                        Label(threadTitle, systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tool")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(request.tool)
                            .font(.headline.monospaced())
                    }

                    if let cwd = request.cwd, !cwd.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Working directory")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(cwd)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if !request.argsSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Details")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(request.argsSummary)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Text("“Allow always” applies for this bridge session until the Mac bridge restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Permission required")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: onAllowNow) {
                        Text("Allow now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)

                    Button(action: onAllowAlways) {
                        Text("Allow always")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)

                    Button(role: .destructive, action: onDeny) {
                        Text("Deny")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                }
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSubmitting)
    }
}