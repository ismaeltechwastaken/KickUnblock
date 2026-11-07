import Foundation

public enum LiveRewind {
    public static let edgeSlack: Double = 8
    public static let resumeFromRecordingAfter: Double = 10
    public static let assumedLatency: Double = 4
    public static let liveEdgeSkip = 60

    public static func skipSeconds(preferred: Int, atLiveEdge: Bool, forward: Bool) -> Int {
        let base = max(1, preferred)
        return atLiveEdge && !forward ? max(base, liveEdgeSkip) : base
    }

    public enum Action: Equatable, Sendable {
        case stay
        case goLive
        case seekRecording(Double)
        case loadRecording(Double)
    }

    public static func action(target: Double, liveEdge: Double, inRecording: Bool, recordingEnd: Double?) -> Action {
        guard target.isFinite, liveEdge.isFinite, liveEdge > 0 else { return .stay }
        let t = max(0, target)
        if t >= liveEdge - edgeSlack { return inRecording ? .goLive : .stay }
        if inRecording, let end = recordingEnd, end.isFinite, end > 1 { return t >= end - 1 ? .goLive : .seekRecording(t) }
        return .loadRecording(t)
    }

    public static func skippedPastRecording(from before: Double, to after: Double, recordingEnd end: Double) -> Bool {
        guard before.isFinite, after.isFinite, end.isFinite, before > 0 else { return false }
        return after - before > 3 && after >= end - 1.5
    }

    public static func resumesFromRecording(pausedFor seconds: Double) -> Bool {
        seconds.isFinite && seconds >= resumeFromRecordingAfter
    }

    public static func edgeElapsed(now: Date, startedAt: Date?, latency: Double?) -> Double? {
        guard let startedAt else { return nil }
        let delay = latency.flatMap { $0.isFinite && $0 >= 0 && $0 < 60 ? $0 : nil } ?? assumedLatency
        let elapsed = now.timeIntervalSince(startedAt) - delay
        guard elapsed.isFinite, elapsed > 0, elapsed < 7 * 24 * 3600 else { return nil }
        return elapsed
    }

    public static func recordingURL(in videos: [WebVideo], broadcastID: Int?) -> URL? {
        let live = videos.filter { $0.is_live == true && $0.sourceURL != nil }
        let match = broadcastID.flatMap { id in live.first { $0.id == id } } ?? live.first
        return match?.sourceURL
    }
}
