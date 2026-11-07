import SwiftUI
import WebKit
import KickUnblockCore

@MainActor
final class KickWebSession: ObservableObject {
    @Published private(set) var identity: KickIdentity?
    var isSignedIn: Bool { identity != nil }
    var username: String? { identity?.displayName }
    @Published private(set) var isVerifying = false
    @Published var lastError: KickAccountError?
    @Published var importStatus: String?

    let dataStore: WKWebsiteDataStore
    private let transport: URLSession
    private var store: WKHTTPCookieStore { dataStore.httpCookieStore }
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var binding = KickWebIdentityBinding()
    private var checkedCookies: [WebCookie] = []
    private var checkedAt = Date.distantPast

    init(dataStore: WKWebsiteDataStore? = nil, session: URLSession? = nil, automaticallyRefresh: Bool = true) {
        self.dataStore = dataStore ?? .default()
        self.transport = session ?? URLSession.shared
        if automaticallyRefresh { Task { [weak self] in await self?.refresh() } }
    }

    func refresh(force: Bool = false) async {
        if let refreshTask { await refreshTask.value; return }
        let pending = Task { [weak self] in
            guard let self else { return }
            await self.validateIdentity(force: force)
        }
        refreshTask = pending
        await pending.value
        refreshTask = nil
    }

    private func readCookies(for url: URL) async -> [WebCookie] {
        let host = url.host?.lowercased() ?? ""
        let all = await store.allCookies()
        return KickSessionCookies.filter(all.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = cookie.path
            return (host == domain || host.hasSuffix("." + domain)) &&
                (cookie.expiresDate.map { $0 > Date() } ?? true) &&
                (url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/"))
        }.map { WebCookie(name: $0.name, value: $0.value, domain: $0.domain) })
    }

    private func validateIdentity(force: Bool) async {
        let version = generation
        let url = KickAccountRequest.identityURL
        let cookies = await readCookies(for: url)
        guard version == generation, !Task.isCancelled else { return }
        binding.observe(cookies)
        identity = binding.identity
        guard KickSessionCookies.isSignedIn(cookies) else {
            binding = KickWebIdentityBinding()
            identity = nil; checkedCookies = []; lastError = nil; return
        }
        let maxAge: TimeInterval = identity == nil ? 3 : 60
        if !force, cookies == checkedCookies, Date().timeIntervalSince(checkedAt) < maxAge { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let r = try KickAccountRequest.build(url, cookies: cookies, userAgent: KickWebClient.userAgent)
            let data = try await perform(r, page: KickAccountEndpoint.loginPage)
            let currentCookies = await readCookies(for: url)
            guard version == generation, !Task.isCancelled else { return }
            checkedCookies = cookies; checkedAt = Date()
            binding.complete(data: data, cookies: cookies, currentCookies: currentCookies)
            identity = binding.identity; lastError = binding.lastError
        } catch {
            let currentCookies = await readCookies(for: url)
            guard version == generation, !Task.isCancelled else { return }
            checkedCookies = cookies; checkedAt = Date()
            binding.fail((error as? KickAccountError) ?? .refused(status: 0, message: error.localizedDescription),
                         cookies: cookies, currentCookies: currentCookies)
            identity = binding.identity; lastError = binding.lastError
        }
    }

    func signOut() async {
        generation += 1
        refreshTask?.cancel()
        binding = KickWebIdentityBinding()
        identity = nil; checkedCookies = []; lastError = nil; importStatus = nil
        let ds = dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await ds.dataRecords(ofTypes: types)
        await ds.removeData(ofTypes: types, for: records.filter { $0.displayName.lowercased().contains("kick") })
        for c in await store.allCookies() where KickSessionCookies.isKickDomain(c.domain) { await store.deleteCookie(c) }
        identity = nil; checkedCookies = []
    }

    // MARK: requests

    private func request(_ url: URL, method: String = "GET", body: Data? = nil, referer: URL? = nil, page: URL? = nil) async throws -> Data {
        let version = generation
        await refresh()
        let cookies = await readCookies(for: url)
        try requireAuthority(cookies, version: version)
        let r = try KickAccountRequest.build(url, method: method, body: body, cookies: cookies,
                                             userAgent: KickWebClient.userAgent, referer: referer)
        return try await authenticated(r, page: page ?? url)
    }

    private func authenticated(_ r: URLRequest, page: URL) async throws -> Data {
        let version = generation
        do {
            let data = try await perform(r, page: page)
            guard version == generation, !Task.isCancelled else { throw KickAccountError.notSignedIn }
            return data
        }
        catch KickAccountError.notSignedIn { await refresh(force: true); throw KickAccountError.notSignedIn }
    }

    private func requireAuthority(_ cookies: [WebCookie], version: Int) throws {
        guard version == generation, !Task.isCancelled else { throw KickAccountError.notSignedIn }
        binding.observe(cookies)
        identity = binding.identity
        guard binding.authorizes(cookies) else { throw KickAccountError.notSignedIn }
    }

    private func perform(_ r: URLRequest, page: URL) async throws -> Data {
        let (data, resp) = try await transport.data(for: r)
        let http = resp as? HTTPURLResponse
        try KickAccountResponse.check(status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                      body: data, url: page)
        return data
    }

    func sendMessage(_ text: String, chatroomID: Int, channelSlug: String? = nil) async throws {
        do {
            let version = generation
            await refresh()
            let url = KickAccountEndpoint.sendMessage(chatroomID: chatroomID).url
            let cookies = await readCookies(for: url)
            try requireAuthority(cookies, version: version)
            let r = try KickAccountRequest.sendMessage(text, chatroomID: chatroomID, channelSlug: channelSlug,
                                                       cookies: cookies, userAgent: KickWebClient.userAgent)
            _ = try await authenticated(r, page: channelSlug.map(KickAccountEndpoint.channelPage) ?? url)
        } catch let e as KickAccountError { lastError = e; throw e }
    }

