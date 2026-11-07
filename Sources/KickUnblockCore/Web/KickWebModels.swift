import Foundation

public struct FlexibleInt: Decodable, Hashable, Sendable {
    public let value: Int?
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else if let d = try? c.decode(Double.self) { value = Int(d) }
        else { value = nil }
    }
}

public struct FlexibleID: Decodable, Hashable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else { value = "" }
    }
}

public struct LenientBool: Decodable, Hashable, Sendable {
    public let value: Bool
    public init(_ value: Bool) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i != 0 }
        else if let s = try? c.decode(String.self) { value = ["true", "1", "yes"].contains(s.lowercased()) }
        else { value = !c.decodeNil() }
    }
}

public enum KickWebDate {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ChatMessage.parseDate(s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

public struct WebCategoryRef: Decodable, Hashable, Sendable {
    public let id: Int?
    public let name: String
    public let slug: String?
}

public struct WebChannelLivestream: Decodable, Hashable, Sendable {
    public let data: Live?
    public struct Live: Decodable, Hashable, Sendable {
        public let id: Int?
        public let session_title: String?
        public let viewers: Int?
        public let thumbnail: WebImage?
        public var thumbnailURL: URL? { thumbnail?.imageCandidates.first }
    }
}

public struct WebChannel: Decodable, Hashable, Sendable {
    public let id: Int
    public let user_id: Int?
    public let slug: String
    public let playback_url: String?
    public let followers_count: FlexibleInt?
    public let livestream: Livestream?
    public let user: User?
    public let chatroom: Chatroom?
    public let verified: LenientBool?
    public let banner_image: WebImage?
    public let offline_banner_image: WebImage?

    public struct Livestream: Decodable, Hashable, Sendable {
        public let id: Int
        public let slug: String?
        public let session_title: String?
        public let is_live: Bool?
        public let start_time: String?
        public let language: String?
        public let is_mature: Bool?
        public let viewer_count: Int?
        public let thumbnail: Thumb?
        public let categories: [WebCategoryRef]?
        public typealias Thumb = WebImage
        public var startedAt: Date? { KickWebDate.parse(start_time) }
        public var thumbnailURL: URL? { thumbnail?.imageCandidates.first }
    }
    public struct User: Decodable, Hashable, Sendable {
        public let id: Int?
        public let username: String
        public let bio: String?
        public let profile_pic: String?
    }
    public struct Chatroom: Decodable, Hashable, Sendable {
        public let id: Int
    }

    public var artworkURL: URL? { ImageURLSanitizer.url(from: user?.profile_pic) }
    public var displayName: String { user?.username ?? slug }
    public var isLive: Bool { livestream?.is_live == true }
    public var hlsURL: URL? { isLive ? playback_url.flatMap(URL.init(string:)) : nil }
    public var broadcasterUserID: Int? { user_id ?? user?.id }
    public var previewImageCandidates: [URL] { previewImageCandidates(liveThumbnail: nil) }

    public func previewImageCandidates(liveThumbnail: WebImage?) -> [URL] {
        let urls = (liveThumbnail?.imageCandidates ?? []) + (livestream?.thumbnail?.imageCandidates ?? [])
            + (offline_banner_image?.imageCandidates ?? [])
            + (banner_image?.imageCandidates ?? [])
        var result: [URL] = []
        for url in urls where !result.contains(url) { result.append(url) }
        return result
    }
}

public struct WebVideo: Decodable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let slug: String?
    public let created_at: String?
    public let session_title: String?
    public let is_live: Bool?
    public let start_time: String?
    public let source: String?
    public let duration: Int?
    public let language: String?
    public let is_mature: Bool?
    public let viewer_count: Int?
    public let views: Int?
    public let thumbnail: Thumb?
    public let video: VideoRef?
    public let categories: [WebCategoryRef]?

    public struct Thumb: Decodable, Hashable, Sendable { public let src: String?; public let url: String? }
    public struct VideoRef: Decodable, Hashable, Sendable {
        public let id: Int?
        public let uuid: String?
        public let views: Int?
        public let is_private: Bool?
        public let status: String?
    }

    public var title: String { session_title ?? "Untitled broadcast" }
    public var durationSeconds: Double? { duration.map { Double($0) / 1000 } }
    public var startedAt: Date? { KickWebDate.parse(start_time ?? created_at) }
    public var thumbnailURL: URL? { (thumbnail?.src ?? thumbnail?.url).flatMap(URL.init(string:)) }
    public var sourceURL: URL? { source.flatMap(URL.init(string:)) }
    public var uuid: String? { video?.uuid }
    public var isFinishedVOD: Bool { is_live != true && video?.is_private != true }
}

public struct WebVideoDetail: Decodable, Hashable, Sendable {
    public let id: Int?
    public let uuid: String?
    public let views: Int?
    public let is_private: Bool?
    public let source: String?
    public let livestream: Livestream?
    public struct Livestream: Decodable, Hashable, Sendable {
        public let session_title: String?
        public let duration: FlexibleInt?
        public let start_time: String?
        public let thumbnail: String?
        public let channel: Channel?
        public struct Channel: Decodable, Hashable, Sendable { public let slug: String?; public let user: WebChannel.User? }
    }
    public var sourceURL: URL? { source.flatMap(URL.init(string:)) }
}

public struct WebClipPage: Decodable, Sendable {
    public let clips: [WebClip]
    public let nextCursor: String?
}

public struct WebClip: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let clip_url: String?
    public let video_url: String?
    public let thumbnail_url: String?
    public let views: Int?
    public let view_count: Int?
    public let duration: Double?
    public let created_at: String?
    public let is_mature: Bool?
    public let category: WebCategoryRef?
    public let creator: Creator?
    public let channel: ChannelRef?
    public struct Creator: Decodable, Hashable, Sendable { public let id: Int?; public let username: String?; public let slug: String? }
    public struct ChannelRef: Decodable, Hashable, Sendable { public let id: Int?; public let username: String?; public let slug: String? }

