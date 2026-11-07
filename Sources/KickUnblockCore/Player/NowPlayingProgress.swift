public struct NowPlayingProgress: Equatable, Sendable {
    public let rate: Double
    public let elapsed: Double?
    public let duration: Double?

    public init(isLive: Bool, advancing: Bool, playbackAllowed: Bool,
                engineRate: Double, position: Double, duration: Double?) {
        rate = advancing && playbackAllowed && engineRate.isFinite && engineRate > 0 ? engineRate : 0
        self.duration = !isLive ? duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil
        elapsed = !isLive && position.isFinite && position >= 0 ? min(position, self.duration ?? position) : nil
    }
}
