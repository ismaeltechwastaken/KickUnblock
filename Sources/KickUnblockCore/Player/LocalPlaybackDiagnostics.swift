import Foundation

public struct LocalPlaybackDiagnostics: Sendable {
    public enum EventKind: String, Codable, Sendable {
        case playing, paused, seeking, seekCompleted, retrying, failed, liveLatency
    }
    public struct Event: Codable, Equatable, Sendable {
        public let kind: EventKind
        public let seconds: Double?
    }
    public private(set) var events: [Event] = []
    public private(set) var isEnabled = false
    public init() {}
    public func exportJSON() throws -> Data {
        struct Export: Encodable { let schemaVersion = 1; let events: [Event] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(events: events))
    }
    public mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { events.removeAll(keepingCapacity: false) }
    }
    public mutating func record(_ kind: EventKind, seconds: Double? = nil) {
        guard isEnabled else { return }
        let safeSeconds = seconds.flatMap { $0.isFinite && (0...86_400).contains($0) ? $0 : nil }
        events.append(Event(kind: kind, seconds: safeSeconds))
        if events.count > 120 { events.removeFirst(events.count - 120) }
    }
}
