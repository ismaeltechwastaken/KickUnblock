import SwiftUI
import KickUnblockCore

struct LaunchOverlay: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?

    private static let cells = LaunchAnimation.cells()
    private static let glyph = Path(brand: BrandMark.glyphPath)
    private static let play = Path(brand: BrandMark.playPath)
    private static let background = Color(hex: LaunchAnimation.backgroundHex)
    private static let green = Color(hex: BrandMark.green)

    var body: some View {
        TimelineView(.animation) { context in
            let t = start.map { context.date.timeIntervalSince($0) } ?? 0
            Canvas { gc, size in draw(&gc, size: size, t: t) }
                .opacity(LaunchAnimation.overlayOpacity(at: t, reduceMotion: reduceMotion))
                .allowsHitTesting(reduceMotion ? t < 0.05 : t < LaunchAnimation.zoomStart)
                .onChange(of: LaunchAnimation.isFinished(at: t, reduceMotion: reduceMotion)) { _, done in
                    if done { onFinish() }
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { start = Date() }
        .task {
            let limit = (reduceMotion ? LaunchAnimation.reducedMotionDuration : LaunchAnimation.total) + 0.6
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            onFinish()
        }
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.background))
        let side = min(size.width, size.height) * 0.38
        let unit = side / BrandMark.canvas
        let scale = reduceMotion ? 1 : LaunchAnimation.zoomScale(at: t)
        gc.translateBy(x: size.width / 2, y: size.height / 2)
        gc.scaleBy(x: unit * scale, y: unit * scale)
        gc.translateBy(x: -BrandMark.canvas / 2, y: -BrandMark.canvas / 2)

        if reduceMotion {
            gc.fill(Self.glyph, with: .color(Self.green)); gc.fill(Self.play, with: .color(Self.green)); return
        }
        let smooth = LaunchAnimation.smoothMarkOpacity(at: t)
        if smooth < 1 {
            var mosaic = gc
            mosaic.opacity = 1 - smooth
            for c in Self.cells {
                let k = LaunchAnimation.cellScale(c, at: t)
                guard k > 0 else { continue }
                let r = c.rect, s = r.size * 0.86 * k
                let rect = CGRect(x: r.x + (r.size - s) / 2, y: r.y + (r.size - s) / 2, width: s, height: s)
                mosaic.fill(Path(roundedRect: rect, cornerRadius: s * 0.22), with: .color(Color(hex: c.shade)))
            }
        }
        if smooth > 0 {
            var mark = gc
            mark.opacity = smooth
            mark.fill(Self.glyph, with: .color(Self.green)); mark.fill(Self.play, with: .color(Self.green))
        }
    }
}
