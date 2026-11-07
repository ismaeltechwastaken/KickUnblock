import Foundation

public enum BrandMark {
    public typealias Point = (x: Double, y: Double)
    public static let canvas: Double = 1024
    public static let tileCornerRadius: Double = 229
    public static let glyph: [Point] = [(196, 224), (340, 224), (340, 440), (556, 224), (760, 224), (472, 512),
                                        (760, 800), (556, 800), (340, 584), (340, 800), (196, 800)]
    public static let play: [Point] = [(643.88, 408), (643.88, 616), (824.02, 512)]
    public static let playGap: Double = 48

    public static var glyphPath: [BrandWordmark.Command] { BrandWordmark.parse(glyphPathData) }
    public static var playPath: [BrandWordmark.Command] { BrandWordmark.parse(playPathData) }

    public static let green = "#53FC18"
    public static let greenOnLight = "#178005"
    public static let carbonTop = "#151515"
    public static let carbonBottom = "#0D0D0D"
}

public enum BrandWordmark {
    public enum Command: Equatable {
        case move(Double, Double)
        case line(Double, Double)
        case quad(Double, Double, Double, Double)
        case cubic(Double, Double, Double, Double, Double, Double)
        case arc(Double, Double, Double, Bool, Bool, Double, Double)
        case close
    }

    public static var kick: [Command] { parse(kickPathData) }
    public static var unblock: [Command] { parse(unblockPathData) }

    public static func parse(_ d: String) -> [Command] {
        var out: [Command] = []
        var op: Character = "M"
        var nums: [Double] = []
        func flush() {
            switch op {
            case "M" where nums.count == 2: out.append(.move(nums[0], nums[1]))
            case "L" where nums.count == 2: out.append(.line(nums[0], nums[1]))
            case "Q" where nums.count == 4: out.append(.quad(nums[0], nums[1], nums[2], nums[3]))
            case "C" where nums.count == 6: out.append(.cubic(nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]))
            case "A" where nums.count == 7: out.append(.arc(nums[0], nums[1], nums[2], nums[3] != 0, nums[4] != 0, nums[5], nums[6]))
            default: break
            }
            nums.removeAll()
        }
        var token = ""
        func endToken() { if let v = Double(token) { nums.append(v) }; token = "" }
        for ch in d {
            if "MLQCAZ".contains(ch) {
                endToken(); flush(); op = ch
                if ch == "Z" { out.append(.close) }
            } else if ch == " " || ch == "," {
                endToken()
            } else if ch == "-" && !token.isEmpty {
                endToken(); token = "-"
            } else {
                token.append(ch)
            }
        }
        endToken(); flush()
        return out
    }

    public static func curvesOnly(_ commands: [Command]) -> [Command] {
        var out: [Command] = []
        var current = (x: 0.0, y: 0.0), start = (x: 0.0, y: 0.0)
        for c in commands {
            switch c {
            case .move(let x, let y): current = (x, y); start = current; out.append(c)
            case .line(let x, let y), .quad(_, _, let x, let y), .cubic(_, _, _, _, let x, let y):
                current = (x, y); out.append(c)
            case .close: current = start; out.append(c)
            case .arc(let rx, let ry, let rotation, let large, let sweep, let x, let y):
                out += arcToCubics(from: current, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep, to: (x, y))
                current = (x, y)
            }
        }
        return out
    }

    static func arcToCubics(from p0: (x: Double, y: Double), rx rxIn: Double, ry ryIn: Double, rotation: Double,
                            large: Bool, sweep: Bool, to p1: (x: Double, y: Double)) -> [Command] {
        var rx = abs(rxIn), ry = abs(ryIn)
        if (p0.x == p1.x && p0.y == p1.y) { return [] }
        if rx == 0 || ry == 0 { return [.line(p1.x, p1.y)] }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: Double) -> (Double, Double) {
            let x = rx * cos(t), y = ry * sin(t)
            return (cosP * x - sinP * y + cx, sinP * x + cosP * y + cy)
        }
        func derivative(_ t: Double) -> (Double, Double) {
            let x = -rx * sin(t), y = ry * cos(t)
            return (cosP * x - sinP * y, sinP * x + cosP * y)
        }
        var out: [Command] = []
        var t = theta1
        for i in 0..<segments {
            let t2 = t + step
            let a = point(t), b = point(t2), da = derivative(t), db = derivative(t2)
            let end = i == segments - 1 ? (p1.x, p1.y) : b
            out.append(.cubic(a.0 + k * da.0, a.1 + k * da.1, b.0 - k * db.0, b.1 - k * db.1, end.0, end.1))
            t = t2
        }
        return out
    }
}
