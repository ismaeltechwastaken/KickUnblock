import Foundation

public enum ChatAccessibilityMotionPolicy {
    public static func allowsAnimation(requested: Bool, preferenceEnabled: Bool, reduceMotion: Bool, energyConstrained: Bool = false) -> Bool {
        requested && preferenceEnabled && !reduceMotion && !energyConstrained
    }
}

public enum ChatEnergyPolicy {
    public static func isConstrained(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        lowPowerMode || thermalState == .serious || thermalState == .critical
    }
}

public struct ChatAccessibilityMetrics: Equatable, Sendable {
    public let messageFontSize: Double
    public let replyFontSize: Double
    public let badgeInfoFontSize: Double
    public var emoteHeight: Double { messageFontSize * 1.6 }
    public var badgeHeight: Double { messageFontSize * 1.15 }

    public init(baseFontSize: Double, bodyScale: Double) {
        let base = ChatFontSize.clamp(baseFontSize)
        messageFontSize = base * bodyScale
        replyFontSize = (base - 2) * bodyScale
        badgeInfoFontSize = max(10, base - 3) * bodyScale
    }
}
