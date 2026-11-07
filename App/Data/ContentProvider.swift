import Foundation
import KickUnblockCore

struct StreamCard: Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let channelName: String
    let title: String
    let viewers: Int?
    let thumbnailURL: URL?
    let avatarURL: URL?
    let category: String?
    let isMature: Bool
    let startedAt: Date?
}

struct CategoryCard: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let viewers: Int?
    let imageURLs: [URL]
    var symbol: String? = nil
    var slug: String? = nil
}

struct ChannelDetail: Hashable {
    let slug: String
    let displayName: String
    let channelID: Int?
    let chatroomID: Int?
    let broadcasterUserID: Int?
    let avatarURL: URL?
    let bannerURL: URL?
    let title: String?
    let isLive: Bool
    let viewers: Int?
    let category: String?
    let startedAt: Date?
    let thumbnailURL: URL?
    let hlsURL: URL?
    let followers: Int?
    let source: ProviderRouter.Choice
    var verified: Bool = false
    var language: String? = nil
    var previewFallbacks: [URL] = []

    var chatTarget: ChatTarget {
        ChatTarget(channelID: channelID, chatroomID: chatroomID, broadcasterUserID: broadcasterUserID, slug: slug)
    }
}

struct VODItem: Identifiable, Hashable {
    let id: Int
    let uuid: String?
    let title: String
    let thumbnailURL: URL?
    let duration: Double?
    let startedAt: Date?
    let views: Int?
    let sourceURL: URL?
}

struct ClipItem: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbnailURL: URL?
    let playbackURL: URL?
    let duration: Double?
    let views: Int
    let createdAt: Date?
    let creator: String?
    let category: String?
}

enum ContentError: LocalizedError {
    case needsWebsiteData(String)
    var errorDescription: String? {
        switch self { case .needsWebsiteData(let what): "\(what) needs Website data. The official API doesn't support it." }
    }
}

extension AppModel {
    var preferredSource: DataSource {
        DataSource(rawValue: UserDefaults.standard.string(PrefKey.dataSource, default: TweakDefault.dataSource)) ?? .website
    }

    func load<T>(website: () async throws -> T, official: () async throws -> T) async throws -> T {
        guard router.choice(preferred: preferredSource) == .website else { return try await official() }
        do { return try await website() }
        catch let e as KickWebError where e.isBlocked {
            router.report(e)
            fallbackNotice = e.localizedDescription
            return try await official()
        }
    }

    // MARK: browse

    func categories(page: Int) async throws -> (items: [CategoryCard], hasMore: Bool) {
        try await load(website: {
            let p = try await web.categories(page: page)
            return (p.data.map { CategoryCard(id: $0.id, name: $0.name, viewers: $0.viewers, imageURLs: $0.imageCandidates, symbol: $0.placeholderSymbol, slug: $0.slug) },
                    p.hasMore)
        }, official: {
            guard page == 1 else { return ([], false) }
            let p = try await api.categories(limit: 100)
            return (p.data.map { CategoryCard(id: $0.id, name: $0.name, viewers: $0.viewer_count, imageURLs: [ImageURLSanitizer.url(from: $0.thumbnail)].compactMap { $0 }) }, false)
        })
    }

    func liveStreams(category: CategoryCard?, cursor: String?) async throws -> (items: [StreamCard], next: String?) {
        do { return try await categoryStreams(category: category, cursor: cursor) }
        catch { throw CategoryListError.map(error, websiteBlocked: router.isFallingBack) }
    }
    private func categoryStreams(category: CategoryCard?, cursor: String?) async throws -> (items: [StreamCard], next: String?) {
        guard let category, let slug = category.slug, !slug.isEmpty else {
            return try await liveStreams(categoryID: category?.id, cursor: cursor)
        }
        if cursor == nil || cursor?.hasPrefix(Self.pageCursorPrefix) == true,
           router.choice(preferred: preferredSource) == .website {
            let page = cursor.flatMap { Int($0.dropFirst(Self.pageCursorPrefix.count)) } ?? 1
            do {
                let p = try await web.livestreams(subcategory: slug, page: page)
                if let items = p.items(inSubcategory: category.id > 0 ? category.id : nil, slug: slug),
                   !items.isEmpty || page > 1 {
                    return (items.map(Self.card), p.hasMore && !items.isEmpty ? "\(Self.pageCursorPrefix)\(page + 1)" : nil)
                }
            } catch let e as KickWebError where e.isBlocked {
                router.report(e)
                fallbackNotice = e.localizedDescription
                return try await liveStreams(categoryID: category.id, cursor: nil)
            } catch {
            }
            let id = (try? await web.subcategory(slug: slug).id) ?? category.id
            return try await liveStreams(categoryID: id, cursor: nil)
        }
        return try await liveStreams(categoryID: category.id, cursor: cursor)
    }

