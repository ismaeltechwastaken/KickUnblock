import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KickAPIClient: Sendable {
    public static let baseURL = URL(string: "https://api.kick.com")!

    public enum APIError: Error, Equatable {
        case notAuthenticated
        case http(Int, String)
    }

    public typealias TokenProvider = @Sendable () async throws -> String?

    private let session: URLSession
    private let token: TokenProvider

    public init(session: URLSession = .shared, token: @escaping TokenProvider) {
        self.session = session
        self.token = token
    }

    // MARK: Requests (all from docs.kick.com / swagger)

    public func channels(slugs: [String]) async throws -> [KickChannel] {
        let q = slugs.map { URLQueryItem(name: "slug", value: $0) }
        let env: KickEnvelope<[KickChannel]> = try await get("/public/v1/channels", q)
        return env.data
    }

    public func channels(broadcasterIDs: [Int]) async throws -> [KickChannel] {
        let q = broadcasterIDs.map { URLQueryItem(name: "broadcaster_user_id", value: String($0)) }
        let env: KickEnvelope<[KickChannel]> = try await get("/public/v1/channels", q)
        return env.data
    }

    public func livestreams(categoryIDs: [Int] = [], languages: [String] = [],
                            limit: Int = 25, cursor: String? = nil) async throws -> KickPage<KickLivestream> {
        try await get("/public/v2/livestreams", Self.livestreamsQuery(categoryIDs: categoryIDs, languages: languages, limit: limit, cursor: cursor))
    }

    static func livestreamsQuery(categoryIDs: [Int], languages: [String], limit: Int, cursor: String?) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        q += categoryIDs.prefix(25).map { .init(name: "category_id", value: String($0)) }
        q += languages.map { .init(name: "language_code", value: $0) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return q
    }

    public func liveStreams(forUserIDs ids: [Int]) async throws -> [KickLivestream] {
        guard !ids.isEmpty else { return [] }
        var out: [KickLivestream] = []
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let env: KickEnvelope<[KickLivestream]> = try await get("/public/v1/users/livestreams",
                                                                   chunk.map { .init(name: "user_id", value: String($0)) })
            out += env.data
        }
        return out
    }

    public func categories(name: String? = nil, tag: String? = nil, limit: Int? = nil, cursor: String? = nil) async throws -> KickPage<KickCategory> {
        var q: [URLQueryItem] = []
        if let name { q.append(.init(name: "name", value: name)) }
        if let tag { q.append(.init(name: "tag", value: tag)) }
        if let limit { q.append(.init(name: "limit", value: String(limit))) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/public/v2/categories", q)
    }

    public func category(id: Int) async throws -> KickCategory {
        let env: KickEnvelope<KickCategory> = try await get("/public/v1/categories/\(id)", [])
        return env.data
    }

    public func currentUser() async throws -> KickUser? {
        let env: KickEnvelope<[KickUser]> = try await get("/public/v1/users", [])
        return env.data.first
    }

    public func users(ids: [Int]) async throws -> [KickUser] {
        guard !ids.isEmpty else { return [] }
        let env: KickEnvelope<[KickUser]> = try await get("/public/v1/users", ids.map { .init(name: "id", value: String($0)) })
        return env.data
    }

    public func sendChat(_ body: KickPostChat) async throws -> KickChatResponse {
        var req = try await request("/public/v1/chat", [])
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let env: KickEnvelope<KickChatResponse> = try await send(req)
        return env.data
    }

    // MARK: Plumbing

    public func makeURL(_ path: String, _ query: [URLQueryItem]) -> URL {
        var c = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    private func request(_ path: String, _ query: [URLQueryItem]) async throws -> URLRequest {
        guard let bearer = try await token() else { throw APIError.notAuthenticated }
        var req = URLRequest(url: makeURL(path, query))
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        try await send(try await request(path, query))
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
