import Foundation

public struct ScrubRange: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var length: Double { max(0, end - start) }
    public func clamp(_ t: Double) -> Double { min(max(t, start), end) }
    public func fraction(_ t: Double) -> Double { length > 0 ? (clamp(t) - start) / length : 0 }
    public func time(atFraction f: Double) -> Double { start + min(max(f, 0), 1) * length }
}

public enum ScrubTimeline {
    public static func range(isLive: Bool, itemDuration: Double?, seekable: [(start: Double, duration: Double)],
                             knownDuration: Double?) -> ScrubRange? {
        func ok(_ d: Double?) -> Double? { d.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        if isLive {
            guard let last = seekable.last, let d = ok(last.duration), last.start.isFinite else { return nil }
            return ScrubRange(start: last.start, end: last.start + d)
        }
        if let d = ok(itemDuration) { return ScrubRange(start: 0, end: d) }
        if let last = seekable.last, let end = ok(last.start + last.duration) { return ScrubRange(start: 0, end: end) }
        if let d = ok(knownDuration) { return ScrubRange(start: 0, end: d) }
        return nil
    }
}

public enum SleepTimerOption: String, CaseIterable, Identifiable, Sendable {
    case off, m15, m30, m45, m60, endOfVideo
    public var id: String { rawValue }
    public var minutes: Int? {
        switch self { case .m15: 15; case .m30: 30; case .m45: 45; case .m60: 60; default: nil }
    }
    public var label: String {
        switch self {
        case .off: "Off"
        case .endOfVideo: "End of VOD"
        default: "\(minutes!) min"
        }
    }
    public static func options(isLive: Bool) -> [SleepTimerOption] { isLive ? allCases.filter { $0 != .endOfVideo } : allCases }
    public func fireDate(from now: Date) -> Date? { minutes.map { now.addingTimeInterval(Double($0) * 60) } }
}

public enum LiveEdge {
    public static let tolerance: Double = 5
    public static func isBehind(current: Double, range: ScrubRange?, holdback: Double) -> Bool {
        guard let r = range, holdback.isFinite, current.isFinite else { return false }
        return r.end - current > holdback + tolerance
    }
    public static func showsScrubBar(_ range: ScrubRange?) -> Bool {
        guard let r = range, r.start.isFinite, r.end.isFinite else { return false }
        let length = r.end - r.start
        return length.isFinite && length > 0
    }
}

public enum PlayerClock {
    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let t = Int(min(seconds, 359_999)), h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

public enum SeekSymbol {
    private static let numbered: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
    public static func name(forward: Bool, seconds: Int) -> String {
        let base = forward ? "goforward" : "gobackward"
        return numbered.contains(seconds) ? "\(base).\(seconds)" : base
    }
}
