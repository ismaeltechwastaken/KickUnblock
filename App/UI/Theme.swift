import SwiftUI
import KickUnblockCore

extension Color {
    init(hex: String) {
        let c = HexColor.rgb(hex) ?? (0, 0, 0)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

struct ThemeReader: DynamicProperty {
    @AppStorage(PrefKey.background) var bgRaw = TweakDefault.background
    @AppStorage(PrefKey.accent) var accentRaw = TweakDefault.accent

    var oled: OLEDBackground { OLEDBackground(rawValue: bgRaw) ?? .carbon }
    var accentChoice: AccentChoice { AccentChoice(rawValue: accentRaw) ?? .kickNeon }
    var background: Color { Color(hex: oled.hex) }
    var surface: Color { Color(hex: oled.surfaceHex) }
    var accent: Color { Color(hex: accentChoice.hex) }
    var onAccent: Color { Color(hex: accentChoice.foregroundHex) }
    var accentText: Color { Color(hex: accentChoice.textHex) }
}

struct ChromeReader: DynamicProperty {
    @AppStorage(PrefKey.chromeStyle) private var chromeRaw = TweakDefault.chromeStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var resolved: ChromeStyle.Resolved {
        ChromeStyle.resolved(raw: chromeRaw, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                             reduceTransparency: reduceTransparency)
    }
}

extension ShapeStyle where Self == Color {
    static var kuPrimary: Color { Color(hex: TextToken.primary.hex) }
    static var kuSecondary: Color { Color(hex: TextToken.secondary.hex) }
    static var kuTertiary: Color { Color(hex: TextToken.tertiary.hex) }
}

struct ThemedRowBackground: View {
    @AppStorage(PrefKey.background) private var bgRaw = TweakDefault.background
    var body: some View {
        let oled = OLEDBackground(rawValue: bgRaw) ?? .carbon
        Rectangle().fill(Color(hex: oled.cardHex))
            .overlay {
                if let b = oled.cardBorderHex { Rectangle().strokeBorder(Color(hex: b), lineWidth: 1) }
            }
    }
}

extension View {
    func themedRows() -> some View { listRowBackground(ThemedRowBackground()) }

    @ViewBuilder func compatPresentationBackground(_ color: Color) -> some View {
        if #available(iOS 18, *) { presentationBackground(color) } else { self }
    }

    func themedBar(_ bar: ToolbarPlacement) -> some View { modifier(ThemedBar(bar: bar)) }

    func chromeSurface<S: Shape>(in shape: S) -> some View { modifier(ChromeSurface(shape: shape)) }

    func themedControlTint() -> some View { modifier(ThemedControlTint()) }
}

private struct ThemedBar: ViewModifier {
    let bar: ToolbarPlacement
    @AppStorage(PrefKey.background) private var bgRaw = TweakDefault.background
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbarBackground(.automatic, for: bar)
        } else {
            let bg = Color(hex: (OLEDBackground(rawValue: bgRaw) ?? .carbon).hex)
            content.toolbarBackground(bg, for: bar).toolbarBackground(.visible, for: bar)
        }
    }
}

private struct ChromeSurface<S: Shape>: ViewModifier {
    let shape: S
    private let chrome = ChromeReader()
    @AppStorage(PrefKey.background) private var bgRaw = TweakDefault.background
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), chrome.resolved.usesGlass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(Color(hex: (OLEDBackground(rawValue: bgRaw) ?? .carbon).surfaceHex), in: shape)
        }
    }
}

