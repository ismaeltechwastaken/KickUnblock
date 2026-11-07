import Foundation

public struct EmoteDecodeAdmission: Sendable {
    public struct Lease: Sendable {
        public let id: UUID
        public let isNew: Bool
    }
    private struct Entry: Sendable {
        let id: UUID
        let bytes: Int
        var consumers: Set<UUID>
    }
    private let maxConcurrent: Int
    private let maxBytes: Int
    private var entries: [String: Entry] = [:]
    public init(maxConcurrent: Int = 2, maxBytes: Int = 8 * 1024 * 1024) {
        self.maxConcurrent = max(0, maxConcurrent)
        self.maxBytes = max(0, maxBytes)
    }
    public var activeBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    public var activeCount: Int { entries.count }
    public mutating func admit(key: String, bytes: Int, consumer: UUID) -> Lease? {
        if var entry = entries[key] {
            guard !entry.consumers.isEmpty else { return nil }
            entry.consumers.insert(consumer)
            entries[key] = entry
            return Lease(id: entry.id, isNew: false)
        }
        guard bytes >= 0, entries.count < maxConcurrent, bytes <= maxBytes - activeBytes else { return nil }
        let id = UUID()
        entries[key] = Entry(id: id, bytes: bytes, consumers: [consumer])
        return Lease(id: id, isNew: true)
    }
    public mutating func release(key: String, id: UUID, consumer: UUID) -> Bool {
        guard var entry = entries[key], entry.id == id else { return false }
        entry.consumers.remove(consumer)
        entries[key] = entry
        return entry.consumers.isEmpty
    }
    public mutating func finish(key: String, id: UUID) -> Bool {
        guard let entry = entries[key], entry.id == id else { return false }
        entries[key] = nil
        return !entry.consumers.isEmpty
    }
    public mutating func invalidateConsumers() {
        for key in Array(entries.keys) { entries[key]?.consumers.removeAll() }
    }
}

public struct EmoteNegativeCache: Sendable {
    public enum Outcome: Sendable { case confirmedStatic, failure }
    private struct Entry: Sendable { let expires: TimeInterval }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let staticTTL: TimeInterval
    private let failureTTL: TimeInterval
    public init(capacity: Int = 512, staticTTL: TimeInterval = 3600, failureTTL: TimeInterval = 5) {
        self.capacity = max(0, capacity)
        self.staticTTL = staticTTL
        self.failureTTL = failureTTL
    }
    public var count: Int { entries.count }
    public mutating func insert(_ outcome: Outcome, key: String, now: TimeInterval) {
        guard capacity > 0 else { return }
        order.removeAll { $0 == key }
        if entries[key] == nil, entries.count >= capacity, let oldest = order.first {
            entries[oldest] = nil
            order.removeFirst()
        }
        entries[key] = Entry(expires: now + (outcome == .confirmedStatic ? staticTTL : failureTTL))
        order.append(key)
    }
    public mutating func contains(_ key: String, now: TimeInterval) -> Bool {
        guard let entry = entries[key] else { return false }
        guard now < entry.expires else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return false
        }
        return true
    }
    public mutating func removeAll() { entries.removeAll(); order.removeAll() }
}
