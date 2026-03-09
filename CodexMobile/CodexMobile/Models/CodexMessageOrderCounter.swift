// FILE: CodexMessageOrderCounter.swift
// Purpose: Thread-safe monotonically increasing counter for message ordering.
// Layer: Model
// Exports: CodexMessageOrderCounter
// Depends on: Foundation

import Foundation
import os

/// Provides a globally unique, monotonically increasing order index for CodexMessage.
/// This ensures messages are always displayed in the order they were created/received,
/// regardless of wall-clock timestamp drift between device and server.
enum CodexMessageOrderCounter {
    private nonisolated(unsafe) static var counter: Int = 0
    private static let lock = NSLock()

    /// Returns the next order index, incrementing the global counter atomically.
    static func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = counter
        counter += 1
        return value
    }

    /// Seeds the counter so new messages always sort after existing persisted ones.
    /// Call this once after loading messages from disk.
    static func seed(from allMessages: [String: [CodexMessage]]) {
        let maxExisting = allMessages.values.flatMap { $0 }.map(\.orderIndex).max() ?? -1
        lock.lock()
        defer { lock.unlock() }
        if maxExisting >= counter {
            counter = maxExisting + 1
        }
    }
}
