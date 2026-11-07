import Foundation

public enum DisplayFormat {
    public static func compactCount(_ n: Int) -> String {
        func trim(_ v: Double, _ suffix: String) -> String {
            let s = v < 10 ? String(format: "%.1f", v) : String(Int(v))
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        switch n {
        case ..<1_000: return String(n)
        case ..<1_000_000: return trim(Double(n) / 1_000, "K")
        default: return trim(Double(n) / 1_000_000, "M")
        }
    }
}
