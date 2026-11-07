public struct LiveRecoveryPolicy: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var wantsPlayback = false
    public private(set) var attempts = 0
    public private(set) var pending = false
    public private(set) var exhausted = false

    private var progressTime: Double?
    private var progressWall: Double?

    public init() {}
    public mutating func setPlaybackWanted(_ wanted: Bool) {
        wantsPlayback = wanted
        pending = false
        progressTime = nil; progressWall = nil
    }
    public func canRecover(generation: UInt64) -> Bool {
        generation == self.generation && wantsPlayback && pending && !exhausted
    }
    public mutating func noProgress(mediaTime: Double, now: Double, eligible: Bool) -> Bool {
        guard eligible, wantsPlayback, !pending, !exhausted, mediaTime.isFinite, now.isFinite else {
            progressTime = nil; progressWall = nil
            return false
        }
        if let time = progressTime, let wall = progressWall, abs(mediaTime - time) < 0.25 {
            return now - wall >= 20
        }
        progressTime = mediaTime; progressWall = now
        return false
    }
    public mutating func startSession(generation: UInt64) {
        self = Self()
        self.generation = generation
        wantsPlayback = true
    }
    public mutating func beginLoad(generation: UInt64) {
        self.generation = generation
        pending = false
        progressTime = nil; progressWall = nil
    }
    public mutating func request(generation: UInt64) -> Double? {
        guard generation == self.generation, wantsPlayback, !pending, !exhausted else { return nil }
        guard attempts < 3 else { exhausted = true; return nil }
        attempts += 1
        pending = true
        return [0.5, 1, 2][attempts - 1]
    }
}
