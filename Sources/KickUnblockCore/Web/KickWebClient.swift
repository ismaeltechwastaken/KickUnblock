import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum KickWebError: Error, Equatable, LocalizedError {
    case blocked(status: Int)
    case notFound
    case http(Int)
    case decoding(String)
    case offline(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let s): "kick.com blocked the request (HTTP \(s)). Switched to the official API."
        case .notFound: "Not found on kick.com."
        case .http(let s): "kick.com returned HTTP \(s)."
        case .decoding(let m): "Unexpected response from kick.com (\(m))."
        case .offline(let m): m
        }
    }
    public var isBlocked: Bool { if case .blocked = self { true } else { false } }
}

public enum ChannelSearch {
    public static let minimumLength = 3
    public static func query(_ text: String) -> String? {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count >= minimumLength ? q : nil
    }
    public static func isQuiet(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if case .http(400)? = error as? KickWebError { return true }
        return false
    }
}

public enum KickWebEndpoint {
    public static let site = URL(string: "https://kick.com")!
    public static let webAPI = URL(string: "https://web.kick.com/api")!

    public static func channel(_ slug: String) -> URL { site.appendingPathComponent("api/v2/channels/\(slug.lowercased())") }
    public static func videos(_ slug: String) -> URL { site.appendingPathComponent("api/v2/channels/\(slug.lowercased())/videos") }
    public static func channelLivestream(_ slug: String) -> URL { site.appendingPathComponent("api/v2/channels/\(slug.lowercased())/livestream") }
    public static func clips(_ slug: String, cursor: String? = nil, sort: String = "date") -> URL {
        var c = URLComponents(url: site.appendingPathComponent("api/v2/channels/\(slug.lowercased())/clips"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "sort", value: sort)] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return c.url!
    }
    public static func video(uuid: String) -> URL { site.appendingPathComponent("api/v1/video/\(uuid)") }
    public static func subcategories(page: Int, limit: Int = BrowseGrid.pageSize) -> URL {
        var c = URLComponents(url: site.appendingPathComponent("api/v1/subcategories"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "limit", value: "\(limit)")]
        return c.url!
    }
    public static func livestreams(categoryID: Int? = nil, cursor: String? = nil, limit: Int = 24) -> URL {
        var c = URLComponents(url: webAPI.appendingPathComponent("v1/livestreams"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "sort", value: "viewer_count_desc")]
        if let categoryID { q.append(URLQueryItem(name: "category_id", value: "\(categoryID)")) }
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        c.queryItems = q
        return c.url!
    }
    public static func livestreams(subcategory slug: String, page: Int = 1, limit: Int = 28) -> URL {
        var c = URLComponents(url: site.appendingPathComponent("stream/livestreams/en"), resolvingAgainstBaseURL: false)!
        c.percentEncodedQueryItems = [URLQueryItem(name: "page", value: "\(max(1, page))"), URLQueryItem(name: "limit", value: "\(limit)"),
                                      URLQueryItem(name: "subcategory", value: strictQueryEncode(slug)), URLQueryItem(name: "sort", value: "desc")]
        return c.url!
    }
    public static func subcategory(slug: String) -> URL { site.appendingPathComponent("api/v1/subcategories/\(slug)") }

    public static func strictQueryEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    public static func emotes(slug: String) -> URL { site.appendingPathComponent("emotes/\(slug.lowercased())") }
    public static func search(_ term: String) -> URL {
        var c = URLComponents(url: site.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "searched_word", value: term)]
        return c.url!
    }
}

public enum KickWebResponse {
    public static func check(status: Int, contentType: String?, body: Data) throws {
        let ct = (contentType ?? "").lowercased()
        let looksHTML = ct.contains("text/html") || body.prefix(64).drop(while: { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D }).first == UInt8(ascii: "<")
        if [403, 429, 503].contains(status) { throw KickWebError.blocked(status: status) }
        if (200..<300).contains(status), looksHTML { throw KickWebError.blocked(status: status) }
        if status == 404 { throw KickWebError.notFound }
        guard (200..<300).contains(status) else { throw KickWebError.http(status) }
    }

