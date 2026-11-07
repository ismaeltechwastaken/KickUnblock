import Foundation

public enum LaunchAnimation {
    public static let blackHold = 0.30
    public static let buildDuration = 0.50
    public static let hold = 0.30
    public static let zoomDuration = 0.50
    public static let reducedMotionDuration = 0.20
    public static var buildStart: Double { blackHold }
    public static var buildEnd: Double { blackHold + buildDuration }
    public static var zoomStart: Double { buildEnd + hold }
    public static var total: Double { zoomStart + zoomDuration }
    public static let popDuration = 0.09
    public static let maxScale = 30.0
    public static let backgroundHex = "#0A0A0A"
    public static let shades = ["#53FC18", "#47DB14", "#3DBF11", "#6CFD3A", "#53FC18", "#5FFC28"]
    public static let gridSize = 32

    public struct Cell: Equatable, Sendable {
        public let column: Int, row: Int
        public let appearAt: Double
        public let shade: String
        public var rect: (x: Double, y: Double, size: Double) {
            let s = BrandMark.canvas / Double(LaunchAnimation.gridSize)
            return (Double(column) * s, Double(row) * s, s)
        }
        public static func == (a: Cell, b: Cell) -> Bool {
            a.column == b.column && a.row == b.row && a.appearAt == b.appearAt && a.shade == b.shade
        }
    }

    public static func cells(seed: UInt64 = 0x4B55_2026) -> [Cell] {
        var rng = SplitMix64(seed: seed)
        let s = BrandMark.canvas / Double(gridSize)
        var out: [Cell] = []
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let c = (x: (Double(col) + 0.5) * s, y: (Double(row) + 0.5) * s)
                guard contains(BrandMark.glyph, c) || contains(BrandMark.play, c) else { continue }
                let u = rng.nextUnit()
                let shade = shades[Int(rng.next() % UInt64(shades.count))]
                out.append(Cell(column: col, row: row, appearAt: buildStart + u * (buildDuration - popDuration), shade: shade))
            }
        }
        return out
    }

    public static func cellScale(_ cell: Cell, at t: Double) -> Double {
        let p = (t - cell.appearAt) / popDuration
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        let c1 = 1.70158, c3 = c1 + 1
        let q = p - 1
        return 1 + c3 * q * q * q + c1 * q * q
    }

    public static func smoothMarkOpacity(at t: Double) -> Double {
        clamp((t - buildEnd) / (hold * 0.5))
    }

    public static func zoomScale(at t: Double) -> Double {
        let p = clamp((t - zoomStart) / zoomDuration)
        return 1 + (maxScale - 1) * expoIn(p)
    }

    public static func overlayOpacity(at t: Double, reduceMotion: Bool = false) -> Double {
        if reduceMotion { return 1 - clamp(t / reducedMotionDuration) }
        let p = clamp((t - zoomStart) / zoomDuration)
        return 1 - smoothstep(0.25, 0.9, p)
    }

    public static func isFinished(at t: Double, reduceMotion: Bool = false) -> Bool {
        t >= (reduceMotion ? reducedMotionDuration : total)
    }

    public static func expoIn(_ p: Double) -> Double {
        p <= 0 ? 0 : (p >= 1 ? 1 : (pow(2, 10 * p - 10) - pow(2, -10)) / (1 - pow(2, -10)))
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t)
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func contains(_ poly: [BrandMark.Point], _ p: (x: Double, y: Double)) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
