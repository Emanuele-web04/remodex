// FILE: CodexSyntheticIdentifiers.swift
// Purpose: Single source for the synthetic identifier families minted by mirrors and live streams instead of the runtime.
// Layer: Model
// Exports: CodexSyntheticIdentifiers
// Depends on: Foundation

import Foundation

// Identifier families that do NOT come from the runtime:
// - "turn:<turnId>|kind:<kind>"  streaming placeholders minted before a real item id exists
// - "rollout-<kind>:<thread>:<turn>"  rollout-mirror synthesized items
// - "ipc-turn-<index>"  Desktop-snapshot turns projected without a raw turn id
// - "<turnId>:input"  Desktop-projected user prompt items
// All of them are provisional: rows carrying them must merge with (and upgrade
// to) the real runtime identity of the same content instead of duplicating it.
nonisolated enum CodexSyntheticIdentifiers {
    /// True for item ids minted by any mirror/stream (placeholder, rollout, or
    /// the local JSONL reader when the provider omitted an item id).
    static func isMirrorMintedItemID(_ itemId: String) -> Bool {
        itemId.hasPrefix("turn:")
            || itemId.hasPrefix("rollout-")
            || itemId.hasPrefix("remodex-jsonl-")
            || itemId.hasPrefix("user-message-line-")
            || itemId.hasPrefix("response-item-line-")
            || itemId.hasPrefix("apply-patch-line-")
            || isProjectedDesktopUserItemID(itemId)
    }

    /// Source-line fallbacks are unique only inside one rollout file. Equal
    /// values from another snapshot need semantic proof before reconciliation.
    static func isJSONLLineFallbackItemID(_ itemId: String) -> Bool {
        itemId.hasPrefix("user-message-line-")
            || itemId.hasPrefix("response-item-line-")
            || itemId.hasPrefix("apply-patch-line-")
    }

    /// True only for rollout-mirror synthesized item ids.
    static func isRolloutMintedItemID(_ itemId: String) -> Bool {
        itemId.hasPrefix("rollout-")
    }

    /// True for the streaming placeholder id of one specific message kind
    /// ("turn:<id>|kind:<kind>"); other kinds' placeholders stay distinct.
    static func isPlaceholderItemID(_ itemId: String, kind: CodexMessageKind) -> Bool {
        itemId.hasPrefix("turn:") && itemId.contains("|kind:\(kind.rawValue)")
    }

    /// Mints the streaming placeholder item id for a turn+kind pair;
    /// `isPlaceholderItemID` must accept exactly what this produces.
    static func placeholderItemID(turnId: String, kind: CodexMessageKind) -> String {
        "turn:\(turnId)|kind:\(kind.rawValue)"
    }

    /// True for placeholder TURN ids the bridge synthesizes ("turn-line-<n>"
    /// from the JSONL history fallback, "rollout-…" from the rollout live
    /// mirror, the history-compaction marker); they group rows and keep
    /// running state visible but are not actionable app-server turn ids.
    static func isBridgeMintedTurnID(_ turnId: String) -> Bool {
        turnId.hasPrefix("turn-line-")
            || turnId.hasPrefix("rollout-")
            || isHistoryCompactionMarkerTurnID(turnId)
    }

    /// True for the banner turn the bridge injects into trimmed thread/read
    /// payloads ("remodex-history-compacted-<id>"). It is a marker, not a real
    /// turn: it must never drive running/interruptible state on the phone.
    static func isHistoryCompactionMarkerTurnID(_ turnId: String) -> Bool {
        turnId.hasPrefix("remodex-history-compacted-")
    }

    /// True for item ids that can ONLY belong to a turn's cumulative
    /// file-change aggregate row: the live streaming placeholder and the
    /// bridge's JSONL turn aggregate ("remodex-jsonl-file-change-<turnId>",
    /// bridge.js). Positive-only signal: aggregates often ADOPT real item ids
    /// mid-turn or via history merge, so a `false` here proves nothing.
    static func isCumulativeFileChangeAggregateItemID(_ itemId: String) -> Bool {
        isPlaceholderItemID(itemId, kind: .fileChange)
            || itemId.hasPrefix("remodex-jsonl-file-change-")
    }

    /// True for turn ids the Desktop projector synthesized from array indices.
    static func isProjectedDesktopTurnID(_ turnId: String) -> Bool {
        turnId.hasPrefix("ipc-turn-")
    }

    /// Mints an in-memory turn identity for runtimes that announce a running
    /// turn before they expose its canonical id. The `ipc-turn-` family keeps
    /// history reconciliation and terminal-state persistence provisional.
    static func provisionalIDLessTurnID() -> String {
        "ipc-turn-idless-\(UUID().uuidString.lowercased())"
    }

    /// True for the Desktop projector's synthetic user prompt item ids.
    static func isProjectedDesktopUserItemID(_ itemId: String) -> Bool {
        itemId.hasSuffix(":input")
    }
}
