import Foundation

public struct LiveCallbackContext: Equatable, Sendable {
    public let engineIsIVS: Bool
    public let boundGeneration: UInt64?
    public let currentGeneration: UInt64
    public let expectedPath: URL?
    public let playerPath: URL?
    public init(engineIsIVS: Bool, boundGeneration: UInt64?, currentGeneration: UInt64, expectedPath: URL?, playerPath: URL?) {
        self.engineIsIVS = engineIsIVS; self.boundGeneration = boundGeneration; self.currentGeneration = currentGeneration
        self.expectedPath = expectedPath; self.playerPath = playerPath
    }
}

public enum LiveCallbackEvent: Equatable, Sendable {
    case benignState
    case endedState(playerStillEnded: Bool)
    case error(playerHasError: Bool)
    case quality(matchesPlayer: Bool)
    case rebuffer
}

public enum LiveCallbackGate {
    public static func accepts(_ event: LiveCallbackEvent, _ c: LiveCallbackContext) -> Bool {
        guard c.engineIsIVS, let bound = c.boundGeneration, bound == c.currentGeneration else { return false }
        let samePath = c.expectedPath != nil && c.playerPath == c.expectedPath
        switch event {
        case .benignState, .rebuffer: return true
        case .endedState(let still): return samePath && still
        case .error(let has): return samePath && has
        case .quality(let matches): return samePath && matches
        }
    }
}

extension LiveQualityPolicy {
    public static func needsFixedQuality(current: LiveRendition?, target: LiveRendition, autoMode: Bool) -> Bool {
        autoMode || current != target
    }
}
