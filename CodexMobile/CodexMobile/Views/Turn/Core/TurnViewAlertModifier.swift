// FILE: TurnViewAlertModifier.swift
// Purpose: Centralizes TurnView approval + git alerts so TurnView stays focused on orchestration.
// Layer: View Modifier
// Exports: turnViewAlerts
// Depends on: SwiftUI, CodexApprovalRequest, GitActionModels

import SwiftUI

private struct TurnViewAlertModifier: ViewModifier {
    @Binding var alertApprovalRequest: CodexApprovalRequest?
    @Binding var isApprovalAlertPresented: Bool
    @Binding var isShowingNothingToCommitAlert: Bool
    @Binding var gitSyncAlert: TurnGitSyncAlert?
    @Binding var isShowingMacHandoffConfirm: Bool
    let macHandoffConfirmMessage: String
    @Binding var macHandoffErrorMessage: String?
    @Binding var macHandoffSuccessMessage: String?

    let onDeclineApproval: (CodexApprovalRequest) -> Void
    let onApproveApproval: (CodexApprovalRequest) -> Void
    let onConfirmGitSyncAction: (TurnGitSyncAlertAction) -> Void
    let onDismissGitSyncAlert: () -> Void
    let onConfirmMacHandoff: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Approval request",
                isPresented: $isApprovalAlertPresented,
                presenting: alertApprovalRequest
            ) { request in
                Button("Decline", role: .destructive) {
                    onDeclineApproval(request)
                }
                Button("Approve") {
                    onApproveApproval(request)
                }
            } message: { request in
                Text(approvalAlertMessage(for: request))
            }
            .alert("Nothing to Commit", isPresented: $isShowingNothingToCommitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("There are no changes to commit.")
            }
            .alert(
                gitSyncAlert?.title ?? "Git",
                isPresented: gitSyncAlertIsPresented,
                presenting: gitSyncAlert
            ) { alert in
                // Renders alert buttons from the shared model so new Git prompts do not add more switch cases here.
                ForEach(alert.buttons) { alertButton in
                    Button(alertButton.title, role: buttonRole(for: alertButton.role)) {
                        let action = alertButton.action
                        if action == .dismissOnly {
                            onDismissGitSyncAlert()
                        } else {
                            onConfirmGitSyncAction(action)
                        }
                    }
                }
            } message: { alert in
                Text(alert.message)
            }
            .alert("Continue on Desktop", isPresented: $isShowingMacHandoffConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Continue") {
                    onConfirmMacHandoff()
                }
            } message: {
                Text(macHandoffConfirmMessage)
            }
            .alert(
                "Continued on Mac",
                isPresented: macHandoffSuccessIsPresented
            ) {
                Button("OK", role: .cancel) {
                    macHandoffSuccessMessage = nil
                }
            } message: {
                Text(macHandoffSuccessMessage ?? "OpenCode handoff completed on your Mac.")
            }
            .alert(
                "Couldn't continue on desktop app",
                isPresented: macHandoffErrorIsPresented
            ) {
                Button("OK", role: .cancel) {
                    macHandoffErrorMessage = nil
                }
            } message: {
                Text(macHandoffErrorMessage ?? "Could not continue this chat on the desktop app.")
            }
    }

    private var gitSyncAlertIsPresented: Binding<Bool> {
        Binding(
            get: { gitSyncAlert != nil },
            set: { isPresented in
                if !isPresented {
                    onDismissGitSyncAlert()
                }
            }
        )
    }

    private var macHandoffErrorIsPresented: Binding<Bool> {
        Binding(
            get: { macHandoffErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    macHandoffErrorMessage = nil
                }
            }
        )
    }

    private var macHandoffSuccessIsPresented: Binding<Bool> {
        Binding(
            get: { macHandoffSuccessMessage != nil },
            set: { isPresented in
                if !isPresented {
                    macHandoffSuccessMessage = nil
                }
            }
        )
    }

    private func approvalAlertMessage(for request: CodexApprovalRequest) -> String {
        var lines: [String] = []

        if let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            lines.append(reason)
        }

        if let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            lines.append("Command: \(command)")
        }

        if lines.isEmpty {
            return "Codex is requesting permission to continue."
        }

        return lines.joined(separator: "\n\n")
    }

    private func buttonRole(for role: TurnGitSyncAlertButtonRole?) -> ButtonRole? {
        switch role {
        case .cancel:
            return .cancel
        case .destructive:
            return .destructive
        case nil:
            return nil
        }
    }
}

extension View {
    func turnViewAlerts(
        alertApprovalRequest: Binding<CodexApprovalRequest?>,
        isApprovalAlertPresented: Binding<Bool>,
        isShowingNothingToCommitAlert: Binding<Bool>,
        gitSyncAlert: Binding<TurnGitSyncAlert?>,
        isShowingMacHandoffConfirm: Binding<Bool>,
        macHandoffConfirmMessage: String,
        macHandoffErrorMessage: Binding<String?>,
        macHandoffSuccessMessage: Binding<String?>,
        onDeclineApproval: @escaping (CodexApprovalRequest) -> Void,
        onApproveApproval: @escaping (CodexApprovalRequest) -> Void,
        onConfirmGitSyncAction: @escaping (TurnGitSyncAlertAction) -> Void,
        onDismissGitSyncAlert: @escaping () -> Void,
        onConfirmMacHandoff: @escaping () -> Void
    ) -> some View {
        modifier(
            TurnViewAlertModifier(
                alertApprovalRequest: alertApprovalRequest,
                isApprovalAlertPresented: isApprovalAlertPresented,
                isShowingNothingToCommitAlert: isShowingNothingToCommitAlert,
                gitSyncAlert: gitSyncAlert,
                isShowingMacHandoffConfirm: isShowingMacHandoffConfirm,
                macHandoffConfirmMessage: macHandoffConfirmMessage,
                macHandoffErrorMessage: macHandoffErrorMessage,
                macHandoffSuccessMessage: macHandoffSuccessMessage,
                onDeclineApproval: onDeclineApproval,
                onApproveApproval: onApproveApproval,
                onConfirmGitSyncAction: onConfirmGitSyncAction,
                onDismissGitSyncAlert: onDismissGitSyncAlert,
                onConfirmMacHandoff: onConfirmMacHandoff
            )
        )
    }
}
