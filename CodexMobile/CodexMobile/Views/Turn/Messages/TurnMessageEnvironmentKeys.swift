// FILE: TurnMessageEnvironmentKeys.swift
// Purpose: SwiftUI environment keys for turn-scoped actions such as reconnect, inline commit/push, assistant revert, and subagent open.
// Layer: View Support
// Exports: EnvironmentValues.reconnectAction, EnvironmentValues.wakeMacDisplayAction, EnvironmentValues.inlineCommitAndPushAction,
//   EnvironmentValues.assistantRevertAction, EnvironmentValues.subagentOpenAction
// Depends on: SwiftUI, CodexMessage

import SwiftUI

private struct ReconnectActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var reconnectAction: (() -> Void)? {
        get { self[ReconnectActionKey.self] }
        set { self[ReconnectActionKey.self] = newValue }
    }
}

private struct WakeMacDisplayActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var wakeMacDisplayAction: (() -> Void)? {
        get { self[WakeMacDisplayActionKey.self] }
        set { self[WakeMacDisplayActionKey.self] = newValue }
    }
}

private struct InlineCommitAndPushActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var inlineCommitAndPushAction: (() -> Void)? {
        get { self[InlineCommitAndPushActionKey.self] }
        set { self[InlineCommitAndPushActionKey.self] = newValue }
    }
}

// Shares the current inline commit/push phase with timeline actions.
private struct InlineCommitAndPushPhaseKey: EnvironmentKey {
    static let defaultValue: InlineCommitAndPushPhase? = nil
}

extension EnvironmentValues {
    var inlineCommitAndPushPhase: InlineCommitAndPushPhase? {
        get { self[InlineCommitAndPushPhaseKey.self] }
        set { self[InlineCommitAndPushPhaseKey.self] = newValue }
    }
}

private struct AssistantRevertActionKey: EnvironmentKey {
    static let defaultValue: ((CodexMessage) -> Void)? = nil
}

extension EnvironmentValues {
    var assistantRevertAction: ((CodexMessage) -> Void)? {
        get { self[AssistantRevertActionKey.self] }
        set { self[AssistantRevertActionKey.self] = newValue }
    }
}

private struct SubagentOpenActionKey: EnvironmentKey {
    static let defaultValue: ((CodexSubagentThreadPresentation) -> Void)? = nil
}

extension EnvironmentValues {
    var subagentOpenAction: ((CodexSubagentThreadPresentation) -> Void)? {
        get { self[SubagentOpenActionKey.self] }
        set { self[SubagentOpenActionKey.self] = newValue }
    }
}
