import SwiftUI
import KickUnblockCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: PlaybackSession
    @SceneStorage("tab") private var savedTab = ""
    @SceneStorage("tab.launchID") private var savedLaunchID = ""
    @State private var selection: AppTab
    @State private var selectionResolved = false
    private let theme = ThemeReader()
    private static let launchID = UUID().uuidString

    init() {
        PrefKey.migrateRetiredLatencyTweaks()
        _selection = State(initialValue: OpeningScreen.current().tab)
    }

    var body: some View {
        ZStack {
            if selectionResolved {
                TabView(selection: $selection) {
                    ForEach(AppTab.allCases) { tab in
                        content(tab)
                            .themedBar(.tabBar)
                            .safeAreaInset(edge: .bottom) {
                                if session.presentation == .mini { Color.clear.frame(height: 74) }
                            }
                            .tabItem { Label(tab.label, systemImage: tab.systemImage) }
                            .tag(tab)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(theme.accentText)
        .background(theme.background.ignoresSafeArea())
        .modifier(LocalDiagnosticsObserver())
        .onAppear {
            let tab = TabRestoration.resolve(savedTab: savedTab, savedLaunchID: savedLaunchID,
                                             currentLaunchID: Self.launchID, opening: OpeningScreen.current())
            if tab != selection { selection = tab }
            savedTab = tab.rawValue; savedLaunchID = Self.launchID
            selectionResolved = true
        }
        .onChange(of: selection) { _, tab in
            savedTab = tab.rawValue; savedLaunchID = Self.launchID
        }
        .onChange(of: model.pendingChannel) { _, slug in
            guard let slug else { return }
            model.pendingChannel = nil
            if selection == .tweaks { selection = .following }
            guard model.visibleChannel?.lowercased() != slug.lowercased() else { return }
            model.channelRequest = ChannelRequest(tab: selection, slug: slug)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if session.presentation == .mini {
                    MiniPlayerBar().padding(.bottom, 56).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .top) {
            if let n = model.fallbackNotice {
                Button { model.fallbackNotice = nil } label: {
                    Label("Using Official API: \(n)", systemImage: "arrow.triangle.branch")
                        .font(.caption).lineLimit(2).padding(10)
                        .chromeSurface(in: Capsule())
                }
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task { try? await Task.sleep(nanoseconds: 5_000_000_000); model.fallbackNotice = nil }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { session.presentation == .full },
                                              set: { if !$0 && session.presentation == .full { session.minimize() } })) {
            PlayerScreen()
                .environmentObject(model)
                .environmentObject(model.auth)
                .environmentObject(model.webSession)
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .compatPresentationBackground(.black)
        }
        .sheet(isPresented: $model.showTweaks) { TweakSheet().environmentObject(model).environmentObject(session).environmentObject(model.webSession) }
        .animation(.spring(duration: 0.3), value: session.presentation)
        .background(theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func content(_ tab: AppTab) -> some View {
        switch tab {
        case .following: FollowingView()
        case .browse: BrowseView()
        case .saved: SavedClipsView()
        case .tweaks: TweaksTab()
        }
    }
}

struct ChannelRequest: Equatable {
    let id = UUID()
    let tab: AppTab
    let slug: String
}

struct ChannelRequestRoute: ViewModifier {
    @EnvironmentObject var model: AppModel
    let tab: AppTab
    @Binding var path: NavigationPath

    func body(content: Content) -> some View {
        content.onChange(of: model.channelRequest, initial: true) { _, request in
            guard let request, request.tab == tab else { return }
            model.channelRequest = nil
            path.append(request.slug)
        }
    }
}

enum Play {
    static func live(_ c: ChannelDetail) -> NowPlaying {
        NowPlaying(kind: .live, title: c.title ?? c.displayName, channelSlug: c.slug, channelName: c.displayName,
                   streamURL: c.hlsURL, embedSlug: c.slug, thumbnailURL: c.thumbnailURL, artworkURL: c.avatarURL, chat: c.chatTarget,
                   savedItem: c.asSaved, liveStartedAt: c.startedAt)
    }

    static func vod(_ v: VODItem, channel c: ChannelDetail, at offset: Double = 0) -> NowPlaying {
        NowPlaying(kind: .vod, title: v.title, channelSlug: c.slug, channelName: c.displayName, streamURL: v.sourceURL,
                   embedSlug: nil, startOffset: offset, thumbnailURL: v.thumbnailURL, artworkURL: c.avatarURL, chat: nil,
                   savedItem: SavedClip(id: "vod:\(v.uuid ?? String(v.id))", kind: .vod, title: v.title, channelSlug: c.slug,
                                        channelName: c.displayName, thumbnailURL: v.thumbnailURL?.absoluteString, artworkURL: c.avatarURL?.absoluteString,
                                        playbackURL: v.sourceURL?.absoluteString, videoUUID: v.uuid, duration: v.duration),
                   knownDuration: v.duration,
                   vodReplay: VODChatReplayTarget.make(vod: v, channel: c))
    }

    static func clip(_ k: ClipItem, slug: String, name: String, artworkURL: URL? = nil) -> NowPlaying {
        NowPlaying(kind: .clip, title: k.title, channelSlug: slug, channelName: name, streamURL: k.playbackURL,
                   embedSlug: nil, thumbnailURL: k.thumbnailURL, artworkURL: artworkURL, chat: nil,
                   savedItem: SavedClip(id: "clip:\(k.id)", kind: .clip, title: k.title, channelSlug: slug, channelName: name,
                                        thumbnailURL: k.thumbnailURL?.absoluteString, artworkURL: artworkURL?.absoluteString, playbackURL: k.playbackURL?.absoluteString,
                                        duration: k.duration),
                   knownDuration: k.duration)
    }
}