    public var playbackURL: URL? { (clip_url ?? video_url).flatMap(URL.init(string:)) }
    public var thumbnailURL: URL? { thumbnail_url.flatMap(URL.init(string:)) }
    public var createdAt: Date? { KickWebDate.parse(created_at) }
    public var viewTotal: Int { view_count ?? views ?? 0 }
}

public struct WebLivestreamList: Decodable, Sendable {
    public let data: Payload
    public struct Payload: Decodable, Sendable {
        public let livestreams: [WebLivestreamCard]
        public let pagination: Pagination?
    }
    public struct Pagination: Decodable, Sendable { public let next_cursor: String? }
}

public struct WebLivestreamCard: Decodable, Hashable, Sendable, Identifiable {
    public let id: FlexibleID
    public let title: String?
    public let viewer_count: Int?
    public let thumbnail: Thumb?
    public let start_time: String?
    public let channel: Channel
    public let category: WebCategoryRef?
    public let language: String?
    public let is_mature: Bool?
    public let tags: [String]?
    public struct Thumb: Decodable, Hashable, Sendable { public let src: String? }
    public struct Channel: Decodable, Hashable, Sendable {
        public let id: Int?
        public let slug: String
        public let profile_pic: String?
        public let username: String?
    }
    public var thumbnailURL: URL? { thumbnail?.src.flatMap(URL.init(string:)) }
    public var startedAt: Date? { KickWebDate.parse(start_time) }
}

public struct WebStreamPage: Decodable, Sendable {
    public let current_page: Int?
    public let data: [Item]
    public let next_page_url: String?

    public var hasMore: Bool { next_page_url?.isEmpty == false && !data.isEmpty }

    public func items(inSubcategory id: Int?, slug: String) -> [Item]? {
        guard !data.isEmpty else { return [] }
        let tagged = data.filter { $0.categories?.isEmpty == false }
        guard !tagged.isEmpty else { return data }
        func belongs(_ i: Item) -> Bool {
            guard let cats = i.categories, !cats.isEmpty else { return true }
            return cats.contains { c in (id != nil && c.id == id) || c.slug == slug }
        }
        let kept = data.filter(belongs)
        return kept.isEmpty ? nil : kept
    }

