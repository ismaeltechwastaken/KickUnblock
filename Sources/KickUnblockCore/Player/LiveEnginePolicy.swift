import Foundation

public struct LiveRendition: Equatable, Hashable, Sendable {
    public let name: String
    public let bitrate: Int
    public let width: Int
    public let height: Int
    public let framerate: Double
    public init(name: String, bitrate: Int, width: Int, height: Int, framerate: Double) {
        self.name = name; self.bitrate = bitrate; self.width = width; self.height = height; self.framerate = framerate
    }
    public var isAudioOnly: Bool { width == 0 && height == 0 }
}

public enum LiveQualityDecision: Equatable, Sendable {
    case auto
    case manual(LiveRendition)
    case audioOnly(LiveRendition?)
    case pending
}

public enum LiveQualityPolicy {
    public static func initialChoice(storedPreference: String?) -> QualityChoice {
        storedPreference.map(QualityChoice.init(rawValue:)) ?? .auto
    }

    public static func decision(for choice: QualityChoice, qualities: [LiveRendition]) -> LiveQualityDecision {
        let video = qualities.filter { !$0.isAudioOnly }
        switch choice {
        case .auto:
            return .auto
        case .source:
            return video.max { $0.bitrate < $1.bitrate }.map(LiveQualityDecision.manual) ?? .pending
        case .rendition(let label):
            if let exact = video.first(where: { $0.name == label }) { return .manual(exact) }
            let h = choice.requestedHeight ?? .max
            let pick = video.filter { $0.height <= h }.max { $0.bitrate < $1.bitrate } ?? video.min { $0.bitrate < $1.bitrate }
            return pick.map(LiveQualityDecision.manual) ?? .pending
        case .audioOnly:
            guard !qualities.isEmpty else { return .pending }
            return .audioOnly(qualities.filter(\.isAudioOnly).first ?? video.min { $0.bitrate < $1.bitrate })
        }
    }

    public static func pills(for qualities: [LiveRendition]) -> [QualityChoice] {
        let video = qualities.filter { !$0.isAudioOnly }.sorted { $0.bitrate > $1.bitrate }
        guard !video.isEmpty else { return [.auto] }
        var out: [QualityChoice] = [.auto]
        for (i, q) in video.enumerated() {
            let c: QualityChoice = i == 0 ? .source : .rendition(q.name)
            if !out.contains(c) { out.append(c) }
        }
        out.append(.audioOnly)
        return out
    }

    public static func pillLabel(_ choice: QualityChoice, qualities: [LiveRendition]) -> String {
        if choice == .source, let top = qualities.filter({ !$0.isAudioOnly }).max(by: { $0.bitrate < $1.bitrate }) {
            return "Source (\(top.name))"
        }
        return choice.label
    }
}

public enum LiveEdgePolicy {
    public static func rebufferToLive(userRewound: Bool) -> Bool { !userRewound }

    public static func measuredDelay(_ seconds: Double?) -> Double? {
        guard let s = seconds, s.isFinite, s >= 0 else { return nil }
        return (s * 10).rounded() / 10
    }

    public static func isBehind(userRewound: Bool, delay: Double?, baseline: Double?) -> Bool {
        if userRewound { return true }
        guard let delay, let baseline else { return false }
        return delay - baseline > 6
    }
}

public enum LiveEngine: Equatable, Sendable {
    case ivs
    case airPlayHandoff
    case avPlayerFallback
    case recording
}

public enum LiveEnginePolicy {
    public static func engine(sdkAvailable: Bool, airPlayActive: Bool) -> LiveEngine {
        guard sdkAvailable else { return .avPlayerFallback }
        return airPlayActive ? .airPlayHandoff : .ivs
    }
}
