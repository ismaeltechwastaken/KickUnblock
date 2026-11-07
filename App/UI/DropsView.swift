import SwiftUI
import ImageIO
import KickUnblockCore

struct DropsView: View {
    @EnvironmentObject var web: KickWebSession
    @State private var snapshot = DropsScreenSnapshot.empty
    @State private var progressError: KickAccountError?
    @State private var error: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var showActiveOnly = true
    @State private var webPage: WebTarget?
    private let theme = ThemeReader()

    var body: some View {
        let sections = snapshot.sections(activeOnly: showActiveOnly)
        let accent = theme.accent
        let accentText = theme.accentText
        let open: (URL) -> Void = { webPage = WebTarget(url: $0) }
        List {
            Section {
                Picker("Show", selection: $showActiveOnly) {
                    Text("Active").tag(true); Text("All").tag(false)
                }.pickerStyle(.segmented)
                if !web.isSignedIn {
                    Text("Sign in under Tweaks › Kick Account to see progress. Claim Drops on kick.com's Drops page.")
                        .font(.caption).foregroundStyle(.kuSecondary)
                } else if let progressError {
                    KickAccountErrorView(error: progressError)
                }
                Button { open(KickAccountEndpoint.dropsPage) } label: { Label("Open kick.com/drops", systemImage: "safari") }
            } footer: {
                Text(DropsCopy.footer)
            }
            .themedRows()

            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.themedRows() }
            if loading && snapshot.allSections.isEmpty { Section { ProgressView() }.themedRows() }
            if loaded && !loading && error == nil && sections.isEmpty {
                Section { Text(showActiveOnly ? "No active campaigns right now." : "No campaigns.").font(.footnote).foregroundStyle(.kuSecondary) }
                    .themedRows()
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        DropsRow(content: row.content, accent: accent, open: open)
                    }
                } header: {
                    DropsSectionHeader(header: section.header, accentText: accentText)
                }
                .themedRows()
            }
        }
        .oledPage()
        .navigationTitle("Drops")
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .sheet(item: $webPage) { t in KickWebSheet(title: "Kick Drops", url: t.url).environmentObject(web) }
    }

    private func load() async {
        loading = true; defer { loading = false; loaded = true }
        do {
            let campaigns = try await web.dropsCampaigns()
            snapshot = DropsScreenSnapshot(campaigns: campaigns, progress: snapshot.progress)
            error = nil
        } catch { self.error = error.localizedDescription }
        guard web.isSignedIn else { return }
        do {
            let progress = try await web.dropsProgress()
            snapshot = snapshot.applying(progress: progress)
            progressError = nil
        }
        catch let e as KickAccountError { progressError = e }
        catch { progressError = .refused(status: 0, message: error.localizedDescription) }
    }
}

enum DropsCopy {
    static let footer = "Kick tracks Drops on kick.com and its official app. KickUnblock sends no watch signals. Watching here may not count. It never claims Drops for you or fakes watch time."
}

private struct DropsSectionHeader: View {
    let header: DropsScreenSnapshot.Header
    let accentText: Color

    var body: some View {
        HStack(spacing: 8) {
            if let logo = header.logoURL {
                DropsThumbnail(url: logo, side: 20, cornerRadius: 4)
            }
            Text(header.title).lineLimit(1)
            Spacer()
            Text(header.statusText).font(.caption2.weight(.bold))
                .foregroundStyle(header.isActive ? accentText : .kuSecondary)
        }
    }
}

private struct DropsRow: View {
    let content: DropsScreenSnapshot.Content
    let accent: Color
    let open: (URL) -> Void

    var body: some View {
        switch content {
        case .details(let d):
            VStack(alignment: .leading, spacing: 4) {
                if let cat = d.category { Label(cat, systemImage: "gamecontroller").font(.caption) }
                if let end = d.endsText { Text(end).font(.caption2).foregroundStyle(.kuSecondary) }
                if let rule = d.ruleText { Text(rule).font(.caption2).foregroundStyle(.kuSecondary) }
                if let chans = d.channelsText { Text(chans).font(.caption2).foregroundStyle(.kuSecondary).lineLimit(2) }
            }
        case .reward(let r):
            HStack(spacing: 10) {
                DropsThumbnail(url: r.imageURL, side: 44, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let f = r.fraction { ProgressView(value: f).tint(accent) }
                    if let caption = r.caption {
                        Text(caption).font(.caption2.monospacedDigit()).foregroundStyle(.kuSecondary)
                    }
                }
                Spacer()
                switch r.action {
                case .claimed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Claimed")
                case .claim:
                    Button("Claim") { open(KickAccountEndpoint.dropsPage) }.buttonStyle(AccentButtonStyle())
                case .none:
                    EmptyView()
                }
            }
        case .connect(let u):
            Button { open(u) } label: { Label("Connect game account", systemImage: "link") }.font(.footnote)
        }
    }
}

private struct DropsThumbnail: View {
    let url: URL?
    let side: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        let px = Int((side * scale).rounded(.up))
        let shown = image ?? url.flatMap { DropsThumbnailLoader.cached($0, px: px) }
        ZStack {
            Color.white.opacity(0.05)
            if let shown {
                Image(uiImage: shown).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").font(.system(size: side * 0.35)).foregroundStyle(.kuSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = DropsThumbnailLoader.cached(url, px: px) { image = hit; return }
            image = nil
            image = await DropsThumbnailLoader.shared.load(url, px: px)
        }
    }
}

private actor DropsThumbnailLoader {
    static let shared = DropsThumbnailLoader()
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 300; return c
    }()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["User-Agent": KickWebClient.userAgent]
        return URLSession(configuration: c)
    }()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    nonisolated static func cached(_ url: URL, px: Int) -> UIImage? {
        cache.object(forKey: key(url, px) as NSString)
    }

    private nonisolated static func key(_ url: URL, _ px: Int) -> String { "\(px)|\(url.absoluteString)" }

    func load(_ url: URL, px: Int) async -> UIImage? {
        let k = Self.key(url, px)
        if let hit = Self.cache.object(forKey: k as NSString) { return hit }
        if let t = inflight[k] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> UIImage? in
            guard let (data, resp) = try? await Self.session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, px),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        inflight[k] = t
        let img = await t.value
        inflight[k] = nil
        if let img { Self.cache.setObject(img, forKey: k as NSString) }
        return img
    }
}

struct WebTarget: Identifiable { let url: URL; var id: String { url.absoluteString } }
