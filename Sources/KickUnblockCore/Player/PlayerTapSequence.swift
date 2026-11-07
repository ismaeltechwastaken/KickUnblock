import Foundation

public struct PlayerTapSequence: Sendable {
    public enum Zone: Sendable, Equatable { case leading, trailing }
    public enum Action: Sendable, Equatable {
        case toggleControls
        case seek(revertToggle: Bool)
    }

    public static let window: TimeInterval = 0.3

    private var lastTap: (zone: Zone, time: TimeInterval)?
    private var seeking = false

    public init() {}

    public mutating func tap(zone: Zone, at time: TimeInterval, canSeek: Bool = true) -> Action {
        defer { lastTap = (zone, time) }
        guard canSeek, let last = lastTap, last.zone == zone, time - last.time <= Self.window else {
            seeking = false
            return .toggleControls
        }
        let revert = !seeking
        seeking = true
        return .seek(revertToggle: revert)
    }
}