private struct ThemedControlTint: ViewModifier {
    @AppStorage(PrefKey.accent) private var accentRaw = TweakDefault.accent
    func body(content: Content) -> some View {
        let accent = AccentChoice(rawValue: accentRaw) ?? .kickNeon
        content.tint(Color(hex: accent.textHex))
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let t = ThemeReader()
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(t.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(t.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

func readableNameColor(_ hex: String?) -> Color? {
    hex.map { Color(hex: Contrast.readableOnDark($0)) }
}

struct OLEDPage: ViewModifier {
    @AppStorage(PrefKey.background) private var bgRaw = TweakDefault.background
    func body(content: Content) -> some View {
        let bg = Color(hex: (OLEDBackground(rawValue: bgRaw) ?? .carbon).hex)
        content
            .scrollContentBackground(.hidden)
            .background(bg.ignoresSafeArea())
            .themedBar(.navigationBar)
    }
}

extension View {
    func oledPage() -> some View { modifier(OLEDPage()) }
}

struct Skeleton: View {
    var cornerRadius: CGFloat = 10
    @State private var phase: CGFloat = -1
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.06))
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private var failedAt: [URL: Date] = [:]
    nonisolated private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 20
        c.httpAdditionalHeaders = ["User-Agent": KickWebClient.userAgent]
        return URLSession(configuration: c)
    }()

    init() { cache.countLimit = 400 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func cachedInOrder(_ urls: [URL]) -> UIImage? {
        for url in urls {
            if let img = cached(url) { return img }
            guard let t = failedAt[url], Date().timeIntervalSince(t) < 60 else { return nil }
        }
        return nil
    }

    func load(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        if let t = failedAt[url], Date().timeIntervalSince(t) < 60 { return nil }
        if let t = inflight[url] { return await t.value }
        let session = self.session
        let t = Task<UIImage?, Never>.detached(priority: .utility) {
            for attempt in 0..<2 {
                if Task.isCancelled { return nil }
                if attempt > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
                guard let (data, resp) = try? await session.data(from: url),
                      let code = (resp as? HTTPURLResponse)?.statusCode else { continue }
                if code == 404 || code == 403 { return nil }
                guard code == 200 else { continue }
                if let img = UIImage(data: data) { return img.preparingForDisplay() ?? img }
                return nil
            }
            return nil
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) } else { failedAt[url] = Date() }
        return img
    }

    func load(firstOf urls: [URL]) async -> UIImage? {
        for u in urls {
            if Task.isCancelled { return nil }
            if let img = await load(u) { return img }
        }
        return nil
    }
}

struct RemoteImage<Fallback: View>: View {
    let urls: [URL]
    var contentMode: ContentMode = .fill
    let fallback: Fallback
    @State private var image: UIImage?
    @State private var failed = false
    @State private var expired = false

    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder fallback: () -> Fallback) {
        self.init(urls: url.map { [$0] } ?? [], contentMode: contentMode, fallback: fallback)
    }

    init(urls: [URL], contentMode: ContentMode = .fill, @ViewBuilder fallback: () -> Fallback) {
        self.urls = urls; self.contentMode = contentMode; self.fallback = fallback()
    }

    var body: some View {
        let cachedImage = image ?? ImageLoader.shared.cachedInOrder(urls)
        let art = TileArt.resolve(hasImage: cachedImage != nil, allFailed: failed, noURLs: urls.isEmpty,
                                  elapsed: expired ? .infinity : 0)
        Group {
            switch art {
            case .image:
                if let cachedImage { Image(uiImage: cachedImage).resizable().aspectRatio(contentMode: contentMode) }
            case .fallback: fallback
            case .skeleton: Skeleton(cornerRadius: 0)
            }
        }
        .task(id: urls) {
            failed = false
            guard !urls.isEmpty else { image = nil; return }
            if let img = await ImageLoader.shared.load(firstOf: urls) {
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            } else if !Task.isCancelled { failed = true }
        }
        .task(id: urls) {
            expired = false
            try? await Task.sleep(nanoseconds: UInt64(BrowseGrid.placeholderDeadline * 1_000_000_000))
            if !Task.isCancelled { expired = true }
        }
    }
}

extension RemoteImage where Fallback == AnyView {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) {
            AnyView(Color.white.opacity(0.05).overlay(Image(systemName: "photo").foregroundStyle(.kuSecondary)))
        }
    }
}

