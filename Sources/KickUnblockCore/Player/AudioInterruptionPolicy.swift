public struct AudioInterruptionPolicy: Sendable {
    public private(set) var isInterrupted = false
    private var wasPlaybackWanted = false
    public init() {}
    public mutating func begin(wantsPlayback: Bool) {
        if !isInterrupted { wasPlaybackWanted = wantsPlayback }
        isInterrupted = true
    }
    public mutating func end(shouldResume: Bool, wantsPlayback: Bool) -> Bool {
        guard isInterrupted else { return false }
        isInterrupted = false
        defer { wasPlaybackWanted = false }
        return shouldResume && wasPlaybackWanted && wantsPlayback
    }
    public mutating func reset() { self = Self() }
}
