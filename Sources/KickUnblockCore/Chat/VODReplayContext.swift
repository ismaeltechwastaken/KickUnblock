import Foundation

public struct VODReplayContext: Hashable, Sendable {
    public let channelID: Int
    public let startedAt: Date
    public let duration: TimeInterval

    public init(channelID: Int, startedAt: Date, duration: TimeInterval) throws {
        guard channelID > 0, startedAt.timeIntervalSince1970.isFinite,
              startedAt.timeIntervalSince1970 >= 0, duration.isFinite, duration > 0,
              startedAt.timeIntervalSince1970 + duration < Double(Int64.max / 1_000_000) else {
            throw VODReplayError.invalidContext
        }
        self.channelID = channelID; self.startedAt = startedAt; self.duration = duration
    }

    public func clamped(_ seconds: TimeInterval) throws -> TimeInterval {
        guard seconds.isFinite else { throw VODReplayError.invalidTimestamp }
        return min(duration, max(0, seconds))
    }

    public func cursor(at seconds: TimeInterval) throws -> String {
        let time = startedAt.timeIntervalSince1970 + (try clamped(seconds))
        return String(Int64((time * 1_000_000).rounded(.down)))
    }
}
