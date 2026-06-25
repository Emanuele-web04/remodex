// FILE: TurnSlashHostContext.swift
// Purpose: Host callbacks and services for centralized slash-command tap routing (PR5a).
// Layer: View Support
// Exports: TurnSlashHostContext
// Depends on: CodexService, CodexThread, TurnComposer command models

import Foundation

struct TurnSlashHostContext {
    let codex: CodexService
    let thread: CodexThread
    let availableForkDestinations: [TurnComposerForkDestination]
    let onShowStatus: () -> Void
    let onOpenFeedbackMail: () -> Void
}