    public struct Item: Decodable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let session_title: String?
        public let start_time: String?
        public let language: String?
        public let is_mature: Bool?
        public let viewer_count: Int?
        public let thumbnail: Thumb?
        public let channel: Channel?
        public let categories: [WebCategoryRef]?
        public struct Thumb: Decodable, Hashable, Sendable { public let src: String?; public let url: String? }
        public struct Channel: Decodable, Hashable, Sendable {
            public let id: Int?
            public let slug: String
            public let user: User?
            public struct User: Decodable, Hashable, Sendable { public let username: String?; public let profilepic: String? }
        }
        public var thumbnailURL: URL? { (thumbnail?.src ?? thumbnail?.url).flatMap(URL.init(string:)) }
        public var startedAt: Date? { KickWebDate.parse(start_time) }
    }
}

public struct WebSubcategoryPage: Decodable, Sendable {
    public let current_page: Int?
    public let data: [WebCategory]
    public let next_page_url: String?
    public let last_page: Int?

    public var hasMore: Bool {
        if next_page_url?.isEmpty == false { return true }
        if let c = current_page, let l = last_page { return c < l }
        return false
    }
}

public struct WebCategory: Decodable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let slug: String
    public let tags: [String]?
    public let viewers: Int?
    public let is_mature: Bool?
    public let banner: Banner?
    public let icon: String?
    public let category: Parent?

    public struct Parent: Decodable, Hashable, Sendable {
        public let id: Int?
        public let name: String?
        public let slug: String?
        public let icon: String?
    }

    public struct Banner: Decodable, Hashable, Sendable {
        public let responsive: String?
        public let url: String?
        public let src: String?
        public init(responsive: String? = nil, url: String? = nil, src: String? = nil) {
            self.responsive = responsive; self.url = url; self.src = src
        }
        enum K: String, CodingKey { case responsive, url, src, srcset }
        public init(from d: Decoder) throws {
            if let s = try? d.singleValueContainer().decode(String.self) { self.init(url: s); return }
            let c = try d.container(keyedBy: K.self)
            self.init(responsive: (try? c.decode(String.self, forKey: .responsive)) ?? (try? c.decode(String.self, forKey: .srcset)),
                      url: try? c.decode(String.self, forKey: .url), src: try? c.decode(String.self, forKey: .src))
        }
    }

    enum K: String, CodingKey { case id, name, slug, tags, viewers, is_mature, banner, icon, category }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = (try? c.decode(String.self, forKey: .slug)) ?? String(id)
        tags = try? c.decode([String].self, forKey: .tags)
        viewers = (try? c.decode(FlexibleInt.self, forKey: .viewers))?.value
        is_mature = try? c.decode(Bool.self, forKey: .is_mature)
        banner = try? c.decode(Banner.self, forKey: .banner)
        icon = try? c.decode(String.self, forKey: .icon)
        category = try? c.decode(Parent.self, forKey: .category)
    }

    public var imageCandidates: [URL] {
        var out: [URL] = []
        for raw in [banner?.responsive, banner?.url, banner?.src, icon, category?.icon] {
            if let u = ImageURLSanitizer.url(from: raw), !out.contains(u) { out.append(u) }
        }
        return out
    }

    public var bannerURL: URL? { imageCandidates.first }

    public var placeholderSymbol: String? {
        [icon, category?.icon].compactMap { $0 }.first { s in !s.isEmpty && !s.contains("/") && s.count <= 4 }
    }
}

public struct WebSearchResult: Decodable, Sendable {
    public let channels: [Channel]?
    public struct Channel: Decodable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let slug: String
        public let isLive: Bool?
        public let followersCount: FlexibleInt?
        public let user: User?
        public struct User: Decodable, Hashable, Sendable { public let id: Int?; public let username: String?; public let profilePic: String? }
        public var displayName: String { user?.username ?? slug }
    }
}
