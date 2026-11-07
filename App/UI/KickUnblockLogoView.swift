import SwiftUI
import KickUnblockCore

struct KickUnblockLogoView: View {
    var size: CGFloat = 28
    var showsBackground = true
    var tileColor: Color? = nil

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / BrandMark.canvas
            ctx.scaleBy(x: s, y: s)
            if showsBackground {
                let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                                cornerRadius: BrandMark.tileCornerRadius, style: .continuous)
                if let tileColor {
                    ctx.fill(tile, with: .color(tileColor))
                } else {
                    ctx.fill(tile, with: .linearGradient(
                        Gradient(colors: [Color(hex: BrandMark.carbonTop), Color(hex: BrandMark.carbonBottom)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: 1024)))
                }
            }
            ctx.fill(Self.glyph, with: .color(Color(hex: BrandMark.green)))
            ctx.fill(Self.play, with: .color(.white))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("KickUnblock")
    }

    private static let glyph = Path(brand: BrandMark.glyphPath)
    private static let play = Path(brand: BrandMark.playPath)
}

struct KickUnblockWordmark: View {
    var height: CGFloat = 18

    private var scale: CGFloat { height / BrandWordmark.height }
    private var tile: CGFloat { BrandWordmark.lockupTile * scale }
    private var gap: CGFloat { BrandWordmark.lockupGap * scale }
    private var textWidth: CGFloat { BrandWordmark.width * scale }

    var body: some View {
        HStack(spacing: gap) {
            KickUnblockLogoView(size: tile, tileColor: Color(hex: "#1C1C1E"))
            Canvas { ctx, _ in
                ctx.scaleBy(x: scale, y: scale)
                ctx.fill(Self.kick, with: .color(Color(hex: BrandMark.green)))
                ctx.fill(Self.unblock, with: .color(.white))
            }
            .frame(width: textWidth, height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("KickUnblock")
    }

    private static let kick = Path(brand: BrandWordmark.kick)
    private static let unblock = Path(brand: BrandWordmark.unblock)
}

extension Path {
    init(brand commands: [BrandWordmark.Command]) {
        self.init()
        for c in BrandWordmark.curvesOnly(commands) {
            switch c {
            case .move(let x, let y): move(to: CGPoint(x: x, y: y))
            case .line(let x, let y): addLine(to: CGPoint(x: x, y: y))
            case .quad(let cx, let cy, let x, let y): addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case .cubic(let ax, let ay, let bx, let by, let x, let y):
                addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: ax, y: ay), control2: CGPoint(x: bx, y: by))
            case .close: closeSubpath()
            case .arc: break
            }
        }
    }
}
