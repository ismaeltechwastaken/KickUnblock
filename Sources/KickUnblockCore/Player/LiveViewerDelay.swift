import Foundation

public enum LiveViewerDelay {
    static func validSync(_ s: Double) -> Bool { s.isFinite && s > 1_000_000_000 }

    public static func seconds(nowUTC: Double, syncTime: Double) -> Double? {
        guard validSync(syncTime), nowUTC.isFinite else { return nil }
        let d = nowUTC - syncTime
        guard d >= -2, d < 86_400 else { return nil }
        return max(0, d.rounded())
    }
}
