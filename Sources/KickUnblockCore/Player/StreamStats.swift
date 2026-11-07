import Foundation

public struct StreamStats: Equatable, Sendable {
    public var width: Int = 0
    public var height: Int = 0
    public var fps: Double?
    public var observedBitrate: Double?
    public var indicatedBitrate: Double?
    public var bufferAhead: Double = 0
    public var droppedFrames: Int = 0
    public var stalls: Int = 0
    public var liveLatency: Double?
    public init() {}

    public var latencyText: String? { liveLatency.map { String(format: "Latency %.1fs", max(0, $0)) } }

    public var resolutionText: String { width > 0 ? "\(width)×\(height)" : "audio" }
    public var fpsText: String { fps.map { String(format: "%.0f fps", $0) } ?? "– fps" }
    public var bitrateText: String { Self.rate(indicatedBitrate ?? observedBitrate) }
    public var bufferText: String { String(format: "%.1fs", bufferAhead) }

    public static func rate(_ bps: Double?) -> String {
        guard let b = bps, b > 0, b.isFinite else { return "– Mbps" }
        return b >= 1_000_000 ? String(format: "%.1f Mbps", b / 1_000_000) : "\(Int((b / 1000).rounded())) kbps"
    }

    public static func bufferAhead(ranges: [(start: Double, duration: Double)], current: Double) -> Double {
        for r in ranges where current >= r.start - 0.1 && current <= r.start + r.duration {
            return max(0, r.start + r.duration - current)
        }
        return 0
    }

    public enum Health: Sendable { case good, fair, poor }
    public var health: Health { bufferAhead >= 3 ? .good : (bufferAhead >= 1 ? .fair : .poor) }
}
