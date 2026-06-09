// FILE: OpenCodePermissionPresenter.swift
// Purpose: App-wide OpenCode permission sheet so requests surface outside TurnView.
// Layer: View Modifier
// Exports: openCodePermissionPresenter
// Depends on: SwiftUI, CodexService, OpenCodePermissionSheet

import SwiftUI

private struct OpenCodePermissionPresenterModifier: ViewModifier {
    @Environment(CodexService.self) private var codex
    @State private var presentedPermission: OpenCodePermissionRequest?
    @State private var isSubmitting = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                syncPresentation()
            }
            .onChange(of: pendingPermissionToken) { _, _ in
                syncPresentation()
            }
            .sheet(item: $presentedPermission) { request in
                OpenCodePermissionSheet(
                    request: request,
                    threadTitle: codex.thread(for: request.threadId)?.title,
                    isSubmitting: isSubmitting,
                    onAllowNow: {
                        submitReply(request, allow: true, scope: .once)
                    },
                    onAllowAlways: {
                        submitReply(request, allow: true, scope: .session)
                    },
                    onDeny: {
                        submitReply(request, allow: false, scope: .once)
                    }
                )
            }
    }

    private var pendingPermissionToken: String {
        guard codex.isOpenCodePermissionsUIEnabled else {
            return ""
        }
        return codex.pendingOpenCodePermissions
            .map { "\($0.permissionId):\($0.tool):\($0.threadId)" }
            .joined(separator: "|")
    }

    private func syncPresentation() {
        guard codex.isOpenCodePermissionsUIEnabled else {
            presentedPermission = nil
            return
        }
        presentedPermission = codex.pendingOpenCodePermission()
    }

    private func submitReply(
        _ request: OpenCodePermissionRequest,
        allow: Bool,
        scope: CodexService.OpenCodePermissionReplyScope
    ) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await codex.replyToOpenCodePermission(request, allow: allow, scope: scope)
                syncPresentation()
            } catch {
                codex.lastErrorMessage = error.localizedDescription
                presentedPermission = codex.pendingOpenCodePermission(for: request.threadId) ?? request
            }
        }
    }
}

extension View {
    func openCodePermissionPresenter() -> some View {
        modifier(OpenCodePermissionPresenterModifier())
    }
}