import Foundation

public enum LiveScrubPresentation {
    public static func fraction(current: Double, range: ScrubRange?, interaction: ScrubInteraction,
                                isNaturalLive: Bool) -> Double {
        guard let shownRange = interaction.snapshot ?? range,
              LiveEdge.showsScrubBar(shownRange) else { return 0 }
        if let preview = interaction.previewTime { return shownRange.fraction(preview) }
        if isNaturalLive, !interaction.isInteracting { return 1 }
        return current.isFinite ? shownRange.fraction(current) : 0
    }
}