struct LiveBadge: View {
    var viewers: Int?
    var body: some View {
        HStack(spacing: 4) {
            Text("LIVE").font(.caption2.weight(.heavy))
            if let v = viewers { Text(DisplayFormat.compactCount(v)).font(.caption2.monospacedDigit()) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color(hex: Contrast.liveBadgeHex), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(Color(hex: Contrast.foregroundHex(on: Contrast.liveBadgeHex)))
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 36
    var body: some View {
        RemoteImage(url: url).frame(width: size, height: size).clipShape(Circle())
    }
}

struct StreamCardView: View {
    let card: StreamCard
    var thumbnailFallbackURLs: [URL] = []
    private var previewURLs: [URL] {
        var result: [URL] = []
        for url in [card.thumbnailURL].compactMap({ $0 }) + thumbnailFallbackURLs
        where !result.contains(url) { result.append(url) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(urls: previewURLs) {
                ZStack {
                    ThemeReader().surface
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle").font(.largeTitle)
                        Text(card.channelName).font(.headline).lineLimit(1)
                    }.foregroundStyle(.kuSecondary).padding()
                }
            }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if card.startedAt != nil { LiveBadge(viewers: card.viewers).padding(6) }
                }
            HStack(alignment: .top, spacing: 10) {
                Avatar(url: card.avatarURL, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(card.channelName).font(.caption).foregroundStyle(.kuSecondary)
                    if let c = card.category { Text(c).font(.caption2).foregroundStyle(.kuTertiary) }
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
    }
}

struct StreamCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Skeleton().aspectRatio(16 / 9, contentMode: .fit)
            HStack(spacing: 10) {
                Skeleton(cornerRadius: 16).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Skeleton(cornerRadius: 4).frame(height: 12)
                    Skeleton(cornerRadius: 4).frame(width: 120, height: 10)
                }
            }
        }
    }
}

struct ErrorBox: View {
    let text: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.kuSecondary)
            Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.kuSecondary)
            if let retry { Button("Retry", action: retry).buttonStyle(.bordered) }
        }
        .frame(maxWidth: .infinity).padding(24)
    }
}

struct FeedStateView: View {
    let phase: FeedPhase
    var emptyTitle = "Nobody's live here"
    var emptyMessage = "This category has no live streams right now."
    var openOnWeb: (() -> Void)? = nil
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .loading, .content:
            EmptyView()
        case .failed(let message):
            if let openOnWeb {
                VStack(spacing: 10) {
                    Image(systemName: "hourglass").font(.title).foregroundStyle(.kuSecondary)
                    Text(message.hasPrefix(CategoryListError.title) ? CategoryListError.title : "This list didn't load")
                        .font(.headline).foregroundStyle(.kuPrimary).multilineTextAlignment(.center)
                    Text(message.hasPrefix(CategoryListError.title) ? "Try again in a minute. You can also open it on kick.com." : message)
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.kuSecondary)
                    HStack(spacing: 10) {
                        Button("Retry", action: retry).buttonStyle(AccentButtonStyle())
                        Button(action: openOnWeb) { Label("Open on kick.com", systemImage: "safari") }
                            .buttonStyle(.bordered).tint(.kuPrimary)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24)
            } else {
                ErrorBox(text: message, retry: retry)
            }
        case .empty(let hidden):
            VStack(spacing: 10) {
                Image(systemName: hidden > 0 ? "eye.slash" : "moon.zzz").font(.title).foregroundStyle(.kuSecondary)
                Text(hidden > 0 ? "Only mature streams are live" : emptyTitle).font(.headline).foregroundStyle(.kuPrimary)
                Text(hidden > 0 ? "\(hidden) live \(hidden == 1 ? "stream is" : "streams are") hidden by Hide mature streams in Tweaks." : emptyMessage)
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.kuSecondary)
                Button("Retry", action: retry).buttonStyle(AccentButtonStyle()).padding(.top, 4)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24)
        }
    }
}

func formatDuration(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "--:--" }
    let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