    static let pageCursorPrefix = "page:"

    func liveStreams(categoryID: Int?, cursor: String?) async throws -> (items: [StreamCard], next: String?) {
        try await load(website: {
            let l = try await web.livestreams(categoryID: categoryID, cursor: cursor)
            return (l.data.livestreams.map(Self.card), l.data.pagination?.next_cursor)
        }, official: {
            let p = try await api.livestreams(categoryIDs: categoryID.map { [$0] } ?? [], cursor: cursor)
            return (p.data.map(Self.card), p.pagination?.next_cursor)
        })
    }

    func search(_ term: String) async throws -> [StreamCard] {
        guard let q = ChannelSearch.query(term) else { return [] }
        return try await load(website: {
            (try await web.search(q).channels ?? []).map {
                StreamCard(id: "s\($0.id)", slug: $0.slug, channelName: $0.displayName, title: $0.isLive == true ? "Live now" : "\(DisplayFormat.compactCount($0.followersCount?.value ?? 0)) followers",
                           viewers: nil, thumbnailURL: nil, avatarURL: $0.user?.profilePic.flatMap(URL.init(string:)),
                           category: nil, isMature: false, startedAt: $0.isLive == true ? Date() : nil)
            }
        }, official: {
            try await api.channels(slugs: [q.lowercased()]).map {
                StreamCard(id: "s\($0.id)", slug: $0.slug, channelName: $0.slug, title: $0.stream_title ?? "",
                           viewers: $0.stream?.viewer_count, thumbnailURL: $0.stream?.thumbnail.flatMap(URL.init(string:)),
                           avatarURL: nil, category: $0.category?.name, isMature: $0.stream?.is_mature ?? false,
                           startedAt: $0.stream?.is_live == true ? Date() : nil)
            }
        })
    }

    // MARK: channel

    func channel(_ slug: String) async throws -> ChannelDetail {
        try await load(website: {
            async let liveRequest = try? web.channelLivestream(slug)
            let c = try await web.channel(slug)
            let ls = c.livestream
            let fetchedLive = await liveRequest
            let live = c.isLive ? fetchedLive ?? nil : nil
            let preview = c.previewImageCandidates(liveThumbnail: live?.thumbnail)
            let banner = (c.offline_banner_image?.imageCandidates.first ?? c.banner_image?.imageCandidates.first)
            return ChannelDetail(slug: c.slug, displayName: c.displayName, channelID: c.id, chatroomID: c.chatroom?.id,
                                 broadcasterUserID: c.broadcasterUserID, avatarURL: c.artworkURL,
                                 bannerURL: banner, title: ls?.session_title ?? live?.session_title, isLive: c.isLive,
                                 viewers: ls?.viewer_count ?? live?.viewers,
                                 category: ls?.categories?.first?.name, startedAt: ls?.startedAt, thumbnailURL: preview.first,
                                 hlsURL: c.hlsURL, followers: c.followers_count?.value, source: .website,
                                 verified: c.verified?.value ?? false, language: ls?.language,
                                 previewFallbacks: Array(preview.dropFirst()))
        }, official: {
            guard let c = try await api.channels(slugs: [slug.lowercased()]).first else { throw KickWebError.notFound }
            let profiles = try? await api.users(ids: [c.broadcaster_user_id])
            let profile = profiles?.first { $0.user_id == c.broadcaster_user_id }
            return ChannelDetail(slug: c.slug, displayName: c.slug, channelID: nil, chatroomID: nil,
                                 broadcasterUserID: c.broadcaster_user_id, avatarURL: ImageURLSanitizer.url(from: profile?.profile_picture),
                                 bannerURL: c.banner_picture.flatMap(URL.init(string:)), title: c.stream_title,
                                 isLive: c.stream?.is_live == true, viewers: c.stream?.viewer_count, category: c.category?.name,
                                 startedAt: KickWebDate.parse(c.stream?.start_time), thumbnailURL: c.stream?.thumbnail.flatMap(URL.init(string:)),
                                 hlsURL: nil, followers: nil, source: .official)
        })
    }

