// FILE: SideConversationSheet.swift
// Purpose: Presents and safely dismisses a native ephemeral `/side` conversation.
// Layer: View Support
// Exports: SideConversationSheet
// Depends on: SwiftUI, TurnView, CodexService

import SwiftUI

struct SideConversationSheet: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss

    let presentation: CodexSideConversationPresentation

    @State private var isClosing = false
    @State private var closeErrorMessage: String?
    @State private var hasFinishedPresentation = false

    var body: some View {
        NavigationStack {
            TurnView(
                thread: presentation.thread,
                isWakingMacDisplayRecovery: false,
                isSideConversation: true,
                initialSidePrompt: presentation.initialPrompt
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                sideContextBar
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        closeSideConversation()
                    } label: {
                        if isClosing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "xmark")
                                .font(AppFont.system(size: 13, weight: .semibold))
                        }
                    }
                    .disabled(isClosing)
                    .accessibilityLabel(isClosing ? "Closing side conversation" : "Close side conversation")
                }
            }
        }
        .interactiveDismissDisabled(true)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .overlay {
            if runtimeState == .recovering {
                recoveryOverlay
            }
        }
        .task(id: runtimeState) {
            guard case .unavailable(let message) = runtimeState else { return }
            await Task.yield()
            finishPresentation(message: message)
        }
    }

    private var runtimeState: CodexSideConversationRuntimeState {
        codex.sideConversationRuntimeState(for: presentation.thread.id)
    }

    private var sideContextBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: parentStatus.symbolName)
                    .font(AppFont.system(size: 13, weight: .semibold))
                    .foregroundStyle(parentStatus.tint)
                    .frame(width: 26, height: 26)
                    .background(parentStatus.tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("From main conversation")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(parentStatus.label)
                        .font(AppFont.caption2())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("Temporary")
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let closeErrorMessage {
                Text(closeErrorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()
        }
        .background(.ultraThinMaterial)
    }

    private var parentStatus: SideConversationParentStatus {
        let parentThreadID = presentation.parentThreadID
        if codex.pendingApprovals.contains(where: { $0.threadId == parentThreadID }) {
            return .needsApproval
        }
        if codex.messages(for: parentThreadID).contains(where: { $0.structuredUserInputRequest != nil }) {
            return .needsInput
        }
        if codex.threadHasActiveOrRunningTurn(parentThreadID) {
            return .working
        }
        if let terminalState = codex.latestTurnTerminalState(for: parentThreadID) {
            switch terminalState {
            case .completed:
                return .finished
            case .failed:
                return .failed
            case .stopped:
                return .stopped
            }
        }
        if codex.goalByThreadID[parentThreadID]?.status == .active {
            return .working
        }
        return codex.isConnected ? .available : .disconnected
    }

    private func closeSideConversation() {
        guard !isClosing else { return }
        isClosing = true
        closeErrorMessage = nil

        Task { @MainActor in
            do {
                try await codex.closeSideConversation(threadID: presentation.thread.id)
                finishPresentation()
            } catch {
                closeErrorMessage = codex.userFacingTurnErrorMessageForFooter(from: error)
                    ?? error.localizedDescription
                isClosing = false
            }
        }
    }

    private var recoveryOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reconnecting side conversation...")
                .font(AppFont.subheadline(weight: .semibold))
            Text("The main conversation is still safe.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.08))
        .contentShape(Rectangle())
    }

    private func finishPresentation(message: String? = nil) {
        guard !hasFinishedPresentation else { return }
        hasFinishedPresentation = true

        if let message {
            codex.lastErrorMessage = message
        }
        codex.acknowledgeSideConversationDismissal(threadID: presentation.thread.id)
        codex.activeThreadId = presentation.parentThreadID
        codex.activeTurnId = codex.activeTurnID(for: presentation.parentThreadID)
        codex.markThreadAsViewed(presentation.parentThreadID)
        if codex.isConnected {
            codex.requestImmediateActiveThreadSync(
                threadId: presentation.parentThreadID,
                forceHistoryRefresh: true
            )
        }
        dismiss()
    }
}

private enum SideConversationParentStatus {
    case working
    case needsInput
    case needsApproval
    case finished
    case failed
    case stopped
    case available
    case disconnected

    var label: String {
        switch self {
        case .working: "Main is working"
        case .needsInput: "Main needs input"
        case .needsApproval: "Main needs approval"
        case .finished: "Main finished"
        case .failed: "Main failed"
        case .stopped: "Main stopped"
        case .available: "Main is available"
        case .disconnected: "Main is disconnected"
        }
    }

    var symbolName: String {
        switch self {
        case .working: "sparkles"
        case .needsInput: "questionmark.bubble"
        case .needsApproval: "exclamationmark.shield"
        case .finished: "checkmark"
        case .failed: "xmark"
        case .stopped: "stop.fill"
        case .available: "circle.fill"
        case .disconnected: "wifi.slash"
        }
    }

    var tint: Color {
        switch self {
        case .working: .blue
        case .needsInput, .needsApproval: .orange
        case .finished, .available: .green
        case .failed: .red
        case .stopped, .disconnected: .secondary
        }
    }
}
