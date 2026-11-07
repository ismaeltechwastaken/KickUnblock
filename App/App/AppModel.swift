import SwiftUI
import KickUnblockCore

@MainActor
final class AppModel: ObservableObject {
    let auth = AuthManager()
    let webSession = KickWebSession()
    let follows = FollowStore()
    let savedStore = SavedClipStore()
    let web = KickWebClient()
    let router = ProviderRouter()
    let playback = PlaybackSession()

    @Published var followed: [FollowedChannel] = []
    @Published var saved: [SavedClip] = []
    @Published var globalEmotes: EmoteIndex = .empty
    @Published var fallbackNotice: String?
    @Published var showTweaks = false
    @Published var pendingChannel: String?
    @Published var channelRequest: ChannelRequest?
    var visibleChannel: String?

    lazy var api = KickAPIClient(token: { [auth] in try await auth.validAccessToken() })

    func bootstrap() async {
        followed = follows.all()
        saved = savedStore.all()
        if let tpl = UserDefaults.standard.string(forKey: PrefKey.kickEmoteURLTemplate), !tpl.isEmpty {
            KickEmoteCDN.urlTemplate = tpl
        }
        await reloadGlobalEmotes()
    }

    // MARK: follows & saved

    func isFollowing(_ slug: String) -> Bool { followed.contains { $0.slug == slug.lowercased() } }

    func toggleFollow(slug: String, id: Int?, name: String, avatar: String?) {
        if follows.isFollowing(slug) { follows.unfollow(slug) }
        else { follows.follow(FollowedChannel(slug: slug, broadcasterUserID: id, displayName: name, avatarURL: avatar)) }
        followed = follows.all()
    }

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }
    func toggleSaved(_ item: SavedClip) { savedStore.toggle(item); saved = savedStore.all() }
    func removeSaved(_ id: String) { savedStore.remove(id); saved = savedStore.all() }

    func clearAllLocalData() {
        playback.close()
        PrefKey.clearAll()
        auth.signOut()
        auth.clearCredentials()
        Task { await webSession.signOut() }
        router.reset()
        URLCache.shared.removeAllCachedResponses()
        EmoteDataCache.shared.removeAll()
        followed = []; saved = []
    }

    // MARK: emotes

    func reloadGlobalEmotes() async {
        let d = UserDefaults.standard
        var idx = EmoteIndex.empty
        if d.bool(PrefKey.emotes7TV, default: TweakDefault.emotes7TV) {
            idx = idx.merging(await Self.fetch(SevenTV.globalSetURL) { SevenTV.index(from: try JSONDecoder().decode(SevenTV.EmoteSet.self, from: $0)) })
        }
        if d.bool(PrefKey.emotesBTTVFFZ, default: TweakDefault.emotesBTTVFFZ) {
            idx = idx.merging(await Self.fetch(BTTV.globalURL) { BTTV.index(try JSONDecoder().decode([BTTV.Emote].self, from: $0)) })
            idx = idx.merging(await Self.fetch(FFZ.globalURL) { FFZ.index(try JSONDecoder().decode(FFZ.Global.self, from: $0)) })
        }
        globalEmotes = idx
    }

    static func fetchSevenTVChannel(kickUserID: Int) async -> SevenTVChannel {
        guard let (data, resp) = try? await URLSession.shared.data(from: SevenTV.kickUserURL(kickUserID: kickUserID)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let c = try? JSONDecoder().decode(SevenTV.UserConnection.self, from: data) else { return .empty }
        return SevenTV.channel(from: c)
    }

    private static func fetch(_ url: URL, _ parse: (Data) throws -> EmoteIndex) async -> EmoteIndex {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .empty }
        return (try? parse(data)) ?? .empty
    }
}