    func vods(_ slug: String) async throws -> [VODItem] {
        try await load(website: {
            try await web.videos(slug).filter(\.isFinishedVOD).map {
                VODItem(id: $0.id, uuid: $0.uuid, title: $0.title, thumbnailURL: $0.thumbnailURL, duration: $0.durationSeconds,
                        startedAt: $0.startedAt, views: $0.views ?? $0.video?.views, sourceURL: $0.sourceURL)
            }
        }, official: { throw ContentError.needsWebsiteData("Past broadcasts") })
    }

    func clips(_ slug: String, cursor: String?) async throws -> (items: [ClipItem], next: String?) {
        try await load(website: {
            let p = try await web.clips(slug, cursor: cursor)
            return (p.clips.map {
                ClipItem(id: $0.id, title: $0.title ?? "Clip", thumbnailURL: $0.thumbnailURL, playbackURL: $0.playbackURL,
                         duration: $0.duration, views: $0.viewTotal, createdAt: $0.createdAt, creator: $0.creator?.username,
                         category: $0.category?.name)
            }, p.nextCursor)
        }, official: { throw ContentError.needsWebsiteData("Clips") })
    }

    func vodSource(uuid: String) async throws -> URL {
        let d = try await web.video(uuid: uuid)
        guard let u = d.sourceURL else { throw KickWebError.notFound }
        return u
    }

    // MARK: mapping

    static func card(_ l: WebLivestreamCard) -> StreamCard {
        StreamCard(id: l.id.value, slug: l.channel.slug, channelName: l.channel.username ?? l.channel.slug,
                   title: l.title ?? "", viewers: l.viewer_count, thumbnailURL: l.thumbnailURL,
                   avatarURL: l.channel.profile_pic.flatMap(URL.init(string:)), category: l.category?.name,
                   isMature: l.is_mature ?? false, startedAt: l.startedAt)
    }

    static func card(_ l: WebStreamPage.Item) -> StreamCard {
        let slug = l.channel?.slug ?? ""
        return StreamCard(id: "\(l.id)", slug: slug, channelName: l.channel?.user?.username ?? slug,
                          title: l.session_title ?? "", viewers: l.viewer_count, thumbnailURL: l.thumbnailURL,
                          avatarURL: l.channel?.user?.profilepic.flatMap(URL.init(string:)),
                          category: l.categories?.first?.name, isMature: l.is_mature ?? false, startedAt: l.startedAt)
    }

    static func card(_ l: KickLivestream) -> StreamCard {
        StreamCard(id: l.id, slug: l.channel.slug, channelName: l.broadcaster_user.username, title: l.title ?? "",
                   viewers: l.viewer_count, thumbnailURL: l.thumbnail.flatMap(URL.init(string:)),
                   avatarURL: l.broadcaster_user.profile_picture.flatMap(URL.init(string:)), category: l.category?.name,
                   isMature: l.has_mature_content ?? false, startedAt: KickWebDate.parse(l.started_at))
    }
}

extension ChannelDetail {
    var asSaved: SavedClip {
        SavedClip(id: "channel:\(slug)", kind: .channel, title: title ?? displayName, channelSlug: slug,
                  channelName: displayName, thumbnailURL: avatarURL?.absoluteString, artworkURL: avatarURL?.absoluteString)
    }
}
