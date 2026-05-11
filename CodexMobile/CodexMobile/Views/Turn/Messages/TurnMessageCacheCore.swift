// FILE: TurnMessageCacheCore.swift
// Purpose: Shared bounded-cache and text-key primitives for timeline render caches.
// Layer: View Support
// Exports: BoundedCache, TurnTextCacheKey
// Depends on: Foundation

import Foundation

// Thread-safe bounded cache that evicts roughly half its entries when full instead of discarding everything.
final class BoundedCache<Key: Hashable, Value> {
    private let maxEntries: Int
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]
    private var accessRankByKey: [Key: UInt64] = [:]
    private var nextAccessRank: UInt64 = 0

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    func set(_ key: Key, value: Value) {
        lock.lock()
        if storage[key] == nil {
            evictIfNeeded()
        }
        storage[key] = value
        markRecentlyUsed(key)
        lock.unlock()
    }

    func getOrSet(_ key: Key, builder: () -> Value) -> Value {
        lock.lock()
        if let cached = storage[key] {
            markRecentlyUsed(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = builder()

        lock.lock()
        if storage[key] == nil {
            evictIfNeeded()
        }
        storage[key] = built
        markRecentlyUsed(key)
        lock.unlock()

        return built
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        accessRankByKey.removeAll(keepingCapacity: false)
        nextAccessRank = 0
        lock.unlock()
    }

    private func evictIfNeeded() {
        guard storage.count >= maxEntries else { return }
        let evictCount = max(maxEntries / 2, 1)
        let keysToRemove = accessRankByKey
            .sorted { $0.value < $1.value }
            .prefix(evictCount)
            .map(\.key)
        for key in keysToRemove {
            storage.removeValue(forKey: key)
            accessRankByKey.removeValue(forKey: key)
        }
    }

    private func markRecentlyUsed(_ key: Key) {
        nextAccessRank &+= 1
        accessRankByKey[key] = nextAccessRank
        if nextAccessRank == .max {
            compactAccessRanks()
        }
    }

    private func compactAccessRanks() {
        let orderedKeys = accessRankByKey
            .sorted { $0.value < $1.value }
            .map(\.key)
        accessRankByKey.removeAll(keepingCapacity: true)
        nextAccessRank = 0
        for key in orderedKeys where storage[key] != nil {
            nextAccessRank &+= 1
            accessRankByKey[key] = nextAccessRank
        }
    }
}

enum TurnTextCacheKey {
    private static let sampleByteCount = 24
    private static let hexDigits = Array("0123456789abcdef")

    static func fingerprint(for text: String) -> String {
        let utf8 = text.utf8
        let byteCount = utf8.count
        let middleStart = max((byteCount / 2) - (sampleByteCount / 2), 0)
        let lastStart = max(byteCount - sampleByteCount, 0)

        return [
            String(byteCount),
            hexSample(in: utf8, startOffset: 0, length: sampleByteCount),
            hexSample(in: utf8, startOffset: middleStart, length: sampleByteCount),
            hexSample(in: utf8, startOffset: lastStart, length: sampleByteCount),
        ].joined(separator: "|")
    }

    static func key(messageID: String, kind: String, text: String) -> String {
        "\(messageID)|\(kind)|\(fingerprint(for: text))"
    }

    static func key(namespace: String, text: String) -> String {
        "\(namespace)|\(fingerprint(for: text))"
    }

    static func stableFingerprint(for text: String) -> String {
        let byteCount = text.utf8.count
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(byteCount)|\(String(hash, radix: 16))"
    }

    static func stableKey(namespace: String, text: String) -> String {
        "\(namespace)|\(stableFingerprint(for: text))"
    }

    static func entriesFingerprint(_ entries: [TurnFileChangeSummaryEntry]) -> String {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.path)
            hasher.combine(entry.action)
            hasher.combine(entry.additions)
            hasher.combine(entry.deletions)
        }
        return String(hasher.finalize())
    }

    private static func hexSample(
        in utf8: String.UTF8View,
        startOffset: Int,
        length: Int
    ) -> String {
        guard !utf8.isEmpty else { return "" }

        let clampedLength = min(length, utf8.count)
        let clampedStart = min(max(startOffset, 0), max(utf8.count - clampedLength, 0))
        let startIndex = utf8.index(utf8.startIndex, offsetBy: clampedStart)
        let endIndex = utf8.index(startIndex, offsetBy: clampedLength)

        var result = String()
        result.reserveCapacity(clampedLength * 2)

        for byte in utf8[startIndex..<endIndex] {
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0F)])
        }

        return result
    }
}
