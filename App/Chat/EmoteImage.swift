import SwiftUI
import UIKit
import ImageIO
import KickUnblockCore

// MARK: - Animated view

final class AnimatedEmoteUIView: UIView {
    private var data: Data?
    private var cacheKey: String?
    private var animate = true
    private var generation = 0
    private var running = false
    private var hasContents = false
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 2
        layer.actions = ["contents": NSNull(), "contentsScale": NSNull()]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    private func display(_ image: CGImage?, scale: CGFloat) {
        layer.contentsScale = scale
        layer.contents = image
        hasContents = image != nil
    }

    func show(data: Data?, key: String, still: UIImage?, animate: Bool) {
        let changed = data != self.data || animate != self.animate || key != cacheKey
        self.data = data
        self.cacheKey = key
        self.animate = animate
        if !hasContents || changed { display(still?.cgImage, scale: still?.scale ?? 2) }
        if changed || (!running && window != nil) { restart() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if !running { restart() }
    }

    func stop() {
        generation += 1
        running = false
        loadTask?.cancel(); loadTask = nil
        layer.removeAnimation(forKey: "emote")
    }

    private func restart() {
        stop()
        guard animate, window != nil, let data, let key = cacheKey else { return }
        let mine = generation
        running = true
        loadTask = Task { @MainActor [weak self] in
            let frames = await EmoteFrameCache.shared.frames(for: data, key: key)
            guard let self, self.generation == mine else { return }
            guard let frames, self.window != nil else { self.running = false; return }
            let a = CAKeyframeAnimation(keyPath: "contents")
            a.values = frames.images
            a.keyTimes = frames.keyTimes
            a.calculationMode = .discrete
            a.duration = frames.duration
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            let now = self.layer.convertTime(CACurrentMediaTime(), from: nil)
            a.beginTime = now - now.truncatingRemainder(dividingBy: frames.duration)
            self.layer.contentsScale = 2
            self.layer.add(a, forKey: "emote")
        }
    }
}

struct AnimatedEmoteView: UIViewRepresentable {
    let data: Data?
    let cacheKey: String
    let still: UIImage?
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.animateEmotes) private var animationPreference = TweakDefault.animateEmotes
    @ObservedObject private var energy = EnergyMonitor.shared

    private var effectiveAnimation: Bool {
        ChatAccessibilityMotionPolicy.allowsAnimation(
            requested: animate, preferenceEnabled: animationPreference, reduceMotion: reduceMotion, energyConstrained: energy.constrained
        )
    }

    func makeUIView(context: Context) -> AnimatedEmoteUIView { AnimatedEmoteUIView(frame: .zero) }
    func updateUIView(_ view: AnimatedEmoteUIView, context: Context) {
        view.show(data: data, key: cacheKey, still: still, animate: effectiveAnimation)
    }
    static func dismantleUIView(_ view: AnimatedEmoteUIView, coordinator: ()) { view.stop() }
}

struct EmoteView: View {
    let name: String
    let url: URL
    let provider: EmoteProvider
    let height: Double
    let animate: Bool
    private struct Loaded { let key: String; let data: Data?; let still: UIImage }
    @State private var loaded: Loaded?

    private var width: Double {
        guard let s = loaded?.still.size, s.height > 0 else { return height }
        return min(height * Double(s.width / s.height), height * 4)
    }

    var body: some View {
        Group {
            if let loaded {
                AnimatedEmoteView(data: loaded.data, cacheKey: loaded.key, still: loaded.still, animate: animate)
                    .frame(width: width, height: height)
            } else {
                Text(name).foregroundStyle(.kuSecondary)
            }
        }
        .accessibilityLabel(name)
        .task(id: url) {
            let url = url, key = EmoteCacheKey.make(url: url, provider: provider)
            let data = await EmoteDataCache.shared.data(for: url, key: key)
            let still = await EmoteDataCache.shared.still(for: url, key: key)
            guard !Task.isCancelled else { return }
            loaded = still.map { Loaded(key: key, data: data, still: $0) }
        }
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    private struct Line { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func lines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var out: [Line] = []
        var line = Line()
        for (i, sub) in subviews.enumerated() {
            var size = sub.sizeThatFits(.unspecified)
            if size.width > maxWidth { size = sub.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil)) }
            let extra = line.items.isEmpty ? size.width : spacing + size.width
            if !line.items.isEmpty && line.width + extra > maxWidth {
                out.append(line); line = Line()
                line.items.append((i, size)); line.width = size.width; line.height = size.height
            } else {
                line.items.append((i, size)); line.width += extra; line.height = max(line.height, size.height)
            }
        }
        if !line.items.isEmpty { out.append(line) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let ls = lines(maxWidth: maxWidth, subviews: subviews)
        let h = ls.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(ls.count - 1, 0))
        let w = ls.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                let pt = CGPoint(x: x, y: y + (line.height - item.size.height) / 2)
                subviews[item.index].place(at: pt, anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