    public static func decode<T: Decodable>(_ type: T.Type, status: Int, contentType: String?, body: Data) throws -> T {
        try check(status: status, contentType: contentType, body: body)
        do { return try JSONDecoder().decode(T.self, from: body) }
        catch { throw KickWebError.decoding(String(describing: error).prefix(160).description) }
    }
}

public final class KickWebClient: @unchecked Sendable {
    public static let userAgent = "KickUnblock/1.0 (iOS)"
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    public static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: Self.request(url)) }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw KickWebError.offline(error.localizedDescription) }
        let http = resp as? HTTPURLResponse
        return try KickWebResponse.decode(T.self, status: http?.statusCode ?? 0,
                                          contentType: http?.value(forHTTPHeaderField: "Content-Type"), body: data)
    }

    public func emoteSets(slug: String) async throws -> KickEmoteSets {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: Self.request(KickWebEndpoint.emotes(slug: slug))) }
        catch { throw KickWebError.offline(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 404 ? KickWebError.notFound : KickWebError.blocked(status: status) }
        guard let sets = KickEmoteSets.parse(data) else { throw KickWebError.blocked(status: status) }
        return sets
    }

    public func channel(_ slug: String) async throws -> WebChannel { try await get(KickWebEndpoint.channel(slug), as: WebChannel.self) }
    public func channelLivestream(_ slug: String) async throws -> WebChannelLivestream.Live? {
        try await get(KickWebEndpoint.channelLivestream(slug), as: WebChannelLivestream.self).data
    }
    public func videos(_ slug: String) async throws -> [WebVideo] { try await get(KickWebEndpoint.videos(slug), as: [WebVideo].self) }
    public func video(uuid: String) async throws -> WebVideoDetail { try await get(KickWebEndpoint.video(uuid: uuid), as: WebVideoDetail.self) }
    public func clips(_ slug: String, cursor: String? = nil) async throws -> WebClipPage { try await get(KickWebEndpoint.clips(slug, cursor: cursor), as: WebClipPage.self) }
    public func categories(page: Int) async throws -> WebSubcategoryPage { try await get(KickWebEndpoint.subcategories(page: page), as: WebSubcategoryPage.self) }
    public func livestreams(categoryID: Int? = nil, cursor: String? = nil) async throws -> WebLivestreamList {
        try await get(KickWebEndpoint.livestreams(categoryID: categoryID, cursor: cursor), as: WebLivestreamList.self)
    }
    public func livestreams(subcategory slug: String, page: Int) async throws -> WebStreamPage {
        try await get(KickWebEndpoint.livestreams(subcategory: slug, page: page), as: WebStreamPage.self)
    }
    public func subcategory(slug: String) async throws -> WebCategory { try await get(KickWebEndpoint.subcategory(slug: slug), as: WebCategory.self) }
    public func search(_ term: String) async throws -> WebSearchResult { try await get(KickWebEndpoint.search(term), as: WebSearchResult.self) }
}

public final class ProviderRouter: @unchecked Sendable {
    public enum Choice: Equatable, Sendable { case website, official }
    public private(set) var blockedUntil: Date?
    public let cooldown: TimeInterval
    private let lock = NSLock()
    public init(cooldown: TimeInterval = 600) { self.cooldown = cooldown }

    public func choice(preferred: DataSource, now: Date = Date()) -> Choice {
        lock.lock(); defer { lock.unlock() }
        guard preferred == .website else { return .official }
        if let until = blockedUntil, now < until { return .official }
        return .website
    }
    public func report(_ error: Error, now: Date = Date()) {
        guard (error as? KickWebError)?.isBlocked == true else { return }
        lock.lock(); blockedUntil = now.addingTimeInterval(cooldown); lock.unlock()
    }
    public func reset() { lock.lock(); blockedUntil = nil; lock.unlock() }
    public var isFallingBack: Bool { lock.lock(); defer { lock.unlock() }; return blockedUntil.map { Date() < $0 } ?? false }
}