    func importFollows(into model: AppModel) async -> Int {
        importStatus = "Importing…"
        var cursor: String?
        var added = 0
        do {
            for _ in 0..<25 {
                let data = try await request(KickAccountEndpoint.followed(cursor: cursor).url)
                let page = FollowedChannelsParser.parse(data)
                for c in page.channels where !model.follows.isFollowing(c.slug) { model.follows.follow(c); added += 1 }
                guard let next = page.nextCursor, next != cursor else { break }
                cursor = next
            }
            model.followed = model.follows.all()
            importStatus = added == 0 ? "No new channels to import." : "Imported \(added) channel\(added == 1 ? "" : "s")."
        } catch let e as KickAccountError {
            lastError = e; importStatus = e.localizedDescription
        } catch { importStatus = error.localizedDescription }
        return added
    }

    func dropsCampaigns() async throws -> [DropsCampaign] {
        var r = URLRequest(url: KickAccountEndpoint.dropsCampaigns.url)
        r.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let http = resp as? HTTPURLResponse
        try KickAccountResponse.check(status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                      body: data, url: KickAccountEndpoint.dropsPage)
        guard let list = try? JSONDecoder().decode(DropsCampaignList.self, from: data) else { throw KickAccountError.decoding }
        return list.data
    }

    func dropsProgress() async throws -> DropsProgress {
        DropsProgress.parse(try await request(KickAccountEndpoint.dropsProgress.url, page: KickAccountEndpoint.dropsPage))
    }
}

// MARK: web view

struct KickWebPage: UIViewRepresentable {
    let url: URL
    var dataStore: WKWebsiteDataStore = .default()
    var opensLoginForm = false
    var onNavigate: () -> Void = {}
    var onBlockedProvider: (KickLoginNavigation.Provider) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate, onBlockedProvider: onBlockedProvider) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        if opensLoginForm {
            cfg.userContentController.addUserScript(WKUserScript(source: KickLoginAssist.openLoginFormScript,
                                                                 injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        cfg.allowsInlineMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        v.isOpaque = false
        v.backgroundColor = .black
        dataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.cookieStore = dataStore.httpCookieStore
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onBlockedProvider = onBlockedProvider
    }

    static func dismantleUIView(_ v: WKWebView, coordinator: Coordinator) {
        coordinator.cookieStore?.remove(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var onNavigate: () -> Void
        var onBlockedProvider: (KickLoginNavigation.Provider) -> Void
        weak var cookieStore: WKHTTPCookieStore?
        init(onNavigate: @escaping () -> Void, onBlockedProvider: @escaping (KickLoginNavigation.Provider) -> Void) {
            self.onNavigate = onNavigate; self.onBlockedProvider = onBlockedProvider
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onNavigate() }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            switch KickLoginNavigation.decide(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true) {
            case .allow: return .allow
            case .cancel: return .cancel
            case .blockedProvider(let p): onBlockedProvider(p); return .cancel
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            switch KickLoginNavigation.decide(url, isMainFrame: true) {
            case .allow: webView.load(navigationAction.request)
            case .cancel: break
            case .blockedProvider(let p): onBlockedProvider(p)
            }
            return nil
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.onNavigate() }
        }
    }
}

struct KickWebSheet: View {
    let title: String
    let url: URL
    var isRecovery = false
    @EnvironmentObject var web: KickWebSession
    @Environment(\.dismiss) private var dismiss
    @State private var blockedProvider: KickLoginNavigation.Provider?

    private var isLogin: Bool { url == KickAccountEndpoint.loginPage }
    private var shouldDismiss: Bool {
        KickWebSheetFinishPolicy.shouldAutoDismiss(isLoginSheet: isLogin, isRecovery: isRecovery, isSignedIn: web.isSignedIn)
    }

    var body: some View {
        NavigationStack {
            KickWebPage(url: url, dataStore: web.dataStore, opensLoginForm: isLogin,
                        onNavigate: { Task { await web.refresh() } },
                        onBlockedProvider: { blockedProvider = $0 })
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top) {
                    if let error = web.lastError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                            Button("Retry verification") { Task { await web.refresh(force: true) } }
                                .font(.footnote.weight(.semibold))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                    }
                    if let p = blockedProvider {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(p.guidance).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            Button { blockedProvider = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Dismiss")
                        }
                        .padding(10)
                        .background(.regularMaterial)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if web.isSignedIn { Label("Signed in", systemImage: "checkmark.seal.fill").labelStyle(.iconOnly).foregroundStyle(.green) }
                        else if isLogin && web.isVerifying { ProgressView() }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { Task { await web.refresh(force: true) }; dismiss() } }
                }
        }
        .onChange(of: web.isSignedIn, initial: true) { _, _ in if shouldDismiss { dismiss() } }
        .task {
            guard isLogin else { return }
            while !Task.isCancelled {
                await web.refresh()
                if shouldDismiss { dismiss(); return }
                try? await Task.sleep(nanoseconds: UInt64(KickLoginAssist.pollInterval * 1_000_000_000))
            }
        }
    }
}

struct KickAccountErrorView: View {
    let error: KickAccountError
    @State private var showPage = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
            if let u = error.webViewURL {
                Button("Open in web view") { showPage = true }.font(.footnote.weight(.semibold))
                    .sheet(isPresented: $showPage) { KickWebSheet(title: u.host ?? "kick.com", url: u, isRecovery: true) }
            }
        }
    }
}
