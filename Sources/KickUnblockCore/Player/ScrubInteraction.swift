import Foundation

public struct ScrubInteraction: Equatable, Sendable {
    public struct Selection: Equatable, Sendable {
        public let id: UInt64
        public let time: Double
    }
    public private(set) var snapshot: ScrubRange?
    public private(set) var previewTime: Double?
    public private(set) var isDragging = false
    public private(set) var isSeeking = false
    private var generation: UInt64 = 0
    public var isInteracting: Bool { isDragging || isSeeking }
    public init() {}

    public mutating func update(fraction: Double, range: ScrubRange) {
        guard fraction.isFinite else { return }
        if !isDragging {
            generation &+= 1
            snapshot = range
            isDragging = true
            isSeeking = false
        }
        previewTime = snapshot?.time(atFraction: fraction)
    }

    public mutating func release(fraction: Double, latestRange: ScrubRange) -> Selection? {
        guard isDragging, fraction.isFinite, let snapshot else { return nil }
        let t = latestRange.clamp(snapshot.time(atFraction: fraction))
        previewTime = t
        isDragging = false
        isSeeking = true
        return Selection(id: generation, time: t)
    }

    public mutating func beginSeek(to time: Double, range: ScrubRange?) -> UInt64 {
        generation &+= 1
        snapshot = range
        previewTime = time
        isDragging = false
        isSeeking = true
        return generation
    }

    public mutating func complete(_ id: UInt64) {
        guard generation == id, isSeeking else { return }
        reset()
    }
    public mutating func cancelDrag() {
        if isDragging { reset() }
    }
    public mutating func reset() {
        generation &+= 1
        snapshot = nil; previewTime = nil; isDragging = false; isSeeking = false
    }
}

public struct LivePlaybackClock: Equatable, Sendable {
    public let mediaTime: Double
    public let wallTime: TimeInterval
    public init(mediaTime: Double, wallTime: TimeInterval) {
        self.mediaTime = mediaTime; self.wallTime = wallTime
    }
    public func position(at now: TimeInterval) -> Double { mediaTime + max(0, now - wallTime) }
}

