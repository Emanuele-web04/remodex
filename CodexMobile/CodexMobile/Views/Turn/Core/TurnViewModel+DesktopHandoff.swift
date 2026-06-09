// FILE: TurnViewModel+DesktopHandoff.swift
// Purpose: Routes desktop handoff to Codex or OpenCode bridge RPCs based on thread provider.
// Layer: View Model
// Exports: TurnViewModel desktop handoff routing
// Depends on: TurnViewModel, CodexService, DesktopHandoffService, CodexThread

import Foundation

extension TurnViewModel {
    enum DesktopHandoffRouteOutcome: Equatable, Sendable {
        case codex
        case opencode(OpenCodeDesktopHandoffResult)
    }

    func continueOnDesktop(
        codex: CodexService,
        thread: CodexThread,
        handoffService: DesktopHandoffService? = nil
    ) async throws -> DesktopHandoffRouteOutcome? {
        guard codex.supportsDesktopHandoffForTurn(threadId: thread.id),
              codex.isDesktopHandoffActionAvailable(forThreadId: thread.id) else {
            return nil
        }

        let service = handoffService ?? DesktopHandoffService(codex: codex)
        let modelProvider = codex.runtimeModelProviderForTurn(threadId: thread.id)
        let directory = thread.gitWorkingDirectory ?? thread.cwd

        if let opencodeResult = try await service.continueOnDesktop(
            threadId: thread.id,
            modelProvider: modelProvider,
            sessionId: nil,
            directory: directory
        ) {
            return .opencode(opencodeResult)
        }

        return .codex
    }

    static func macHandoffConfirmMessage(
        for thread: CodexThread,
        codex: CodexService
    ) -> String {
        let modelProvider = CodexModelOption.normalizedProvider(
            codex.runtimeModelProviderForTurn(threadId: thread.id)
        )

        if modelProvider == "opencode" {
            return "Remodex will open OpenCode on your Mac and try to select this session in the TUI. If the desktop app opens without a deep link, finish in Terminal or the in-app session picker."
        }

        return "Remodex will force close and reopen Codex.app on this device. Any desktop runs in progress will be stopped, and unsaved draft text there may be lost before this chat is opened."
    }
}